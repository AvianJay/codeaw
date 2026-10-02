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
  ) {}

  roots(): { path: string; source: "config" | "session" }[] {
    const seen = new Set<string>();
    const out: { path: string; source: "config" | "session" }[] = [];
    const add = (p: string, source: "config" | "session") => {
      const real = realPath(p);
      const key = process.platform === "win32" ? real.toLowerCase() : real;
      if (seen.has(key)) return;
      seen.add(key);
      out.push({ path: real, source });
    };
    for (const w of this.workspaces()) add(w, "config");
    for (const c of this.sessionCwds()) add(c, "session");
    return out;
  }

  resolve(p: unknown): string {
    if (typeof p !== "string" || !p) throw acp.RequestError.invalidParams(undefined, "path is required");
    if (!path.isAbsolute(p)) throw acp.RequestError.invalidParams(undefined, "path must be absolute");
    const real = realPath(p);
    if (!this.roots().some((r) => isInside(r.path, real))) {
      throw acp.RequestError.invalidParams(undefined, "Path is outside the allowed workspaces");
    }
    return real;
  }
}

export interface DirEntry {
  name: string;
  path: string;
  type: "file" | "dir" | "link";
  size: number;
  mtime: string;
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
  const file = guard.resolve(p);
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
