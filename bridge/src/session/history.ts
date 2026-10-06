import type { LogEntry } from "./types.js";

const DETAIL_THRESHOLD = 4 * 1024;
const INLINE_INPUT_LIMIT = 1024;

function collaboration(update: any): boolean {
  // Match tool identities, never words inside a shell command or its arguments.
  const identity = update._meta?.claudeCode?.toolName ?? update.name ?? update.title ?? "";
  const name = String(identity).split(".").at(-1)!.replace(/[_-]/g, "").toLowerCase();
  return ["spawnagent", "waitagent", "sendinput", "sendmessage", "followuptask", "delegate", "subagent", "task", "agent", "collabagenttoolcall"].includes(name) ||
    !!update.rawInput?.agentsStates || !!update._meta?.claudeCode?.toolResponse?.agentId ||
    !!update.rawInput?.agentThreadId || !!update.rawInput?.subagent_type ||
    update._meta?.claudeCode?.subagent === true || update._meta?.jetbrains?.air?.subagent === true;
}

/** Only transport projections are shortened. The durable log and agent context stay intact. */
export function lazyToolEntry(entry: LogEntry): LogEntry {
  if (entry.kind !== "update" || !["tool_call", "tool_call_update"].includes(entry.update.sessionUpdate)) return entry;
  const u = entry.update as any;
  // Collaboration tools encode child identity/lifecycle in their output. Keep those inline.
  if (collaboration(u)) return entry;
  const bytes = Buffer.byteLength(JSON.stringify(u));
  if (bytes < DETAIL_THRESHOLD) return entry;
  const { content, rawOutput, rawInput, _meta, ...header } = u;
  if (rawInput !== undefined && Buffer.byteLength(JSON.stringify(rawInput)) <= INLINE_INPUT_LIMIT) header.rawInput = rawInput;
  if (typeof header.title === "string" && header.title.length > 256) header.title = header.title.slice(0, 256) + "…";
  const meta = { ..._meta };
  delete meta.terminal_output;
  delete meta.terminal_output_delta;
  if (meta.claudeCode?.toolResponse) {
    meta.claudeCode = { ...meta.claudeCode };
    delete meta.claudeCode.toolResponse;
  }
  const exitCode = rawOutput?.exit_code ?? rawOutput?.exitCode ?? _meta?.terminal_exit?.exit_code;
  const update = { ...header, _meta: { ...meta, codeaw: { ...meta.codeaw, deferredTool: {
    seq: entry.seq, bytes, hasDiff: content?.some((c: any) => c.type === "diff") === true,
    ...(typeof exitCode === "number" ? { exitCode } : {}),
  } } } };
  return { ...entry, update } as LogEntry;
}
