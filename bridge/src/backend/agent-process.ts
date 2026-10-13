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
import { desktopEnvironment, recoverCodexPath, resolveCommand } from "../util/environment.js";
import { AcpSubagents } from "./acp-subagents.js";
import { AgentTempDirectory } from "./agent-temp.js";

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
  /** `session/fork` honours a fork point, so a sent message can be edited (see docs/protocol.md). */
  forkAtMessage?: boolean;
}

/**
 * Adapters whose `session/fork` keeps history only up to `_meta.jetbrains.air.fork.messageId`.
 * Older releases ignore the fork point and would copy the whole conversation.
 */
const FORK_POINT_ADAPTERS: Record<string, number[]> = {
  "@agentclientprotocol/claude-agent-acp": [0, 71, 0],
  "@agentclientprotocol/codex-acp": [1, 8, 0],
};

export function supportsForkPoint(init: acp.InitializeResponse | undefined): boolean {
  if (!init?.agentCapabilities?.sessionCapabilities?.fork) return false;
  const info = init.agentInfo as { name?: unknown; version?: unknown } | undefined | null;
  const minimum = typeof info?.name === "string" ? FORK_POINT_ADAPTERS[info.name] : undefined;
  if (!minimum || typeof info?.version !== "string") return false;
  const version = info.version.split(/[-+]/)[0].split(".").map(Number);
  if (version.length !== 3 || version.some((n) => !Number.isInteger(n))) return false;
  for (let i = 0; i < 3; i++) if (version[i] !== minimum[i]) return version[i] > minimum[i];
  return true;
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

interface AgentRun {
  child: ChildProcess;
  temporary?: AgentTempDirectory;
  closed: Promise<void>;
  hasClosed: boolean;
  retiring?: Promise<void>;
}

/** Capabilities the bridge advertises to every agent (see docs/protocol.md). */
export function bridgeClientCapabilities(): acp.ClientCapabilities {
  return {
    terminal: false,
    elicitation: { form: {} },
    session: { configOptions: { boolean: {} }, notices: {} },
    // Native children are translated to ordinary attributed tool calls/chunks.
    subagents: {},
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

  private run?: AgentRun;
  private conn?: acp.ClientConnection;
  private starting?: Promise<void>;
  private stopping?: Promise<void>;
  private retiring: Promise<void> = Promise.resolve();
  private stoppedGeneration = 0;
  private goneGeneration = 0;
  private stderrTail = "";
  private readonly log: Logger;
  private readonly logFile: string;
  private readonly subagents = new AcpSubagents();
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

  get supportsForkAtMessage(): boolean {
    return supportsForkPoint(this.init);
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
      forkAtMessage: this.supportsForkAtMessage,
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
    this.lastUsed = Date.now();
    this.lastError = undefined;
    this.init = undefined;
    this.stderrTail = "";
    this.subagents.clear();
    const generation = ++this.generation;
    await this.stopping;
    await this.retiring;
    if (this.status !== "starting") return this.fail(generation, "agent stopped during initialize");
    if (this.run && !this.run.hasClosed) return this.fail(generation, "previous agent process is still exiting; retry after it has stopped");
    const { command, args, env } = this.config;
    const inherited = desktopEnvironment({ ...process.env, ...env });
    let environment = this.id === "codex" ? recoverCodexPath(inherited) : inherited;
    if (environment.CODEX_PATH !== inherited.CODEX_PATH) this.log.warn("Codex desktop's old WindowsApps executable disappeared; using the current installed Codex CLI");
    if (!resolveCommand(command, environment)) {
      return this.fail(generation, `ACP executable not found: ${command}. Install this agent from the ACP installer or fix its command in settings.`);
    }
    this.log.info(`starting: ${command} ${args.join(" ")}`);
    let temporary: AgentTempDirectory | undefined;
    let child: ChildProcess;
    try {
      if (process.platform === "win32" && /(?:^|[\\/])agy_acp_server\.exe$/i.test(command)) {
        temporary = await AgentTempDirectory.create(path.join(path.dirname(this.logFile), "..", "tmp", "agy-acp"));
        environment = temporary.environment(environment);
      }
      if (this.status !== "starting") throw new Error("agent stopped during initialize");
      child = spawn(command, args, {
        cwd: this.config.cwd ?? os.homedir(),
        env: environment,
        stdio: ["pipe", "pipe", "pipe"],
        windowsHide: true,
      });
    } catch (err) {
      await temporary?.dispose().catch(() => this.log.warn("could not remove agent temp directory"));
      return this.fail(generation, `spawn failed: ${(err as Error).message}`);
    }
    const run: AgentRun = { child, temporary, hasClosed: false, closed: Promise.resolve() };
    run.closed = new Promise<void>((resolve) => child.once("close", () => { run.hasClosed = true; resolve(); }));
    this.run = run;

    const spawnError = new Promise<never>((_, reject) => {
      child.once("error", (err) => reject(new Error(`spawn failed: ${err.message}`)));
    });
    child.stderr!.on("data", (chunk: Buffer) => { if (generation === this.generation) this.onStderr(chunk); });
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
    const conn = this.conn = app.connect({
      writable: stream.writable,
      readable: stream.readable.pipeThrough(new TransformStream<acp.AnyMessage, acp.AnyMessage>({
        transform: (message, controller) => {
          for (const routed of this.subagents.transform(message)) controller.enqueue(routed);
        },
      })),
    });
    // stdout closing is the earliest sign of death; the process 'exit' event can lag behind.
    void conn.closed.then(() => this.onGone(generation, "closed its connection"));

    let timer: NodeJS.Timeout | undefined;
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`initialize timed out after ${this.startTimeoutMs} ms`)), this.startTimeoutMs);
      timer.unref();
    });
    try {
      const init = await Promise.race([
        (async () => {
          if (temporary && child.pid) await temporary.recordProcess(child.pid);
          return conn.agent.request("initialize", {
            protocolVersion: acp.PROTOCOL_VERSION,
            clientCapabilities: bridgeClientCapabilities(),
            clientInfo: { name: "codeaw-bridge", title: "codeaw", version: VERSION },
          });
        })(),
        spawnError,
        timeout,
      ]);
      if (generation !== this.generation) throw new Error("agent restarted during initialize");
      if (this.status !== "starting" || this.run !== run) throw new Error("agent stopped during initialize");
      this.init = init;
      this.status = "ready";
      this.lastUsed = Date.now();
      this.log.info(`ready (${describeAgent(init)})`);
    } catch (err) {
      const message = (err as Error).message;
      const detail = (/abort/i.test(message) ? "ACP connection closed before initialization completed. Check the agent executable and its Node.js runtime." : message)
        + (this.stderrTail ? `\n${this.stderrTail.trim().slice(-800)}` : "");
      clearTimeout(timer);
      await this.retire(run);
      return this.fail(generation, detail);
    } finally { clearTimeout(timer); }
  }

  private fail(generation: number, detail: string): never {
    if (generation === this.generation && this.stoppedGeneration !== generation) {
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
    }
    this.conn = undefined;
    const run = this.run;
    if (run) void this.retire(run);
    this.subagents.clear();
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
      if (method === "session/load") this.subagents.clear((params as { sessionId: string }).sessionId);
      const result = (await conn.agent.request(method, params as never, options)) as T;
      if (method === "session/close" || method === "session/delete") {
        this.subagents.clear((params as { sessionId: string }).sessionId);
      }
      return result;
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
  stop(reason = "stopped"): Promise<void> {
    return this.stopping ??= this.stopRun(reason).finally(() => { this.stopping = undefined; });
  }

  private async stopRun(reason: string): Promise<void> {
    this.log.info(`stopping (${reason})`);
    this.status = "stopped";
    this.stoppedGeneration = this.generation;
    const run = this.run;
    if (run) await this.retire(run);
    else await this.retiring;
    if (this.run === run && (!run || run.hasClosed)) {
      this.conn = undefined;
      this.run = undefined;
      this.subagents.clear();
    }
  }

  /** stdout EOF can precede PyInstaller's parent cleanup; let it finish first. */
  private retire(run: AgentRun): Promise<void> {
    if (!run.retiring) {
      run.retiring = (async () => {
        try { run.child.stdin?.end(); } catch { /* Already closed. */ }
        if (!await this.waitForClose(run, run.temporary ? 5000 : 2500)) {
          this.killTree(run.child);
          if (!await this.waitForClose(run, 2500)) {
            this.log.warn("agent process did not exit; retaining its temp directory");
            return;
          }
        }
        await run.temporary?.dispose().catch(() => this.log.warn("could not remove agent temp directory; will retry after bridge restart"));
        if (this.run === run) this.run = undefined;
      })();
    }
    return this.retiring = run.retiring;
  }

  private async waitForClose(run: AgentRun, timeoutMs: number): Promise<boolean> {
    if (run.hasClosed) return true;
    let timer: NodeJS.Timeout | undefined;
    try {
      return await Promise.race([run.closed.then(() => true), new Promise<false>((resolve) => {
        timer = setTimeout(() => resolve(false), timeoutMs);
        timer.unref();
      })]);
    } finally { clearTimeout(timer); }
  }

  private killTree(child: ChildProcess): void {
    if (!child.pid || child.exitCode !== null || child.signalCode !== null) return;
    if (process.platform === "win32") {
      spawnSync("taskkill", ["/pid", String(child.pid), "/T", "/F"], { windowsHide: true, timeout: 5000 });
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
