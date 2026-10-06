import type { LogEntry } from "./types.js";

const DETAIL_THRESHOLD = 16 * 1024;

/** Only transport projections are shortened. The durable log and agent context stay intact. */
export function lazyToolEntry(entry: LogEntry): LogEntry {
  if (entry.kind !== "update" || !["tool_call", "tool_call_update"].includes(entry.update.sessionUpdate)) return entry;
  const u = entry.update as any;
  // Collaboration tools encode child identity/lifecycle in their output. Keep those inline.
  if (/spawn|wait_agent|send_input|delegate|subagent|\btask\b|\bagent\b/i.test(`${u.name ?? ""} ${u.title ?? ""}`) ||
      u.rawInput?.agentsStates || u._meta?.claudeCode?.toolResponse?.agentId) return entry;
  const terminal = u._meta?.terminal_output ?? u._meta?.terminal_output_delta;
  const bytes = Buffer.byteLength(JSON.stringify([u.content, u.rawOutput, terminal?.data]));
  if (bytes < DETAIL_THRESHOLD) return entry;
  const { content, rawOutput, _meta, ...header } = u;
  const meta = { ..._meta };
  delete meta.terminal_output;
  delete meta.terminal_output_delta;
  const exitCode = rawOutput?.exit_code ?? _meta?.terminal_exit?.exit_code;
  const update = { ...header, _meta: { ...meta, codeaw: { ...meta.codeaw, deferredTool: {
    seq: entry.seq, bytes, hasDiff: content?.some((c: any) => c.type === "diff") === true,
    ...(typeof exitCode === "number" ? { exitCode } : {}),
  } } } };
  return { ...entry, update } as LogEntry;
}
