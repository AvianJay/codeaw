import crypto from "node:crypto";
import fs from "node:fs";
import http2 from "node:http2";
import type { LiveActivityConfig } from "../config.js";
import type { CompletedTurn, TurnState } from "../session/types.js";
import { concise, type WorkStatus } from "../session/work-status.js";
import { logger } from "../util/log.js";

const log = logger("live-activity");
export interface ActivitySnapshot {
  sessionId: string; agentId: string; title?: string; state: TurnState;
  projectless?: boolean;
  turnPromptId?: string; turnStartedAt?: number; completedTurn?: CompletedTurn; work: WorkStatus;
}
export interface ActivityContent {
  title?: string; backgroundUpdates?: boolean; project: string; agent: string; state: string; phase: string; summary: string;
  startedAt: number; endedAt?: number; updatedAt: number;
}
export function activityContent(s: ActivitySnapshot, details: boolean, startedAt: number): ActivityContent {
  return {
    title: details ? concise(s.title?.trim() || s.work.project, 100) : "Codeaw",
    backgroundUpdates: true,
    project: details ? concise(s.work.project, 60) : "Codeaw", agent: concise(s.agentId, 30),
    state: s.state, phase: s.work.phase,
    summary: details ? concise(s.work.summary) : s.work.phase === "error" ? "執行失敗" : s.work.phase === "cancelled" ? "已停止" : s.work.phase === "disconnected" ? "等待重新同步" : s.state === "idle" ? "已完成" : s.state === "requires_action" ? "等待你的回覆" : "AI 正在工作…",
    startedAt, ...(s.state === "idle" ? { endedAt: s.completedTurn?.endedAt ?? Date.now() } : {}), updatedAt: Date.now(),
  };
}
export function activityPayload(content: ActivityContent, now = Date.now()): object {
  const end = content.state === "idle";
  return { aps: { timestamp: Math.floor(now / 1000), event: end ? "end" : "update", "content-state": content,
    ...(end ? { "dismissal-date": Math.floor(now / 1000) + 60 } : { "stale-date": Math.floor(now / 1000) + 120 }),
  } };
}

export interface PushResult { status: number; reason?: string }
export type ActivityTransport = (token: string, headers: Record<string, string>, payload: object) => Promise<PushResult>;
interface Registration {
  deviceId: string; activityId: string; sessionId: string; turnId: string; token: string;
  includeDetails: boolean; startedAt: number; expiresAt: number; lastSent: number;
  latest?: ActivitySnapshot; timer?: NodeJS.Timeout; sending: boolean; failures: number;
}

/** Device-bound subscriptions survive WebSocket suspension. No APNs keys or tokens reach logs. */
export class LiveActivityPush {
  private readonly registrations = new Map<string, Registration>();
  private readonly key?: crypto.KeyObject;
  private provider?: { value: string; at: number };
  private connection?: http2.ClientHttp2Session;
  private heartbeat?: NodeJS.Timeout;
  private stopped = false;
  private lastError?: string;

  constructor(
    private readonly config: LiveActivityConfig | undefined,
    private readonly deviceExists: (id: string) => boolean,
    private readonly snapshot: (sessionId: string) => ActivitySnapshot | undefined,
    private readonly transport: ActivityTransport = (token, headers, payload) => this.sendHttp2(token, headers, payload),
  ) {
    if (!config) return;
    try {
      const key = crypto.createPrivateKey(fs.readFileSync(config.privateKeyPath));
      if (key.asymmetricKeyType !== "ec" || key.asymmetricKeyDetails?.namedCurve !== "prime256v1") throw new Error("key");
      this.key = key;
      this.heartbeat = setInterval(() => {
        for (const r of this.registrations.values()) {
          const s = snapshot(r.sessionId);
          if (s) this.observe(s); else this.remove(r);
        }
      }, 60_000);
      this.heartbeat.unref();
    } catch {
      this.lastError = "APNs 金鑰無法讀取，請檢查 privateKeyPath 與 .p8 金鑰";
      log.warn(this.lastError);
    }
  }

  info(): { enabled: boolean; ready: boolean; environment?: string; includeDetails?: boolean; error?: string } {
    return { enabled: !!this.config, ready: !!this.key, environment: this.config?.environment,
      includeDetails: this.config?.includeDetails, error: this.lastError };
  }

  register(deviceId: string, params: Record<string, any>): object {
    if (!this.key || !this.config) return { registered: false, ...this.info() };
    const { activityId, sessionId, turnId, pushToken } = params;
    if (![activityId, sessionId, turnId].every((v) => typeof v === "string" && v.length > 0 && v.length <= 200) ||
      typeof pushToken !== "string" || !/^[a-f0-9]{32,512}$/i.test(pushToken)) throw new Error("Invalid Live Activity registration");
    if (!this.deviceExists(deviceId)) throw new Error("Device revoked");
    const s = this.snapshot(sessionId);
    if (!s || (s.turnPromptId !== turnId && s.completedTurn?.promptId !== turnId)) throw new Error("Live Activity turn is no longer current");
    const id = deviceId + ":" + activityId;
    const previous = this.registrations.get(id);
    if (previous) this.remove(previous);
    const owned = [...this.registrations.values()].filter((r) => r.deviceId === deviceId);
    if (owned.length >= 16 || this.registrations.size >= 64) throw new Error("Too many Live Activities");
    const now = Date.now();
    const r: Registration = { deviceId, activityId, sessionId, turnId, token: pushToken.toLowerCase(),
      includeDetails: params.includeDetails === true, startedAt: s.turnStartedAt ?? s.completedTurn?.startedAt ?? now,
      expiresAt: now + 8 * 60 * 60_000, lastSent: 0, sending: false, failures: 0 };
    this.registrations.set(id, r);
    this.observe(s);
    return { registered: true, ...this.info() };
  }

  unregister(deviceId: string, activityId: unknown): object {
    const r = this.registrations.get(deviceId + ":" + activityId);
    if (r) this.remove(r);
    return {};
  }

  observe(s: ActivitySnapshot): void {
    for (const r of this.registrations.values()) {
      if (r.sessionId !== s.sessionId) continue;
      if (!this.deviceExists(r.deviceId) || r.expiresAt < Date.now()) { this.remove(r); continue; }
      r.latest = s.turnPromptId === r.turnId || s.completedTurn?.promptId === r.turnId ? s : {
        ...s, state: "idle", completedTurn: { promptId: r.turnId, startedAt: r.startedAt, endedAt: Date.now() },
        work: { ...s.work, phase: "completed", summary: "已完成" },
      };
      if (r.latest.state !== "running" && r.timer) { clearTimeout(r.timer); r.timer = undefined; }
      this.schedule(r);
    }
  }

  private schedule(r: Registration, retryMs = 0): void {
    if (r.sending || r.timer || this.stopped) return;
    // Coalesce streamed summaries. End/approval bypass the normal 15-second interval.
    const important = r.latest?.state !== "running";
    const wait = Math.max(retryMs, r.lastSent + (important ? 1000 : 15_000) - Date.now(), 0);
    r.timer = setTimeout(() => { r.timer = undefined; void this.deliver(r); }, wait);
    r.timer.unref();
  }

  private jwt(): string {
    const now = Math.floor(Date.now() / 1000);
    if (this.provider && now - this.provider.at < 3000) return this.provider.value;
    const header = Buffer.from(JSON.stringify({ alg: "ES256", kid: this.config!.keyId })).toString("base64url");
    const claims = Buffer.from(JSON.stringify({ iss: this.config!.teamId, iat: now })).toString("base64url");
    const signature = crypto.sign("sha256", Buffer.from(header + "." + claims), { key: this.key!, dsaEncoding: "ieee-p1363" }).toString("base64url");
    const value = header + "." + claims + "." + signature;
    this.provider = { value, at: now };
    return value;
  }

  private async deliver(r: Registration): Promise<void> {
    if (this.stopped || !r.latest || !this.deviceExists(r.deviceId) || r.expiresAt < Date.now()) { this.remove(r); return; }
    r.sending = true;
    const s = r.latest;
    r.latest = undefined;
    const content = activityContent(s, this.config!.includeDetails && r.includeDetails, r.startedAt);
    const headers = { authorization: "bearer " + this.jwt(), "apns-topic": this.config!.bundleId + ".push-type.liveactivity",
      "apns-push-type": "liveactivity", "apns-priority": s.state === "running" ? "5" : "10", "apns-expiration": "0" };
    try {
      const result = await this.transport(r.token, headers, activityPayload(content));
      r.lastSent = Date.now();
      if (result.status === 200) {
        this.lastError = undefined;
        r.failures = 0;
        if (s.state === "idle") this.remove(r);
      } else if (result.status === 410 || (result.status === 400 && ["BadDeviceToken", "DeviceTokenNotForTopic"].includes(result.reason ?? ""))) {
        this.lastError = `APNs ${result.status}：${result.reason}`;
        this.remove(r);
      } else {
        this.lastError = `APNs 回應 ${result.status}，請檢查簽名、環境與金鑰`;
        r.latest ??= s;
        r.failures++;
      }
    } catch {
      this.lastError = "無法連線 Apple APNs";
      r.latest ??= s;
      r.failures++;
    } finally {
      r.sending = false;
      if (this.registrations.get(r.deviceId + ":" + r.activityId) === r && r.latest) this.schedule(r, r.failures ? Math.min(60_000, 5000 * 2 ** Math.min(r.failures, 4)) : 0);
    }
  }

  private sendHttp2(token: string, headers: Record<string, string>, payload: object): Promise<PushResult> {
    if (!this.connection || this.connection.closed || this.connection.destroyed) {
      this.connection = http2.connect(this.config!.environment === "sandbox" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com");
      this.connection.on("error", () => { /* Each pending stream handles its own failure. */ });
      const connection = this.connection;
      connection.on("goaway", () => connection.close());
    }
    const connection = this.connection;
    return new Promise((resolve, reject) => {
      const request = connection.request({ ":method": "POST", ":path": "/3/device/" + token, ...headers });
      let status = 0, body = "";
      request.setTimeout(10_000, () => request.destroy(new Error("APNs timeout")));
      request.on("response", (h) => { status = Number(h[":status"]); });
      request.setEncoding("utf8");
      request.on("data", (chunk) => { if (body.length < 1024) body += chunk; });
      request.on("error", reject);
      request.on("end", () => {
        let reason: string | undefined;
        try { reason = JSON.parse(body).reason; } catch { /* Empty success response. */ }
        resolve({ status, reason });
      });
      request.end(JSON.stringify(payload));
    });
  }

  private remove(r: Registration): void {
    if (r.timer) clearTimeout(r.timer);
    const key = r.deviceId + ":" + r.activityId;
    if (this.registrations.get(key) === r) this.registrations.delete(key);
  }

  dispose(): void {
    this.stopped = true;
    if (this.heartbeat) clearInterval(this.heartbeat);
    for (const r of this.registrations.values()) this.remove(r);
    this.connection?.destroy();
  }
}
