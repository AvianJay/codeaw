import fs from "node:fs";
import path from "node:path";
import { randomUUID, createHash } from "node:crypto";
import { pathToFileURL } from "node:url";
import type { IncomingMessage } from "node:http";
import type { Readable } from "node:stream";
import { isInside, realPath } from "../util/paths.js";
import { mimeFor } from "./ext.js";

export const MAX_UPLOAD_BYTES = 512 * 1024 * 1024;
export const UPLOAD_TIMEOUT_MS = 60 * 60 * 1000;
export class UploadError extends Error {
  constructor(readonly status: number, message: string) { super(message); }
}

export class UploadTooLargeError extends UploadError {
  constructor(readonly limit: number) {
    super(413, `Files must be at most ${Math.round(limit / 1024 / 1024)} MiB`);
  }
}

/** Await disk errors as promise rejections, including while the sender is idle. */
async function writeUpload(body: Readable, file: string, limit: number) {
  const handle = await fs.promises.open(file, "wx", 0o600);
  let size = 0;
  const hash = createHash("sha256");
  try {
    // Leave HTTP requests alive on oversize/write errors so HTTP can answer them.
    for await (const chunk of body.iterator({ destroyOnReturn: false })) {
      const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      size += bytes.length;
      if (size > limit) throw new UploadTooLargeError(limit);
      hash.update(bytes);
      for (let offset = 0; offset < bytes.length;) {
        const { bytesWritten } = await handle.write(bytes, offset, bytes.length - offset);
        if (!bytesWritten) throw new Error("Upload write made no progress");
        offset += bytesWritten;
      }
    }
    await handle.close();
  } catch (error) {
    await handle.close().catch(() => {});
    await fs.promises.unlink(file).catch(() => {});
    throw error;
  }
  return { size, sha256: hash.digest("hex") };
}

/** Bounded chunks go straight to disk; incomplete files are removed on failure. */
export async function receiveUpload(req: IncomingMessage, cwd: string, name: string | null) {
  if (!name || name.length > 180 || /[\\/\x00-\x1f]/.test(name) || name === "." || name === "..") throw new UploadError(400, "Invalid filename");
  const length = Number(req.headers["content-length"]);
  if (Number.isFinite(length) && length > MAX_UPLOAD_BYTES) throw new UploadError(413, "Files must be at most 512 MiB");
  const directory = path.join(cwd, ".codeaw-uploads");
  await fs.promises.mkdir(directory, { recursive: true });
  if (!isInside(realPath(cwd), realPath(directory)) || fs.lstatSync(directory).isSymbolicLink()) throw new UploadError(403, "Upload folder must be inside the session directory and cannot be a link");
  const filename = name.replace(/[<>:"|?*]/g, "_").replace(/[. ]+$/, "_");
  const file = path.join(directory, `${randomUUID()}-${filename}`);
  req.setTimeout(120_000, () => req.destroy(new UploadError(408, "Upload stalled for two minutes")));
  let saved: Awaited<ReturnType<typeof writeUpload>>;
  try {
    saved = await writeUpload(req, file, MAX_UPLOAD_BYTES);
  } finally {
    req.setTimeout(0);
  }
  return { name, path: file, ...saved,
    block: { type: "resource_link", name, uri: pathToFileURL(file).href, description: `Uploaded file on the bridge: ${file}` } };
}

export interface UploadedFile {
  path: string;
  uri: string;
  name: string;
  size: number;
  mimeType?: string;
}

/** Preserve Nicko's readable file names, with Windows and path sanitization. */
export function uploadName(raw: unknown): string {
  let name = (String(raw ?? "").split(/[\\/]/).pop() ?? "")
    .replace(/[\u0000-\u001f<>:"|?*]/g, "_")
    .replace(/[. ]+$/, "")
    .trim();
  if (name.length > 120) {
    const ext = path.extname(name).slice(0, 20);
    name = name.slice(0, 120 - ext.length) + ext;
  }
  if (/^(con|prn|aux|nul|com\d|lpt\d)(\.|$)/i.test(name)) name = `_${name}`;
  return name && name !== "." && name !== ".." ? name : "file";
}

/** Compatibility store for clients that upload before selecting a session. */
export class UploadStore {
  readonly dir: string;
  constructor(dataDir: string, readonly limit = MAX_UPLOAD_BYTES) {
    this.dir = path.join(dataDir, "uploads");
  }

  async save(rawName: unknown, contentType: unknown, body: Readable): Promise<UploadedFile> {
    const name = uploadName(rawName);
    const folder = path.join(this.dir, randomUUID());
    await fs.promises.mkdir(folder, { recursive: true });
    const file = path.join(folder, name);
    let size: number;
    try {
      ({ size } = await writeUpload(body, file, this.limit));
    } catch (error) {
      await fs.promises.rm(folder, { recursive: true, force: true }).catch(() => {});
      throw error;
    }
    const declared = typeof contentType === "string" ? contentType.split(";")[0].trim().toLowerCase() : "";
    const mimeType = /^[a-z]+\/[\w.+-]+$/.test(declared) && declared !== "application/octet-stream" ? declared : mimeFor(file);
    return { path: file, uri: pathToFileURL(file).href, name, size, ...(mimeType ? { mimeType } : {}) };
  }

  prune(maxAgeMs = 30 * 24 * 60 * 60_000, now = Date.now()): void {
    let folders: string[];
    try { folders = fs.readdirSync(this.dir); } catch { return; }
    for (const name of folders) {
      const folder = path.join(this.dir, name);
      try {
        if (now - fs.statSync(folder).mtimeMs > maxAgeMs) fs.rmSync(folder, { recursive: true, force: true });
      } catch { /* in use or already gone */ }
    }
  }
}
