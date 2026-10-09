import fs from "node:fs";
import path from "node:path";
import type http from "node:http";
import { pipeline } from "node:stream/promises";
import { Readable } from "node:stream";
import { ZipFile } from "yazl";
import { isInside } from "../util/paths.js";
import { type PathGuard } from "./ext.js";

export const MAX_ARCHIVE_BYTES = 2 * 1024 * 1024 * 1024;
export const MAX_ARCHIVE_ENTRIES = 10_000;
export const MAX_ARCHIVE_SELECTIONS = 500;
export class DownloadError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

/** RFC 5987 preserves Unicode names without allowing HTTP header injection. */
export function attachmentHeader(name: string): string {
  const safe = path.basename(name).replace(/[\x00-\x1f\x7f]/g, "_");
  const ascii = safe.replace(/[^\x20-\x7e]|["\\]/g, "_") || "download";
  const utf8 = encodeURIComponent(safe).replace(/['()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
  return `attachment; filename="${ascii}"; filename*=UTF-8''${utf8}`;
}

export interface ArchiveEntry { file: string; name: string; stat: fs.Stats }
export async function prepareArchive(guard: PathGuard, body: any): Promise<{ name: string; entries: ArchiveEntry[] }> {
  let base: string;
  try { base = guard.directory(body?.path); }
  catch (error) { throw new DownloadError(403, (error as Error).message); }
  if (!Array.isArray(body?.paths) || !body.paths.length || body.paths.length > MAX_ARCHIVE_SELECTIONS) {
    throw new DownloadError(400, `Select between 1 and ${MAX_ARCHIVE_SELECTIONS} files or folders`);
  }
  const entries: ArchiveEntry[] = [], seen = new Set<string>();
  let bytes = 0;
  const visit = async (selected: string, depth: number): Promise<void> => {
    if (depth > 64) throw new DownloadError(400, "Folder nesting is too deep");
    const relative = path.relative(base, selected).replace(/\\/g, "/");
    if (!relative || !isInside(base, selected)) throw new DownloadError(403, "Selection is outside this directory");
    if (Buffer.byteLength(relative) > 65535 || relative.includes("\0")) throw new DownloadError(400, "Invalid archive filename");
    const key = process.platform === "win32" ? relative.toLowerCase() : relative;
    if (seen.has(key)) return;
    seen.add(key);
    let file: string;
    try { file = guard.resolveReadable(selected); }
    catch (error) { throw new DownloadError(403, (error as Error).message); }
    let stat: fs.Stats;
    try { stat = await fs.promises.stat(file); }
    catch { throw new DownloadError(404, "A selected file no longer exists or cannot be read"); }
    if (!stat.isFile() && !stat.isDirectory()) throw new DownloadError(400, "Only regular files and folders can be downloaded");
    if (entries.length >= MAX_ARCHIVE_ENTRIES) throw new DownloadError(413, `ZIP is limited to ${MAX_ARCHIVE_ENTRIES} entries`);
    if (stat.isFile()) {
      bytes += stat.size;
      if (bytes > MAX_ARCHIVE_BYTES) throw new DownloadError(413, "Selected files exceed the 2 GiB ZIP limit");
    }
    entries.push({ file, name: stat.isDirectory() ? relative + "/" : relative, stat });
    if (stat.isDirectory()) {
      let children: fs.Dirent[];
      try { children = await fs.promises.readdir(file, { withFileTypes: true }); }
      catch { throw new DownloadError(403, "Cannot read a selected folder"); }
      for (const child of children) {
        // Do not recurse through symlinks or Windows junctions within a folder.
        if (!child.isSymbolicLink()) await visit(path.join(selected, child.name), depth + 1);
      }
    }
  };
  for (const selected of body.paths) {
    if (typeof selected !== "string" || !path.isAbsolute(selected)) throw new DownloadError(400, "Selected paths must be absolute");
    await visit(path.resolve(selected), 0);
  }
  return { name: `${path.basename(base) || "files"}.zip`, entries };
}

/** ZIP STORE keeps the final size known and streams each file with backpressure. */
export async function sendArchive(res: http.ServerResponse, guard: PathGuard, body: any, inline = false): Promise<void> {
  const { name, entries } = await prepareArchive(guard, body);
  if (res.destroyed) return;
  const zip = new ZipFile();
  const output = zip.outputStream as Readable;
  let source: fs.ReadStream | undefined, aborted = false;
  const abort = () => {
    if (res.writableFinished) return;
    aborted = true;
    source?.destroy();
    output.destroy();
  };
  res.once("close", abort);
  zip.on("error", (error) => output.destroy(error));
  try {
    for (const entry of entries) {
      const options = { mtime: entry.stat.mtime, mode: entry.stat.mode, compress: false, size: entry.stat.size };
      if (entry.stat.isDirectory()) zip.addEmptyDirectory(entry.name, { mtime: options.mtime, mode: options.mode });
      else zip.addReadStreamLazy(entry.name, options, (callback) => {
        if (aborted) { callback(new Error("Download cancelled"), undefined!); return; }
        // Recheck the guard immediately before opening a lazily read entry.
        try {
          const file = guard.resolveReadable(entry.file);
          source = fs.createReadStream(file);
          callback(null, source);
        } catch (error) { callback(error as Error, undefined!); }
      });
    }
    // @types/yazl omits the documented total-size callback argument.
    zip.end({ forceZip64Format: false, comment: "" }, ((size: number) => {
      if (!res.destroyed) res.writeHead(200, {
        "Content-Type": "application/zip", "Content-Length": size,
        ...(inline ? {} : { "Content-Disposition": attachmentHeader(name) }),
        "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
      });
    }) as () => void);
    await pipeline(output, res);
  } finally {
    res.off("close", abort);
    source?.destroy();
    output.destroy();
  }
}
