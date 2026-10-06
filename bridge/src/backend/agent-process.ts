import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { spawnSync, type ChildProcess } from "node:child_process";
import { Readable, Writable } from "node:stream";
import spawn from "cross-spawn";
import * as acp from "@agentclientprotocol/sdk";
import type { AgentConfig } from "../config.js";
import { logger, type Logger } from "../util/log.js";
import { VERSION } from "../version.js";
import type { AgentBackend } from "./backend.js";
import type { DesktopState } from "./codex-desktop-state.js";
import { desktopEnvironment, resolveCommand } from "../util/environment.js";

export type AgentStatus = "stopped" | "starting" | "ready" | "error";

export interface AgentInfo {
  id: string;
  name: string;
  status: AgentStatus;
  error?: string;
  agentInfo?: unknown;
  capabilities?: acp.AgentCapabilities;
  authMethods?: unknown[];
  steering: boolean;
}

/** Callbacks from the agent into the session layer. `agentId` identifies the sender. */
export interface AgentHandlers {
  onUpdate(agentId: string, params: acp.SessionNotification): void;
  onPermission(agentId: string, params: acp.RequestPermissionRequest, signal: AbortSignal): Promise<acp.RequestPermissionResponse>;
  onElicitation(agentId: string, params: acp.CreateElicitationRequest, signal: AbortSignal): Promise<acp.CreateElicitationResponse>;
  onExit(agentId: string, generation: number, detail: string): void;
  onHistoryReset?(agentId: string, sessionId: string, updates: acp.SessionUpdate[]): void;
  onSessionState?(agentId: string, sessionId: string, state: DesktopState): void;
  onSessionError?(agentId: string, sessionId: string, message: string): void;
}

const LOG_ROTATE_BYTES = 5 * 1024 * 1024;

/** Capabilities the bridge advertises to every agent (see docs/protocol.md). */
export function bridgeClientCapabilities(): acp.ClientCapabilities {
  return {
    terminal: false,
    elicitation: { form: {} },
    session: { configOptions: { boolean: {} }, notices: {} },
    // Claude only reports structured shell output (terminal_info/output/exit) when this is set.
    _meta: { terminal_output: true, "subagent-transcript": true },
  };
}

/**
 * One ACP agent subprocess speaking JSON-RPC over stdio. Handles many sessions.
 * Started lazily, restarted on demand after a crash; `generation` tells callers
 * whether a session they activated earlier still lives in the current process.
 */
export class AgentProcess implements AgentBackend {
  readonly id: string;
  readonly config: AgentConfig;
  generation = 0;
  status: AgentStatus = "stopped";
  lastError?: string;
  init?: acp.InitializeResponse;

  private child?: ChildProcess;
  private conn?: acp.ClientConnection;
  private starting?: Promise<void>;
  private goneGeneration = 0;
  private stderrTail = "";
  private readonly log: Logger;
  private readonly logFile: string;
  /** Requests currently in flight; used to decide whether the process is idle. */
  inflight = 0;
  lastUsed = Date.now();

  constructor(
    id: string,
    config: AgentConfig,
    private readonly handlers: AgentHandlers,
    logDir: string,
    private readonly startTimeoutMs = 60_000,
  ) {
    this.id = id;
    this.config = config;
    this.log = logger(`agent:${id}`);
    this.logFile = path.join(logDir, `${id}.log`);
  }

  get capabilities(): acp.AgentCapabilities | undefined {
    return this.init?.agentCapabilities ?? undefined;
  }

  get supportsSteering(): boolean {
    const meta = this.init?._meta as Record<string, any> | undefined | null;
    return meta?.steering?.supported === true;
  }

  get running(): boolean {
    return this.status === "ready" || this.status === "starting";
  }

  describe(): AgentInfo {
    return {
      id: this.id,
      name: this.config.name,
      status: this.status,
      error: this.status === "error" ? this.lastError : undefined,
      agentInfo: this.init?.agentInfo ?? undefined,
      capabilities: this.init?.agentCapabilities ?? undefined,
      authMethods: this.init?.authMethods ?? undefined,
      steering: this.supportsSteering,
    };
  }

  /** Starts the process if needed and resolves once `initialize` succeeded. */
  ensureStarted(): Promise<void> {
    if (this.status === "ready") return Promise.resolve();
    if (!this.starting) {
      this.starting = this.start().finally(() => {
        this.starting = undefined;
      });
    }
    return this.starting;
  }

  private async start(): Promise<void> {
    this.status = "starting";
    this.lastError = undefined;
    this.stderrTail = "";
    const generation = ++this.generation;
    const { command, args, env } = this.config;
    const environment = desktopEnvironment({ ...process.env, ...env });
    if (!resolveCommand(command, environment)) {
      return this.fail(generation, `ACP executable not found: ${command}. Install this agent from the ACP installer or fix its command in settings.`);
    }
    this.log.info(`starting: ${command} ${args.join(" ")}`);
    let child: ChildProcess;
    try {
      child = spawn(command, args, {
        cwd: this.config.cwd ?? os.homedir(),
        env: environment,
        stdio: ["pipe", "pipe", "pipe"],
        windowsHide: true,
      });
    } catch (err) {
      return this.fail(generation, `spawn failed: ${(err as Error).message}`);
    }
    this.child = child;

    const spawnError = new Promise<never>((_, reject) => {
      child.once("error", (err) => reject(new Error(`spawn failed: ${err.message}`)));
    });
    child.stderr!.on("data", (chunk: Buffer) => this.onStderr(chunk));
    child.once("exit", (code, signal) => this.onExit(generation, code, signal));

    const stream = acp.ndJsonStream(
      Writable.toWeb(child.stdin!) as WritableStream<Uint8Array>,
      Readable.toWeb(child.stdout!) as unknown as ReadableStream<Uint8Array>,
    );
    const app = acp
      .client({ name: "codeaw-bridge" })
      .onNotification("session/update", (ctx) => {
        if (generation === this.generation) this.handlers.onUpdate(this.id, ctx.params);
      })
      .onRequest("session/request_permission", (ctx) => this.handlers.onPermission(this.id, ctx.params, ctx.signal))
      .onRequest("elicitation/create", (ctx) => this.handlers.onElicitation(this.id, ctx.params, ctx.signal));
    this.conn = app.connect(stream);
    // stdout closing is the earliest sign of death; the process 'exit' event can lag behind.
    void this.conn.closed.then(() => this.onGone(generation, "closed its connection"));

    let timer: NodeJS.Timeout | undefined;
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`initialize timed out after ${this.startTimeoutMs} ms`)), this.startTimeoutMs);
      timer.unref();
    });
    try {
      const init = await Promise.race([
        this.conn.agent.request("initialize", {
          protocolVersion: acp.PROTOCOL_VERSION,
          clientCapabilities: bridgeClientCapabilities(),
          clientInfo: { name: "codeaw-bridge", title: "codeaw", version: VERSION },
        }),
        spawnError,
        timeout,
      ]);
      if (generation !== this.generation) throw new Error("agent restarted during initialize");
      this.init = init;
      this.status = "ready";
      this.lastUsed = Date.now();
      this.log.info(`ready (${describeAgent(init)})`);
    } catch (err) {
      const message = (err as Error).message;
      const detail = (/abort/i.test(message) ? "ACP connection closed before initialization completed. Check the agent executable and its Node.js runtime." : message)
        + (this.stderrTail ? `\n${this.stderrTail.trim().slice(-800)}` : "");
      this.killTree();
      return this.fail(generation, detail);
    } finally { clearTimeout(timer); }
  }

  private fail(generation: number, detail: string): never {
    if (generation === this.generation) {
      this.status = "error";
      this.lastError = detail;
    }
    this.log.error(`failed to start: ${detail}`);
    throw new Error(`Agent "${this.config.name}" failed to start: ${detail}`);
  }

  private onStderr(chunk: Buffer): void {
    const text = chunk.toString("utf8");
    this.stderrTail = (this.stderrTail + text).slice(-4000);
    try {
      fs.mkdirSync(path.dirname(this.logFile), { recursive: true });
      try {
        if (fs.statSync(this.logFile).size > LOG_ROTATE_BYTES) fs.renameSync(this.logFile, this.logFile + ".1");
      } catch {
        // no log file yet
      }
      fs.appendFileSync(this.logFile, text);
    } catch {
      // logging must never take the bridge down
    }
  }

  private onExit(generation: number, code: number | null, signal: NodeJS.Signals | null): void {
    const clean = code === 0 || signal === "SIGTERM";
    this.onGone(generation, `exited (code ${code ?? "null"}${signal ? `, signal ${signal}` : ""})`, clean);
  }

  /** Runs once per generation, for whichever of "connection closed" / "process exited" comes first. */
  private onGone(generation: number, detail: string, clean = false): void {
    if (generation !== this.generation || this.goneGeneration === generation) return;
    this.goneGeneration = generation;
    const wasReady = this.status === "ready";
    if (this.status !== "stopped") {
      this.status = clean ? "stopped" : "error";
      if (this.status === "error") this.lastError = detail + (this.stderrTail ? `\n${this.stderrTail.trim().slice(-800)}` : "");
      this.killTree();
    }
    this.conn = undefined;
    this.child = undefined;
    if (wasReady) this.log.warn(detail);
    this.handlers.onExit(this.id, generation, detail);
  }

  async request<T = unknown>(method: string, params: unknown, options?: acp.SendRequestOptions): Promise<T> {
    await this.ensureStarted();
    const conn = this.conn;
    if (!conn) throw new Error(`Agent "${this.config.name}" is not running`);
    this.inflight++;
    this.lastUsed = Date.now();
    try {
      return (await conn.agent.request(method, params as never, options)) as T;
    } finally {
      this.inflight--;
      this.lastUsed = Date.now();
    }
  }

  async notify(method: string, params: unknown): Promise<void> {
    const conn = this.conn;
    if (!conn || this.status !== "ready") return;
    await conn.agent.notify(method, params as never);
  }

  /** Closes stdin (agents exit on EOF), then kills the whole process tree if it lingers. */
  async stop(reason = "stopped"): Promise<void> {
    const child = this.child;
    if (!child) {
      this.status = "stopped";
      return;
    }
    this.log.info(`stopping (${reason})`);
    this.status = "stopped";
    try {
      child.stdin?.end();
    } catch {
      // already closed
    }
    const exited = new Promise<void>((resolve) => child.once("exit", () => resolve()));
    const timer = new Promise<"timeout">((resolve) => setTimeout(() => resolve("timeout"), 2500).unref());
    if ((await Promise.race([exited, timer])) === "timeout") this.killTree();
    this.conn = undefined;
    this.child = undefined;
  }

  private killTree(): void {
    const child = this.child;
    if (!child?.pid) return;
    if (process.platform === "win32") {
      spawnSync("taskkill", ["/pid", String(child.pid), "/T", "/F"], { windowsHide: true });
    } else {
      try {
        child.kill("SIGKILL");
      } catch {
        // gone
      }
    }
  }
}

function describeAgent(init: acp.InitializeResponse): string {
  const info = init.agentInfo as { name?: string; version?: string } | undefined | null;
  return info ? `${info.name ?? "?"} ${info.version ?? ""}`.trim() : "unknown agent";
}
