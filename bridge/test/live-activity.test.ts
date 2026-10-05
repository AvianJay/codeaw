import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { LiveActivityPush, activityPayload, activityContent, type ActivitySnapshot, type ActivityTransport } from "../src/notify/live-activity.js";
import { ConfigSchema, type LiveActivityConfig } from "../src/config.js";
import { newFakeSession, promptText, startTestBridge, TestClient } from "./helpers.js";

const homes: string[] = [];
const services: LiveActivityPush[] = [];
afterEach(() => { services.forEach((s) => s.dispose()); services.length = 0; vi.useRealTimers(); homes.forEach((h) => fs.rmSync(h, { recursive: true, force: true })); homes.length = 0; });
function config(): LiveActivityConfig {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-apns-")); homes.push(home);
  const pair = crypto.generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const keyFile = path.join(home, "AuthKey.p8");
  fs.writeFileSync(keyFile, pair.privateKey.export({ type: "pkcs8", format: "pem" }));
  return { teamId: "ABCDE12345", keyId: "12345ABCDE", privateKeyPath: keyFile, bundleId: "tw.avianjay.codeaw", environment: "sandbox", includeDetails: true };
}
const snapshot: ActivitySnapshot = { sessionId: "codex:s", agentId: "codex", state: "running", turnPromptId: "turn", turnStartedAt: 1000,
  work: { project: "Codeaw", phase: "command", summary: "npm test", updatedAt: 1000 } };
const registration = { activityId: "activity", sessionId: "codex:s", turnId: "turn", pushToken: "a".repeat(64), includeDetails: true };

describe("APNs Live Activities", () => {
  it("builds matching bounded content and explicit end/stale dates; redacts details", () => {
    const content = activityContent(snapshot, true, 1000);
    expect(content).toMatchObject({ project: "Codeaw", summary: "npm test", startedAt: 1000 });
    const update: any = activityPayload(content, 200_000);
    expect(update.aps).toMatchObject({ event: "update", timestamp: 200, "stale-date": 320 });
    const redacted = activityContent({ ...snapshot, work: { ...snapshot.work, project: "secret", summary: "secret command" } }, false, 1000);
    expect(redacted.project).toBe("Codeaw"); expect(redacted.summary).not.toContain("secret");
    const end: any = activityPayload(activityContent({ ...snapshot, state: "idle", completedTurn: { promptId: "turn", startedAt: 1000, endedAt: 3000 } }, true, 1000), 200_000);
    expect(end.aps).toMatchObject({ event: "end", "dismissal-date": 260, "content-state": { endedAt: 3000 } });
    expect(Buffer.byteLength(JSON.stringify(update))).toBeLessThan(4096);
  });

  it("signs ES256, coalesces updates, ends promptly and keeps the start time", async () => {
    vi.useFakeTimers(); vi.setSystemTime(100_000);
    const cfg = config();
    const send = vi.fn<ActivityTransport>(async () => ({ status: 200 }));
    const service = new LiveActivityPush(cfg, () => true, () => snapshot, send); services.push(service);
    service.register("phone", registration);
    await vi.advanceTimersByTimeAsync(1);
    expect(send).toHaveBeenCalledTimes(1);
    const headers = send.mock.calls[0][1] as any;
    expect(headers).toMatchObject({ "apns-topic": "tw.avianjay.codeaw.push-type.liveactivity", "apns-push-type": "liveactivity", "apns-priority": "5" });
    const jwt = headers.authorization.replace("bearer ", "").split(".");
    expect(JSON.parse(Buffer.from(jwt[1], "base64url").toString())).toMatchObject({ iss: cfg.teamId, iat: 100 });
    expect(crypto.verify("sha256", Buffer.from(jwt[0] + "." + jwt[1]), { key: crypto.createPublicKey(fs.readFileSync(cfg.privateKeyPath)), dsaEncoding: "ieee-p1363" }, Buffer.from(jwt[2], "base64url"))).toBe(true);
    for (const text of ["first", "latest"]) service.observe({ ...snapshot, work: { ...snapshot.work, summary: text } });
    await vi.advanceTimersByTimeAsync(15_001);
    expect(send).toHaveBeenCalledTimes(2);
    expect((send.mock.calls[1][2] as any).aps["content-state"].summary).toBe("latest");
    service.observe({ ...snapshot, state: "idle", completedTurn: { promptId: "turn", startedAt: 1000, endedAt: 116_000 } });
    await vi.advanceTimersByTimeAsync(1001);
    expect((send.mock.calls.at(-1)![2] as any).aps).toMatchObject({ event: "end", "content-state": { startedAt: 1000, endedAt: 116_000 } });
  });

  it("binds tokens to their paired device, drops invalid/revoked tokens and bounds registrations", async () => {
    vi.useFakeTimers(); vi.setSystemTime(100_000);
    let authorized = true;
    const send = vi.fn(async () => ({ status: 410 }));
    const service = new LiveActivityPush(config(), () => authorized, () => snapshot, send); services.push(service);
    expect(() => service.register("phone", { ...registration, pushToken: "bad token" })).toThrow();
    expect(() => service.register("phone", { ...registration, turnId: "old" })).toThrow();
    service.register("phone", registration);
    service.unregister("different-phone", "activity");
    await vi.advanceTimersByTimeAsync(1);
    expect(send).toHaveBeenCalledTimes(1);
    service.observe(snapshot); await vi.advanceTimersByTimeAsync(60_000);
    expect(send).toHaveBeenCalledTimes(1);
    service.register("phone", registration); authorized = false;
    await vi.advanceTimersByTimeAsync(1);
    expect(send).toHaveBeenCalledTimes(1);
    expect(() => service.register("phone", registration)).toThrow("revoked");
  });

  it("retries end events after a transient failure instead of leaving a running island", async () => {
    vi.useFakeTimers(); vi.setSystemTime(100_000);
    const send = vi.fn().mockResolvedValueOnce({ status: 503 }).mockResolvedValue({ status: 200 });
    const end = { ...snapshot, state: "idle" as const, completedTurn: { promptId: "turn", startedAt: 1000, endedAt: 3000 } };
    const service = new LiveActivityPush(config(), () => true, () => end, send); services.push(service);
    service.register("phone", registration); await vi.advanceTimersByTimeAsync(1);
    await vi.advanceTimersByTimeAsync(10_001);
    expect(send).toHaveBeenCalledTimes(2);
    expect((send.mock.calls[1][2] as any).aps.event).toBe("end");
  });

  it("approval and completion bypass a pending streamed-text timer", async () => {
    vi.useFakeTimers(); vi.setSystemTime(100_000);
    const send = vi.fn<ActivityTransport>(async () => ({ status: 200 }));
    const service = new LiveActivityPush(config(), () => true, () => snapshot, send); services.push(service);
    service.register("phone", registration); await vi.advanceTimersByTimeAsync(1);
    service.observe({ ...snapshot, work: { ...snapshot.work, summary: "next command" } });
    service.observe({ ...snapshot, state: "requires_action", work: { ...snapshot.work, phase: "attention", summary: "等待批准" } });
    await vi.advanceTimersByTimeAsync(1001);
    expect(send).toHaveBeenCalledTimes(2);
    expect((send.mock.calls[1][2] as any).aps["content-state"].phase).toBe("attention");
  });

  it("rejects invalid key curves and never reports a failed key as usable", () => {
    const cfg = config();
    fs.writeFileSync(cfg.privateKeyPath, crypto.generateKeyPairSync("ec", { namedCurve: "secp384r1" }).privateKey.export({ type: "pkcs8", format: "pem" }));
    const service = new LiveActivityPush(cfg, () => true, () => snapshot); services.push(service);
    expect(service.info()).toMatchObject({ enabled: true, ready: false });
    expect(service.register("phone", registration)).toMatchObject({ registered: false });
  });

  it("defaults APNs off and exposes running work to unattached authenticated phones", async () => {
    expect(ConfigSchema.parse({ agents: {} }).notifications.liveActivity).toBeUndefined();
    const tb = await startTestBridge();
    const sender = await TestClient.connect(tb.url, tb.tokenFor("A"));
    const watcher = await TestClient.connect(tb.url, tb.tokenFor("B"));
    try {
      const session = await newFakeSession(sender, tb.home);
      const run = sender.request("session/prompt", promptText(session.sessionId, "slow 30"));
      await watcher.waitFor(() => watcher.received.some((r) => r.method === "_codeaw/activity" && r.params.state === "running"));
      const list: any = await watcher.request("_codeaw/activity/list", {});
      expect(list.activities[0]).toMatchObject({ state: "running", turnPromptId: expect.any(String), turnStartedAt: expect.any(Number), work: { project: path.basename(tb.home) } });
      expect(await watcher.request("_codeaw/live_activity/info", {})).toMatchObject({ enabled: false, ready: false });
      await run;
      await watcher.waitFor(() => watcher.received.some((r) => r.method === "_codeaw/activity" && r.params.state === "idle" && r.params.completedTurn));
      expect(watcher.received.filter((r) => r.method === "session/update")).toHaveLength(0);
    } finally { sender.close(); watcher.close(); await tb.stop(); }
  });
});
