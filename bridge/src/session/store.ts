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
 *   chats/<uuid>/                    working files for a projectless conversation
 */
export class SessionStore {
  private readonly sessionsDir: string;
  private readonly blobsDir: string;
  private readonly deletedDir: string;
  private readonly deleted = new Set<string>();
  private readonly fds = new Map<string, number>();

  constructor(readonly dataDir: string) {
    this.sessionsDir = path.join(dataDir, "sessions");
    this.blobsDir = path.join(dataDir, "blobs");
    this.deletedDir = path.join(dataDir, "deleted-sessions");
    fs.mkdirSync(this.sessionsDir, { recursive: true });
    fs.mkdirSync(this.blobsDir, { recursive: true });
    fs.mkdirSync(this.deletedDir, { recursive: true });
    for (const name of fs.readdirSync(this.deletedDir)) {
      const record = readJson<{ id?: string }>(path.join(this.deletedDir, name), {});
      if (typeof record.id === "string") this.deleted.add(record.id);
    }
  }

  private dir(id: string): string {
    return path.join(this.sessionsDir, safeName(id));
  }

  readMeta(id: string): SessionMeta | undefined {
    if (this.isDeleted(id)) return undefined;
    return readJson<SessionMeta | undefined>(path.join(this.dir(id), "meta.json"), undefined);
  }

  writeMeta(meta: SessionMeta): void {
    if (this.isDeleted(meta.id)) return;
    writeFileAtomic(path.join(this.dir(meta.id), "meta.json"), JSON.stringify(meta, null, 1));
  }

  listMetas(): SessionMeta[] {
    const out: SessionMeta[] = [];
    for (const name of fs.readdirSync(this.sessionsDir)) {
      const meta = readJson<SessionMeta | undefined>(path.join(this.sessionsDir, name, "meta.json"), undefined);
      if (meta?.id && !this.isDeleted(meta.id)) out.push(meta);
    }
    return out;
  }

  createChatDirectory(): string {
    const root = path.resolve(this.dataDir, "chats");
    fs.mkdirSync(root, { recursive: true });
    const cwd = path.join(root, crypto.randomUUID());
    fs.mkdirSync(cwd);
    return cwd;
  }

  /** Creation failed: remove only our empty allocation, never agent-created files. */
  discardEmptyChatDirectory(cwd: string): void {
    if (path.dirname(cwd) !== path.resolve(this.dataDir, "chats") || !/^[0-9a-f-]{36}$/.test(path.basename(cwd))) return;
    try { fs.rmdirSync(cwd); } catch { /* Preserve nonempty directories. */ }
  }

  readEntries(id: string): LogEntry[] {
    if (this.isDeleted(id)) return [];
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
    if (this.isDeleted(id)) return;
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
    const directory = path.resolve(this.dir(id));
    if (path.dirname(directory) !== path.resolve(this.sessionsDir)) throw new Error("Invalid session deletion path");
    // Retained native histories must not reappear after refresh or bridge restart.
    writeFileAtomic(path.join(this.deletedDir, safeName(id) + ".json"), JSON.stringify({ id, deletedAt: new Date().toISOString() }));
    this.deleted.add(id);
    this.close(id);
    fs.rmSync(directory, { recursive: true, force: true });
  }

  isDeleted(id: string): boolean { return this.deleted.has(id); }

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
