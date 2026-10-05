import crypto from "node:crypto";
import fs from "node:fs";
import { once } from "node:events";
import path from "node:path";
import type { Readable } from "node:stream";
import { pathToFileURL } from "node:url";
import { mimeFor } from "./ext.js";

export const MAX_UPLOAD_BYTES = 50 * 1024 * 1024;
const KEEP_UPLOADS_MS = 30 * 24 * 60 * 60_000;

export interface UploadedFile {
  path: string;
  uri: string;
  name: string;
  size: number;
  mimeType?: string;
}

export class UploadTooLargeError extends Error {
  constructor(readonly limit: number) {
    super(`File is larger than ${Math.round(limit / 1024 / 1024)} MB`);
  }
}

/** Keeps the device's file name, minus anything that could leave the folder or upset Windows. */
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

/** Files a device sent for an agent to read: `<dataDir>/uploads/<id>/<file name>`. */
export class UploadStore {
  readonly dir: string;

  constructor(dataDir: string, readonly limit = MAX_UPLOAD_BYTES) {
    this.dir = path.join(dataDir, "uploads");
  }

  async save(rawName: unknown, contentType: unknown, body: Readable): Promise<UploadedFile> {
    const name = uploadName(rawName);
    const folder = path.join(this.dir, `${new Date().toISOString().slice(0, 10).replace(/-/g, "")}-${crypto.randomBytes(4).toString("hex")}`);
    fs.mkdirSync(folder, { recursive: true });
    const file = path.join(folder, name);
    const out = fs.createWriteStream(file, { flags: "wx" });
    let size = 0;
    try {
      // Keep the request open on failure so the caller can still answer it.
      for await (const chunk of body.iterator({ destroyOnReturn: false })) {
        size += (chunk as Buffer).length;
        if (size > this.limit) throw new UploadTooLargeError(this.limit);
        if (!out.write(chunk)) await once(out, "drain");
      }
      await new Promise<void>((resolve, reject) => out.end((err?: Error | null) => (err ? reject(err) : resolve())));
    } catch (err) {
      out.destroy();
      await once(out, "close").catch(() => undefined);
      fs.rmSync(folder, { recursive: true, force: true });
      throw err;
    }
    const declared = typeof contentType === "string" ? contentType.split(";")[0].trim().toLowerCase() : "";
    const mimeType = /^[a-z]+\/[\w.+-]+$/.test(declared) && declared !== "application/octet-stream" ? declared : mimeFor(file);
    return { path: file, uri: pathToFileURL(file).href, name, size, ...(mimeType ? { mimeType } : {}) };
  }

  /** Drops uploads older than `maxAgeMs`; agents only need them while a conversation is active. */
  prune(maxAgeMs = KEEP_UPLOADS_MS, now = Date.now()): void {
    let folders: string[];
    try {
      folders = fs.readdirSync(this.dir);
    } catch {
      return;
    }
    for (const name of folders) {
      const folder = path.join(this.dir, name);
      try {
        if (now - fs.statSync(folder).mtimeMs > maxAgeMs) fs.rmSync(folder, { recursive: true, force: true });
      } catch {
        // in use or already gone
      }
    }
  }
}
