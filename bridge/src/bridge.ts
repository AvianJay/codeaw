import http from "node:http";
import os from "node:os";
import type { AddressInfo } from "node:net";
import type { LoadedConfig } from "./config.js";
import { AgentRegistry } from "./backend/registry.js";
import { PushNotifier } from "./notify/ntfy.js";
import { DeviceStore } from "./server/auth.js";
import { PathGuard } from "./server/ext.js";
import { createHttpHandlers } from "./server/http.js";
import { SessionManager } from "./session/manager.js";
import { SessionStore } from "./session/store.js";
import { logger } from "./util/log.js";
import { tailscaleIPv4 } from "./util/tailscale.js";
import { TerminalManager } from "./terminal/manager.js";

const log = logger("bridge");

export interface BridgeOptions {
  /** Override `listen.hosts` (tests use 127.0.0.1). */
  hosts?: string[];
  /** Override `listen.port` (0 = random). */
  port?: number;
  agentStartTimeoutMs?: number;
  fetchImpl?: typeof fetch;
}

export interface Bridge {
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
  manager.start();
  const guard = new PathGuard(() => config.workspaces, () => manager.knownCwds());
  const terminals = new TerminalManager(guard);
  const handlers = createHttpHandlers({ manager, registry, guard, notifier, terminals, devices, store, hostName: os.hostname() });

  const servers = new Map<string, http.Server>();
  let port = opts.port ?? config.listen.port;

  const listen = (host: string) =>
    new Promise<void>((resolve, reject) => {
      const server = http.createServer(handlers.onRequest);
      server.on("upgrade", handlers.onUpgrade);
      server.once("error", reject);
      server.listen(port, host, () => {
        server.off("error", reject);
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

  for (const host of wanted()) await listen(host);

  // Tailscale may come up after us (boot, VPN reconnect): keep trying to bind its address.
  const retry =
    !opts.hosts && config.listen.hosts === "auto"
      ? setInterval(() => {
          for (const host of wanted()) {
            if (!servers.has(host)) listen(host).catch((err) => log.warn(`cannot listen on ${host}: ${(err as Error).message}`));
          }
        }, 30_000)
      : undefined;
  retry?.unref();

  return {
    manager,
    registry,
    devices,
    notifier,
    addresses: () => [...servers.keys()].map((h) => `${h}:${port}`),
    port: () => port,
    async stop() {
      if (retry) clearInterval(retry);
      notifier.dispose();
      await terminals.dispose();
      await handlers.close();
      await Promise.all(
        [...servers.values()].map(
          (s) =>
            new Promise<void>((resolve) => {
              s.closeAllConnections?.();
              s.close(() => resolve());
            }),
        ),
      );
      await manager.shutdown();
      await registry.stopAll();
    },
  };
}
