#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import { parseArgs } from "node:util";
import { defaultConfigFile, loadConfig, writeDefaultConfig, type LoadedConfig } from "./config.js";
import { startBridge } from "./bridge.js";
import { DeviceStore, formatCode } from "./server/auth.js";
import { logger, setLogLevel } from "./util/log.js";
import { terminalQr } from "./util/qr.js";
import { tailscaleSelf } from "./util/tailscale.js";
import { VERSION } from "./version.js";

const log = logger("main");

const HELP = `codeaw-bridge ${VERSION}

Usage: codeaw-bridge [command] [options]

Commands:
  start            Run the bridge (default)
  init             Write a starter config (~/.codeaw/config.yaml) if none exists
  pair             Print a QR code / one-time code to pair a phone (valid 5 minutes)
  devices          List paired devices
  revoke <id|name> Remove a paired device

Options:
  -c, --config <file>  Config file (default: ${defaultConfigFile()})
  -p, --port <port>    Override listen.port
      --debug          Verbose logging
  -h, --help           Show this help
`;

async function wsUrls(port: number, listening?: string[]): Promise<string[]> {
  const ts = await tailscaleSelf();
  const urls: string[] = [];
  if (ts.ip && (!listening || listening.some((a) => a.startsWith(ts.ip + ":")))) urls.push(`ws://${ts.ip}:${port}/acp`);
  if (ts.dnsName && ts.ip && (!listening || listening.some((a) => a.startsWith(ts.ip + ":")))) urls.push(`ws://${ts.dnsName}:${port}/acp`);
  if (urls.length === 0) urls.push(`ws://127.0.0.1:${port}/acp`);
  return urls;
}

async function printPairing(loaded: LoadedConfig, port: number, listening?: string[]): Promise<void> {
  const devices = new DeviceStore(loaded.home);
  const code = devices.createPairingCode();
  const urls = await wsUrls(port, listening);
  const params = new URLSearchParams();
  for (const u of urls) params.append("u", u);
  params.set("c", code);
  params.set("n", os.hostname());
  const link = `codeaw://pair?${params.toString()}`;
  process.stdout.write("\n" + (await terminalQr(link)));
  process.stdout.write(`\n  用 codeaw App 掃描上方 QR code 配對（5 分鐘內有效、只能用一次）\n`);
  process.stdout.write(`  手動輸入：網址 ${urls[0]}\n            配對碼 ${formatCode(code)}\n\n`);
}

function ensureConfig(file: string): LoadedConfig {
  if (writeDefaultConfig(file)) log.info(`created ${file} — review it, then restart if you change anything`);
  return loadConfig(file);
}

async function main(): Promise<void> {
  const { values, positionals } = parseArgs({
    allowPositionals: true,
    options: {
      config: { type: "string", short: "c" },
      port: { type: "string", short: "p" },
      debug: { type: "boolean" },
      help: { type: "boolean", short: "h" },
    },
  });
  if (values.help) {
    process.stdout.write(HELP);
    return;
  }
  if (values.debug) setLogLevel("debug");
  const file = values.config ?? defaultConfigFile();
  const command = positionals[0] ?? "start";

  switch (command) {
    case "init": {
      if (writeDefaultConfig(file)) process.stdout.write(`Wrote ${file}\n`);
      else process.stdout.write(`${file} already exists\n`);
      process.stdout.write(fs.readFileSync(file, "utf8"));
      return;
    }
    case "pair": {
      const loaded = ensureConfig(file);
      await printPairing(loaded, values.port ? Number(values.port) : loaded.config.listen.port);
      return;
    }
    case "devices": {
      const loaded = ensureConfig(file);
      const list = new DeviceStore(loaded.home).list();
      if (list.length === 0) process.stdout.write("No paired devices. Run `codeaw-bridge pair`.\n");
      for (const d of list) process.stdout.write(`${d.id}  ${d.name.padEnd(24)} paired ${d.createdAt}  last seen ${d.lastSeenAt ?? "-"}\n`);
      return;
    }
    case "revoke": {
      const loaded = ensureConfig(file);
      const target = positionals[1];
      if (!target) throw new Error("Usage: codeaw-bridge revoke <device id or name>");
      const ok = new DeviceStore(loaded.home).revoke(target);
      process.stdout.write(ok ? `Revoked ${target}. Its open connections drop on their next reconnect.\n` : `No device ${target}\n`);
      return;
    }
    case "start": {
      const loaded = ensureConfig(file);
      const bridge = await startBridge(loaded, values.port ? { port: Number(values.port) } : {});
      const agents = Object.entries(loaded.config.agents)
        .filter(([, a]) => a.enabled)
        .map(([id, a]) => `${a.name} (${id})`);
      log.info(`agents: ${agents.join(", ") || "none — edit " + loaded.file}`);
      if (loaded.config.notifications.ntfy) log.info(`push: ntfy topic "${loaded.config.notifications.ntfy.topic}" on ${loaded.config.notifications.ntfy.server}`);
      const urls = await wsUrls(bridge.port(), bridge.addresses());
      log.info(`connect the app to ${urls.join("  or  ")}`);
      if (bridge.devices.list().length === 0) await printPairing(loaded, bridge.port(), bridge.addresses());
      else log.info("run `codeaw-bridge pair` in another terminal to add a device");

      let stopping = false;
      const shutdown = async (signal: string) => {
        if (stopping) return;
        stopping = true;
        log.info(`${signal}: shutting down`);
        const force = setTimeout(() => process.exit(1), 8000);
        force.unref();
        await bridge.stop().catch((err) => log.error("shutdown failed", err));
        process.exit(0);
      };
      process.on("SIGINT", () => void shutdown("SIGINT"));
      process.on("SIGTERM", () => void shutdown("SIGTERM"));
      process.on("SIGBREAK", () => void shutdown("SIGBREAK"));
      return;
    }
    default:
      process.stdout.write(HELP);
      process.exitCode = 2;
  }
}

main().catch((err) => {
  log.error((err as Error).message);
  process.exit(1);
});
