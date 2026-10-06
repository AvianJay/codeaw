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
import { SessionManager } from "./session/manager.js";
import { SessionStore } from "./session/store.js";
import { logger } from "./util/log.js";
import { tailscaleIPv4 } from "./util/tailscale.js";
import { TerminalManager } from "./terminal/manager.js";
import { CpaUsageService } from "./server/cpa.js";
import { findWebRoot } from "./server/web.js";
import { UPLOAD_TIMEOUT_MS } from "./server/uploads.js";

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
  stop(): Promise<void>;
}

export async function startBridge(loaded: LoadedConfig, opts: BridgeOptions = {}): Promise<Bridge> {
  const { config, home, dataDir } = loaded;
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
  const guard = new PathGuard(() => config.workspaces, () => manager.knownCwds(), () => config.filesystem.allowAllPaths);
  const terminals = new TerminalManager(guard);
  const cpa = new CpaUsageService(opts.fetchImpl);
  const handlers = createHttpHandlers({ manager, registry, guard, notifier, terminals, cpa, devices, store, hostName: os.hostname(), webRoot });

  const servers = new Map<string, http.Server>();
  const binding = new Set<string>();
  let stopping: Promise<void> | undefined;
  let retry: NodeJS.Timeout | undefined;
  let port = opts.port ?? config.listen.port;

  const listen = (host: string) =>
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
        servers.set(host, server);
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
    notifier.dispose();
    liveActivity.dispose();
    await terminals.dispose();
    await handlers.close();
    await Promise.all([...servers.values()].map((server) => new Promise<void>((resolve) => {
      server.closeAllConnections?.();
      server.close(() => resolve());
    })));
    await manager.shutdown();
    await registry.stopAll();
  })();

  try {
    for (const host of wanted()) {
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
  retry =
    !opts.hosts && config.listen.hosts === "auto"
      ? setInterval(() => {
          for (const host of wanted()) {
            if (!stopping && !servers.has(host) && !binding.has(host)) listen(host).catch((err) => log.warn(`cannot listen on ${host}: ${(err as Error).message}`));
          }
        }, 30_000)
      : undefined;
  retry?.unref();

  return {
    webRoot,
    manager,
    registry,
    devices,
    notifier,
    addresses: () => [...servers.keys()].map((h) => `${h}:${port}`),
    port: () => port,
    stop,
  };
}
