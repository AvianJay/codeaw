import fs from "node:fs";
import path from "node:path";
import { randomUUID, createHash } from "node:crypto";
import { pathToFileURL } from "node:url";
import type { IncomingMessage } from "node:http";
import { isInside, realPath } from "../util/paths.js";

export const MAX_UPLOAD_BYTES = 512 * 1024 * 1024;
export const UPLOAD_TIMEOUT_MS = 60 * 60 * 1000;
export class UploadError extends Error {
  constructor(readonly status: number, message: string) { super(message); }
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
  const handle = await fs.promises.open(file, "wx", 0o600);
  let size = 0;
  const hash = createHash("sha256");
  req.setTimeout(120_000, () => req.destroy(new UploadError(408, "Upload stalled for two minutes")));
  try {
    for await (const chunk of req) {
      const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      size += bytes.length;
      if (size > MAX_UPLOAD_BYTES) throw new UploadError(413, "Files must be at most 512 MiB");
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
  } finally {
    req.setTimeout(0);
  }
  return { name, path: file, size, sha256: hash.digest("hex"),
    block: { type: "resource_link", name, uri: pathToFileURL(file).href, description: `Uploaded file on the bridge: ${file}` } };
}
