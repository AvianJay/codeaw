import path from "node:path";
import fs from "node:fs";
import type net from "node:net";
import { loadConfig, type LoadedConfig } from "../config.js";
import { startBridge, type Bridge, type BridgeOptions } from "../bridge.js";
import { serveControl, type ControlRequest } from "./control.js";
import { createAppLaunch, createPairing } from "./pairing.js";
import { desktopSettings, saveDesktopSettings } from "./settings.js";
import { loginStartupEnabled, setLoginStartup } from "./autostart.js";
import { AgentInstaller, registerInstalledAgent } from "../agents/install.js";
import { BridgeUpdater, verifiedBridgeInstaller } from "../updater.js";
import { VERSION, BUILD_NUMBER, UPDATE_CHANNEL } from "../version.js";
import { manageDesktopService } from "../remote-desktop/service.js";
export type DesktopPage = "pair" | "settings" | "devices" | "agents" | "updates";

export class BridgeRuntime {
  bridge?: Bridge;
  state = "starting";
  private server?: net.Server;
  private page?: DesktopPage;
  private queue: Promise<unknown> = Promise.resolve();
  private stopping?: Promise<void>;
  readonly installer: AgentInstaller;
  readonly updater: BridgeUpdater;

  constructor(public loaded: LoadedConfig, private options: BridgeOptions = {}, private onQuit: () => void = () => undefined) {
    this.installer = new AgentInstaller(loaded.file, (agent) => this.serialize(async () => registerInstalledAgent(loaded.file, agent)));
    this.updater = new BridgeUpdater(loaded.file);
  }

  async start(): Promise<void> {
    this.server = await serveControl(this.loaded.file, (request) => this.handle(request));
    try { this.bridge = await startBridge(this.loaded, this.options); this.state = "running"; }
    catch (err) { await this.stop(); throw err; }
  }

  status() {
    return { state: this.state, pid: process.pid, version: VERSION, buildNumber: BUILD_NUMBER, channel: UPDATE_CHANNEL,
      port: this.bridge?.port(), addresses: this.bridge?.addresses() ?? [],
      clients: this.bridge?.manager.clientCount ?? 0, devices: this.bridge?.devices.list().length ?? 0,
      configFile: this.loaded.file, logFile: path.join(this.loaded.home, "bridge.log"),
      agents: this.bridge?.registry.describe().map(({ id, name, status }) => ({ id, name, status })) ?? [] };
  }

  openDesktop(page?: DesktopPage): void {
    if (!["win32", "darwin"].includes(process.platform)) throw new Error("Native tray and windows are available on Windows and macOS");
    this.page = page;
  }

  private serialize<T>(action: () => Promise<T>): Promise<T> {
    const result = this.queue.then(action);
    this.queue = result.catch(() => undefined);
    return result;
  }

  async restart(loaded = loadConfig(this.loaded.file)): Promise<void> {
    this.state = "restarting";
    await this.bridge?.stop();
    this.bridge = undefined;
    try { this.bridge = await startBridge(loaded, this.options); this.loaded = loaded; this.state = "running"; }
    catch (err) { this.state = "error"; throw err; }
  }

  private async handle(request: ControlRequest): Promise<unknown> {
    switch (request.command) {
      case "status": return this.status();
      case "poll": { const page = this.page; this.page = undefined; return { ...this.status(), page }; }
      case "show": {
        if (request.page !== undefined && !["pair", "settings", "devices", "agents", "updates"].includes(String(request.page))) throw new Error("Unknown desktop page");
        this.openDesktop(request.page as DesktopPage | undefined);
        return this.status();
      }
      case "pair": {
        if (!this.bridge || this.state !== "running") throw new Error("Bridge is not running");
        return createPairing(this.loaded.home, this.bridge.port(), this.bridge.addresses());
      }
      case "app": {
        if (!this.bridge || this.state !== "running") throw new Error("Bridge is not running");
        if (!this.bridge.webRoot || !fs.existsSync(path.join(this.bridge.webRoot, "index.html"))) throw new Error("Web app not found. Run npm run build:web in bridge, or install a release with its web folder.");
        return createAppLaunch(this.loaded.home, this.bridge.port(), this.bridge.addresses());
      }
      case "settings": return desktopSettings(loadConfig(this.loaded.file));
      case "installDesktopService": await manageDesktopService(this.loaded.file, "install"); return this.status();
      case "uninstallDesktopService": await manageDesktopService(this.loaded.file, "uninstall"); return this.status();
      case "activateDesktopGateway": await this.restart(); return this.status();
      case "agentCatalog": return this.installer.list(request.refresh === true);
      case "installAgent": {
        if (typeof request.id !== "string") throw new Error("Missing agent id");
        return this.installer.start(request.id);
      }
      case "installerStatus": return this.installer.getStatus();
      case "updaterStatus": return this.updater.getStatus();
      case "checkUpdate": return this.updater.check();
      case "setUpdateChannel": return this.updater.setChannel(request.channel);
      case "prepareBridgeUpdate": return this.updater.prepare(request.kind);
      case "bridgeUpdateInstaller": return verifiedBridgeInstaller(this.loaded.file, this.updater.getStatus());
      case "autostart": return { enabled: await loginStartupEnabled(this.loaded.file) };
      case "setAutostart": {
        if (typeof request.enabled !== "boolean") throw new Error("Missing startup preference");
        await setLoginStartup(this.loaded.file, request.enabled);
        return { enabled: request.enabled };
      }
      case "pairingStatus": {
        if (typeof request.code !== "string") throw new Error("Missing pairing code");
        return { pending: this.bridge?.devices.isPairingCodePending(request.code) ?? false };
      }
      case "saveSettings": return this.serialize(async () => {
        const previous = this.loaded;
        const options = this.options;
        const saved = saveDesktopSettings(this.loaded.file, request.settings);
        // A saved listen port becomes effective even if startup had a CLI port override.
        this.options = { ...this.options, port: undefined };
        try { await this.restart(saved.loaded); }
        catch {
          saved.restore();
          this.options = options;
          await this.restart(previous);
          throw new Error("Cannot start with these settings. Previous settings were restored (check the port is free).");
        }
        return this.status();
      });
      case "devices": return this.bridge?.devices.list().map(({ tokenHash: _secret, ...device }) => device) ?? [];
      case "revoke": {
        if (typeof request.id !== "string") throw new Error("Missing device id");
        return { revoked: this.bridge?.devices.revoke(request.id) ?? false };
      }
      case "restart": return this.serialize(async () => { await this.restart(); return this.status(); });
      case "stop": {
        setTimeout(() => this.onQuit(), 100);
        return { stopping: true };
      }
      default: throw new Error("Unknown control command");
    }
  }

  stop(): Promise<void> {
    return this.stopping ??= (async () => {
      await this.installer.stop();
      await this.updater.stop();
      await this.serialize(async () => {
        this.state = "stopping";
        await this.bridge?.stop();
        this.bridge = undefined;
        await new Promise<void>((resolve) => this.server ? this.server.close(() => resolve()) : resolve());
        this.state = "stopped";
      });
    })();
  }
}
