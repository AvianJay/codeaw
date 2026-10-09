import { EventEmitter } from "node:events";
import fs from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";

// Codex Desktop's private, length-prefixed IPC protocol. No app code is executed.
// Protocol reference: https://github.com/dreamingboat/codex-lan-companion
export interface DesktopIpcMessage {
  type: string;
  method?: string;
  requestId?: string;
  sourceClientId?: string;
  handledByClientId?: string;
  version?: number;
  resultType?: string;
  result?: any;
  error?: string;
  params?: any;
  [key: string]: unknown;
}

export interface DesktopIpcOptions {
  pipe?: string;
  archivePath?: string;
  modelCatalogPath?: string;
  timeoutMs?: number;
  versions?: Record<string, number>;
}

const MAX_FRAME_BYTES = 64 * 1024 * 1024;

/** Assemble a fragmented frame once, even for a large desktop history snapshot. */
export class DesktopIpcFrameDecoder {
  private readonly header = Buffer.alloc(4);
  private headerBytes = 0;
  private payload?: Buffer;
  private payloadBytes = 0;

  push(chunk: Buffer): Buffer[] {
    const frames: Buffer[] = [];
    let offset = 0;
    while (offset < chunk.length) {
      if (!this.payload) {
        const size = Math.min(4 - this.headerBytes, chunk.length - offset);
        chunk.copy(this.header, this.headerBytes, offset, offset + size);
        this.headerBytes += size;
        offset += size;
        if (this.headerBytes < 4) break;
        const length = this.header.readUInt32LE(0);
        if (length < 2 || length > MAX_FRAME_BYTES) throw new Error("Invalid Codex desktop IPC frame");
        this.headerBytes = 0;
        if (chunk.length - offset >= length) {
          frames.push(chunk.subarray(offset, offset + length));
          offset += length;
          continue;
        }
        this.payload = Buffer.allocUnsafe(length);
        this.payloadBytes = 0;
      }
      const size = Math.min(this.payload.length - this.payloadBytes, chunk.length - offset);
      chunk.copy(this.payload, this.payloadBytes, offset, offset + size);
      this.payloadBytes += size;
      offset += size;
      if (this.payloadBytes === this.payload.length) {
        frames.push(this.payload);
        this.payload = undefined;
        this.payloadBytes = 0;
      }
    }
    return frames;
  }
}

const CURRENT_VERSIONS: Record<string, number> = {
  "thread-owner-discovery": 1,
  "thread-stream-state-changed": 11,
  "thread-stream-following-changed": 1,
  "thread-stream-following-status-requested": 1,
  "thread-follower-start-turn": 2,
  "thread-follower-load-complete-history": 1,
  "thread-follower-steer-turn": 1,
  "thread-follower-update-thread-settings": 2,
  "thread-follower-interrupt-turn": 4,
  "thread-follower-command-approval-decision": 1,
  "thread-follower-file-approval-decision": 1,
  "thread-follower-permissions-request-approval-response": 1,
  "thread-follower-submit-user-input": 1,
  "thread-follower-submit-mcp-server-elicitation-response": 1,
};

export function codexDesktopPipe(): string {
  return process.platform === "win32"
    ? "\\\\.\\pipe\\codex-ipc"
    : path.join(process.env.CODEX_HOME ?? path.join(os.homedir(), ".codex"), "ipc", "ipc.sock");
}

/** Read only the method-version table in a distributed app.asar, never user state. */
export async function readDesktopIpcVersions(archivePath: string): Promise<Record<string, number> | undefined> {
  const file = await fs.open(archivePath, "r");
  try {
    const prefix = Buffer.alloc(16);
    if ((await file.read(prefix, 0, 16, 0)).bytesRead !== 16) return;
    const headerSize = prefix.readUInt32LE(4);
    const jsonSize = prefix.readUInt32LE(12);
    if (jsonSize < 2 || jsonSize > 32 * 1024 * 1024 || headerSize < jsonSize + 8) return;
    const header = Buffer.alloc(jsonSize);
    if ((await file.read(header, 0, jsonSize, 16)).bytesRead !== jsonSize) return;
    const entries = JSON.parse(header.toString("utf8"))?.files?.[".vite"]?.files?.build?.files ?? {};
    const candidates = Object.entries(entries).sort(([a], [b]) => Number(!a.startsWith("src-")) - Number(!b.startsWith("src-")));
    for (const [name, raw] of candidates) {
      const entry = raw as any;
      const size = Number(entry.size), offset = Number(entry.offset);
      if (!name.endsWith(".js") || entry.unpacked || !Number.isSafeInteger(size) || size < 1 || size > 8 * 1024 * 1024 || !Number.isSafeInteger(offset) || offset < 0) continue;
      const content = Buffer.alloc(size);
      if ((await file.read(content, 0, size, 8 + headerSize + offset)).bytesRead !== size) continue;
      const table = content.toString("utf8").match(/\{[^{}]{0,16000}"thread-follower-start-turn"\s*:\s*\d+[^{}]{0,16000}\}/)?.[0];
      if (!table) continue;
      try {
        const versions = JSON.parse(table);
        if (Object.values(versions).every((v) => Number.isSafeInteger(v) && (v as number) >= 0)) return versions;
      } catch { /* Try the next bundle. */ }
    }
  } finally {
    await file.close();
  }
}

async function installedArchives(): Promise<string[]> {
  if (process.platform !== "win32") return [];
  const roots = [path.join(process.env.ProgramFiles ?? "C:\\Program Files", "WindowsApps")];
  const archives: string[] = [];
  for (const root of roots) {
    try {
      const packages = (await fs.readdir(root)).filter((name) => /^OpenAI\.Codex_/.test(name)).sort((a, b) => b.localeCompare(a, undefined, { numeric: true }));
      for (const name of packages) archives.push(path.join(root, name, "app", "resources", "app.asar"));
    } catch { /* An explicit archivePath also works without WindowsApps enumeration. */ }
  }
  return archives;
}

export function encodeDesktopIpc(message: DesktopIpcMessage): Buffer {
  const json = Buffer.from(JSON.stringify(message), "utf8");
  if (json.length > MAX_FRAME_BYTES) throw new Error("Codex desktop IPC message is too large");
  const header = Buffer.alloc(4);
  header.writeUInt32LE(json.length);
  return Buffer.concat([header, json]);
}

/** Independent RPC client: disconnecting it never stops the desktop's app-server. */
export class CodexDesktopIpc extends EventEmitter {
  clientId?: string;
  generation = 0;
  versions: Record<string, number>;
  private socket?: net.Socket;
  private ready?: Promise<void>;
  private decoder = new DesktopIpcFrameDecoder();
  private readonly pending = new Map<string, { resolve: (message: DesktopIpcMessage) => void; reject: (error: Error) => void; timer: NodeJS.Timeout }>();
  private reconnectTimer?: NodeJS.Timeout;
  private reconnectWanted = false;
  private retryMs = 500;

  constructor(readonly options: DesktopIpcOptions = {}) {
    super();
    this.versions = options.versions ?? CURRENT_VERSIONS;
  }

  get connected(): boolean { return this.clientId !== undefined && this.socket?.writable === true; }

  ensureReady(): Promise<void> {
    if (this.connected) return Promise.resolve();
    if (!this.ready) {
      const ready = this.connect().catch((error) => {
        if (this.ready === ready) this.disconnect(new Error("Codex desktop is unavailable"));
        throw error;
      });
      this.ready = ready;
    }
    return this.ready;
  }

  private async connect(): Promise<void> {
    if (!this.options.versions) {
      for (const archive of this.options.archivePath ? [this.options.archivePath] : await installedArchives()) {
        try {
          const table = await readDesktopIpcVersions(archive);
          if (table) { this.versions = table; break; }
        } catch { /* Use the tested protocol version when no app bundle is accessible. */ }
      }
    }
    const socket = net.createConnection(this.options.pipe ?? codexDesktopPipe());
    this.socket = socket;
    this.decoder = new DesktopIpcFrameDecoder();
    socket.on("data", (chunk) => this.onData(socket, typeof chunk === "string" ? Buffer.from(chunk) : chunk));
    socket.on("error", () => this.disconnect(new Error("Codex desktop IPC connection failed"), socket));
    socket.on("close", () => this.disconnect(new Error("Codex desktop IPC connection closed"), socket));
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => { socket.destroy(); reject(new Error("Codex desktop connection timed out")); }, this.options.timeoutMs ?? 5000);
      const finish = () => { clearTimeout(timer); socket.off("connect", connected); socket.off("error", failed); socket.off("close", closed); };
      const connected = () => { finish(); resolve(); };
      const failed = () => { finish(); reject(new Error("Codex desktop is unavailable")); };
      const closed = () => { finish(); reject(new Error("Codex desktop connection closed")); };
      socket.once("connect", connected); socket.once("error", failed); socket.once("close", closed);
    });
    const response = await this.requestRaw("initialize", { clientType: "webcontrolui" }, { includeVersion: false });
    if (typeof response.result?.clientId !== "string") throw new Error("Codex desktop IPC registration failed");
    this.clientId = response.result.clientId;
    this.generation++;
    this.retryMs = 500;
    this.emit("connected");
  }

  private onData(socket: net.Socket, chunk: Buffer): void {
    if (socket !== this.socket) return;
    let frames: Buffer[];
    try { frames = this.decoder.push(chunk); }
    catch { this.disconnect(new Error("Invalid Codex desktop IPC frame"), socket); return; }
    for (const frame of frames) {
      if (socket !== this.socket) return;
      let message: DesktopIpcMessage;
      try { message = JSON.parse(frame.toString("utf8")); }
      catch { this.disconnect(new Error("Invalid Codex desktop IPC message"), socket); return; }
      if (!message || typeof message !== "object" || typeof message.type !== "string") { this.disconnect(new Error("Invalid Codex desktop IPC envelope"), socket); return; }
      if (message.type === "response" && typeof message.requestId === "string") {
        const pending = this.pending.get(message.requestId);
        if (pending) {
          this.pending.delete(message.requestId);
          clearTimeout(pending.timer);
          if (message.resultType === "error") pending.reject(new DesktopIpcRequestError(message));
          else pending.resolve(message);
        }
      } else if (message.type === "request" && message.requestId) {
        // This follower never advertises itself as a thread owner.
        socket.write(encodeDesktopIpc({ type: "response", requestId: message.requestId, method: message.method, resultType: "error", error: "no-client-found" }));
      } else {
        this.emit("message", message);
      }
    }
  }

  async request(method: string, params: any = {}, options: { targetClientId?: string; timeoutMs?: number } = {}): Promise<DesktopIpcMessage> {
    await this.ensureReady();
    return this.requestRaw(method, params, options);
  }

  private requestRaw(method: string, params: any, options: { targetClientId?: string; timeoutMs?: number; includeVersion?: boolean }): Promise<DesktopIpcMessage> {
    const socket = this.socket;
    if (!socket?.writable) return Promise.reject(new Error("Codex desktop is not connected"));
    const requestId = randomUUID();
    const message: DesktopIpcMessage = { type: "request", requestId, method, params, sourceClientId: this.clientId, targetClientId: options.targetClientId };
    if (options.includeVersion !== false) {
      message.version = this.versions[method] ?? 0;
      if (method === "thread-follower-interrupt-turn" && params.expectedTurnId == null && message.version >= 4) message.version = 3;
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(requestId);
        reject(new Error(`Codex desktop request timed out (${method}); its outcome may be unknown`));
      }, options.timeoutMs ?? this.options.timeoutMs ?? 12000);
      this.pending.set(requestId, { resolve, reject, timer });
      try { socket.write(encodeDesktopIpc(message)); }
      catch { clearTimeout(timer); this.pending.delete(requestId); reject(new Error("Codex desktop IPC write failed")); }
    });
  }

  async broadcast(method: string, params: any, targetClientIds?: string[]): Promise<void> {
    await this.ensureReady();
    this.socket!.write(encodeDesktopIpc({ type: "broadcast", method, params, sourceClientId: this.clientId, version: this.versions[method] ?? 0, targetClientIds }));
  }

  setReconnectWanted(wanted: boolean): void {
    this.reconnectWanted = wanted;
    if (!wanted && this.reconnectTimer) { clearTimeout(this.reconnectTimer); this.reconnectTimer = undefined; }
    if (wanted && !this.connected) this.scheduleReconnect();
  }

  private scheduleReconnect(): void {
    if (!this.reconnectWanted || this.reconnectTimer) return;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined;
      void this.ensureReady().catch(() => { this.retryMs = Math.min(this.retryMs * 2, 10000); this.scheduleReconnect(); });
    }, this.retryMs);
    this.reconnectTimer.unref();
  }

  private disconnect(error: Error, socket = this.socket): void {
    if (socket && socket !== this.socket) return;
    const wasConnected = this.clientId !== undefined;
    this.socket = undefined;
    this.ready = undefined;
    this.clientId = undefined;
    this.decoder = new DesktopIpcFrameDecoder();
    socket?.destroy();
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
    this.pending.clear();
    if (wasConnected) this.emit("disconnected");
    this.scheduleReconnect();
  }

  close(): void {
    this.setReconnectWanted(false);
    this.disconnect(new Error("Codex desktop follower disconnected"));
  }
}

export class DesktopIpcRequestError extends Error {
  constructor(readonly response: DesktopIpcMessage) {
    // Do not include private IPC payloads or desktop error details in bridge logs.
    super(response.error === "no-client-found" ? "Codex desktop no longer owns this session" : `Codex desktop rejected ${response.method ?? "the request"}`);
  }
}
