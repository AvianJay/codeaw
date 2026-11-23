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
import { logger } from "../util/log.js";
import { expandHome, readJson, safeName, writeFileAtomic } from "../util/paths.js";

const log = logger("agy");

type Turn = { resolve: (result: acp.PromptResponse) => void; reject: (error: Error) => void; text: string };
type AgySession = {
  id: string; cwd: string; additionalDirectories: string[]; nativeId?: string;
  model: string; effort: string; mode: string;
  child?: ChildProcess; starting?: Promise<void>; closing?: Promise<void>; applied?: string; turn?: Turn;
  cancelled?: boolean; stderr: string; tools: Set<string>; secrets?: string[]; titled?: boolean;
};
type SavedSession = Pick<AgySession, "id" | "cwd" | "additionalDirectories" | "nativeId" | "model" | "effort" | "mode"> & { titled?: boolean };

/**
 * CC Switch writes .env for Gemini CLI; AGY itself deliberately does not read it.
 * A missing file reads as empty: CC Switch leaves none while Google sign-in is selected.
 */
export function geminiProviderEnvironment(file: string): Record<string, string> {
  const env: Record<string, string> = {};
  let content: string;
  try { content = fs.readFileSync(expandHome(file), "utf8"); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return env;
    throw error;
  }
  for (const line of content.split(/\r?\n/)) {
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
export const agySettingsFile = () => path.join(os.homedir(), ".gemini", "antigravity-cli", "settings.json");
const TITLE_LENGTH = 60;

/**
 * Why AGY cannot reach its model provider, as far as the bridge can tell before starting it.
 * AGY itself only says "GEMINI_API_KEY environment variable is not set" after a launch.
 */
export function agyProviderProblem(settings: { modelProvider?: unknown }, env: NodeJS.ProcessEnv, opts: { agentId: string; geminiEnvFile?: string; settingsPath: string }): string | undefined {
  if (settings.modelProvider !== "gemini" || env.GEMINI_API_KEY?.trim()) return undefined;
  const source = opts.geminiEnvFile
    ? `${opts.geminiEnvFile} has no GEMINI_API_KEY (CC Switch empties it while its Gemini provider is "Google Official")`
    : "the bridge's environment has no GEMINI_API_KEY";
  return `Antigravity CLI is set to use a Gemini API provider ("modelProvider": "gemini" in ${opts.settingsPath}), but ${source}. ` +
    `Select your API provider for Gemini in CC Switch, or set GEMINI_API_KEY and GOOGLE_GEMINI_BASE_URL under agents.${opts.agentId}.env in the codeaw config. ` +
    `To use Google sign-in instead, remove "modelProvider" from that settings file and sign in by running agy once on this computer.`;
}

/**
 * AGY reports provider failures as `agent executor error: generating and executing: Error 400,
 * Message: {json}, Status: 400 Bad Request, Details: []`. The phone shows the provider's own words.
 */
export function agyErrorMessage(raw: string): string {
  const text = raw.trim();
  const status = /\bError (\d{3}), Message: /.exec(text);
  const end = text.lastIndexOf(", Status: ");
  let message: string | undefined;
  let code: string | undefined;
  if (status && end > status.index) {
    const body = text.slice(status.index + status[0].length, end);
    try {
      const parsed = JSON.parse(body);
      const error = parsed?.error ?? parsed;
      message = typeof error?.message === "string" ? error.message : undefined;
      code = typeof error?.code === "string" ? error.code : typeof error?.status === "string" ? error.status : undefined;
    } catch {
      message = body.replace(/^"|"$/g, "");
    }
  }
  if (!status || !message) return text.replace(/^(?:error:\s*)?agent executor error:\s*(?:generating and executing:\s*)?/i, "") || text;
  const http = status[1];
  let hint = "";
  if (code === "model_not_found" || /unknown provider for model|model.*not (?:found|supported)|no such model/i.test(message)) {
    hint = " This provider does not serve that model: pick another one in the model menu. Custom models from AGY's customModelsConfig are listed there too.";
  } else if (http === "401" || http === "403") {
    hint = " Check the GEMINI_API_KEY that AGY gets.";
  } else if (http === "429") {
    hint = " The provider is rate limiting or out of quota; try again later or pick another model.";
  }
  return `The model provider answered HTTP ${http}: ${message}.${hint}`.replace(/\.\./g, ".");
}

const str = (input: Record<string, unknown>, ...keys: string[]) => {
  for (const key of keys) if (typeof input[key] === "string" && (input[key] as string).trim()) return (input[key] as string).trim();
  return undefined;
};
const shortPath = (p: string) => path.win32.basename(p) || p;

/** How a tool call reads on the phone. AGY names tools by function and passes PascalCase arguments. */
export function agyToolCall(name: string, input: Record<string, unknown>): { title: string; kind: acp.ToolKind; locations?: acp.ToolCallLocation[] } {
  const file = str(input, "Path", "AbsolutePath", "TargetFile", "FilePath", "File");
  const dir = str(input, "DirectoryPath", "SearchPath", "SearchDirectory", "Directory");
  const at = (p: string | undefined) => (p ? { locations: [{ path: p }] } : {});
  switch (name) {
    case "run_command":
    case "send_command_input":
      return { title: str(input, "CommandLine", "Command", "Input") ?? "Run command", kind: "execute", ...at(str(input, "Cwd")) };
    case "command_status":
      return { title: "Check command status", kind: "execute" };
    case "read_file":
    case "view_file":
    case "view_file_outline":
    case "view_code_item":
      return { title: file ? `Read ${shortPath(file)}` : "Read file", kind: "read", ...at(file) };
    case "edit_file":
    case "replace_file_content":
    case "multi_replace_file_content":
      return { title: file ? `Edit ${shortPath(file)}` : "Edit file", kind: "edit", ...at(file) };
    case "write_file":
    case "write_to_file":
    case "create_file":
      return { title: file ? `Write ${shortPath(file)}` : "Write file", kind: "edit", ...at(file) };
    case "delete_file":
      return { title: file ? `Delete ${shortPath(file)}` : "Delete file", kind: "delete", ...at(file) };
    case "list_dir":
    case "list_directory":
      return { title: `List ${dir ?? file ?? "folder"}`, kind: "read", ...at(dir ?? file) };
    case "grep_search":
    case "search_files":
    case "codebase_search": {
      const query = str(input, "Query", "Pattern", "SearchQuery");
      return { title: query ? `Search ${query}` : "Search files", kind: "search", ...at(dir) };
    }
    case "find_by_name": {
      const pattern = str(input, "Pattern", "Query");
      return { title: pattern ? `Find ${pattern}` : "Find files", kind: "search", ...at(dir) };
    }
    case "search_web":
      return { title: `Search the web${str(input, "query", "Query") ? `: ${str(input, "query", "Query")}` : ""}`, kind: "fetch" };
    case "read_url_content":
    case "fetch_url":
      return { title: str(input, "Url", "url") ?? "Fetch page", kind: "fetch" };
  }
  const kind: acp.ToolKind = /write|replace|edit/.test(name) ? "edit" : /view|read|list/.test(name) ? "read" : /grep|find|search/.test(name) ? "search" : "other";
  const words = name.replace(/_/g, " ").trim();
  return { title: (words.charAt(0).toUpperCase() + words.slice(1)) || "Tool", kind, ...at(file) };
}

/** `run_command` output opens with when it ran and how it ended; keep what it printed, and a failing exit code. */
export function agyToolOutput(name: string, output: string): string {
  if (name !== "run_command" && name !== "command_status") return output;
  const marker = output.indexOf("Command output:");
  if (marker < 0) return output;
  const exit = /Command exited with code (-?\d+)/.exec(output.slice(0, marker));
  const printed = output.slice(marker + "Command output:".length).replace(/\r\n/g, "\n").replace(/^\n+|\s+$/g, "");
  return exit && exit[1] !== "0" ? `Exit code ${exit[1]}${printed ? `\n${printed}` : ""}` : printed;
}

/** A chat title from the first prompt, as other agents name their chats. */
export function agyTitle(text: string): string | undefined {
  const line = text.split(/\r?\n/).map((l) => l.trim()).find(Boolean)?.replace(/\s+/g, " ");
  if (!line) return undefined;
  return line.length > TITLE_LENGTH ? line.slice(0, TITLE_LENGTH - 1).trimEnd() + "…" : line;
}

/** One native NDJSON subprocess per conversation. No ACP or permission bypass flags. */
export class AgyBackend implements AgentBackend {
  generation = 0;
  status: AgentStatus = "stopped";
  lastUsed = Date.now();
  inflight = 0;
  readonly supportsSteering = false;
  readonly supportsForkAtMessage = false;
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
    logDir: string, private readonly startTimeoutMs = 60_000, private readonly settingsPath = agySettingsFile()) {
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
    const problem = this.providerProblem();
    // `agy models` would fail the same way; the chat explains it when a message is sent.
    if (problem) log.warn(`[${this.id}] ${problem}`);
    this.models = problem ? undefined : await this.readCatalog();
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

  private providerProblem(env = this.environment()): string | undefined {
    return agyProviderProblem(readJson<any>(this.settingsPath, {}), env, { agentId: this.id, geminiEnvFile: this.config.geminiEnvFile, settingsPath: this.settingsPath });
  }

  private file(id: string): string { return path.join(this.stateDir, safeName(id) + ".json"); }

  private save(s: AgySession): void {
    const { id, cwd, additionalDirectories, nativeId, model, effort, mode, titled } = s;
    writeFileAtomic(this.file(id), JSON.stringify({ id, cwd, additionalDirectories, nativeId, model, effort, mode, ...(titled ? { titled } : {}) }));
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
    const settings = readJson<any>(this.settingsPath, {});
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
        const settings = readJson<any>(this.settingsPath, {});
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
        const input = info.parameters && typeof info.parameters === "object" ? info.parameters : {};
        const shown = agyToolCall(name, input);
        const content: acp.ToolCallContent[] = [];
        const output = typeof info.output === "string" ? agyToolOutput(name, info.output) : info.output == null ? "" : JSON.stringify(info.output);
        if (output) content.push({ type: "content", content: { type: "text", text: this.redact(s, output) } });
        if (info.error) content.push({ type: "content", content: { type: "text", text: this.redact(s, info.error.message || JSON.stringify(info.error)) } });
        const status = info.error ? "failed" : u.state === "DONE" ? "completed" : "in_progress";
        if (!s.tools.has(toolCallId)) {
          s.tools.add(toolCallId);
          this.update(s, { sessionUpdate: "tool_call", toolCallId, ...shown, status, rawInput: input, content });
        } else this.update(s, { sessionUpdate: "tool_call_update", toolCallId, status, content, rawOutput: info.output });
      }
    }
    if (event.event === "result" && s.turn) {
      const r = event.result ?? {};
      const turn = s.turn;
      s.turn = undefined;
      if (r.status !== "SUCCESS" && !["CANCELED", "INTERRUPTED"].includes(r.status)) {
        turn.reject(new Error(this.redact(s, r.error ? agyErrorMessage(String(r.error)) : `AGY ended with ${r.status ?? "an invalid result"}`)));
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
    if (s.cancelled) return;
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
            reject(new Error(this.redact(s, event.result?.error ? agyErrorMessage(String(event.result.error)) : "AGY did not initialize")));
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
    const problem = this.providerProblem();
    if (problem) throw acp.RequestError.invalidRequest(undefined, problem);
    if (!s.titled) {
      const title = agyTitle(text);
      if (title) {
        s.titled = true;
        this.save(s);
        this.update(s, { sessionUpdate: "session_info_update", title });
      }
    }
    s.cancelled = false;
    s.starting = this.startProcess(s);
    try { await s.starting; }
    catch (error) { if (!s.cancelled) throw error; }
    finally { s.starting = undefined; }
    if (s.cancelled) { await this.closeProcess(s, true); return { stopReason: "cancelled" }; }
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
    await Promise.all([...this.sessions.values()].map(async (s) => {
      await this.closeProcess(s, true);
      await s.starting?.catch(() => undefined);
      await this.closeProcess(s, true);
    }));
    this.handlers.onExit(this.id, generation, reason);
  }
}
