import crypto from "node:crypto";
import type http from "node:http";
import type { Duplex } from "node:stream";
import { WebSocket, WebSocketServer } from "ws";
import { z } from "zod";
import type { DeviceStore } from "../server/auth.js";
import { desktopHelper, NativeDesktop } from "./native.js";
import { DesktopError, FrameBudget, Input, SessionOptions, framePacket, modes, profiles,
  type BackendFactory, type DesktopBackend, type NativeFrame, type NativeInfo } from "./protocol.js";
import { tailscaleIPv4 } from "../util/tailscale.js";

interface Session {
  id: string; owner: string; token: string; ticketHash: Buffer; expires: number; options: SessionOptions;
  backend?: DesktopBackend; socket?: WebSocket; timer?: NodeJS.Timeout; videoTimer?: NodeJS.Timeout;
  epoch: number; seq: number; ready: boolean; pending?: number; pendingAt?: number;
  activeUntil: number; budget: FrameBudget; closed: boolean; capturing: boolean; chain: Promise<void>;
  actualMode: SessionOptions["mode"]; lastCursor?: string; receivedAt: number; receivedCount: number;
}
const hash = (ticket: string) => crypto.createHash("sha256").update(ticket).digest();
const json = (res: http.ServerResponse, status: number, value: unknown) => {
  const body = JSON.stringify(value);
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", "Content-Length": Buffer.byteLength(body) }); res.end(body);
};
async function body(req: http.IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = []; let size = 0;
  for await (const chunk of req) { size += chunk.length; if (size > 4096) throw new DesktopError(413, "too_large", "請求過大"); chunks.push(chunk); }
  try { return JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch { throw new DesktopError(400, "invalid_request", "無效的桌面請求"); }
}
export interface DesktopManagerOptions {
  devices: DeviceStore; enabled: () => boolean; systemAvailable?: boolean; backendFactory?: BackendFactory;
  available?: () => boolean; now?: () => number;
}

/** Desktop lifetime is independent of ACP and its message queues. */
export class DesktopManager {
  private session?: Session;
  private wss = new WebSocketServer({ noServer: true, maxPayload: 16 * 1024, perMessageDeflate: false });
  private sockets = new Set<WebSocket>();
  private factory: BackendFactory;
  private available: () => boolean;
  private now: () => number;
  private revocation: NodeJS.Timeout;
  constructor(private readonly opts: DesktopManagerOptions) {
    this.factory = opts.backendFactory ?? ((privilege) => new NativeDesktop(privilege));
    this.available = opts.available ?? (() => process.platform === "win32" && !!desktopHelper());
    this.now = opts.now ?? Date.now;
    this.revocation = setInterval(() => {
      const s = this.session;
      if (s && (!opts.enabled() || !opts.devices.authenticate(s.token))) void this.close(s);
    }, 1000); this.revocation.unref();
  }
  async info() {
    if (!this.opts.enabled() || !this.available()) return { version: 1, enabled: this.opts.enabled(), available: false,
      state: this.opts.enabled() ? "helper_missing" : "disabled", modes, privilegeModes: ["user"], monitors: [] };
    let native: NativeInfo;
    if (this.session?.backend) native = (await this.session.backend.request("info")).result as NativeInfo;
    else {
      const backend = this.factory(this.opts.systemAvailable ? "system" : "user");
      try { native = (await backend.request("info")).result as NativeInfo; } finally { await backend.dispose(); }
    }
    return { version: 1, enabled: true, available: true, state: native.state, modes,
      smooth: native.smooth, hardware: native.hardware, privilegeModes: this.opts.systemAvailable ? ["user", "system"] : ["user"],
      monitors: native.monitors, busy: !!this.session };
  }
  async create(owner: string, token: string, value: unknown) {
    if (!this.opts.enabled()) throw new DesktopError(403, "disabled", "請先在電腦端啟用遠端桌面");
    if (!this.available()) throw new DesktopError(503, "helper_missing", "請更新 Windows bridge 以使用遠端桌面");
    if (this.session) throw new DesktopError(409, "busy", "另一個裝置正在控制桌面");
    const parsed = SessionOptions.safeParse(value);
    if (!parsed.success) throw new DesktopError(400, "invalid_options", "無效的桌面模式或螢幕設定");
    if (parsed.data.privilege === "system" && !this.opts.systemAvailable) throw new DesktopError(403, "privilege_required", "請在電腦端啟用進階桌面服務");
    const id = crypto.randomBytes(16).toString("hex"), ticket = crypto.randomBytes(32).toString("hex");
    const s: Session = { id, owner, token, ticketHash: hash(ticket), expires: this.now() + 30_000, options: parsed.data,
      epoch: 1, seq: 0, ready: false, actualMode: parsed.data.mode, activeUntil: this.now() + 2000,
      budget: new FrameBudget(profiles[parsed.data.mode].bytesPerSecond), closed: false, capturing: false,
      chain: Promise.resolve(), receivedAt: this.now(), receivedCount: 0 };
    this.session = s;
    s.timer = setTimeout(() => { void this.close(s); }, 30_000); s.timer.unref();
    return { sessionId: id, ticket, socketPath: `/api/desktop/sessions/${id}/socket` };
  }
  async onRequest(req: http.IncomingMessage, res: http.ServerResponse, url: URL): Promise<boolean> {
    if (!url.pathname.startsWith("/api/desktop/")) return false;
    try {
      const token = req.headers.authorization?.startsWith("Bearer ") ? req.headers.authorization.slice(7).trim() : undefined;
      const device = this.opts.devices.authenticate(token);
      if (!device || !token) throw new DesktopError(401, "unauthorized", "裝置未配對或已撤銷");
      if (req.method === "GET" && url.pathname === "/api/desktop/info") json(res, 200, await this.info());
      else if (req.method === "POST" && url.pathname === "/api/desktop/sessions") json(res, 201, await this.create(device.id, token, await body(req)));
      else if (req.method === "DELETE" && url.pathname === `/api/desktop/sessions/${this.session?.id}` && this.session?.owner === device.id) {
        await this.close(this.session); json(res, 200, {});
      } else json(res, 404, { error: "桌面連線不存在", code: "not_found" });
    } catch (error) {
      const e = error instanceof DesktopError ? error : new DesktopError(503, "unavailable", "桌面服務暫時無法使用");
      if (!res.headersSent) json(res, e.status, { error: e.message, code: e.code }); else res.destroy();
    }
    return true;
  }
  onUpgrade(req: http.IncomingMessage, socket: Duplex, head: Buffer, url: URL): boolean {
    if (!url.pathname.startsWith("/api/desktop/")) return false;
    const s = this.session;
    if (!s || s.socket || url.pathname !== `/api/desktop/sessions/${s.id}/socket` || this.now() >= s.expires) {
      socket.end("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n"); return true;
    }
    this.wss.handleUpgrade(req, socket, head, (ws) => {
      this.sockets.add(ws);
      // Reserve before asynchronous authentication: two sockets cannot consume one ticket.
      s.socket = ws;
      const authentication = setTimeout(() => ws.terminate(), 3000); authentication.unref();
      let authenticated = false;
      ws.on("error", () => { void this.close(s); });
      ws.on("close", () => { clearTimeout(authentication); this.sockets.delete(ws); void this.close(s); });
      ws.on("message", (bytes, binary) => {
        let msg: any;
        try { if (binary) throw new Error(); msg = JSON.parse(bytes.toString()); } catch { ws.close(1008, "Invalid message"); return; }
        if (!authenticated) {
          const candidate = typeof msg.ticket === "string" && msg.ticket.length <= 128 ? hash(msg.ticket) : Buffer.alloc(0);
          if (msg.type !== "auth" || candidate.length !== s.ticketHash.length || !crypto.timingSafeEqual(candidate, s.ticketHash)
            || this.now() >= s.expires || !this.opts.devices.authenticate(s.token) || !this.opts.enabled()) {
            ws.close(1008, "Unauthorized"); return;
          }
          authenticated = true; clearTimeout(authentication); s.ticketHash.fill(0);
          if (s.timer) clearTimeout(s.timer);
          s.chain = this.start(s).catch((error) => this.error(s, error));
          return;
        }
        if (this.now() - s.receivedAt >= 1000) { s.receivedAt = this.now(); s.receivedCount = 0; }
        if (++s.receivedCount > 150) { ws.close(1008, "Too many messages"); return; }
        s.chain = s.chain.then(() => this.message(s, msg)).catch((error) => this.error(s, error));
      });
      let alive = true;
      ws.on("pong", () => { alive = true; });
      const heartbeat = setInterval(() => { if (!alive) ws.terminate(); else { alive = false; ws.ping(); } }, 20_000);
      heartbeat.unref(); ws.once("close", () => clearInterval(heartbeat));
    });
    return true;
  }
  private send(s: Session, value: unknown) { if (!s.closed && s.socket?.readyState === WebSocket.OPEN) s.socket.send(JSON.stringify(value)); }
  private async start(s: Session) {
    if (s.closed) return;
    s.backend = this.factory(s.options.privilege);
    s.backend.onEvent = (event) => {
      if (s.closed) return;
      if (event.epoch !== undefined && event.epoch !== s.epoch) return;
      if (event.type === "video-frame") this.send(s, { ...event, epoch: s.epoch });
      else if (event.type === "video-error") void this.fallback(s);
      else if (event.type === "error") this.error(s, new DesktopError(503, "helper_stopped", "桌面元件已停止"));
      else this.send(s, event);
    };
    const info = (await s.backend.request("info")).result as NativeInfo;
    if (!info.monitors.some((m) => m.id === s.options.monitorId)) s.options.monitorId = info.monitors.find((m) => m.primary)?.id ?? info.monitors[0]?.id;
    if (!s.options.monitorId) throw new DesktopError(409, "display_unavailable", "目前沒有可擷取的螢幕");
    this.send(s, { type: "info", ...info, privilege: s.options.privilege });
    await this.configure(s);
  }
  private async configure(s: Session) {
    if (s.timer) clearTimeout(s.timer); if (s.videoTimer) clearTimeout(s.videoTimer);
    s.ready = false; s.pending = undefined; s.seq = 0; s.lastCursor = undefined;
    s.budget = new FrameBudget(profiles[s.actualMode].bytesPerSecond);
    await s.backend!.request("configure", { monitorId: s.options.monitorId });
    if (s.closed) return;
    this.send(s, { type: "status", state: "connecting", mode: s.actualMode, requestedMode: s.options.mode, epoch: s.epoch });
    if (s.actualMode === "smooth") {
      s.videoTimer = setTimeout(() => { void this.fallback(s); }, 8000); s.videoTimer.unref();
      try { await s.backend!.request("video", { fps: s.options.fps, bitrate: 4_000_000, longEdge: 1920, bindAddress: tailscaleIPv4() ?? "127.0.0.1", epoch: s.epoch }); }
      catch { await this.fallback(s); }
    } else this.schedule(s, 0);
  }
  private async fallback(s: Session) {
    if (s.closed || s.actualMode !== "smooth") return;
    s.actualMode = "balanced"; s.epoch++;
    if (s.videoTimer) clearTimeout(s.videoTimer);
    try { await s.backend!.request("videoStop"); await this.configure(s);
      this.send(s, { type: "notice", message: "高流暢串流無法使用，已切換一般模式" });
    } catch (error) { this.error(s, error); }
  }
  private schedule(s: Session, delay: number) {
    if (s.closed || s.actualMode === "smooth") return;
    if (s.timer) clearTimeout(s.timer);
    s.timer = setTimeout(() => { void this.capture(s); }, delay); s.timer.unref();
  }
  private async capture(s: Session) {
    if (s.closed || s.capturing || !s.backend) return;
    const profile = profiles[s.actualMode];
    if (s.pending !== undefined) {
      if (this.now() - (s.pendingAt ?? this.now()) > 15_000) { await this.close(s); return; }
      this.schedule(s, 200); return;
    }
    if (s.actualMode === "onDemand" && s.seq > 0 && this.now() > s.activeUntil) { this.schedule(s, 500); return; }
    const budgetDelay = s.budget.delay(1);
    if (budgetDelay > 0 || (s.socket?.bufferedAmount ?? 0) > 64 * 1024) { this.schedule(s, Math.max(100, budgetDelay)); return; }
    s.capturing = true; const epoch = s.epoch;
    try {
      const reply = await s.backend.request("capture", { longEdge: profile.longEdge, quality: profile.quality, full: s.seq === 0 });
      if (s.closed || epoch !== s.epoch) return;
      const frame = reply.result as NativeFrame;
      if (frame.cursor) {
        const cursor = JSON.stringify(frame.cursor);
        if (cursor !== s.lastCursor) { s.lastCursor = cursor; this.send(s, { type: "cursor", ...frame.cursor, epoch }); }
      }
      if (frame.tiles?.length && s.socket?.readyState === WebSocket.OPEN) {
        const seq = ++s.seq;
        const packet = framePacket({ type: "frame", ...frame, epoch, seq }, reply.payload);
        s.budget.consume(packet.length); s.pending = seq; s.pendingAt = this.now();
        s.socket.send(packet, { binary: true, compress: false });
      }
    } catch (error) {
      const e = error instanceof DesktopError ? error : new DesktopError(409, "capture_unavailable", "桌面暫時無法擷取");
      this.send(s, { type: "status", state: e.code, message: e.message, epoch });
      s.ready = false;
      try {
        const info = (await s.backend.request("info")).result as NativeInfo;
        if (info.monitors.length && !info.monitors.some((monitor) => monitor.id === s.options.monitorId)) {
          await s.backend.request("release");
          s.options.monitorId = info.monitors.find((monitor) => monitor.primary)?.id ?? info.monitors[0].id;
          s.epoch++;
          this.send(s, { type: "info", ...info, monitorId: s.options.monitorId });
          await this.configure(s);
        }
      } catch { /* Retry capture when the console or display returns. */ }
    } finally { s.capturing = false; this.schedule(s, 1000 / profile.fps); }
  }
  private async message(s: Session, msg: any) {
    if (s.closed || !s.backend) return;
    switch (msg.type) {
      case "ack":
        if (msg.epoch !== s.epoch) return;
        if (s.actualMode === "smooth" && msg.seq === 0) {
          s.ready = true; if (s.videoTimer) clearTimeout(s.videoTimer);
        } else if (msg.seq === s.pending) {
          await s.backend.request("ack"); s.pending = undefined; s.ready = true;
        } else return;
        this.send(s, { type: "status", state: "active", mode: s.actualMode, requestedMode: s.options.mode, epoch: s.epoch });
        break;
      case "input": {
        const input = Input.safeParse(msg.input);
        if (!input.success) throw new DesktopError(400, "invalid_input", "無效的桌面輸入");
        if (input.data.kind === "release") { await s.backend.request("release"); return; }
        if (!s.ready || msg.epoch !== s.epoch) return;
        if (input.data.kind === "sas" && s.options.privilege !== "system") throw new DesktopError(403, "privilege_required", "Ctrl+Alt+Del 需要進階權限");
        try { await s.backend.request("input", { input: input.data }); }
        catch (error) {
          if (error instanceof DesktopError && ["input_blocked", "sas_disabled"].includes(error.code)) {
            this.send(s, { type: "notice", code: error.code, message: error.message }); return;
          }
          throw error;
        }
        if (input.data.kind !== "pointer") s.activeUntil = this.now() + 2000;
        break;
      }
      case "configure": {
        const parsed = SessionOptions.safeParse({ ...s.options, ...msg.options });
        if (!parsed.success || parsed.data.privilege !== s.options.privilege) throw new DesktopError(400, "invalid_options", "權限切換需要重新連線");
        await s.backend.request("release"); await s.backend.request("videoStop");
        s.options = parsed.data; s.actualMode = s.options.mode; s.epoch++; s.activeUntil = this.now() + 2000;
        await this.configure(s); break;
      }
      case "refresh": s.activeUntil = this.now() + 2000; if (s.actualMode !== "smooth") this.schedule(s, 0); break;
      case "answer":
        if (msg.epoch !== s.epoch) return;
        if (s.actualMode === "smooth" && typeof msg.sdp === "string" && msg.sdp.length <= 12_000) await s.backend.request("answer", { sdp: msg.sdp }); break;
      case "candidate":
        if (msg.epoch !== s.epoch) return;
        if (s.actualMode === "smooth" && typeof msg.candidate === "string" && msg.candidate.length <= 1024) await s.backend.request("candidate", { candidate: msg.candidate, mid: String(msg.mid ?? "0").slice(0, 32) }); break;
      case "videoFailed": if (msg.epoch === s.epoch) await this.fallback(s); break;
      case "stats": {
        if (s.actualMode !== "smooth" || msg.epoch !== s.epoch) return;
        const parsed = z.object({ loss: z.number().finite().min(0).max(1), bitrate: z.number().finite().min(128_000).max(8_000_000) }).safeParse(msg);
        if (parsed.success) await s.backend.request("bitrate", { bitrate: parsed.data.bitrate }); break;
      }
      default: throw new DesktopError(400, "invalid_message", "無效的桌面訊息");
    }
  }
  private error(s: Session, error: unknown) {
    const e = error instanceof DesktopError ? error : new DesktopError(503, "unavailable", "桌面服務暫時無法使用");
    this.send(s, { type: "error", code: e.code, message: e.message });
    void this.close(s);
  }
  private async close(s: Session) {
    if (s.closed) return; s.closed = true;
    if (s.timer) clearTimeout(s.timer); if (s.videoTimer) clearTimeout(s.videoTimer);
    s.socket?.close(1000, "Desktop session ended");
    await s.backend?.dispose(); s.token = ""; s.ticketHash.fill(0);
    if (this.session === s) this.session = undefined;
  }
  async dispose() {
    clearInterval(this.revocation);
    if (this.session) await this.close(this.session);
    for (const ws of this.sockets) ws.terminate();
    await new Promise<void>((resolve) => this.wss.close(() => resolve()));
  }
}
