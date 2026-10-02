/**
 * Folding of `tool_call` / `tool_call_update` into one tool-call state.
 * The app's timeline reducer implements exactly the same rules (app/lib/data/timeline.dart),
 * which is what makes a compacted replay equivalent to the raw log.
 *
 * Rules:
 * - scalar fields (title, kind, status, name, rawInput, rawOutput) replace when present and not null
 * - `content` replaces when present, except that diff items seen earlier survive when the new
 *   content carries no diff (Kimi overwrites the diff with plain output)
 * - `locations` replace when present
 * - `_meta.terminal_output.data` and `_meta.terminal_output_delta.data` APPEND to the accumulated
 *   terminal output; `terminal_info` / `terminal_exit` replace; `claudeCode` merges shallowly;
 *   any other `_meta` key replaces
 */

export interface ToolCallState {
  toolCallId: string;
  title?: string;
  kind?: string;
  status?: string;
  name?: string;
  content?: any[];
  locations?: any[];
  rawInput?: unknown;
  rawOutput?: unknown;
  terminalOutput: string;
  terminalId?: string;
  meta: Record<string, any>;
}

export function emptyToolCall(toolCallId: string): ToolCallState {
  return { toolCallId, terminalOutput: "", meta: {} };
}

const SCALARS = ["title", "kind", "status", "name", "rawInput", "rawOutput"] as const;

export function mergeToolCall(state: ToolCallState, update: Record<string, any>): ToolCallState {
  const next: ToolCallState = { ...state, meta: { ...state.meta } };
  for (const key of SCALARS) {
    const v = update[key];
    if (v !== undefined && v !== null) (next as any)[key] = v;
  }
  if (Array.isArray(update.content)) {
    const incoming = update.content as any[];
    const oldDiffs = (state.content ?? []).filter((c) => c?.type === "diff");
    const hasDiff = incoming.some((c) => c?.type === "diff");
    next.content = !hasDiff && oldDiffs.length > 0 ? [...oldDiffs, ...incoming] : incoming;
  }
  if (Array.isArray(update.locations)) next.locations = update.locations;

  const meta = update._meta;
  if (meta && typeof meta === "object") {
    for (const [key, value] of Object.entries(meta as Record<string, any>)) {
      if (key === "terminal_output" || key === "terminal_output_delta") {
        if (value && typeof value.data === "string") next.terminalOutput += value.data;
        if (value?.terminal_id) next.terminalId = value.terminal_id;
      } else if (key === "terminal_info") {
        next.meta.terminal_info = value;
        if (value?.terminal_id) next.terminalId = value.terminal_id;
      } else if (key === "claudeCode" && value && typeof value === "object") {
        next.meta.claudeCode = { ...(next.meta.claudeCode ?? {}), ...value };
      } else if (key !== "codeaw") {
        next.meta[key] = value;
      }
    }
  }
  return next;
}

/** Serializes a folded state back into a single `tool_call` session update. */
export function toolCallToUpdate(state: ToolCallState): Record<string, any> {
  const meta: Record<string, any> = { ...state.meta };
  if (state.terminalOutput || state.terminalId) {
    meta.terminal_output = { terminal_id: state.terminalId ?? state.toolCallId, data: state.terminalOutput };
  }
  const update: Record<string, any> = {
    sessionUpdate: "tool_call",
    toolCallId: state.toolCallId,
    title: state.title ?? "",
  };
  for (const key of ["kind", "status", "name", "rawInput", "rawOutput", "content", "locations"] as const) {
    if (state[key] !== undefined) update[key] = state[key];
  }
  if (Object.keys(meta).length > 0) update._meta = meta;
  return update;
}
