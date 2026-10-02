import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { afterEach, describe, expect, it } from "vitest";
import YAML from "yaml";
import { loadConfig } from "../src/config.js";
import { BridgeRuntime } from "../src/desktop/runtime.js";
import { requestControl, runningStatus, serveControl } from "../src/desktop/control.js";
import { bridgeInvocation } from "../src/desktop/process.js";
import { launchdPlist, quoteWindowsArgument, systemdUnit } from "../src/desktop/service.js";
import { desktopSettings } from "../src/desktop/settings.js";
import { loginCommand } from "../src/desktop/autostart.js";
import { setLogSilent } from "../src/util/log.js";
import { startBridge } from "../src/bridge.js";

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

async function start(file = configFile()) {
  const runtime = new BridgeRuntime(loadConfig(file));
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
  for (const home of homes.splice(0)) fs.rmSync(home, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
});

describe("desktop runtime", () => {
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
    await new Promise<void>((resolve) => occupied.listen(0, "127.0.0.2", resolve));
    const port = (occupied.address() as net.AddressInfo).port;
    await expect(startBridge(loadConfig(file), { hosts: ["127.0.0.1", "127.0.0.2"], port })).rejects.toThrow();
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

  it("survives the launching CLI, avoids duplicate background processes, restarts and stops", async () => {
    const file = configFile();
    try {
      await cli(file, ["start", "--background"]);
      const first = await runningStatus(file);
      expect(first.state).toBe("running");
      expect(first.pid).not.toBe(process.pid);
      await cli(file, ["start", "--background"]);
      expect((await runningStatus(file)).pid).toBe(first.pid);
      await cli(file, ["restart"]);
      expect((await runningStatus(file)).state).toBe("running");
      expect(await cli(file, ["status"])).toContain("running");
      // The service/background log contains no interactive pairing code.
      expect(fs.readFileSync(path.join(path.dirname(file), "bridge.log"), "utf8")).not.toContain("配對碼");
    } finally { await cli(file, ["stop"]); }
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
