import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { isDeepStrictEqual } from "node:util";
import { parse, stringify } from "smol-toml";
import type { AgentBackend } from "./backend.js";
import { expandHome } from "../util/paths.js";

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

/** Called only for new chats; existing chats restore their own saved settings. */
export function codexDefaults(agent: AgentBackend): Record<string, string> {
  if (!isCodex(agent)) return {};
  try {
    const config = parse(read(configFile(agent)), { integersAsBigInt: "asNeeded" });
    const sandbox = config.default_permissions === ":danger-full-access" ? "danger-full-access"
      : config.default_permissions === ":read-only" ? "read-only"
      : config.default_permissions === ":workspace" ? "workspace-write" : config.sandbox_mode;
    const mode = sandbox === "danger-full-access" ? "agent-full-access"
      : sandbox === "read-only" ? "read-only"
      : sandbox === "workspace-write" ? (config.approvals_reviewer === "auto_review" || config.approvals_reviewer === "guardian_subagent" ? "agent" : "workspace-write") : undefined;
    return {
      ...(typeof config.model === "string" ? { model: config.model } : {}),
      ...(typeof config.model_reasoning_effort === "string" ? { reasoning_effort: config.model_reasoning_effort } : {}),
      ...(mode ? { mode } : {}),
    };
  } catch { throw new Error("Could not read Codex defaults from config.toml"); }
}

/** Save explicit user changes only, never a resume, import or fork. */
export function saveCodexDefaults(agent: AgentBackend, configId: string, options: any[], modeId?: string): void {
  if (!isCodex(agent) || !["model", "reasoning_effort", "mode"].includes(configId)) return;
  const updates: Record<string, string> = {};
  if (configId === "mode") {
    const mode = modeId ?? options.find((o) => o.id === "mode")?.currentValue;
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
