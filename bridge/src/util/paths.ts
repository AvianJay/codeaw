import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const isWindows = process.platform === "win32";

/** Root of all codeaw state: config, devices, pairing codes, data. */
export function codeawHome(): string {
  return process.env.CODEAW_HOME ?? path.join(os.homedir(), ".codeaw");
}

/** Maps any string (e.g. `claude:uuid`) to a file-name-safe token. Reversible enough for debugging. */
export function safeName(id: string): string {
  return id.replace(/[^A-Za-z0-9._-]/g, (c) => "_" + c.charCodeAt(0).toString(16).padStart(2, "0"));
}

export function expandHome(p: string): string {
  if (p === "~") return os.homedir();
  if (p.startsWith("~/") || p.startsWith("~\\")) return path.join(os.homedir(), p.slice(2));
  return p;
}

/** Resolves symlinks/junctions when the path exists; otherwise just normalizes it. */
export function realPath(p: string): string {
  const abs = path.resolve(expandHome(p));
  try {
    return fs.realpathSync.native(abs);
  } catch {
    return abs;
  }
}

function comparable(p: string): string {
  const n = path.normalize(p).replace(/[\\/]+$/, "");
  return isWindows ? n.toLowerCase() : n;
}

/** True when `child` is `root` or lies below it. Both must already be absolute and resolved. */
export function isInside(root: string, child: string): boolean {
  const r = comparable(root);
  const c = comparable(child);
  if (c === r) return true;
  return c.startsWith(r + path.sep) || (isWindows && c.startsWith(r + "/"));
}

export function samePath(a: string, b: string): boolean {
  return comparable(path.resolve(a)) === comparable(path.resolve(b));
}

/** Writes via a temp file + rename so readers never see a half-written file. */
export function writeFileAtomic(file: string, data: string): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(tmp, data);
  fs.renameSync(tmp, file);
}

export function readJson<T>(file: string, fallback: T): T {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8")) as T;
  } catch {
    return fallback;
  }
}
