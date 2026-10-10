import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { spawn, execFile } from "node:child_process";
import { promisify } from "node:util";
import http from "node:http";
import crypto from "node:crypto";
import { afterEach, describe, expect, it, vi } from "vitest";
import YAML from "yaml";
import { loadConfig } from "../src/config.js";
import { BridgeRuntime } from "../src/desktop/runtime.js";
import { requestControl, runningStatus, serveControl } from "../src/desktop/control.js";
import { bridgeInvocation } from "../src/desktop/process.js";
import { launchdPlist, quoteWindowsArgument, systemdUnit } from "../src/desktop/service.js";
import { desktopSettings } from "../src/desktop/settings.js";
import { loginCommand } from "../src/desktop/autostart.js";
import { setLogSilent } from "../src/util/log.js";
import { startBridge, type BridgeOptions } from "../src/bridge.js";
import { createAppLaunch } from "../src/desktop/pairing.js";
import { ACP_REGISTRY_URL, platformTarget } from "../src/agents/registry.js";
import { VERSION, BUILD_NUMBER, UPDATE_CHANNEL } from "../src/version.js";
import { TestClient, FAKE_AGENT, BRIDGE_DIR, newFakeSession, promptText } from "./helpers.js";
import * as gatewayConfig from "../src/remote-desktop/gateway-config.js";
import * as environment from "../src/util/environment.js";
import { desktopHelper } from "../src/remote-desktop/native.js";

setLogSilent(true);
const homes: string[] = [];
const runtimes: BridgeRuntime[] = [];
const servers: net.Server[] = [];

function configFile() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-desktop-"));
  homes.push(home);
  const file = path.join(home, "config.yaml");
  fs.writeFileSync(file, "# keep my comments\n" + YAML.stringify({ listen: { hosts: ["127.0.0.1"], port: 0 }, workspaces: [home],
    agents: { fake: { name: "Fake", command: "unused", env: { SYNTHETIC_TEST_SECRET: "fixture-value" }, enabled: true } },
    notifications: { ntfy: { topic: "test", token: "synthetic-token" } }, custom: { preserved: true } }));
  return file;
}

async function start(file = configFile(), options: BridgeOptions = {}) {
  const runtime = new BridgeRuntime(loadConfig(file), options);
  runtimes.push(runtime);
  await runtime.start();
  return runtime;
}

async function freePort(): Promise<number> {
  const server = net.createServer();
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as net.AddressInfo).port;
  await new Promise<void>((resolve) => server.close(() => resolve()));
  return port;
}

afterEach(async () => {
  for (const runtime of runtimes.splice(0)) await runtime.stop();
  for (const server of servers.splice(0)) await new Promise<void>((resolve) => server.close(() => resolve()));
  for (const home of homes.splice(0)) await fs.promises.rm(home, { recursive: true, force: true, maxRetries: 15, retryDelay: 100 });
  vi.restoreAllMocks();
});

describe("desktop runtime", () => {
  it("detects local agents over IPC without registry access, preserves running clients and applies after restart", async () => {
    const runtime = await start();
    const file = runtime.loaded.file;
    const firstBridge = runtime.bridge!;
    firstBridge.devices.addDeviceWithToken("Detection fixture", "synthetic-detection-token");
    const client = await TestClient.connect(`ws://127.0.0.1:${firstBridge.port()}/acp`, "synthetic-detection-token");
    vi.spyOn(environment, "resolveCommand").mockImplementation((name) => name === "omp" ? "/installed/omp" : undefined);
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("Offline fixture"));
    try {
      expect(await requestControl(file, { command: "detectAgents" })).toEqual({
        detected: [{ id: "omp", name: "Oh My Pi" }], added: [{ id: "omp", name: "Oh My Pi" }], existing: [], restartRequired: true,
      });
      expect(runtime.bridge).toBe(firstBridge);
      expect(firstBridge.registry.has("omp")).toBe(false);
      expect((await client.request("_codeaw/agents/list", {})).agents.map((agent: any) => agent.id)).toEqual(["fake"]);
      const configured = loadConfig(file).config;
      expect(configured.agents.omp.args).toEqual(["acp"]);
      expect(configured.agents.fake.env).toEqual({ SYNTHETIC_TEST_SECRET: "fixture-value" });
      expect(fs.readFileSync(file, "utf8")).toContain("# keep my comments");
      expect(globalThis.fetch).not.toHaveBeenCalled();
      expect(await requestControl(file, { command: "detectAgents" })).toMatchObject({ added: [], existing: [{ id: "omp", name: "Oh My Pi" }], restartRequired: false });
      client.close();
      await requestControl(file, { command: "restart" });
      expect(runtime.bridge!.registry.has("omp")).toBe(true);
      expect(runtime.status().agents).toContainEqual({ id: "omp", name: "Oh My Pi", status: "stopped" });
    } finally { client.close(); }
  });

  it.skipIf(process.platform === "win32" && !desktopHelper())("migrates gateway listeners while an agent turn and its ACP connection remain live", async () => {
    const file = configFile();
    const parsed = YAML.parse(fs.readFileSync(file, "utf8"));
    parsed.agents.fake = { name: "Fake", command: process.execPath, args: ["--import", "tsx", FAKE_AGENT], cwd: BRIDGE_DIR, enabled: true };
    fs.writeFileSync(file, YAML.stringify(parsed));
    const registration = vi.spyOn(gatewayConfig, "gatewayRegistration").mockReturnValue(undefined);
    const runtime = await start(file);
    const bridge = runtime.bridge!;
    const port = bridge.port();
    const token = "synthetic-migration-token";
    bridge.devices.addDeviceWithToken("Migration test", token);
    const client = await TestClient.connect(`ws://127.0.0.1:${port}/acp`, token);
    const session = await newFakeSession(client, runtime.loaded.home);
    const turn = client.request("session/prompt", promptText(session.sessionId, "slow 50"));
    await client.waitFor(() => client.text(session.sessionId).length > 0);
    const ownerSid = process.platform === "win32"
      ? (await promisify(execFile)("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", "[Security.Principal.WindowsIdentity]::GetCurrent().User.Value"], { windowsHide: true })).stdout.trim()
      : "S-1-5-21-1-2-3-1001";
    const pipe = process.platform === "win32" ? `\\\\.\\pipe\\codeaw-backend-${crypto.randomBytes(16).toString("hex")}` : path.join(runtime.loaded.home, "backend.sock");
    registration.mockReturnValue({ name: "CodeawDesktop-0123456789abcdef", configFile: file, home: runtime.loaded.home, ownerSid,
      backendPipe: pipe, port, hosts: ["127.0.0.1"], gateway: "unused", helper: desktopHelper() ?? "unused", webRoot: "unused", enabled: true });
    await requestControl(file, { command: "activateDesktopGateway" });
    expect(runtime.bridge).toBe(bridge);
    expect(bridge.addresses()).toEqual([`127.0.0.1:${port}`]);
    const pipeHealth = await new Promise<number>((resolve, reject) => {
      const request = http.get({ socketPath: pipe, path: "/api/health" }, (response) => { response.resume(); resolve(response.statusCode!); });
      request.on("error", reject);
    });
    expect(pipeHealth).toBe(200);
    const probe = net.createServer(); servers.push(probe);
    await new Promise<void>((resolve, reject) => { probe.once("error", reject); probe.listen(port, "127.0.0.1", resolve); });
    await new Promise<void>((resolve) => probe.close(() => resolve())); servers.splice(servers.indexOf(probe), 1);
    registration.mockReturnValue(undefined);
    await requestControl(file, { command: "activateDesktopGateway" });
    expect((await fetch(`http://127.0.0.1:${port}/api/health`)).status).toBe(200);
    expect(await turn).toHaveProperty("stopReason", "end_turn");
    expect(client.events(session.sessionId, "error")).toEqual([]);
    expect(runtime.bridge).toBe(bridge);
    client.close();
  });

  it("exposes update state through local IPC without opening remote update administration", async () => {
    const runtime = await start();
    const file = runtime.loaded.file;
    expect(await requestControl(file, { command: "status" })).toMatchObject({ version: VERSION, buildNumber: BUILD_NUMBER, channel: UPDATE_CHANNEL });
    expect(await requestControl(file, { command: "updaterStatus" })).toMatchObject({ state: "idle", channel: UPDATE_CHANNEL });
    await expect(requestControl(file, { command: "setUpdateChannel", channel: "invalid" })).rejects.toThrow(/channel/);
    const channel = UPDATE_CHANNEL === "release" ? "nightly" : "release";
    expect(await requestControl(file, { command: "setUpdateChannel", channel })).toMatchObject({ channel, state: "idle" });
    await expect(requestControl(file, { command: "prepareBridgeUpdate", kind: "portable" })).rejects.toThrow(/newer/);
    await expect(requestControl(file, { command: "bridgeUpdateInstaller" })).rejects.toThrow(/verified/);
    expect((await fetch(`http://127.0.0.1:${runtime.bridge!.port()}/api/prepareBridgeUpdate`)).status).toBe(401);
  });

  it("installs through local IPC, keeps the bridge running until restart and loads the new agent", async () => {
    const runtime = await start();
    const file = runtime.loaded.file;
    const fetchOriginal = globalThis.fetch;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, options) => {
      if (input === ACP_REGISTRY_URL) return new Response(JSON.stringify({ agents: [{
        id: "test-agent", name: "Installed fixture", version: "1.0.0", distribution: { binary: {
          [platformTarget()]: { archive: "https://example.com/fixture.exe", cmd: "./agent.exe", args: ["acp"] },
        } },
      }] }));
      if (input === "https://example.com/fixture.exe") return new Response("synthetic executable fixture");
      return fetchOriginal(input, options);
    });
    const firstBridge = runtime.bridge;
    expect((await requestControl(file, { command: "agentCatalog" }))[0]).toMatchObject({ supported: true, configured: false });
    await expect(requestControl(file, { command: "installAgent", id: "unknown" })).rejects.toThrow(/Unknown ACP registry agent/);
    await requestControl(file, { command: "installAgent", id: "test-agent" });
    expect((await runtime.installer.wait()).state).toBe("succeeded");
    expect((await requestControl(file, { command: "installerStatus" })).state).toBe("succeeded");
    expect(runtime.bridge).toBe(firstBridge);
    expect(runtime.bridge!.registry.has("test-agent")).toBe(false);
    const installed = loadConfig(file).config.agents["test-agent"];
    expect(installed.args).toEqual(["acp"]);
    expect(fs.readFileSync(installed.command, "utf8")).toBe("synthetic executable fixture");
    expect((await requestControl(file, { command: "agentCatalog" }))[0].configured).toBe(true);
    expect((await fetch(`http://127.0.0.1:${runtime.bridge!.port()}/api/installAgent`)).status).toBe(401);
    await requestControl(file, { command: "restart" });
    expect(runtime.bridge!.registry.has("test-agent")).toBe(true);
    expect(fs.readFileSync(file, "utf8")).toContain("# keep my comments");
  });

  it("opens the live local web app with a one-time code and keeps launching off HTTP", async () => {
    const file = configFile();
    const webRoot = path.join(path.dirname(file), "web");
    fs.mkdirSync(webRoot);
    fs.writeFileSync(path.join(webRoot, "index.html"), "<!doctype html><title>codeaw</title>");
    const runtime = await start(file, { webRoot });
    const app = await requestControl(file, { command: "app" });
    const url = new URL(app.url);
    expect(url.origin).toBe(`http://127.0.0.1:${runtime.bridge!.port()}`);
    expect(url.searchParams.has("pair")).toBe(true);
    expect(url.searchParams.has("token")).toBe(false);
    expect(await (await fetch(url)).text()).toContain("<title>codeaw</title>");
    const response = await fetch(new URL("/api/pair", url), {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code: url.searchParams.get("c"), deviceName: "Desktop App" }),
    });
    expect(response.status).toBe(200);
    expect(runtime.bridge!.devices.isPairingCodePending(url.searchParams.get("c")!)).toBe(false);
    expect(runtime.bridge!.devices.pair(url.searchParams.get("c")!, "Another App")).toHaveProperty("status", 403);
    expect((await fetch(new URL("/api/app", url))).status).toBe(401);
    const next = new URL((await requestControl(file, { command: "app" })).url);
    expect(next.searchParams.get("c")).not.toBe(url.searchParams.get("c"));
    expect(runtime.bridge!.devices.isPairingCodePending(next.searchParams.get("c")!)).toBe(true);
  });

  it("reports missing web assets without issuing a code", async () => {
    const file = configFile();
    await start(file, { webRoot: path.join(path.dirname(file), "missing") });
    await expect(requestControl(file, { command: "app" })).rejects.toThrow(/npm run build:web/);
    expect(fs.existsSync(path.join(path.dirname(file), "pairing.json"))).toBe(false);
  });

  it("uses loopback for wildcard and IPv6 listeners and rejects remote-only listeners", () => {
    const home = path.dirname(configFile());
    expect(new URL(createAppLaunch(home, 7860, ["100.64.0.10:7860", "0.0.0.0:7860"]).url).host).toBe("127.0.0.1:7860");
    expect(new URL(createAppLaunch(home, 7860, ["::1:7860"]).url).host).toBe("[::1]:7860");
    expect(() => createAppLaunch(home, 7860, ["100.64.0.10:7860"])).toThrow(/local listener/);
  });

  it("uses the live port for pairing and keeps administration off the phone HTTP server", async () => {
    const runtime = await start();
    const file = runtime.loaded.file;
    const status = await requestControl(file, { command: "status" });
    expect(status.state).toBe("running");
    expect(status.port).toBeGreaterThan(0);
    const pair = await requestControl(file, { command: "pair" });
    expect(pair.urls[0]).toBe(`ws://127.0.0.1:${status.port}/acp`);
    expect(pair.qr).toMatch(/^data:image\/png;base64,/);
    const link = new URL(pair.link);
    expect(link.searchParams.get("c")).toBe(pair.code.replace("-", ""));
    expect(await requestControl(file, { command: "pairingStatus", code: pair.code })).toEqual({ pending: true });
    const response = runtime.bridge!.devices.pair(pair.code, "Test phone");
    expect(response).toHaveProperty("token");
    expect(await requestControl(file, { command: "pairingStatus", code: pair.code })).toEqual({ pending: false });
    expect(runtime.bridge!.devices.pair(pair.code, "Second phone")).toHaveProperty("status", 403);
    const devices = await requestControl(file, { command: "devices" });
    expect(devices).toHaveLength(1);
    expect(devices[0]).not.toHaveProperty("tokenHash");
    expect(JSON.stringify(await requestControl(file, { command: "settings" }))).not.toContain("fixture-value");
    expect(JSON.stringify(await requestControl(file, { command: "settings" }))).not.toContain("synthetic-token");
    expect((await fetch(`http://127.0.0.1:${status.port}/api/settings`)).status).toBe(401);
    await requestControl(file, { command: "revoke", id: devices[0].id });
    expect(await requestControl(file, { command: "devices" })).toEqual([]);
  });

  it("rejects duplicate instances and releases IPC after stopping", async () => {
    const runtime = await start();
    const duplicate = new BridgeRuntime(runtime.loaded);
    await expect(duplicate.start()).rejects.toThrow();
    expect((await runningStatus(runtime.loaded.file)).state).toBe("running");
    await runtime.stop();
    expect(await runningStatus(runtime.loaded.file)).toBeUndefined();
    const next = await start(runtime.loaded.file);
    expect(next.state).toBe("running");
  });

  it("saves validated settings, preserves advanced YAML and actually rebinds the port", async () => {
    const runtime = await start();
    const file = runtime.loaded.file;
    const port = await freePort();
    const settings = desktopSettings(runtime.loaded);
    const saved = await requestControl(file, { command: "saveSettings", settings: {
      port, workspaces: [runtime.loaded.home], idleSessionCloseMinutes: 15, idleAgentStopMinutes: 45, agents: { fake: false },
    } });
    expect(saved.port).toBe(port);
    expect(saved.agents).toEqual([]);
    expect((await fetch(`http://127.0.0.1:${port}/api/health`)).ok).toBe(true);
    const text = fs.readFileSync(file, "utf8");
    const doc = YAML.parse(text);
    expect(text).toContain("# keep my comments");
    expect(doc.agents.fake.env.SYNTHETIC_TEST_SECRET).toBe("fixture-value");
    expect(doc.notifications.ntfy.token).toBe("synthetic-token");
    expect(doc.custom.preserved).toBe(true);
    expect(settings.agents[0].enabled).toBe(true);
  });

  it("restores the previous config and listener when a settings port is occupied", async () => {
    const runtime = await start();
    const original = fs.readFileSync(runtime.loaded.file, "utf8");
    const occupied = net.createServer();
    servers.push(occupied);
    await new Promise<void>((resolve) => occupied.listen(0, "127.0.0.1", resolve));
    const port = (occupied.address() as net.AddressInfo).port;
    await expect(requestControl(runtime.loaded.file, { command: "saveSettings", settings: {
      port, workspaces: [], idleSessionCloseMinutes: 30, idleAgentStopMinutes: 60, agents: { fake: true },
    } })).rejects.toThrow(/Previous settings were restored/);
    expect(fs.readFileSync(runtime.loaded.file, "utf8")).toBe(original);
    const status = await requestControl(runtime.loaded.file, { command: "status" });
    expect(status.state).toBe("running");
    expect((await fetch(`http://127.0.0.1:${status.port}/api/health`)).ok).toBe(true);
  });

  it("does not touch the config for invalid settings or unknown agents", async () => {
    const runtime = await start();
    const original = fs.readFileSync(runtime.loaded.file, "utf8");
    await expect(requestControl(runtime.loaded.file, { command: "saveSettings", settings: {
      port: -1, workspaces: [], idleSessionCloseMinutes: 30, idleAgentStopMinutes: 60, agents: {},
    } })).rejects.toThrow(/Invalid settings/);
    await expect(requestControl(runtime.loaded.file, { command: "saveSettings", settings: {
      port: 7860, workspaces: [], idleSessionCloseMinutes: 30, idleAgentStopMinutes: 60, agents: { missing: true },
    } })).rejects.toThrow(/Unknown agent/);
    expect(fs.readFileSync(runtime.loaded.file, "utf8")).toBe(original);
  });

  it("releases earlier listeners when a later bind fails", async () => {
    const file = configFile();
    const occupied = net.createServer();
    servers.push(occupied);
    const secondHost = process.platform === "darwin" ? "::1" : "127.0.0.2";
    await new Promise<void>((resolve, reject) => { occupied.once("error", reject); occupied.listen(0, secondHost, resolve); });
    const port = (occupied.address() as net.AddressInfo).port;
    await expect(startBridge(loadConfig(file), { hosts: ["127.0.0.1", secondHost], port })).rejects.toThrow();
    const probe = net.createServer();
    servers.push(probe);
    await new Promise<void>((resolve, reject) => { probe.once("error", reject); probe.listen(port, "127.0.0.1", resolve); });
  });

  it("returns a controlled error for malformed local requests and still accepts the next client", async () => {
    const file = configFile();
    const server = await serveControl(file, async () => "healthy");
    servers.push(server);
    await expect(requestControl(file, { command: null } as any)).rejects.toThrow("Invalid control command");
    expect(await requestControl(file, { command: "status" })).toBe("healthy");
  });
});

describe("background CLI", () => {
  async function cli(file: string, args: string[]) {
    const invocation = bridgeInvocation();
    return new Promise<string>((resolve, reject) => {
      const child = spawn(invocation.executable, [...invocation.args, ...args, "--config", file], { windowsHide: true });
      let output = "";
      child.stdout.on("data", (chunk) => { output += chunk; });
      child.stderr.on("data", (chunk) => { output += chunk; });
      child.once("error", reject);
      child.once("exit", (code) => code === 0 ? resolve(output) : reject(new Error(`${args.join(" ")}: ${output}`)));
    });
  }

  it("retries update checks after a previous failure in the running bridge", async () => {
    const file = configFile();
    let checks = 0;
    let update = { state: "error", message: "Previous update check failed", installedVersion: `${VERSION}+${BUILD_NUMBER}`,
      channel: UPDATE_CHANNEL, target: "windows-x64", releaseUrl: "https://github.com/AvianJay/codeaw/releases/latest", updateAvailable: false };
    servers.push(await serveControl(file, async (request) => {
      if (request.command === "status") return { state: "running" };
      if (request.command === "updaterStatus") return update;
      if (request.command === "checkUpdate") { checks++; update = { ...update, state: "current", message: "Bridge is up to date." }; return update; }
      throw new Error("Unexpected update command");
    }));
    expect(await cli(file, ["update", "check"])).toContain("Bridge is up to date.");
    expect(checks).toBe(1);
  });

  it("survives the launching CLI, avoids duplicate background processes, restarts and stops", async () => {
    const file = configFile();
    let backgroundPid: number | undefined;
    try {
      await cli(file, ["start", "--background"]);
      const first = await runningStatus(file);
      backgroundPid = first.pid;
      expect(first.state).toBe("running");
      expect(first.pid).not.toBe(process.pid);
      await cli(file, ["start", "--background"]);
      expect((await runningStatus(file)).pid).toBe(first.pid);
      await cli(file, ["restart"]);
      expect((await runningStatus(file)).state).toBe("running");
      expect(await cli(file, ["status"])).toContain("running");
      // The service/background log contains no interactive pairing code.
      expect(fs.readFileSync(path.join(path.dirname(file), "bridge.log"), "utf8")).not.toContain("配對碼");
      // Native stderr in Windows PowerShell must not terminate the background
      // wrapper. Starting this deliberately absent agent emits a real error.
      const pairing = await requestControl(file, { command: "pair" });
      const current = await runningStatus(file);
      const response = await fetch(`http://127.0.0.1:${current.port}/api/pair`, { method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code: pairing.code, deviceName: "Background error regression" }) });
      const paired = await response.json() as { token: string };
      const client = await TestClient.connect(`ws://127.0.0.1:${current.port}/acp`, paired.token);
      try {
        await expect(client.request("session/new", { cwd: path.dirname(file), mcpServers: [], _meta: { codeaw: { agentId: "fake" } } })).rejects.toThrow("Internal error");
        await new Promise((resolve) => setTimeout(resolve, 300));
        expect((await runningStatus(file)).pid).toBe(first.pid);
        expect(fs.readFileSync(path.join(path.dirname(file), "bridge.log"), "utf8")).toContain("failed to start");
      } finally { client.close(); }
    } finally {
      await cli(file, ["stop"]);
      // The control pipe closes before Node and its Windows log wrapper exit.
      // Wait before afterEach removes the wrapper's working directory.
      for (let attempt = 0; backgroundPid && attempt < 100; attempt++) {
        try { process.kill(backgroundPid, 0); } catch { break; }
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
    }
    expect(await runningStatus(file)).toBeUndefined();
  });
});

describe("service launch arguments", () => {
  it("escapes spaces, quotes and trailing backslashes without a shell", () => {
    expect(quoteWindowsArgument('C:\\with space\\')).toBe('"C:\\with space\\\\"');
    expect(quoteWindowsArgument('a"b')).toBe('"a\\"b"');
    const invocation = { executable: "/tools/node space", args: ["/source/index.js"] };
    const unit = systemdUnit("/config/a % $/config.yaml", invocation);
    expect(unit).toContain('"/tools/node space" "/source/index.js"');
    expect(unit).toContain("%% $$");
    expect(unit).toContain("Restart=on-failure");
    const plist = launchdPlist("/config/a & b/config.yaml", "tw.codeaw.test", invocation);
    expect(plist).toContain("a &amp; b");
    expect(plist).toContain("<key>SuccessfulExit</key><false/>");
    const startup = loginCommand("C:\\a'b space\\config.yaml", { executable: "C:\\node space\\node.exe", args: ["C:\\index.js"] });
    expect(startup).toContain("-WindowStyle Hidden");
    const script = Buffer.from(startup.split(" ").at(-1)!, "base64").toString("utf16le");
    expect(script).toContain("'C:\\a''b space\\config.yaml'");
    expect(script).toContain("'tray'");
  });
});
