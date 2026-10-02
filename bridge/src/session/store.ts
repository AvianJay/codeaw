import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { readJson, safeName, writeFileAtomic } from "../util/paths.js";
import { logger } from "../util/log.js";
import type { LogEntry, SessionMeta } from "./types.js";

const log = logger("store");

/**
 * On-disk layout under `dataDir`:
 *   sessions/<safe id>/meta.json     SessionMeta
 *   sessions/<safe id>/events.jsonl  one LogEntry per line, append-only
 *   blobs/<sha256>                   image bytes, blobs/<sha256>.mime holds the MIME type
 */
export class SessionStore {
  private readonly sessionsDir: string;
  private readonly blobsDir: string;
  private readonly fds = new Map<string, number>();

  constructor(readonly dataDir: string) {
    this.sessionsDir = path.join(dataDir, "sessions");
    this.blobsDir = path.join(dataDir, "blobs");
    fs.mkdirSync(this.sessionsDir, { recursive: true });
    fs.mkdirSync(this.blobsDir, { recursive: true });
  }

  private dir(id: string): string {
    return path.join(this.sessionsDir, safeName(id));
  }

  readMeta(id: string): SessionMeta | undefined {
    return readJson<SessionMeta | undefined>(path.join(this.dir(id), "meta.json"), undefined);
  }

  writeMeta(meta: SessionMeta): void {
    writeFileAtomic(path.join(this.dir(meta.id), "meta.json"), JSON.stringify(meta, null, 1));
  }

  listMetas(): SessionMeta[] {
    const out: SessionMeta[] = [];
    for (const name of fs.readdirSync(this.sessionsDir)) {
      const meta = readJson<SessionMeta | undefined>(path.join(this.sessionsDir, name, "meta.json"), undefined);
      if (meta?.id) out.push(meta);
    }
    return out;
  }

  readEntries(id: string): LogEntry[] {
    const file = path.join(this.dir(id), "events.jsonl");
    let text: string;
    try {
      text = fs.readFileSync(file, "utf8");
    } catch {
      return [];
    }
    const out: LogEntry[] = [];
    for (const line of text.split("\n")) {
      if (!line) continue;
      try {
        out.push(JSON.parse(line) as LogEntry);
      } catch {
        // A crash can leave a torn last line; everything before it is still valid.
        log.warn(`skipping corrupt log line in ${id}`);
      }
    }
    return out;
  }

  append(id: string, entry: LogEntry): void {
    let fd = this.fds.get(id);
    if (fd === undefined) {
      fs.mkdirSync(this.dir(id), { recursive: true });
      fd = fs.openSync(path.join(this.dir(id), "events.jsonl"), "a");
      this.fds.set(id, fd);
    }
    fs.writeSync(fd, JSON.stringify(entry) + "\n");
  }

  /** Drops the log (used when re-importing a session). */
  truncate(id: string): void {
    this.close(id);
    try {
      fs.rmSync(path.join(this.dir(id), "events.jsonl"), { force: true });
    } catch {
      // nothing to drop
    }
  }

  delete(id: string): void {
    this.close(id);
    fs.rmSync(this.dir(id), { recursive: true, force: true });
  }

  close(id: string): void {
    const fd = this.fds.get(id);
    if (fd !== undefined) {
      fs.closeSync(fd);
      this.fds.delete(id);
    }
  }

  closeAll(): void {
    for (const id of [...this.fds.keys()]) this.close(id);
  }

  /** Stores base64 data once; returns its SHA-256 hex digest. */
  putBlob(base64: string, mimeType: string): string {
    const bytes = Buffer.from(base64, "base64");
    const sha = crypto.createHash("sha256").update(bytes).digest("hex");
    const file = path.join(this.blobsDir, sha);
    if (!fs.existsSync(file)) {
      fs.writeFileSync(file, bytes);
      fs.writeFileSync(file + ".mime", mimeType);
    }
    return sha;
  }

  blob(sha: string): { file: string; mimeType: string } | undefined {
    if (!/^[0-9a-f]{64}$/.test(sha)) return undefined;
    const file = path.join(this.blobsDir, sha);
    if (!fs.existsSync(file)) return undefined;
    let mimeType = "application/octet-stream";
    try {
      mimeType = fs.readFileSync(file + ".mime", "utf8").trim() || mimeType;
    } catch {
      // unknown type
    }
    return { file, mimeType };
  }
}

export function newEpoch(): string {
  return crypto.randomBytes(6).toString("hex");
}
