import http from "node:http";
import os from "node:os";
import type { AddressInfo } from "node:net";
import type { LoadedConfig } from "./config.js";
import { AgentRegistry } from "./backend/registry.js";
import { PushNotifier } from "./notify/ntfy.js";
import { LiveActivityPush } from "./notify/live-activity.js";
import path from "node:path";
import { expandHome } from "./util/paths.js";
import { DeviceStore } from "./server/auth.js";
import { PathGuard } from "./server/ext.js";
import { createHttpHandlers } from "./server/http.js";
import { UploadStore } from "./server/uploads.js";
import { SessionManager } from "./session/manager.js";
import { SessionStore } from "./session/store.js";
import { logger } from "./util/log.js";
import { tailscaleIPv4 } from "./util/tailscale.js";
import { TerminalManager } from "./terminal/manager.js";
import { CpaUsageService } from "./server/cpa.js";
import { findWebRoot } from "./server/web.js";
import { UPLOAD_TIMEOUT_MS } from "./server/uploads.js";
import { DesktopManager } from "./remote-desktop/manager.js";
import type { BackendFactory } from "./remote-desktop/protocol.js";
import { gatewayRegistration, type GatewayManifest } from "./remote-desktop/gateway-config.js";
import { desktopHelper } from "./remote-desktop/native.js";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { listenPrivateHttp, type PrivateHttpListener } from "./remote-desktop/private-http.js";

const log = logger("bridge");

export interface BridgeOptions {
  /** Override `listen.hosts` (tests use 127.0.0.1). */
  hosts?: string[];
  /** Override `listen.port` (0 = random). */
  port?: number;
  agentStartTimeoutMs?: number;
  fetchImpl?: typeof fetch;
  /** Override the public Flutter web asset directory. */
  webRoot?: string;
  desktopBackendFactory?: BackendFactory;
  /** Private user bridge endpoint when the system gateway owns the public port. */
  gatewayPipe?: string;
}

export interface Bridge {
  webRoot?: string;
  manager: SessionManager;
  registry: AgentRegistry;
  devices: DeviceStore;
  notifier: PushNotifier;
  /** Addresses actually listening, e.g. ["127.0.0.1:7860", "100.64.0.10:7860"]. */
  addresses(): string[];
  port(): number;
  /** Move listeners without stopping agents, sessions, or existing client connections. */
  activateDesktopGateway(): Promise<void>;
  stop(): Promise<void>;
}

export async function startBridge(loaded: LoadedConfig, opts: BridgeOptions = {}): Promise<Bridge> {
  const { config, home, dataDir } = loaded;
  let gateway = gatewayRegistration(loaded.file);
  opts = { ...opts, gatewayPipe: opts.gatewayPipe ?? gateway?.backendPipe };
  const webRoot = opts.webRoot ?? findWebRoot();
  const store = new SessionStore(dataDir);
  const devices = new DeviceStore(home);
  // The registry and the manager reference each other through the handler interface.
  let manager!: SessionManager;
  const registry = new AgentRegistry(
    config.agents,
    {
      onUpdate: (a, p) => manager.onUpdate(a, p),
      onPermission: (a, p, s) => manager.onPermission(a, p, s),
      onElicitation: (a, p, s) => manager.onElicitation(a, p, s),
      onExit: (a, g, d) => manager.onExit(a, g, d),
      onHistoryReset: (a, id, updates) => manager.onHistoryReset(a, id, updates),
      onSessionState: (a, id, state) => manager.onSessionState(a, id, state),
      onSessionError: (a, id, message) => manager.onSessionError(a, id, message),
    },
    dataDir,
    opts.agentStartTimeoutMs,
  );
  manager = new SessionManager(registry, store, {
    idleSessionCloseMs: config.idleSessionCloseMinutes * 60_000,
    idleAgentStopMs: config.idleAgentStopMinutes * 60_000,
    hostName: os.hostname(),
  });
  const notifier = new PushNotifier(config.notifications.ntfy, () => manager.clientCount > 0, opts.fetchImpl);
  manager.notifier = notifier;
  const liveConfig = config.notifications.liveActivity;
  const liveActivity = new LiveActivityPush(liveConfig ? { ...liveConfig,
    privateKeyPath: path.resolve(home, expandHome(liveConfig.privateKeyPath)) } : undefined,
    (id) => devices.list().some((d) => d.id === id), (id) => manager.activitySnapshot(id));
  manager.liveActivity = liveActivity;
  manager.start();
  const uploads = new UploadStore(dataDir);
  uploads.prune();
  const pruneUploads = setInterval(() => uploads.prune(), 12 * 60 * 60_000);
  pruneUploads.unref();
  const guard = new PathGuard(() => config.workspaces, () => manager.knownCwds(), () => config.filesystem.allowAllPaths, () => [uploads.dir]);
  const terminals = new TerminalManager(guard);
  const cpa = new CpaUsageService(opts.fetchImpl);
  const desktop = new DesktopManager({ devices, enabled: () => config.remoteDesktop.enabled,
    backendFactory: opts.desktopBackendFactory, ...(opts.desktopBackendFactory ? { available: () => true } : {}) });
  const handlers = createHttpHandlers({ manager, registry, guard, notifier, terminals, cpa, devices, store, uploads, hostName: os.hostname(), webRoot, desktop });

  const servers = new Map<string, PrivateHttpListener>();
  const draining = new Set<PrivateHttpListener>();
  const binding = new Set<string>();
  let stopping: Promise<void> | undefined;
  let retry: NodeJS.Timeout | undefined;
  let port = opts.port ?? config.listen.port;

  const listen = (host: string, target = servers) =>
    new Promise<void>((resolve, reject) => {
      binding.add(host);
      const server = http.createServer({ requestTimeout: UPLOAD_TIMEOUT_MS }, handlers.onRequest);
      server.on("upgrade", handlers.onUpgrade);
      server.once("error", (err) => { binding.delete(host); reject(err); });
      server.listen(port, host, () => {
        server.removeAllListeners("error");
        server.on("error", (err) => log.warn(`listener ${host}: ${err.message}`));
        binding.delete(host);
        if (stopping) { server.close(() => reject(new Error("Bridge is stopping"))); return; }
        port = (server.address() as AddressInfo).port;
        target.set(host, server);
        log.info(`listening on ${host}:${port}`);
        resolve();
      });
    });

  const wanted = (): string[] => {
    if (opts.hosts) return opts.hosts;
    if (config.listen.hosts !== "auto") return config.listen.hosts;
    const ts = tailscaleIPv4();
    return ts ? ["127.0.0.1", ts] : ["127.0.0.1"];
  };

  const stop = (): Promise<void> => stopping ??= (async () => {
    if (retry) clearInterval(retry);
    clearInterval(pruneUploads);
    notifier.dispose();
    liveActivity.dispose();
    await desktop.dispose();
    await terminals.dispose();
    await handlers.close();
    await Promise.all([...servers.values(), ...draining].map((server) => new Promise<void>((resolve) => {
      server.closeAllConnections?.();
      server.close(() => resolve());
    })));
    await manager.shutdown();
    await registry.stopAll();
  })();

  const listenPipe = async (pipe: string, registration?: GatewayManifest) => {
    return listenPrivateHttp(pipe, handlers.onRequest, handlers.onUpgrade, async () => {
      if (registration) {
        const helper = desktopHelper(); if (!helper) throw new Error("Desktop helper is required to protect the backend pipe");
        await promisify(execFile)(helper, ["--protect-pipe", pipe, registration.ownerSid], { windowsHide: true, timeout: 10_000 });
      }
    });
  };

  const startRetry = () => {
    if (opts.gatewayPipe || opts.hosts || config.listen.hosts !== "auto") return;
    retry = setInterval(() => {
      for (const host of wanted()) {
        if (!stopping && !servers.has(host) && !binding.has(host)) listen(host).catch((err) => log.warn(`cannot listen on ${host}: ${(err as Error).message}`));
      }
    }, 30_000);
    retry.unref();
  };

  const activateDesktopGateway = async () => {
    const next = gatewayRegistration(loaded.file);
    const pipe = next?.backendPipe;
    if (pipe === opts.gatewayPipe) return;
    if (stopping) throw new Error("Bridge is stopping");
    if (retry) { clearInterval(retry); retry = undefined; }
    const prepared = new Map<string, PrivateHttpListener>();
    try {
      if (pipe) prepared.set(pipe, await listenPipe(pipe, next));
      else for (const host of wanted()) {
        try { await listen(host, prepared); }
        catch (error) {
          if (!opts.hosts && config.listen.hosts === "auto" && host !== "127.0.0.1") log.warn(`cannot listen on ${host} yet: ${(error as Error).message}`);
          else throw error;
        }
      }
    } catch (error) {
      for (const server of prepared.values()) { server.closeAllConnections?.(); server.close(); }
      startRetry();
      throw error;
    }
    // Stop accepting on old endpoints, but let live ACP connections and jobs continue.
    for (const server of servers.values()) {
      draining.add(server);
      server.close(() => draining.delete(server));
      server.closeIdleConnections?.();
    }
    servers.clear();
    for (const [endpoint, server] of prepared) servers.set(endpoint, server);
    gateway = next;
    opts = { ...opts, gatewayPipe: pipe };
    startRetry();
  };

  try {
    if (opts.gatewayPipe) {
      servers.set(opts.gatewayPipe, await listenPipe(opts.gatewayPipe, gateway));
    }
    for (const host of opts.gatewayPipe ? [] : wanted()) {
      try { await listen(host); }
      catch (err) {
        // A Tailscale adapter may be present before its address is ready at boot.
        if (!opts.hosts && config.listen.hosts === "auto" && host !== "127.0.0.1") {
          log.warn(`cannot listen on ${host} yet: ${(err as Error).message}`);
        } else throw err;
      }
    }
    if (!servers.size) throw new Error("No listen hosts configured");
  } catch (err) { await stop(); throw err; }

  // Tailscale may come up after us (boot, VPN reconnect): keep trying to bind its address.
  startRetry();

  return {
    webRoot,
    manager,
    registry,
    devices,
    notifier,
    addresses: () => (gateway ? wanted() : [...servers.keys()]).map((h) => `${h}:${port}`),
    port: () => port,
    stop,
    activateDesktopGateway,
  };
}
