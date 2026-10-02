import crypto from "node:crypto";
import * as acp from "@agentclientprotocol/sdk";
import type { AgentRegistry } from "../backend/registry.js";
import type { PushNotifier } from "../notify/ntfy.js";
import type { ClientHandle, SessionManager } from "../session/manager.js";
import { logger } from "../util/log.js";
import { gitDiff, gitStatus, listDir, readFile, type PathGuard } from "./ext.js";

const log = logger("client");

export interface FrontendDeps {
  manager: SessionManager;
  registry: AgentRegistry;
  guard: PathGuard;
  notifier: PushNotifier;
}

const passthrough = (params: unknown) => (params ?? {}) as Record<string, any>;

/**
 * One app connection. Owns an ACP AgentApp (the SDK handles JSON-RPC framing and
 * validation); every handler delegates to the shared SessionManager.
 */
export class FrontendConnection implements ClientHandle {
  readonly id = "c_" + crypto.randomBytes(5).toString("hex");
  foreground = true;
  activeSessionId?: string;
  readonly app: acp.AgentApp;
  private ctx?: acp.AgentContext;
  private chain: Promise<void> = Promise.resolve();
  private disposed = false;

  constructor(
    readonly deviceName: string,
    private readonly deps: FrontendDeps,
  ) {
    const { manager } = deps;
    const bind = <T extends { client: acp.AgentContext }>(ctx: T): T => {
      this.ctx ??= ctx.client;
      return ctx;
    };
    this.app = acp
      .agent({ name: "codeaw-bridge" })
      .onConnect((conn) => {
        this.ctx ??= conn.client;
        manager.addClient(this);
        void conn.closed.finally(() => this.dispose());
      })
      .onRequest("initialize", (ctx) => {
        bind(ctx);
        return manager.initializeResponse();
      })
      .onRequest("authenticate", () => ({}))
      .onRequest("session/new", (ctx) => this.flushed(manager.newSession(this, bind(ctx).params)))
      .onRequest("session/load", (ctx) => this.flushed(manager.loadSession(this, bind(ctx).params)))
      .onRequest("session/resume", (ctx) => this.flushed(manager.resumeSession(this, bind(ctx).params)))
      .onRequest("session/list", (ctx) => manager.listSessions(this, bind(ctx).params))
      .onRequest("session/prompt", (ctx) => this.flushed(manager.prompt(this, bind(ctx).params)))
      .onRequest("session/set_config_option", (ctx) => this.flushed(manager.setConfigOption(this, bind(ctx).params)))
      .onRequest("session/set_mode", (ctx) => this.flushed(manager.setMode(this, bind(ctx).params)))
      .onRequest("session/close", (ctx) => this.flushed(manager.closeSession(this, bind(ctx).params)))
      .onRequest("session/delete", (ctx) => this.flushed(manager.deleteSession(this, bind(ctx).params)))
      .onNotification("session/cancel", (ctx) => manager.cancel(this, bind(ctx).params))
      .onNotification("_codeaw/client/state", passthrough, (ctx) => manager.setClientState(this, ctx.params))
      .onNotification("_codeaw/session/detach", passthrough, (ctx) => manager.detach(this, ctx.params.sessionId))
      .onRequest("_codeaw/agents/list", passthrough, () => ({ agents: deps.registry.describe() }))
      .onRequest("_codeaw/agents/restart", passthrough, async (ctx) => {
        const agent = deps.registry.get(String(ctx.params.agentId));
        await agent.stop("restart requested");
        await agent.ensureStarted();
        return { agent: agent.describe() };
      })
      .onRequest("_codeaw/workspaces/list", passthrough, () => ({
        roots: deps.guard.roots().map((r) => ({ ...r, name: r.path.split(/[\\/]/).filter(Boolean).pop() ?? r.path })),
      }))
      .onRequest("_codeaw/fs/list", passthrough, (ctx) => listDir(deps.guard, ctx.params.path))
      .onRequest("_codeaw/fs/read", passthrough, (ctx) => readFile(deps.guard, ctx.params.path, ctx.params.maxBytes))
      .onRequest("_codeaw/git/status", passthrough, (ctx) => gitStatus(deps.guard, ctx.params.cwd))
      .onRequest("_codeaw/git/diff", passthrough, (ctx) => gitDiff(deps.guard, ctx.params.cwd, ctx.params.path, ctx.params.staged))
      .onRequest("_codeaw/session/reimport", passthrough, (ctx) => this.flushed(manager.reimport(String(ctx.params.sessionId))))
      .onRequest("_codeaw/notify/info", passthrough, () => deps.notifier.info())
      .onRequest("_codeaw/notify/test", passthrough, async () => ({
        sent: await deps.notifier.send({ kind: "turn_end", sessionId: "test:test", agentName: "codeaw 測試通知" }),
      }));
  }

  notify(method: string, params: unknown): Promise<void> {
    const ctx = this.ctx;
    if (this.disposed || !ctx) return Promise.resolve();
    this.chain = this.chain
      .then(() => ctx.notify(method, params as never))
      .catch((err) => log.debug(`notify ${method} to ${this.deviceName} failed: ${(err as Error).message}`));
    return this.chain;
  }

  request<T>(method: string, params: unknown, signal: AbortSignal): Promise<T> {
    const ctx = this.ctx;
    if (this.disposed || !ctx) return Promise.reject(new Error("client gone"));
    return new Promise<T>((resolve, reject) => {
      this.chain = this.chain.then(() => {
        if (signal.aborted) return reject(new Error("withdrawn"));
        ctx.request<T>(method, params as never, { cancellationSignal: signal }).then(resolve, reject);
      });
    });
  }

  flush(): Promise<void> {
    return this.chain;
  }

  /**
   * Responses are written by the SDK directly while notifications go through `chain`;
   * waiting for the chain keeps "updates of a turn arrive before its response".
   */
  private async flushed<T>(result: Promise<T>): Promise<T> {
    try {
      return await result;
    } finally {
      await this.chain;
    }
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.deps.manager.removeClient(this);
    log.info(`${this.deviceName} disconnected`);
  }
}
