import { afterEach, describe, expect, it } from "vitest";
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { once } from "node:events";
import { WebSocket } from "ws";
import { DeviceStore } from "../src/server/auth.js";
import { DesktopManager } from "../src/remote-desktop/manager.js";
import { FrameBudget, type DesktopBackend, type NativeReply } from "../src/remote-desktop/protocol.js";
import { startDesktopGateway } from "../src/remote-desktop/gateway.js";
import { DESKTOP_INSTALL_SCRIPT, desktopServiceFailure } from "../src/remote-desktop/service.js";
import { GatewayManifest } from "../src/remote-desktop/gateway-config.js";
import { desktopHelper } from "../src/remote-desktop/native.js";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import crypto from "node:crypto";

class FakeDesktop implements DesktopBackend {
  onEvent?: (event: Record<string, any>) => void;
  calls: { command: string; params: Record<string, any> }[] = [];
  disposed = false;
  async request(command: string, params: Record<string, any> = {}): Promise<NativeReply> {
    this.calls.push({ command, params });
    if (command === "video") throw new Error("No encoder");
    const result = command === "info" ? { monitors: [{ id: "m", name: "Monitor", width: 640, height: 360, x: -640, y: 0, primary: true }], smooth: true, hardware: false, state: "ready" }
      : command === "capture" ? { width: 128, height: 128, sourceWidth: 640, sourceHeight: 360, full: params.full,
        tiles: [{ x: 0, y: 0, width: 128, height: 128, offset: 0, length: 3 }], cursor: { x: .5, y: .5, visible: true } } : {};
    return { result, payload: command === "capture" ? Buffer.from([1, 2, 3]) : Buffer.alloc(0) };
  }
  async dispose() { await this.request("release"); this.disposed = true; }
}
const cleanup: (() => Promise<void>)[] = [];
afterEach(async () => { for (const close of cleanup.splice(0).reverse()) await close(); });
async function harness({ enabled = true, system = false, clock }: { enabled?: boolean; system?: boolean; clock?: () => number } = {}) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-desktop-test-"));
  const devices = new DeviceStore(home); const token = "test-device-token", otherToken = "other-test-device-token";
  const device = devices.addDeviceWithToken("Phone", token); devices.addDeviceWithToken("Other", otherToken);
  const backends: FakeDesktop[] = [];
  const manager = new DesktopManager({ devices, enabled: () => enabled, systemAvailable: system, now: clock, available: () => true,
    backendFactory: () => { const backend = new FakeDesktop(); backends.push(backend); return backend; } });
  const server = http.createServer((req, res) => { void manager.onRequest(req, res, new URL(req.url!, "http://localhost")); });
  server.on("upgrade", (req, socket, head) => manager.onUpgrade(req, socket, head, new URL(req.url!, "http://localhost")));
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${(server.address() as any).port}`;
  cleanup.push(async () => { await manager.dispose(); await new Promise<void>((resolve) => server.close(() => resolve()));
    // The harness created this exact temp directory, never a computed project path.
    if (!path.resolve(home).startsWith(path.join(os.tmpdir(), "codeaw-desktop-test-"))) throw new Error("Invalid test directory");
    fs.rmSync(home, { recursive: true, force: true }); });
  const request = (method: string, route: string, data?: unknown, credential = token) => fetch(base + route, {
    method, headers: { Authorization: `Bearer ${credential}`, "Content-Type": "application/json" }, body: data === undefined ? undefined : JSON.stringify(data) });
  const create = async (options: object = {}) => {
    const response = await request("POST", "/api/desktop/sessions", options);
    expect(response.status).toBe(201); return response.json() as Promise<{ sessionId: string; ticket: string; socketPath: string }>;
  };
  const open = async (session: Awaited<ReturnType<typeof create>>, ticket = session.ticket) => {
    const ws = new WebSocket(base.replace("http:", "ws:") + session.socketPath), messages: any[] = [], frames: any[] = [];
    ws.on("error", () => undefined);
    ws.on("message", (bytes, binary) => { if (binary) { const data = Buffer.from(bytes as Buffer); frames.push(JSON.parse(data.subarray(4, 4 + data.readUInt32LE(0)).toString())); }
      else messages.push(JSON.parse(bytes.toString())); });
    await once(ws, "open"); ws.send(JSON.stringify({ type: "auth", ticket }));
    return { ws, messages, frames, send: (value: unknown) => ws.send(JSON.stringify(value)) };
  };
  return { home, base, manager, devices, token, device, otherToken, backends, request, create, open };
}
async function until(predicate: () => boolean, timeout = 3000) {
  const start = Date.now(); while (!predicate()) { if (Date.now() - start > timeout) throw new Error("Desktop event timed out"); await new Promise((resolve) => setTimeout(resolve, 10)); }
}

describe("remote desktop", () => {
  it("requires pairing, local opt-in, and an explicit system capability", async () => {
    const h = await harness({ enabled: false });
    expect((await h.request("GET", "/api/desktop/info", undefined, "invalid")).status).toBe(401);
    expect((await h.request("POST", "/api/desktop/sessions", {})).status).toBe(403);
    expect(h.backends).toHaveLength(0);
    const basic = await harness();
    expect((await basic.request("POST", "/api/desktop/sessions", { privilege: "system" })).status).toBe(403);
    expect((await basic.request("POST", "/api/desktop/sessions", { mode: "unknown" })).status).toBe(400);
  });
  it("starts no capture before ticket authentication and rejects parallel control", async () => {
    const h = await harness(); const session = await h.create();
    expect(session.socketPath).not.toContain(session.ticket); expect(h.backends).toHaveLength(0);
    expect((await h.request("POST", "/api/desktop/sessions", {}, h.otherToken)).status).toBe(409);
    const c = await h.open(session, "wrong-ticket"); await until(() => c.ws.readyState === WebSocket.CLOSED);
    expect(h.backends).toHaveLength(0);
    await until(() => c.ws.readyState === WebSocket.CLOSED);
    const next = await h.create(); expect(next.ticket).not.toBe(session.ticket);
  });
  it("waits for rendering ACK, rejects stale input, and preserves Unicode", async () => {
    const h = await harness(); const session = await h.create(); const c = await h.open(session);
    await until(() => c.frames.length === 1);
    c.send({ type: "input", epoch: 1, input: { kind: "text", text: "not-ready" } });
    await new Promise((resolve) => setTimeout(resolve, 150));
    expect(h.backends[0].calls.filter((x) => x.command === "capture")).toHaveLength(1);
    expect(h.backends[0].calls.some((x) => x.command === "input")).toBe(false);
    c.send({ type: "ack", epoch: 1, seq: 1 }); await until(() => c.messages.some((m) => m.state === "active"));
    c.send({ type: "input", epoch: 0, input: { kind: "text", text: "stale" } });
    c.send({ type: "input", epoch: 1, input: { kind: "text", text: "中文😀" } });
    await until(() => h.backends[0].calls.some((x) => x.command === "input"));
    expect(h.backends[0].calls.filter((x) => x.command === "input").map((x) => x.params.input.text)).toEqual(["中文😀"]);
    c.ws.close(); await until(() => h.backends[0].disposed);
    expect(h.backends[0].calls.at(-1)?.command).toBe("release");
  });
  it("validates coordinates and blocks another device from ending the session", async () => {
    const h = await harness(); const session = await h.create(); const c = await h.open(session);
    expect((await h.request("DELETE", `/api/desktop/sessions/${session.sessionId}`, undefined, h.otherToken)).status).toBe(404);
    await until(() => c.frames.length === 1); c.send({ type: "ack", epoch: 1, seq: 1 });
    await until(() => c.messages.some((m) => m.state === "active"));
    c.send({ type: "input", epoch: 1, input: { kind: "pointer", x: 2, y: .5 } });
    await until(() => c.ws.readyState === WebSocket.CLOSED);
    expect(h.backends[0].calls.some((x) => x.command === "input")).toBe(false);
  });
  it("expires tickets and consumes them only once", async () => {
    let now = 0; const h = await harness({ clock: () => now }); const session = await h.create(); now = 30_001;
    const ws = new WebSocket(h.base.replace("http:", "ws:") + session.socketPath);
    const error = await new Promise<Error>((resolve) => ws.once("error", resolve)); expect(error.message).toContain("404");
    expect(h.backends).toHaveLength(0);
    expect((await h.request("DELETE", `/api/desktop/sessions/${session.sessionId}`)).status).toBe(200);
  });
  it("revocation closes a live socket and releases input within two seconds", async () => {
    const h = await harness(); const c = await h.open(await h.create()); await until(() => c.frames.length === 1);
    h.devices.revoke(h.device.id); await until(() => c.ws.readyState === WebSocket.CLOSED, 2000);
    await until(() => h.backends[0].disposed); expect(h.backends[0].calls.at(-1)?.command).toBe("release");
  });
  it("on-demand stops capturing after its activity window, then refreshes", async () => {
    let now = 0; const h = await harness({ clock: () => now }); const c = await h.open(await h.create({ mode: "onDemand" }));
    await until(() => c.frames.length === 1); c.send({ type: "ack", epoch: 1, seq: 1 }); now = 3000;
    await new Promise((resolve) => setTimeout(resolve, 1100)); expect(c.frames).toHaveLength(1);
    c.send({ type: "refresh" }); await until(() => c.frames.length === 2);
    expect(h.backends[0].calls.filter((x) => x.command === "capture").every((x) => x.params.longEdge === 960 && x.params.quality === 45)).toBe(true);
  });
  it("falls back from WebRTC without losing ownership or opening a second worker", async () => {
    const h = await harness(); const c = await h.open(await h.create({ mode: "smooth" }));
    await until(() => c.frames.length === 1); expect(h.backends).toHaveLength(1);
    expect(c.messages.some((m) => m.type === "notice")).toBe(true); expect(c.frames[0].epoch).toBe(2);
  });
  it("accounts oversized frames against the future low-data budget", () => {
    const budget = new FrameBudget(16000, 65536, 0); expect(budget.delay(100000, 0)).toBe(0); budget.consume(100000);
    expect(budget.delay(1, 1000)).toBeGreaterThan(1000); expect(budget.delay(1, 3000)).toBe(0);
  });
});

describe("pre-login gateway", () => {
  it.skipIf(process.platform !== "win32")("writes a sanitized receipt even when installer preflight fails", async () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-install-receipt-"));
    cleanup.push(async () => { fs.rmSync(directory, { recursive: true, force: true }); });
    const script = path.join(directory, "install.ps1"), result = path.join(directory, "result.json");
    fs.writeFileSync(script, "\ufeff" + DESKTOP_INSTALL_SCRIPT);
    await expect(promisify(execFile)("powershell.exe", ["-NoProfile", "-NonInteractive", "-File", script,
      "-RequestFile", path.join(directory, "synthetic-private-value.json"), "-ResultFile", result], { windowsHide: true })).rejects.toMatchObject({ code: 1 });
    const receipt = JSON.parse(fs.readFileSync(result, "utf8"));
    expect(receipt).toEqual({ ok: false, stage: "preflight", code: expect.any(Number) });
    expect(JSON.stringify(receipt)).not.toContain("synthetic-private-value");
  });

  it("reports only recognized install stages and numeric error codes", () => {
    expect(desktopServiceFailure({ stage: "registration", code: 1639, error: "secret" })).toContain("註冊 Windows 服務，錯誤碼 1639");
    expect(desktopServiceFailure({ stage: "secret", code: "secret" })).not.toContain("secret");
    expect(desktopServiceFailure(undefined)).toContain("原設定已保留");
  });
  it.skipIf(process.platform !== "win32" || !desktopHelper())("attests the actual Windows pipe owner before forwarding credentials", async () => {
    const h = await harness();
    const sid = (await promisify(execFile)("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", "[Security.Principal.WindowsIdentity]::GetCurrent().User.Value"], { windowsHide: true })).stdout.trim();
    const pipe = `\\\\.\\pipe\\codeaw-backend-${crypto.randomBytes(16).toString("hex")}`;
    const requests: string[] = [];
    const backend = http.createServer((req, res) => { requests.push(req.headers.authorization ?? ""); res.setHeader("Content-Type", "application/json"); res.end('{"userBackend":true}'); });
    await new Promise<void>((resolve) => backend.listen(pipe, resolve));
    cleanup.push(() => new Promise<void>((resolve) => backend.close(() => resolve())));
    const manifest = { name: "CodeawDesktop-0123456789abcdef", configFile: path.join(h.home, "config.yaml"), home: h.home,
      ownerSid: sid, backendPipe: pipe, port: 7860, hosts: "auto" as const, gateway: "unused", helper: desktopHelper()!, webRoot: "missing", enabled: false };
    const gateway = await startDesktopGateway(manifest, { port: 0, hosts: ["127.0.0.1"] }); cleanup.push(() => gateway.close());
    const response = await fetch(`http://127.0.0.1:${gateway.port()}/api/user-test`, { headers: { Authorization: `Bearer ${h.token}` }, signal: AbortSignal.timeout(6000) });
    expect(response.status).toBe(200); expect(await response.json()).toEqual({ userBackend: true });
    expect(requests).toEqual([`Bearer ${h.token}`]);
    const wrong = await startDesktopGateway({ ...manifest, ownerSid: sid === "S-1-5-18" ? "S-1-5-19" : "S-1-5-18" }, { port: 0, hosts: ["127.0.0.1"] }); cleanup.push(() => wrong.close());
    expect((await fetch(`http://127.0.0.1:${wrong.port()}/api/user-test`, { headers: { Authorization: `Bearer ${h.token}` }, signal: AbortSignal.timeout(6000) })).status).toBe(503);
    expect(requests).toHaveLength(1);
  });
  it("serves Web and desktop while the user backend is offline; auth storage stays read-only", async () => {
    const h = await harness(); fs.mkdirSync(path.join(h.home, "web")); fs.writeFileSync(path.join(h.home, "web/index.html"), "<title>Desktop</title>");
    const gateway = await startDesktopGateway({ name: "CodeawDesktop-0123456789abcdef", configFile: path.join(h.home, "config.yaml"), home: h.home,
      ownerSid: "S-1-5-21-1-2-3-1001", backendPipe: "\\\\.\\pipe\\codeaw-backend-0123456789abcdef0123456789abcdef",
      port: 7860, hosts: "auto", gateway: "unused", helper: "missing-test-helper", webRoot: path.join(h.home, "web"), enabled: false },
      { port: 0, hosts: ["127.0.0.1"] });
    cleanup.push(() => gateway.close()); const base = `http://127.0.0.1:${gateway.port()}`;
    const before = fs.statSync(path.join(h.home, "devices.json")).mtimeMs;
    expect(await (await fetch(base + "/")).text()).toContain("Desktop");
    const response = await fetch(base + "/api/device", { headers: { Authorization: `Bearer ${h.token}` } }); expect(response.status).toBe(200);
    expect(fs.statSync(path.join(h.home, "devices.json")).mtimeMs).toBe(before);
    expect((await (await fetch(base + "/api/health")).json() as any).desktopGateway).toBe(true);
    expect((await fetch(base + "/api/missing")).status).toBe(503);
  });
  it("restricts service manifests and includes transactional rollback and protected paths", () => {
    expect(GatewayManifest.safeParse({ backendPipe: "\\\\other-pc\\pipe\\arbitrary" }).success).toBe(false);
    expect(DESKTOP_INSTALL_SCRIPT).toContain("Assert-Within $root $programRoot");
    expect(DESKTOP_INSTALL_SCRIPT).toContain("Secure-Directory $stage");
    expect(DESKTOP_INSTALL_SCRIPT).toContain("$oldManifest");
    expect(DESKTOP_INSTALL_SCRIPT).not.toContain("Get-Credential");
  });
});
