import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { isDeepStrictEqual } from "node:util";
import { RequestError } from "@agentclientprotocol/sdk";
import { parse, stringify } from "smol-toml";
import type { AgentBackend } from "./backend.js";
import { expandHome } from "../util/paths.js";

// The desktop owner accepts the sandbox and approval policy independently.
// codex-acp sends one of its fixed presets on every turn.
export const DESKTOP_FULL_ACCESS_ASK = "codeaw-full-access-on-request";

const MODES: Record<string, Record<string, string>> = {
  "read-only": { sandbox_mode: "read-only", approval_policy: "on-request", approvals_reviewer: "user" },
  "workspace-write": { sandbox_mode: "workspace-write", approval_policy: "on-request", approvals_reviewer: "user" },
  agent: { sandbox_mode: "workspace-write", approval_policy: "on-request", approvals_reviewer: "auto_review" },
  "agent-full-access": { sandbox_mode: "danger-full-access", approval_policy: "never", approvals_reviewer: "user" },
};

export function isCodex(agent: AgentBackend): boolean {
  return agent.id === "codex" || /(?:^|[\\/])codex-acp(?:\.(?:cmd|exe|ps1))?$/i.test(agent.config.command);
}

function configFile(agent: AgentBackend): string {
  const home = agent.config.env.CODEX_HOME ?? process.env.CODEX_HOME ?? path.join(os.homedir(), ".codex");
  const file = path.resolve(agent.config.cwd ?? process.cwd(), expandHome(home), "config.toml");
  try { return fs.realpathSync(file); } catch { return file; }
}

// Find complete TOML statements, including multiline strings/arrays. Keep all
// unrelated text verbatim; config may contain credentials and personal comments.
function statements(text: string): { start: number; end: number }[] {
  const out: { start: number; end: number }[] = [];
  let start = 0, quote = "", triple = false, depth = 0, comment = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (comment && c !== "\n") continue;
    if (quote) {
      if (quote === '"' && c === "\\") { i++; continue; }
      if (c === quote && (!triple || text.slice(i, i + 3) === quote.repeat(3))) {
        if (triple) {
          i += 2;
          // TOML permits one or two extra quotes at the end of multiline strings.
          for (let extra = 0; extra < 2 && text[i + 1] === quote; extra++) i++;
        }
        quote = "";
      }
      continue;
    }
    if (c === "#") comment = true;
    else if (c === '"' || c === "'") {
      quote = c; triple = text.slice(i, i + 3) === c.repeat(3);
      if (triple) i += 2;
    } else if (c === "[" || c === "{") depth++;
    else if (c === "]" || c === "}") depth--;
    if (c === "\n") {
      comment = false;
      if (depth === 0) { out.push({ start, end: i + 1 }); start = i + 1; }
    }
  }
  if (start < text.length) out.push({ start, end: text.length });
  return out;
}

/** Update only root defaults, preserving every other setting and its formatting. */
export function patchCodexDefaults(text: string, updates: Record<string, string>): string {
  const original = parse(text, { integersAsBigInt: "asNeeded" });
  const pending = new Map(Object.entries(updates));
  const newline = text.includes("\r\n") ? "\r\n" : "\n";
  let result = "", end = 0;
  for (const range of statements(text)) {
    const statement = text.slice(range.start, range.end);
    if (statement.trimStart().startsWith("[")) break;
    const match = statement.match(/^\s*(?:"([^"\n]+)"|'([^'\n]+)'|([\w-]+))\s*=/);
    const key = match && (match[1] ?? match[2] ?? match[3]);
    result += key && pending.has(key) ? `${stringify({ [key]: pending.get(key) }).trim()}${newline}` : statement;
    if (key) pending.delete(key);
    end = range.end;
  }
  if (pending.size && result && !result.endsWith("\n")) result += newline;
  for (const [key, value] of pending) result += `${stringify({ [key]: value }).trim()}${newline}`;
  result += text.slice(end);
  // Fail without writing if an unfamiliar TOML construct was not edited safely.
  if (!isDeepStrictEqual({ ...parse(result, { integersAsBigInt: "asNeeded" }) }, { ...original, ...updates })) throw new Error("Cannot safely update Codex defaults");
  return result;
}

function read(file: string): string {
  try { return fs.readFileSync(file, "utf8"); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return ""; throw error; }
}

/** Windows limits one environment variable to 32,767 characters. */
const MAX_CONFIG_OVERRIDE_LENGTH = 30_000;

/**
 * The environment that makes Codex tell its model `instructions`.
 *
 * Codex ignores the instructions of an MCP server, and in code mode its model does not
 * see tool descriptions either. codex-acp applies the JSON in `CODEX_CONFIG` to every
 * thread it starts or resumes, so the text goes into `developer_instructions`. That
 * replaces the user's own setting, which is therefore read and put in front; when it
 * cannot be read, nothing is changed. It is read when the agent starts.
 */
export function codexInstructionsEnvironment(agent: AgentBackend, env: NodeJS.ProcessEnv, instructions: string): NodeJS.ProcessEnv {
  let overrides: Record<string, unknown> = {};
  if (env.CODEX_CONFIG) {
    try { overrides = JSON.parse(env.CODEX_CONFIG); } catch { return env; }
    if (!overrides || typeof overrides !== "object" || Array.isArray(overrides)) return env;
  }
  let own = overrides.developer_instructions;
  if (own === undefined) {
    try { own = parse(read(configFile(agent)), { integersAsBigInt: "asNeeded" }).developer_instructions; }
    catch { return env; }
  }
  if (own !== undefined && typeof own !== "string") return env;
  const value = JSON.stringify({ ...overrides, developer_instructions: [own?.trim(), instructions].filter(Boolean).join("\n\n") });
  return value.length > MAX_CONFIG_OVERRIDE_LENGTH ? env : { ...env, CODEX_CONFIG: value };
}

/** Called only for new chats; existing chats restore their own saved settings. */
export function codexDefaults(agent: AgentBackend, requestedMode?: unknown): Record<string, string> {
  if (!isCodex(agent)) return {};
  let config: Record<string, unknown>;
  try {
    config = parse(read(configFile(agent)), { integersAsBigInt: "asNeeded" });
  } catch { throw new Error("Could not read Codex defaults from config.toml"); }
  const sandbox = config.default_permissions === ":danger-full-access" ? "danger-full-access"
    : config.default_permissions === ":read-only" ? "read-only"
    : config.default_permissions === ":workspace" ? "workspace-write" : config.sandbox_mode;
  const workspace = config.approvals_reviewer === "auto_review" || config.approvals_reviewer === "guardian_subagent" ? "agent" : "workspace-write";
  let mode: string | undefined;
  if (typeof requestedMode === "string" && Object.hasOwn(MODES, requestedMode)) mode = requestedMode;
  else if (sandbox === "danger-full-access") {
    if (config.approval_policy === "never") mode = "agent-full-access";
    else if (config.approval_policy === undefined || config.approval_policy === "on-request") mode = workspace;
    else throw RequestError.invalidRequest(undefined, "codex-acp cannot represent this full-access approval policy. Choose Workspace access in the permissions menu of an existing Codex chat, or set approval_policy to on-request in your Codex config.toml before starting an ACP chat.");
  } else if (sandbox === "read-only") mode = "read-only";
  else if (sandbox === "workspace-write") mode = workspace;
  return {
    ...(typeof config.model === "string" ? { model: config.model } : {}),
    ...(typeof config.model_reasoning_effort === "string" ? { reasoning_effort: config.model_reasoning_effort } : {}),
    ...(mode ? { mode } : {}),
  };
}

/** Save explicit user changes only, never a resume, import or fork. */
export function saveCodexDefaults(agent: AgentBackend, configId: string, options: any[], modeId?: string): void {
  if (!isCodex(agent) || !["model", "reasoning_effort", "mode"].includes(configId)) return;
  const updates: Record<string, string> = {};
  if (configId === "mode") {
    const mode = modeId ?? options.find((o) => o.id === "mode")?.currentValue;
    // The owner persists this per thread. Do not replace the default used by ACP/CLI.
    if (mode === DESKTOP_FULL_ACCESS_ASK) return;
    if (!Object.hasOwn(MODES, mode)) throw new Error("Unsupported Codex permission mode");
    Object.assign(updates, MODES[mode]);
  } else {
    for (const [id, key] of [["model", "model"], ["reasoning_effort", "model_reasoning_effort"]]) {
      const value = options.find((o) => o.id === id)?.currentValue;
      if (typeof value === "string" && value) updates[key] = value;
    }
  }
  try {
    const file = configFile(agent);
    const text = read(file);
    // Newer Codex profiles cannot be combined with legacy sandbox_mode.
    if (updates.sandbox_mode && typeof parse(text, { integersAsBigInt: "asNeeded" }).default_permissions === "string") {
      updates.default_permissions = updates.sandbox_mode === "workspace-write" ? ":workspace" : `:${updates.sandbox_mode}`;
      delete updates.sandbox_mode;
    }
    const updated = patchCodexDefaults(text, updates);
    if (updated !== text) {
      fs.mkdirSync(path.dirname(file), { recursive: true });
      const temporary = `${file}.${process.pid}.tmp`;
      let mode = 0o600;
      try { mode = fs.statSync(file).mode & 0o777; } catch { /* New personal config. */ }
      try {
        fs.writeFileSync(temporary, updated, { mode });
        fs.renameSync(temporary, file);
      } finally { fs.rmSync(temporary, { force: true }); }
    }
  } catch {
    // TOML parser errors include source lines; never return them to clients/logs.
    throw new Error("This chat's setting changed, but its Codex default could not be saved to config.toml");
  }
}
