import fs from "node:fs";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import * as acp from "@agentclientprotocol/sdk";
import { isInside, realPath } from "../util/paths.js";

const execFileAsync = promisify(execFile);

const DEFAULT_READ_BYTES = 512 * 1024;
const MAX_READ_BYTES = 4 * 1024 * 1024;
const MAX_DIFF_BYTES = 2 * 1024 * 1024;

const MIME_BY_EXT: Record<string, string> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".bmp": "image/bmp",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".pdf": "application/pdf",
};

export function mimeFor(file: string): string | undefined {
  return MIME_BY_EXT[path.extname(file).toLowerCase()];
}

/**
 * Decides which paths the phone may touch: configured workspaces plus every session cwd.
 * Paths are resolved through symlinks/junctions before the check.
 */
export class PathGuard {
  constructor(
    private readonly workspaces: () => string[],
    private readonly sessionCwds: () => string[],
    private readonly allowAllPaths: () => boolean = () => false,
    /** Readable through `resolveReadable`, never offered as workspaces (device uploads). */
    private readonly readableRoots: () => string[] = () => [],
  ) {}

  get allowsAllPaths(): boolean { return this.allowAllPaths(); }

  roots(): { path: string; source: "config" | "session" | "filesystem" }[] {
    const seen = new Set<string>();
    const out: { path: string; source: "config" | "session" | "filesystem" }[] = [];
    const add = (p: string, source: "config" | "session" | "filesystem") => {
      const real = realPath(p);
      try { if (!fs.statSync(real).isDirectory()) return; } catch { return; }
      const key = process.platform === "win32" ? real.toLowerCase() : real;
      if (seen.has(key)) return;
      seen.add(key);
      out.push({ path: real, source });
    };
    for (const w of this.workspaces()) add(w, "config");
    for (const c of this.sessionCwds()) add(c, "session");
    if (this.allowAllPaths()) {
      if (process.platform === "win32") {
        for (let letter = 65; letter <= 90; letter++) add(`${String.fromCharCode(letter)}:\\`, "filesystem");
      } else add("/", "filesystem");
    }
    return out;
  }

  resolve(p: unknown): string {
    return this.check(p, this.roots().map((r) => r.path));
  }

  /** Like `resolve`, but also allows files that devices uploaded, for previews. */
  resolveReadable(p: unknown): string {
    return this.check(p, [...this.roots().map((r) => r.path), ...this.readableRoots().map(realPath)]);
  }

  private check(p: unknown, roots: string[]): string {
    if (typeof p !== "string" || !p) throw acp.RequestError.invalidParams(undefined, "path is required");
    if (!path.isAbsolute(p)) throw acp.RequestError.invalidParams(undefined, "path must be absolute");
    const real = realPath(p);
    if (!this.allowAllPaths() && !roots.some((root) => isInside(root, real))) {
      throw acp.RequestError.invalidParams(undefined, "Path is outside the allowed workspaces");
    }
    return real;
  }

  directory(p: unknown): string {
    const dir = this.resolve(p);
    try { if (fs.statSync(dir).isDirectory()) return dir; } catch { /* Explain before starting an agent. */ }
    throw acp.RequestError.invalidParams(undefined, `Working directory does not exist or is not a directory on this bridge: ${dir}`);
  }
}

export interface DirEntry {
  name: string;
  path: string;
  type: "file" | "dir" | "link";
  size: number;
  mtime: string;
}

/** Create exactly one child in a validated existing directory; never overwrite. */
export function createDirectory(guard: PathGuard, parentPath: unknown, name: unknown) {
  const parent = guard.directory(parentPath);
  if (typeof name !== "string" || !name || name !== name.trim() || name.length > 200 ||
      /[\\/<>:"|?*\x00-\x1f]/.test(name) || name === "." || name === ".." || /[. ]$/.test(name) ||
      /^(con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\.|$)/i.test(name)) {
    throw acp.RequestError.invalidParams(undefined, "資料夾名稱不可含路徑、特殊字元或 Windows 保留名稱");
  }
  const target = path.join(parent, name);
  try { fs.mkdirSync(target, { recursive: false }); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === "EEXIST") throw acp.RequestError.invalidParams(undefined, "同名檔案或資料夾已存在，請換一個名稱");
    throw acp.RequestError.invalidParams(undefined, "無法建立資料夾，請檢查電腦上的寫入權限");
  }
  return { path: guard.directory(target), name };
}

export function listDir(guard: PathGuard, p: unknown): { path: string; parent?: string; entries: DirEntry[] } {
  const dir = guard.resolve(p);
  let dirents: fs.Dirent[];
  try {
    dirents = fs.readdirSync(dir, { withFileTypes: true });
  } catch (err) {
    throw acp.RequestError.invalidParams(undefined, `Cannot read directory: ${(err as Error).message}`);
  }
  const entries: DirEntry[] = [];
  for (const d of dirents) {
    const full = path.join(dir, d.name);
    let size = 0;
    let mtime = "";
    let type: DirEntry["type"] = d.isDirectory() ? "dir" : d.isSymbolicLink() ? "link" : "file";
    try {
      const st = fs.statSync(full);
      size = st.size;
      mtime = st.mtime.toISOString();
      if (type === "link" && st.isDirectory()) type = "dir";
    } catch {
      // broken link or no permission: still list it
    }
    entries.push({ name: d.name, path: full, type, size, mtime });
  }
  entries.sort((a, b) => (a.type === "dir") !== (b.type === "dir") ? (a.type === "dir" ? -1 : 1) : a.name.localeCompare(b.name));
  const parent = path.dirname(dir);
  let parentAllowed = false;
  try {
    parentAllowed = parent !== dir && !!guard.resolve(parent);
  } catch {
    parentAllowed = false;
  }
  return { path: dir, ...(parentAllowed ? { parent } : {}), entries };
}

export function readFile(guard: PathGuard, p: unknown, maxBytes: unknown) {
  const file = guard.resolveReadable(p);
  const limit = Math.min(typeof maxBytes === "number" && maxBytes > 0 ? maxBytes : DEFAULT_READ_BYTES, MAX_READ_BYTES);
  let st: fs.Stats;
  try {
    st = fs.statSync(file);
  } catch (err) {
    throw acp.RequestError.invalidParams(undefined, `Cannot read file: ${(err as Error).message}`);
  }
  if (!st.isFile()) throw acp.RequestError.invalidParams(undefined, "Not a file");
  const fd = fs.openSync(file, "r");
  try {
    const buf = Buffer.alloc(Math.min(limit, st.size));
    const n = fs.readSync(fd, buf, 0, buf.length, 0);
    const bytes = buf.subarray(0, n);
    const binary = bytes.subarray(0, 8192).includes(0);
    const mimeType = mimeFor(file);
    return {
      path: file,
      size: st.size,
      mtime: st.mtime.toISOString(),
      binary,
      truncated: st.size > n,
      ...(binary ? {} : { text: bytes.toString("utf8") }),
      ...(mimeType ? { mimeType } : {}),
    };
  } finally {
    fs.closeSync(fd);
  }
}

const SEARCH_LIMIT = 50;
const SEARCH_MAX_LIMIT = 200;
const SEARCH_MAX_FILES = 50_000;
const SEARCH_MAX_DIRS = 5_000;
const SEARCH_WALK_MS = 2_000;
const SEARCH_CACHE_MS = 10_000;
// Generated or vendored trees that a walk outside git should not descend into.
const SEARCH_SKIP_DIRS = new Set([".git", ".hg", ".svn", "node_modules", ".dart_tool", ".gradle", ".next", ".venv", "venv", "__pycache__", "build", "dist", "target", "Pods"]);
const projectFileCache = new Map<string, { at: number; files: string[] }>();

/** Paths relative to `cwd` (with `/`): git's tracked and unignored files, else a bounded walk. */
async function projectFiles(cwd: string): Promise<string[]> {
  const cached = projectFileCache.get(cwd);
  if (cached && Date.now() - cached.at < SEARCH_CACHE_MS) return cached.files;
  let files: string[];
  try {
    files = (await git(cwd, ["ls-files", "--cached", "--others", "--exclude-standard", "-z"])).split("\0").filter(Boolean).slice(0, SEARCH_MAX_FILES);
  } catch {
    // Not a repository (or no git): walk breadth-first without blocking other sessions for long.
    files = [];
    const pending = [""];
    const deadline = Date.now() + SEARCH_WALK_MS;
    for (let visited = 0; pending.length && files.length < SEARCH_MAX_FILES && visited < SEARCH_MAX_DIRS && Date.now() < deadline; visited++) {
      const rel = pending.shift()!;
      const dirents = await fs.promises.readdir(path.join(cwd, rel), { withFileTypes: true }).catch(() => [] as fs.Dirent[]);
      for (const d of dirents) {
        const child = rel ? `${rel}/${d.name}` : d.name;
        if (d.isDirectory()) {
          if (!SEARCH_SKIP_DIRS.has(d.name)) pending.push(child);
        } else if (files.length < SEARCH_MAX_FILES) {
          files.push(child);
        }
      }
    }
  }
  if (projectFileCache.size >= 16) projectFileCache.delete(projectFileCache.keys().next().value!);
  projectFileCache.set(cwd, { at: Date.now(), files });
  return files;
}

/** Higher is better; undefined when `query` does not match `rel` at all. */
function searchScore(rel: string, query: string): number | undefined {
  const lower = rel.toLowerCase();
  if (!query) return -rel.split("/").length;
  const base = lower.slice(lower.lastIndexOf("/") + 1);
  if (base.startsWith(query)) return 1000 - base.length;
  if (base.includes(query)) return 800 - base.indexOf(query);
  if (lower.includes(query)) return 600 - lower.indexOf(query) / 100;
  // Subsequence match, preferring characters that start a path segment or word.
  let next = 0;
  let last = -1;
  let score = 300;
  for (let i = 0; i < lower.length && next < query.length; i++) {
    if (lower[i] !== query[next]) continue;
    if (i === 0 || "/._- ".includes(lower[i - 1])) score += 10;
    if (last >= 0) score -= Math.min(i - last - 1, 10);
    last = i;
    next++;
  }
  return next === query.length ? score : undefined;
}

/** Files and folders under `cwd` for `@` mentions, best matches first. */
export async function searchFiles(guard: PathGuard, cwdParam: unknown, queryParam: unknown, limitParam: unknown) {
  const cwd = guard.resolve(cwdParam);
  if (!fs.statSync(cwd, { throwIfNoEntry: false })?.isDirectory()) throw acp.RequestError.invalidParams(undefined, "Not a directory");
  const query = (typeof queryParam === "string" ? queryParam : "").trim().replace(/\\/g, "/").toLowerCase();
  const limit = typeof limitParam === "number" && limitParam > 0 ? Math.min(Math.floor(limitParam), SEARCH_MAX_LIMIT) : SEARCH_LIMIT;
  const files = await projectFiles(cwd);
  const dirs = new Set<string>();
  for (const file of files) {
    for (let i = file.indexOf("/"); i > 0; i = file.indexOf("/", i + 1)) dirs.add(file.slice(0, i));
  }
  const ranked: { rel: string; type: "file" | "dir"; score: number }[] = [];
  for (const [list, type] of [[dirs, "dir"], [files, "file"]] as const) {
    for (const rel of list) {
      const score = searchScore(rel, query);
      if (score !== undefined) ranked.push({ rel, type, score });
    }
  }
  ranked.sort((a, b) => b.score - a.score || (a.type === b.type ? 0 : a.type === "dir" ? -1 : 1) || a.rel.length - b.rel.length || a.rel.localeCompare(b.rel));
  return {
    cwd,
    files: ranked.slice(0, limit).map((r) => ({ path: path.join(cwd, r.rel), relative: r.rel, type: r.type })),
    truncated: ranked.length > limit,
  };
}

async function git(cwd: string, args: string[]): Promise<string> {
  const { stdout } = await execFileAsync("git", ["-c", "core.quotepath=off", ...args], {
    cwd,
    windowsHide: true,
    maxBuffer: MAX_DIFF_BYTES * 2,
    encoding: "utf8",
  });
  return stdout;
}

export async function gitStatus(guard: PathGuard, cwdParam: unknown) {
  const cwd = guard.resolve(cwdParam);
  let root: string;
  try {
    root = (await git(cwd, ["rev-parse", "--show-toplevel"])).trim();
  } catch {
    return { files: [] as unknown[] };
  }
  const branch = (await git(cwd, ["rev-parse", "--abbrev-ref", "HEAD"]).catch(() => "")).trim() || undefined;
  const raw = await git(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]);
  const parts = raw.split("\0");
  const files: { path: string; index: string; worktree: string; origPath?: string }[] = [];
  for (let i = 0; i < parts.length; i++) {
    const rec = parts[i];
    if (rec.length < 4) continue;
    const index = rec[0];
    const worktree = rec[1];
    const rel = rec.slice(3);
    const entry: (typeof files)[number] = { path: path.join(root, rel), index, worktree };
    if (index === "R" || index === "C") entry.origPath = path.join(root, parts[++i] ?? "");
    files.push(entry);
  }
  return { root: path.normalize(root), branch, files };
}

export async function gitDiff(guard: PathGuard, cwdParam: unknown, fileParam: unknown, staged: unknown) {
  const cwd = guard.resolve(cwdParam);
  const file = fileParam === undefined || fileParam === null ? undefined : guard.resolve(fileParam);
  const args = ["diff", "--no-color", "--no-ext-diff"];
  if (staged === true) args.push("--cached");
  if (file) args.push("--", file);
  let diff = await git(cwd, args).catch((err: Error) => {
    throw acp.RequestError.invalidParams(undefined, `git diff failed: ${err.message}`);
  });
  if (!diff && file && staged !== true) {
    // Untracked files have no diff; show them as fully added.
    const tracked = await git(cwd, ["ls-files", "--error-unmatch", "--", file]).then(() => true, () => false);
    if (!tracked && fs.existsSync(file) && fs.statSync(file).isFile()) {
      const text = fs.readFileSync(file).subarray(0, MAX_DIFF_BYTES).toString("utf8");
      const lines = text.split("\n");
      if (lines[lines.length - 1] === "") lines.pop();
      const rel = path.relative(cwd, file).replace(/\\/g, "/");
      diff = `diff --git a/${rel} b/${rel}\nnew file\n--- /dev/null\n+++ b/${rel}\n@@ -0,0 +1,${lines.length} @@\n` + lines.map((l) => "+" + l).join("\n") + "\n";
    }
  }
  const truncated = Buffer.byteLength(diff) > MAX_DIFF_BYTES;
  return { diff: truncated ? diff.slice(0, MAX_DIFF_BYTES) : diff, truncated };
}
