import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { WebSocket } from "ws";
import * as acp from "@agentclientprotocol/sdk";
import { createWebSocketStream } from "@agentclientprotocol/sdk/experimental/ws-client";
import { ConfigSchema, type LoadedConfig } from "../src/config.js";
import type { AgentConfig } from "../src/config.js";
import { startBridge, type Bridge } from "../src/bridge.js";
import { setLogSilent } from "../src/util/log.js";
import { SessionStore } from "../src/session/store.js";

setLogSilent(process.env.CODEAW_TEST_LOG !== "1");

const here = path.dirname(fileURLToPath(import.meta.url));
export const BRIDGE_DIR = path.resolve(here, "..");
export const FAKE_AGENT = path.join(here, "fake-agent.ts");

export interface TestBridgeOptions {
  steering?: boolean;
  /** The fake agent supports `session/fork` from a message, like codex-acp ≥ 1.8. */
  fork?: boolean;
  ntfy?: Record<string, unknown>;
  fetchImpl?: typeof fetch;
  home?: string;
  /** Keep the fake agent's own state but give the bridge a fresh data dir. */
  freshData?: boolean;
  port?: number;
  hosts?: string[];
  /** Keep the temp home after stop() (to restart a bridge on the same agent state). */
  keepHome?: boolean;
  webRoot?: string;
  desktopSync?: AgentConfig["desktopSync"];
}

export interface TestBridge {
  bridge: Bridge;
  home: string;
  url: string;
  http: string;
  loaded: LoadedConfig;
  tokenFor(name: string): string;
  stop(): Promise<void>;
}

export async function startTestBridge(opts: TestBridgeOptions = {}): Promise<TestBridge> {
  const home = opts.home ?? fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-test-"));
  const config = ConfigSchema.parse({
    workspaces: [home],
    agents: {
      fake: {
        name: "Fake",
        command: process.execPath,
        args: ["--import", "tsx", FAKE_AGENT],
        cwd: BRIDGE_DIR,
        env: { FAKE_AGENT_STATE: path.join(home, "fake-state.json"), FAKE_AGENT_STEERING: opts.steering ? "1" : "0", FAKE_AGENT_FORK: opts.fork ? "1" : "0" },
        ...(opts.desktopSync !== undefined ? { desktopSync: opts.desktopSync } : {}),
      },
    },
    notifications: opts.ntfy ? { ntfy: opts.ntfy } : {},
  });
  const dataDir = path.join(home, opts.freshData ? `data-${Date.now()}` : "data");
  const loaded: LoadedConfig = { config, file: path.join(home, "config.yaml"), home, dataDir };
  const bridge = await startBridge(loaded, { hosts: opts.hosts ?? ["127.0.0.1"], port: opts.port ?? 0, fetchImpl: opts.fetchImpl, webRoot: opts.webRoot });
  const tokens = new Map<string, string>();
  return {
    bridge,
    home,
    loaded,
    url: `ws://${opts.hosts?.[0] && opts.hosts[0] !== "0.0.0.0" ? opts.hosts[0] : "127.0.0.1"}:${bridge.port()}/acp`,
    http: `http://${opts.hosts?.[0] && opts.hosts[0] !== "0.0.0.0" ? opts.hosts[0] : "127.0.0.1"}:${bridge.port()}`,
    tokenFor(name: string) {
      let token = tokens.get(name);
      if (!token) {
        token = Buffer.from(name.padEnd(32, "x")).toString("hex").slice(0, 64);
        bridge.devices.addDeviceWithToken(name, token);
        tokens.set(name, token);
      }
      return token;
    },
    async stop() {
      await bridge.stop();
      // Temp homes we created ourselves are removed; a caller-provided home is left alone.
      if (!opts.home && !opts.keepHome) fs.rmSync(home, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
    },
  };
}

export interface Received {
  method: string;
  params: any;
}

/** ACP client over WebSocket that records everything it receives. */
export class TestClient {
  received: Received[] = [];
  permissionAnswer?: (params: any, signal: AbortSignal) => Promise<any> | any;
  elicitationAnswer?: (params: any, signal: AbortSignal) => Promise<any> | any;
  permissionSignals: AbortSignal[] = [];
  init: any;
  private conn!: acp.ClientConnection;

  static async connect(url: string, token: string): Promise<TestClient> {
    const c = new TestClient();
    const record = (method: string) => (ctx: { params: any }) => {
      c.received.push({ method, params: ctx.params });
      if (method === "_codeaw/terminal/event" && ctx.params.data?.includes("\x1b[6n")) {
        void c.request("_codeaw/terminal/write", { terminalId: ctx.params.terminalId, data: "\x1b[1;1R" });
      }
    };
    const any = (p: unknown) => p as any;
    const app = acp
      .client({ name: "test-client" })
      .onNotification("session/update", record("session/update"))
      .onNotification("_codeaw/event", any, record("_codeaw/event"))
      .onNotification("_codeaw/replay", any, record("_codeaw/replay"))
      .onNotification("_codeaw/history/page", any, record("_codeaw/history/page"))
      .onNotification("_codeaw/activity", any, record("_codeaw/activity"))
      .onNotification("_codeaw/terminal/event", any, record("_codeaw/terminal/event"))
      .onRequest("session/request_permission", async (ctx) => {
        c.received.push({ method: "session/request_permission", params: ctx.params });
        c.permissionSignals.push(ctx.signal);
        if (!c.permissionAnswer) return new Promise<never>(() => undefined);
        return c.permissionAnswer(ctx.params, ctx.signal);
      })
      .onRequest("elicitation/create", async (ctx) => {
        c.received.push({ method: "elicitation/create", params: ctx.params });
        if (!c.elicitationAnswer) return new Promise<never>(() => undefined);
        return c.elicitationAnswer(ctx.params, ctx.signal);
      });
    const stream = createWebSocketStream(url, { WebSocket: WebSocket as any, headers: { Authorization: `Bearer ${token}` } });
    c.conn = app.connect(stream);
    c.init = await c.request("initialize", { protocolVersion: acp.PROTOCOL_VERSION, clientCapabilities: {} });
    return c;
  }

  request<T = any>(method: string, params: unknown): Promise<T> {
    return this.conn.agent.request(method, params as never) as Promise<T>;
  }

  notify(method: string, params: unknown): Promise<void> {
    return this.conn.agent.notify(method, params as never);
  }

  close(): void {
    this.conn.close();
  }

  updates(sessionId: string): any[] {
    return this.received.filter((r) => r.method === "session/update" && r.params.sessionId === sessionId).map((r) => r.params);
  }

  events(sessionId: string, type?: string): any[] {
    return this.received
      .filter((r) => r.method === "_codeaw/event" && r.params.sessionId === sessionId && (!type || r.params.event.type === type))
      .map((r) => r.params);
  }

  /** session/update + _codeaw/event messages for one session, in arrival order. */
  log(sessionId: string): Received[] {
    return this.received.filter((r) => (r.method === "session/update" || r.method === "_codeaw/event") && r.params.sessionId === sessionId);
  }

  text(sessionId: string, kind = "agent_message_chunk"): string {
    return this.updates(sessionId)
      .filter((p) => p.update.sessionUpdate === kind && p.update.content.type === "text")
      .map((p) => p.update.content.text)
      .join("");
  }

  async waitFor(pred: () => boolean, timeoutMs = 8000): Promise<void> {
    const start = Date.now();
    while (!pred()) {
      if (Date.now() - start > timeoutMs) throw new Error("waitFor timed out");
      await new Promise((r) => setTimeout(r, 20));
    }
  }
}

export async function newFakeSession(c: TestClient, cwd: string, extra: Record<string, unknown> = {}): Promise<any> {
  return c.request("session/new", { cwd, mcpServers: [], _meta: { codeaw: { agentId: "fake", ...extra } } });
}

export function promptText(sessionId: string, text: string, meta?: Record<string, unknown>) {
  return { sessionId, prompt: [{ type: "text", text }], ...(meta ? { _meta: { codeaw: meta } } : {}) };
}

/** The session's complete log as stored on disk, shaped like the notifications clients get. */
export function rawLog(tb: TestBridge, sessionId: string): Received[] {
  return new SessionStore(tb.loaded.dataDir).readEntries(sessionId).map((e) =>
    e.kind === "update"
      ? { method: "session/update", params: { sessionId, update: e.update, _meta: { codeaw: { seq: e.seq } } } }
      : { method: "_codeaw/event", params: { sessionId, event: e.event, _meta: { codeaw: { seq: e.seq } } } },
  );
}
