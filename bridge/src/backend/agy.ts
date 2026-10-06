import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { spawnSync, type ChildProcess } from "node:child_process";
import { createInterface } from "node:readline";
import spawn from "cross-spawn";
import * as acp from "@agentclientprotocol/sdk";
import type { AgentConfig } from "../config.js";
import type { AgentBackend } from "./backend.js";
import type { AgentHandlers, AgentInfo, AgentStatus } from "./agent-process.js";
import { desktopEnvironment, resolveCommand } from "../util/environment.js";
import { expandHome, readJson, safeName, writeFileAtomic } from "../util/paths.js";

type Turn = { resolve: (result: acp.PromptResponse) => void; reject: (error: Error) => void; text: string };
type AgySession = {
  id: string; cwd: string; additionalDirectories: string[]; nativeId?: string;
  model: string; effort: string; mode: string;
  child?: ChildProcess; starting?: Promise<void>; closing?: Promise<void>; applied?: string; turn?: Turn;
  cancelled?: boolean; stderr: string; tools: Set<string>; secrets?: string[];
};
type SavedSession = Pick<AgySession, "id" | "cwd" | "additionalDirectories" | "nativeId" | "model" | "effort" | "mode">;

/** CC Switch writes .env for Gemini CLI; AGY itself deliberately does not read it. */
export function geminiProviderEnvironment(file: string): Record<string, string> {
  const env: Record<string, string> = {};
  for (const line of fs.readFileSync(expandHome(file), "utf8").split(/\r?\n/)) {
    const match = line.match(/^\s*(?:export\s+)?(GEMINI_API_KEY|GOOGLE_GEMINI_BASE_URL|GEMINI_MODEL)\s*=\s*(.*?)\s*$/);
    if (!match) continue;
    let value = match[2];
    if (/^["']/.test(value) && value.endsWith(value[0])) value = value.slice(1, -1);
    else value = value.replace(/\s+#.*$/, "").trim();
    env[match[1]] = value;
  }
  return env;
}

const builtins = ["gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.6-flash", "gemini-3.1-pro"];
const efforts = ["low", "medium", "high"];
const settingsFile = () => path.join(os.homedir(), ".gemini", "antigravity-cli", "settings.json");

/** One native NDJSON subprocess per conversation. No ACP or permission bypass flags. */
export class AgyBackend implements AgentBackend {
  generation = 0;
  status: AgentStatus = "stopped";
  lastUsed = Date.now();
  inflight = 0;
  readonly supportsSteering = false;
  readonly capabilities: acp.AgentCapabilities = {
    loadSession: false,
    promptCapabilities: { image: false, audio: false, embeddedContext: true },
    sessionCapabilities: { resume: {}, close: {}, additionalDirectories: {} },
  };
  private readonly sessions = new Map<string, AgySession>();
  private readonly stateDir: string;
  private command?: string;
  private lastError?: string;
  private starting?: Promise<void>;
  private models?: acp.SessionConfigSelectOption[];

  constructor(readonly id: string, readonly config: AgentConfig, private readonly handlers: AgentHandlers,
    logDir: string, private readonly startTimeoutMs = 60_000) {
    this.stateDir = path.join(path.dirname(logDir), "agy", safeName(id));
  }

  get running(): boolean { return this.status === "ready"; }

  describe(): AgentInfo {
    return { id: this.id, name: this.config.name, status: this.status, error: this.lastError,
      agentInfo: { name: "antigravity-cli", title: "Antigravity CLI" }, capabilities: this.capabilities, steering: false };
  }

  private environment(): NodeJS.ProcessEnv {
    // Explicit agent env takes precedence; provider file is reread for every new process.
    return { ...desktopEnvironment(), ...(this.config.geminiEnvFile ? geminiProviderEnvironment(this.config.geminiEnvFile) : {}), ...this.config.env };
  }

  async ensureStarted(): Promise<void> {
    if (this.running) return;
    if (!this.starting) this.starting = this.initialize().finally(() => { this.starting = undefined; });
    return this.starting;
  }

  private async initialize(): Promise<void> {
    if (this.config.args.some((a) => /^(--(?:print|prompt|continue|conversation)|-p|-c)(?:=|$)/.test(a))) {
      throw new Error("AGY conversation and prompt flags are managed by Codeaw; remove them from agents args");
    }
    this.command = resolveCommand(this.config.command, this.environment());
    if (!this.command) {
      this.status = "error";
      this.lastError = `AGY executable not found: ${this.config.command}`;
      throw new Error(this.lastError);
    }
    this.generation++;
    this.models = await this.readCatalog();
    this.status = "ready";
    this.lastError = undefined;
  }

  private readCatalog(): Promise<acp.SessionConfigSelectOption[] | undefined> {
    // The CLI's account/provider-specific catalog may contain custom or Claude models.
    const args = [...this.config.args];
    for (const flag of ["--model", "--effort", "--mode"]) {
      for (let i = args.length - 1; i >= 0; i--) {
        if (args[i] === flag) args.splice(i, 2);
        else if (args[i].startsWith(flag + "=")) args.splice(i, 1);
      }
    }
    const child = spawn(this.command!, [...args, "models"], { env: this.environment(), cwd: this.config.cwd, windowsHide: true, stdio: ["ignore", "pipe", "ignore"] });
    let output = "";
    child.stdout!.on("data", (chunk: Buffer) => { output = (output + chunk.toString("utf8")).slice(0, 100_000); });
    return new Promise((resolve) => {
      const timer = setTimeout(() => { void this.kill(child); resolve(undefined); }, Math.min(this.startTimeoutMs, 10_000));
      child.once("error", () => { clearTimeout(timer); resolve(undefined); });
      child.once("close", (code) => {
        clearTimeout(timer);
        const models = output.split(/\r?\n/).flatMap((line) => {
          const [value, name] = line.split("\t");
          return value && name ? [{ value, name }] : [];
        });
        resolve(code === 0 && models.length ? models : undefined);
      });
    });
  }

  private file(id: string): string { return path.join(this.stateDir, safeName(id) + ".json"); }

  private save(s: AgySession): void {
    const { id, cwd, additionalDirectories, nativeId, model, effort, mode } = s;
    writeFileAtomic(this.file(id), JSON.stringify({ id, cwd, additionalDirectories, nativeId, model, effort, mode }));
  }

  private session(id: string): AgySession {
    let s = this.sessions.get(id);
    if (!s) {
      const saved = readJson<SavedSession | undefined>(this.file(id), undefined);
      if (!saved || saved.id !== id) throw acp.RequestError.invalidParams(undefined, "Unknown AGY conversation; open a Codeaw conversation first");
      s = { ...saved, stderr: "", tools: new Set() };
      this.sessions.set(id, s);
    }
    return s;
  }

  private catalog(): acp.SessionConfigSelectOption[] {
    const models = this.models?.map((m) => ({ ...m })) ?? builtins.flatMap((family) => (family.endsWith("pro") ? ["low", "high"] : efforts).map((effort) => ({
      value: `${family}-${effort}`, name: `${family.replace("gemini-", "Gemini ").replace("-flash", " Flash").replace("-pro", " Pro")} (${effort})`,
    })));
    const settings = readJson<any>(settingsFile(), {});
    for (const [value, info] of Object.entries(settings.customModelsConfig?.customModels ?? {}) as Array<[string, any]>) {
      const existing = models.find((m) => m.value === value);
      if (existing && info.displayName) existing.name = info.displayName;
      else if (!existing) models.push({ value, name: info.displayName || value });
    }
    return models;
  }

  private configOptions(s: AgySession): acp.SessionConfigOption[] {
    const models = this.catalog();
    if (!models.some((m) => m.value === s.model)) models.push({ value: s.model, name: s.model });
    const options: acp.SessionConfigOption[] = [
      { id: "model", name: "Model", category: "model", type: "select", currentValue: s.model, options: models,
        description: "Applied to the next turn. Custom model names must be defined in AGY settings." },
      { id: "mode", name: "Mode", category: "mode", type: "select", currentValue: s.mode,
        description: "AGY headless uses local permission rules. Interactive approvals are unavailable; unapproved tools are denied.",
        options: [{ value: "accept-edits", name: "Accept edits" }, { value: "plan", name: "Plan" }] },
    ];
    if (builtins.some((family) => s.model === family || s.model.startsWith(family + "-"))) {
      options.splice(1, 0, { id: "effort", name: "Reasoning effort", category: "thought_level", type: "select",
        currentValue: s.effort, options: [{ value: "default", name: "Model default" }, ...efforts.map((value) => ({ value, name: value }))] });
    }
    return options;
  }

  private setup(s: AgySession): acp.NewSessionResponse {
    return { sessionId: s.id, configOptions: this.configOptions(s), modes: { currentModeId: s.mode,
      availableModes: [{ id: "accept-edits", name: "Accept edits" }, { id: "plan", name: "Plan" }] } };
  }

  async request<T = unknown>(method: string, raw: unknown, _options?: acp.SendRequestOptions): Promise<T> {
    await this.ensureStarted();
    this.inflight++;
    this.lastUsed = Date.now();
    try {
      const p = raw as any;
      if (method === "session/new") {
        const settings = readJson<any>(settingsFile(), {});
        const arg = (flag: string) => {
          const index = this.config.args.indexOf(flag);
          return index >= 0 ? this.config.args[index + 1] : this.config.args.find((a) => a.startsWith(flag + "="))?.slice(flag.length + 1);
        };
        const s: AgySession = { id: randomUUID(), cwd: p.cwd, additionalDirectories: p.additionalDirectories ?? [],
          model: arg("--model") || this.environment().GEMINI_MODEL || settings.model || "gemini-3.8-flash-low",
          effort: arg("--effort") || "default", mode: arg("--mode") || "accept-edits", stderr: "", tools: new Set() };
        this.sessions.set(s.id, s);
        this.save(s);
        return this.setup(s) as T;
      }
      const s = this.session(p.sessionId);
      if (method === "session/resume" || method === "session/load") return this.setup(s) as T;
      if (method === "session/set_mode" || method === "session/set_config_option") {
        const key = method === "session/set_mode" ? "mode" : p.configId;
        const value = method === "session/set_mode" ? p.modeId : p.value;
        if (typeof value !== "string" || !value.trim() || /[\r\n\0]/.test(value)) throw acp.RequestError.invalidParams(undefined, "Invalid AGY setting");
        if (key === "model") { s.model = value; s.effort = "default"; }
        else if (key === "effort" && ["default", ...efforts].includes(value) && this.configOptions(s).some((o) => o.id === "effort")) s.effort = value;
        else if (key === "mode" && ["accept-edits", "plan"].includes(value)) s.mode = value;
        else throw acp.RequestError.invalidParams(undefined, "Unsupported AGY setting");
        this.save(s);
        return { configOptions: this.configOptions(s) } as T;
      }
      if (method === "session/close") { await this.closeProcess(s); return {} as T; }
      if (method === "session/prompt") return await this.prompt(s, p.prompt) as T;
      throw acp.RequestError.methodNotFound(method);
    } finally { this.inflight--; this.lastUsed = Date.now(); }
  }

  async notify(method: string, raw: unknown): Promise<void> {
    if (method === "session/cancel") {
      const s = this.sessions.get((raw as any).sessionId);
      if (s) await this.closeProcess(s, true);
    }
  }

  private update(s: AgySession, update: acp.SessionUpdate): void {
    this.handlers.onUpdate(this.id, { sessionId: s.id, update });
  }

  private redact(s: AgySession, text: string): string {
    for (const value of s.secrets ?? []) text = text.replaceAll(value, "[REDACTED]");
    return text;
  }

  private event(s: AgySession, event: any): void {
    if (event.event === "init") {
      if (typeof event.conversation_id !== "string" || !event.conversation_id) throw new Error("AGY did not return a conversation ID");
      if (s.nativeId && s.nativeId !== event.conversation_id) throw new Error("AGY resumed a different conversation");
      s.nativeId = event.conversation_id;
      this.save(s);
    }
    if (event.event === "step_update" && s.turn) {
      const u = event.step_update ?? {};
      if (u.step_type === "agent_response" && typeof u.text_delta === "string") {
        s.turn.text += u.text_delta;
        this.update(s, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: u.text_delta } });
      } else if (/thought|thinking/.test(u.step_type) && typeof u.text_delta === "string") {
        this.update(s, { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: u.text_delta } });
      } else if (u.step_type === "tool") {
        const info = u.tool_info ?? {};
        const name = u.tool_name || info.name || "tool";
        const toolCallId = `${s.nativeId}:${u.step_index}`;
        const input = info.parameters ?? {};
        const kind: acp.ToolKind = name === "run_command" || name === "command_status" ? "execute" : /write|replace|edit/.test(name) ? "edit" : /view|read|list|grep|find/.test(name) ? "read" : "other";
        const content: acp.ToolCallContent[] = [];
        const output = typeof info.output === "string" ? info.output : info.output == null ? "" : JSON.stringify(info.output);
        if (output) content.push({ type: "content", content: { type: "text", text: output } });
        if (info.error) content.push({ type: "content", content: { type: "text", text: info.error.message || JSON.stringify(info.error) } });
        const status = info.error ? "failed" : u.state === "DONE" ? "completed" : "in_progress";
        if (!s.tools.has(toolCallId)) {
          s.tools.add(toolCallId);
          this.update(s, { sessionUpdate: "tool_call", toolCallId, title: input.CommandLine || name, kind, status, rawInput: input, content });
        } else this.update(s, { sessionUpdate: "tool_call_update", toolCallId, status, content, rawOutput: info.output });
      }
    }
    if (event.event === "result" && s.turn) {
      const r = event.result ?? {};
      const turn = s.turn;
      s.turn = undefined;
      if (r.status !== "SUCCESS" && !["CANCELED", "INTERRUPTED"].includes(r.status)) {
        turn.reject(new Error(this.redact(s, r.error || `AGY ended with ${r.status ?? "an invalid result"}`)));
        return;
      }
      if (!turn.text && r.response) this.update(s, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: r.response } });
      const u = r.usage;
      turn.resolve({ stopReason: r.status === "SUCCESS" ? "end_turn" : "cancelled", ...(u ? { usage: {
        inputTokens: u.input_tokens ?? 0, outputTokens: u.output_tokens ?? 0, totalTokens: u.total_tokens ?? 0,
        thoughtTokens: u.thinking_tokens ?? 0, cachedReadTokens: u.cache_read_tokens ?? 0,
      } } : {}) });
    }
  }

  private launchOptions(s: AgySession): { args: string[]; env: NodeJS.ProcessEnv; fingerprint: string } {
    const args = [...this.config.args];
    // Settings are session-local. Avoid duplicate model/mode/effort flags supplied in config.
    for (const flag of ["--model", "--effort", "--mode", "--input-format", "--output-format"]) {
      for (let i = args.length - 1; i >= 0; i--) {
        if (args[i] === flag) args.splice(i, 2);
        else if (args[i].startsWith(flag + "=")) args.splice(i, 1);
      }
    }
    args.push("--input-format", "stream-json", "--output-format", "stream-json", "--model", s.model, "--mode", s.mode);
    if (s.effort !== "default") args.push("--effort", s.effort);
    for (const directory of s.additionalDirectories) args.push("--add-dir", directory);
    const env = this.environment();
    // Kept only in memory, never written to state/logs; notices provider changes on restart.
    return { args, env, fingerprint: JSON.stringify([args, env.GEMINI_API_KEY, env.GOOGLE_GEMINI_BASE_URL]) };
  }

  private async startProcess(s: AgySession): Promise<void> {
    const options = this.launchOptions(s);
    if (s.child && s.applied === options.fingerprint) return;
    await this.closeProcess(s);
    if (s.nativeId) options.args.push("--conversation", s.nativeId);
    s.stderr = "";
    s.applied = options.fingerprint;
    s.secrets = Object.entries(options.env).filter(([name, value]) => /KEY|TOKEN|SECRET|PASSWORD/i.test(name) && value && value.length > 5).map(([, value]) => value!);
    const child = spawn(this.command!, options.args, { cwd: s.cwd, env: options.env, stdio: ["pipe", "pipe", "pipe"], windowsHide: true, detached: process.platform !== "win32" });
    s.child = child;
    const lines = createInterface({ input: child.stdout! });
    let ready = false;
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error(`AGY initialization timed out after ${this.startTimeoutMs} ms`));
        void this.closeProcess(s);
      }, this.startTimeoutMs);
      const failed = (detail: string) => {
        const error = new Error(this.redact(s, detail + (s.stderr ? `\n${s.stderr.trim().slice(-1200)}` : "")));
        if (!ready) { clearTimeout(timer); reject(error); }
        if (s.child === child) {
          s.turn?.reject(error);
          s.turn = undefined;
          void this.closeProcess(s);
        }
      };
      child.stderr!.on("data", (chunk: Buffer) => { s.stderr = (s.stderr + chunk.toString("utf8")).slice(-4000); });
      child.once("error", (error) => failed(error.message));
      child.once("exit", (code, signal) => { lines.close(); failed(`AGY exited (${code ?? signal ?? "unknown"})`); });
      lines.on("line", (line) => {
        if (s.child !== child || !line.trim()) return;
        try {
          const event = JSON.parse(line);
          this.event(s, event);
          if (event.event === "init") { ready = true; clearTimeout(timer); resolve(); }
          else if (event.event === "result" && !ready) {
            clearTimeout(timer);
            reject(new Error(this.redact(s, event.result?.error || "AGY did not initialize")));
            void this.closeProcess(s);
          }
        } catch (error) {
          // JSON.parse errors can quote the offending payload (including credentials).
          failed("Invalid AGY stream or conversation ID");
        }
      });
    });
  }

  private async prompt(s: AgySession, blocks: acp.ContentBlock[]): Promise<acp.PromptResponse> {
    if (s.turn || s.starting) throw acp.RequestError.invalidRequest(undefined, "AGY is already running a turn; queue this message");
    const text = blocks.map((b) => {
      if (b.type === "text") return b.text;
      if (b.type === "resource_link") return `${b.name || "Attached file"}: ${b.uri}`;
      if (b.type === "resource" && "text" in b.resource) return `${b.resource.uri}\n${b.resource.text}`;
      throw acp.RequestError.invalidParams(undefined, "AGY headless accepts text and file references. Upload images as files instead of inline images.");
    }).join("\n");
    s.cancelled = false;
    s.starting = this.startProcess(s);
    try { await s.starting; }
    catch (error) { if (!s.cancelled) throw error; }
    finally { s.starting = undefined; }
    if (s.cancelled) return { stopReason: "cancelled" };
    return new Promise<acp.PromptResponse>((resolve, reject) => {
      s.turn = { resolve, reject, text: "" };
      s.child!.stdin!.write(JSON.stringify({ event: "user", message: { content: text } }) + "\n", (error) => {
        if (error) { s.turn?.reject(error); s.turn = undefined; }
      });
    });
  }

  private async kill(child: ChildProcess): Promise<void> {
    if (!child.pid || child.exitCode !== null || child.signalCode !== null) return;
    if (process.platform === "win32") spawnSync("taskkill", ["/pid", String(child.pid), "/T", "/F"], { windowsHide: true });
    else {
      try { process.kill(-child.pid, "SIGKILL"); }
      catch { child.kill("SIGKILL"); }
    }
  }

  private async closeProcess(s: AgySession, cancelled = false): Promise<void> {
    const child = s.child;
    if (cancelled) s.cancelled = true;
    if (cancelled && s.turn) { s.turn.resolve({ stopReason: "cancelled" }); s.turn = undefined; }
    if (s.closing) return s.closing;
    if (!child) return;
    s.child = undefined;
    s.applied = undefined;
    s.closing = this.dispose(child, cancelled);
    try { await s.closing; } finally { s.closing = undefined; }
  }

  private async dispose(child: ChildProcess, cancelled: boolean): Promise<void> {
    if (child.exitCode !== null || child.signalCode !== null) return;
    const exited = new Promise<void>((resolve) => child.once("exit", () => resolve()));
    child.stdin?.end();
    if (cancelled) await this.kill(child);
    let timer: NodeJS.Timeout | undefined;
    try {
      await Promise.race([exited, new Promise<void>((resolve) => { timer = setTimeout(resolve, 1500); })]);
      await this.kill(child);
    } finally { clearTimeout(timer); }
  }

  async stop(reason = "bridge stopped"): Promise<void> {
    await this.starting?.catch(() => undefined);
    const generation = this.generation;
    this.status = "stopped";
    await Promise.all([...this.sessions.values()].map((s) => this.closeProcess(s, true)));
    this.handlers.onExit(this.id, generation, reason);
  }
}
