import fs from "node:fs";
import path from "node:path";
import { randomUUID, createHash } from "node:crypto";
import { pathToFileURL } from "node:url";
import type { IncomingMessage } from "node:http";
import { isInside, realPath } from "../util/paths.js";

export const MAX_UPLOAD_BYTES = 20 * 1024 * 1024;
export class UploadError extends Error {
  constructor(readonly status: number, message: string) { super(message); }
}

/** Raw bytes, bounded before allocating or writing. The client sends Content-Length. */
export async function receiveUpload(req: IncomingMessage, cwd: string, name: string | null) {
  if (!name || name.length > 180 || /[\\/\x00-\x1f]/.test(name) || name === "." || name === "..") throw new UploadError(400, "Invalid filename");
  const length = Number(req.headers["content-length"]);
  if (Number.isFinite(length) && length > MAX_UPLOAD_BYTES) throw new UploadError(413, "Files must be at most 20 MiB");
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_UPLOAD_BYTES) throw new UploadError(413, "Files must be at most 20 MiB");
    chunks.push(Buffer.from(chunk));
  }
  const bytes = Buffer.concat(chunks);
  const directory = path.join(cwd, ".codeaw-uploads");
  fs.mkdirSync(directory, { recursive: true });
  if (!isInside(realPath(cwd), realPath(directory)) || fs.lstatSync(directory).isSymbolicLink()) throw new UploadError(403, "Upload folder must be inside the session directory and cannot be a link");
  const filename = name.replace(/[<>:"|?*]/g, "_").replace(/[. ]+$/, "_");
  const file = path.join(directory, `${randomUUID()}-${filename}`);
  fs.writeFileSync(file, bytes, { flag: "wx", mode: 0o600 });
  return { name, path: file, size, sha256: createHash("sha256").update(bytes).digest("hex"),
    block: { type: "resource_link", name, uri: pathToFileURL(file).href, description: `Uploaded file on the bridge: ${file}` } };
}
