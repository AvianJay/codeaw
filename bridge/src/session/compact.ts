import type { LogEntry, UpdateEntry } from "./types.js";
import { codeawMeta, isChunk } from "./types.js";
import { parentToolCallId } from "./subagent.js";
import { emptyToolCall, mergeToolCall, toolCallToUpdate, type ToolCallState } from "./toolcall.js";

/** Snapshot-type updates: only the latest one matters. */
const KEEP_LAST = new Set(["plan", "available_commands_update", "current_mode_update", "config_option_update", "usage_update"]);

type Slot =
  | { kind: "entry"; entry: LogEntry }
  | { kind: "message"; seq: number; t: number; at: number; first: any; parts: any[] }
  | { kind: "tool"; seq: number; t: number; at: number; state: ToolCallState; agentStatesSeq?: number; statusSeq?: number; lifecycleSeq?: number }
  | { kind: "info"; seq: number; t: number; at: number; update: Record<string, any> };

/** One compacted item and the seq where it first appeared, which orders pages stably within an epoch. */
export interface CompactGroup {
  first: number;
  entries: LogEntry[];
}

/**
 * Produces a shorter log whose reduction (see toolcall.ts / the app reducer) equals the
 * reduction of the full log:
 * - chunks of one message (same type + `_meta.codeaw.mid`) become as few chunks as possible,
 *   placed where the message first appeared
 * - a tool call and all its updates become one `tool_call` at its first position
 * - snapshot updates keep only their last occurrence; `session_info_update`s merge into one
 * - `state` events keep turn boundaries and the last state, so clients retain turn footers
 * Output entries keep the highest `seq` they absorbed, so seqs are not monotonic.
 */
export function compactLog(entries: LogEntry[]): LogEntry[] {
  return compactGroups(entries).flatMap((g) => g.entries);
}

export function compactGroups(entries: LogEntry[]): CompactGroup[] {
  const lastIndex = new Map<string, number>();
  let lastState = -1;
  entries.forEach((e, i) => {
    if (e.kind === "update" && KEEP_LAST.has(e.update.sessionUpdate)) lastIndex.set(e.update.sessionUpdate, i);
    if (e.kind === "event" && e.event.type === "state") lastState = i;
  });

  const slots: Slot[] = [];
  const messages = new Map<string, Extract<Slot, { kind: "message" }>>();
  const tools = new Map<string, Extract<Slot, { kind: "tool" }>>();
  let info: Extract<Slot, { kind: "info" }> | undefined;
  let inTurn = false;
  let turnStartedAt: number | undefined;

  entries.forEach((e, i) => {
    if (e.kind === "event") {
      if (e.event.type === "state") {
        const active = e.event.state !== "idle";
        const start = active && (!inTurn || (e.event.turnStartedAt !== undefined && e.event.turnStartedAt !== turnStartedAt));
        const end = !active && (e.event.stopReason || e.event.completedTurn);
        inTurn = active;
        if (active) turnStartedAt = e.event.turnStartedAt;
        if (i !== lastState && !start && !end) return;
      }
      slots.push({ kind: "entry", entry: e });
      return;
    }
    const u = e.update as any;
    if (isChunk(e.update)) {
      const mid = codeawMeta(u).mid ?? `seq${e.seq}`;
      const key = JSON.stringify([u.sessionUpdate, parentToolCallId(u), mid]);
      let slot = messages.get(key);
      if (!slot) {
        slot = { kind: "message", seq: e.seq, t: e.t, at: e.seq, first: u, parts: [] };
        messages.set(key, slot);
        slots.push(slot);
      }
      slot.seq = Math.max(slot.seq, e.seq);
      if (u.sessionUpdate === "user_message_chunk") {
        const previous = codeawMeta(slot.first), current = codeawMeta(u);
        if (current.replace === true && current.partIndex === 0) slot.parts = [];
        slot.first = { ...slot.first, _meta: { ...slot.first._meta, ...u._meta, codeaw: {
          ...previous, ...current,
          ...(previous.receipt === "read" ? { receipt: "read" } : {}),
        } } };
      }
      const last = slot.parts[slot.parts.length - 1];
      if (u.content?.type === "text" && last?.type === "text") {
        slot.parts[slot.parts.length - 1] = { ...last, text: last.text + u.content.text };
      } else {
        slot.parts.push(u.content);
      }
      return;
    }
    if (u.sessionUpdate === "tool_call" || u.sessionUpdate === "tool_call_update") {
      let slot = tools.get(u.toolCallId);
      if (!slot) {
        slot = { kind: "tool", seq: e.seq, t: e.t, at: e.seq, state: emptyToolCall(u.toolCallId) };
        tools.set(u.toolCallId, slot);
        slots.push(slot);
      }
      slot.seq = Math.max(slot.seq, e.seq);
      if ((u.rawInput?.agentsStates && typeof u.rawInput.agentsStates === "object") ||
        (u.rawInput?.agentThreadId && u.rawInput?.agentPath && ["started", "completed", "interrupted"].includes(u.rawInput.activityKind))) {
        slot.agentStatesSeq = codeawMeta(u).agentStatesSeq ?? e.seq;
      }
      if (typeof u.status === "string") slot.statusSeq = codeawMeta(u).toolStatusSeq ?? e.seq;
      const response = u._meta?.claudeCode?.toolResponse;
      if (typeof response?.status === "string" || response?.isAsync === true || typeof u.rawOutput?.status === "string") {
        slot.lifecycleSeq = codeawMeta(u).toolLifecycleSeq ?? e.seq;
      }
      slot.state = mergeToolCall(slot.state, u);
      return;
    }
    if (u.sessionUpdate === "session_info_update") {
      const merged = { ...(info?.update ?? {}), ...u, _meta: { ...(info?.update._meta ?? {}), ...(u._meta ?? {}) } };
      if (info) slots.splice(slots.indexOf(info), 1);
      info = { kind: "info", seq: e.seq, t: e.t, at: e.seq, update: merged };
      slots.push(info);
      return;
    }
    if (KEEP_LAST.has(u.sessionUpdate) && lastIndex.get(u.sessionUpdate) !== i) return;
    slots.push({ kind: "entry", entry: e });
  });

  const out: CompactGroup[] = [];
  for (const slot of slots) {
    switch (slot.kind) {
      case "entry":
        out.push({ first: slot.entry.seq, entries: [slot.entry] });
        break;
      case "message": {
        const entries: LogEntry[] = [];
        for (const [partIndex, part] of slot.parts.entries()) {
          const meta = codeawMeta(slot.first);
          const update = { ...slot.first, content: part,
            ...(meta.replace === true ? { _meta: { ...slot.first._meta, codeaw: { ...meta, partIndex } } } : {}),
          };
          entries.push({ seq: slot.seq, t: slot.t, kind: "update", update } as UpdateEntry);
        }
        out.push({ first: slot.at, entries });
        break;
      }
      case "tool": {
        const update = toolCallToUpdate(slot.state);
        // A later title/status update must not make an old child-state snapshot
        // override a newer report from a different collaboration tool on replay.
        if (slot.agentStatesSeq !== undefined || slot.statusSeq !== undefined || slot.lifecycleSeq !== undefined) {
          update._meta = { ...update._meta, codeaw: {
            ...(slot.agentStatesSeq !== undefined ? { agentStatesSeq: slot.agentStatesSeq } : {}),
            ...(slot.statusSeq !== undefined ? { toolStatusSeq: slot.statusSeq } : {}),
            ...(slot.lifecycleSeq !== undefined ? { toolLifecycleSeq: slot.lifecycleSeq } : {}),
          } };
        }
        out.push({ first: slot.at, entries: [{ seq: slot.seq, t: slot.t, kind: "update", update } as UpdateEntry] });
        break;
      }
      case "info":
        out.push({ first: slot.at, entries: [{ seq: slot.seq, t: slot.t, kind: "update", update: slot.update } as UpdateEntry] });
        break;
    }
  }
  return out;
}
