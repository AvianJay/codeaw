#!/usr/bin/env node
import path from "node:path";
import { parseArgs } from "node:util";
import { defaultConfigFile, loadConfig, writeDefaultConfig, type LoadedConfig } from "./config.js";
import { DeviceStore } from "./server/auth.js";
import { logger, setLogLevel } from "./util/log.js";
import { terminalQr } from "./util/qr.js";
import { VERSION } from "./version.js";
import { requestControl, runningStatus } from "./desktop/control.js";
import { createPairing, wsUrls } from "./desktop/pairing.js";
import { launchDesktop, startBackground } from "./desktop/process.js";
import { BridgeRuntime, type DesktopPage } from "./desktop/runtime.js";
import { manageService } from "./desktop/service.js";
import { loginStartupEnabled, setLoginStartup } from "./desktop/autostart.js";
import { AgentInstaller, type InstallStatus } from "./agents/install.js";
import { BridgeUpdater, installBridgeUpdate, type BridgeUpdateStatus } from "./updater.js";

const log = logger("main");
const HELP = `codeaw-bridge ${VERSION}

Usage: codeaw-bridge [command] [options]

Commands:
  start            Run in the foreground (default on Linux)
  tray             Run in the background with a tray / macOS menu bar
  stop             Gracefully stop the running bridge
  restart          Reload config and restart the running bridge
  status           Show bridge status and connected device count
  settings         Open the desktop settings window
  agents <action>  list / install <id> (ACP registry agents)
  update <action>  check / download / install (verified bridge updates)
  autostart <action> install / uninstall / status (Windows/macOS login tray)
  init             Write a starter config if none exists
  pair             Print a QR / one-time code (valid 5 minutes)
  devices          List paired devices
  revoke <id|name> Remove a paired device
  service <action> install / uninstall / start / stop / restart / status
                   Windows SCM, Linux systemd --user, macOS LaunchAgent

Options:
  -c, --config <file>  Config file (default: ${defaultConfigFile()})
  -p, --port <port>    Override listen.port (0 = random)
      --background     Start detached; logs go to the config folder's bridge.log
      --tray           Show the tray / macOS menu bar when starting
      --window         Open the pairing, ACP installer or updater window
      --channel <name>  Select release or nightly for bridge updates
      --headless       Suppress interactive pairing (for service managers)
      --debug          Verbose logging
  -h, --help           Show this help
`;

function ensureConfig(file: string): LoadedConfig {
  if (writeDefaultConfig(file)) log.info(`created ${file}`);
  return loadConfig(file);
}

async function printPairing(pair: Awaited<ReturnType<typeof createPairing>>): Promise<void> {
  process.stdout.write("\n" + await terminalQr(pair.link));
  process.stdout.write("\n  用 codeaw App 掃描上方 QR code 配對（5 分鐘內有效、只能用一次）\n");
  process.stdout.write(`  手動輸入：網址 ${pair.urls[0]}\n            配對碼 ${pair.code}\n\n`);
}

async function main(): Promise<void> {
  const { values, positionals } = parseArgs({ allowPositionals: true, options: {
    config: { type: "string", short: "c" }, port: { type: "string", short: "p" },
    background: { type: "boolean" }, tray: { type: "boolean" }, window: { type: "boolean" },
    headless: { type: "boolean" }, debug: { type: "boolean" }, help: { type: "boolean", short: "h" },
    channel: { type: "string" },
  } });
  if (values.help) { process.stdout.write(HELP); return; }
  if (values.debug) setLogLevel("debug");
  const file = path.resolve(values.config ?? defaultConfigFile());
  const command = positionals[0] ?? (["win32", "darwin"].includes(process.platform) ? "tray" : "start");
  const port = values.port === undefined ? undefined : Number(values.port);
  if (port !== undefined && (!Number.isInteger(port) || port < 0 || port > 65535)) throw new Error("Port must be an integer from 0 to 65535");
  if ((values.tray || command === "tray" || command === "settings" || values.window) && !["win32", "darwin"].includes(process.platform)) {
    throw new Error("Native tray and windows are available on Windows and macOS");
  }

  const showDesktop = async (page?: DesktopPage, channel?: string) => {
    const loaded = ensureConfig(file);
    await startBackground(file, { port, debug: values.debug });
    if (channel !== undefined) await requestControl(file, { command: "setUpdateChannel", channel });
    await requestControl(file, { command: "show", page: page ?? (new DeviceStore(loaded.home).list().length === 0 ? "pair" : undefined) });
    await launchDesktop(file);
    log.info("bridge running in the background; use the tray menu to pair or change settings");
  };

  switch (command) {
    case "init": {
      process.stdout.write(writeDefaultConfig(file) ? `Wrote ${file}\n` : `${file} already exists\n`);
      return;
    }
    case "tray": await showDesktop(); return;
    case "settings": await showDesktop("settings"); return;
    case "update": {
      const action = positionals[1] ?? "check";
      if (!["check", "download", "install"].includes(action) || (values.channel !== undefined && !["release", "nightly"].includes(values.channel))) {
        throw new Error("Usage: codeaw-bridge update <check|download|install> [--channel release|nightly] [--window]");
      }
      if (values.window) { await showDesktop("updates", values.channel); return; }
      const running = await runningStatus(file);
      const updater = new BridgeUpdater(file);
      const status = () => running ? requestControl<BridgeUpdateStatus>(file, { command: "updaterStatus" }) : Promise.resolve(updater.getStatus());
      const wait = async (requireSuccess = true) => {
        let found = await status();
        let message = "";
        while (["checking", "downloading"].includes(found.state)) {
          if (found.message !== message) { message = found.message; process.stdout.write(message + "\n"); }
          if (!running) found = await updater.wait();
          else { await new Promise((resolve) => setTimeout(resolve, 500)); found = await status(); }
        }
        if (requireSuccess && found.state === "error") throw new Error(found.message);
        return found;
      };
      if (values.channel) {
        if (running) await requestControl(file, { command: "setUpdateChannel", channel: values.channel });
        else updater.setChannel(values.channel);
      }
      let found = await wait(false);
      // Reuse a verified installer staged by the tray or a previous CLI invocation.
      if (!(action === "install" && found.state === "ready" && found.kind === "installer")) {
        if (running) await requestControl(file, { command: "checkUpdate" }); else updater.check();
        found = await wait();
        process.stdout.write(`${found.message}\nInstalled: ${found.installedVersion} · ${found.channel} · ${found.target}\n${found.releaseUrl}\n`);
        if (action === "check" || !found.updateAvailable) return;
        const kind = action === "install" ? "installer" : "portable";
        if (running) await requestControl(file, { command: "prepareBridgeUpdate", kind }); else updater.prepare(kind);
        found = await wait();
      }
      if (action === "install") {
        await installBridgeUpdate(file, found);
        process.stdout.write("Verified bridge installer opened. Complete the installer to update and restart the tray.\n");
      } else process.stdout.write(found.message + "\n");
      return;
    }
    case "agents": {
      if (values.window) { await showDesktop("agents"); return; }
      const action = positionals[1] ?? "list";
      if (!["list", "install"].includes(action) || (action === "install" && !positionals[2])) {
        throw new Error("Usage: codeaw-bridge agents <list|install <id>>");
      }
      ensureConfig(file);
      const running = await runningStatus(file);
      const installer = new AgentInstaller(file);
      if (action === "list") {
        const agents = running ? await requestControl<Awaited<ReturnType<AgentInstaller["list"]>>>(file, { command: "agentCatalog" }) : await installer.list();
        for (const agent of agents) process.stdout.write(`${agent.id.padEnd(24)} ${agent.name} · ${agent.version} · ${agent.supported ? agent.kind : "unavailable on " + agent.target}${agent.configured ? " · configured" : ""}\n`);
        return;
      }
      let status: InstallStatus;
      if (running) {
        status = await requestControl(file, { command: "installAgent", id: positionals[2] });
        let message = "";
        while (status.state === "installing") {
          if (status.message !== message) { message = status.message; process.stdout.write(message + "\n"); }
          await new Promise((resolve) => setTimeout(resolve, 500));
          status = await requestControl(file, { command: "installerStatus" });
        }
      } else {
        await installer.start(positionals[2]!);
        status = installer.getStatus();
        let message = "";
        while (status.state === "installing") {
          if (status.message !== message) { message = status.message; process.stdout.write(message + "\n"); }
          await new Promise((resolve) => setTimeout(resolve, 500));
          status = installer.getStatus();
        }
      }
      if (status.state !== "succeeded") throw new Error(status.message);
      process.stdout.write(`Installed ${status.name} ${status.version}. ${running ? "Run codeaw-bridge restart to apply it (active turns will stop)." : "Start codeaw-bridge to use it."}\n`);
      return;
    }
    case "autostart": {
      const action = positionals[1] ?? "status";
      if (action === "status") process.stdout.write(await loginStartupEnabled(file) ? "Login tray startup enabled\n" : "Login tray startup disabled\n");
      else if (action === "install" || action === "uninstall") {
        if (action === "install") ensureConfig(file);
        await setLoginStartup(file, action === "install");
        process.stdout.write(action === "install" ? "Login tray startup enabled\n" : "Login tray startup removed\n");
      } else throw new Error("Usage: codeaw-bridge autostart <install|uninstall|status>");
      return;
    }
    case "status": {
      const status = await runningStatus(file);
      process.stdout.write(status ? `${status.state} · PID ${status.pid} · ${status.clients} connected · ${status.devices} paired\n${status.addresses.join("\n")}\n` : "Bridge is stopped\n");
      return;
    }
    case "stop": {
      if (!await runningStatus(file)) { process.stdout.write("Bridge is already stopped\n"); return; }
      await requestControl(file, { command: "stop" });
      for (let i = 0; i < 100; i++) {
        if (!await runningStatus(file)) { process.stdout.write("Bridge stopped\n"); return; }
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
      throw new Error("Bridge did not stop within 10 seconds");
    }
    case "restart": {
      await requestControl(file, { command: "restart" });
      process.stdout.write("Bridge restarted with updated config\n");
      return;
    }
    case "service": {
      if (positionals[1] === "install") ensureConfig(file);
      await manageService(file, positionals[1] ?? "status");
      return;
    }
    case "pair": {
      if (values.window) { await showDesktop("pair"); return; }
      const loaded = ensureConfig(file);
      const status = await runningStatus(file);
      await printPairing(status ? await requestControl(file, { command: "pair" }) : await createPairing(loaded.home, port ?? loaded.config.listen.port));
      return;
    }
    case "devices": {
      const loaded = ensureConfig(file);
      const list = new DeviceStore(loaded.home).list();
      if (!list.length) process.stdout.write("No paired devices. Run codeaw-bridge pair.\n");
      for (const d of list) process.stdout.write(`${d.id}  ${d.name.padEnd(24)} paired ${d.createdAt}  last seen ${d.lastSeenAt ?? "-"}\n`);
      return;
    }
    case "revoke": {
      const loaded = ensureConfig(file);
      const target = positionals[1];
      if (!target) throw new Error("Usage: codeaw-bridge revoke <device id or name>");
      const ok = new DeviceStore(loaded.home).revoke(target);
      process.stdout.write(ok ? `Revoked ${target}. Open connections drop on their next reconnect.\n` : `No device ${target}\n`);
      return;
    }
    case "start": {
      const loaded = ensureConfig(file);
      if (values.background) {
        const status = await startBackground(file, { port, debug: values.debug });
        if (values.tray) {
          await requestControl(file, { command: "show", page: new DeviceStore(loaded.home).list().length ? undefined : "pair" });
          await launchDesktop(file);
        }
        log.info(`background bridge PID ${status.pid}; log: ${status.logFile}`);
        return;
      }
      let stopping = false;
      const shutdown = async (signal: string) => {
        if (stopping) return;
        stopping = true;
        log.info(`${signal}: shutting down`);
        const force = setTimeout(() => process.exit(1), 8000);
        force.unref();
        try { await runtime.stop(); process.exit(0); }
        catch { log.error("shutdown failed"); process.exit(1); }
      };
      const runtime = new BridgeRuntime(loaded, port === undefined ? {} : { port }, () => void shutdown("stop"));
      await runtime.start();
      process.on("SIGINT", () => void shutdown("SIGINT"));
      process.on("SIGTERM", () => void shutdown("SIGTERM"));
      process.on("SIGBREAK", () => void shutdown("SIGBREAK"));
      const bridge = runtime.bridge!;
      log.info(`agents: ${bridge.registry.describe().map((a) => `${a.name} (${a.id})`).join(", ") || "none — configure agents in settings"}`);
      log.info(`connect the app to ${(await wsUrls(bridge.port(), bridge.addresses())).join("  or  ")}`);
      if (values.tray) {
        runtime.openDesktop(bridge.devices.list().length ? undefined : "pair");
        await launchDesktop(file);
      } else if (!values.headless && !bridge.devices.list().length) {
        await printPairing(await createPairing(loaded.home, bridge.port(), bridge.addresses()));
      }
      return;
    }
    default: process.stdout.write(HELP); process.exitCode = 2;
  }
}

main().catch((err) => { log.error((err as Error).message); process.exit(1); });
