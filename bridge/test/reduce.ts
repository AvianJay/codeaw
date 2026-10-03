/**
 * Reference implementation of the app's timeline reducer (app/lib/data/timeline.dart).
 * Used to prove that a compacted replay reduces to the same timeline as the raw log.
 */
import { emptyToolCall, mergeToolCall, type ToolCallState } from "../src/session/toolcall.js";
import { parentToolCallId } from "../src/session/subagent.js";

export interface Timeline {
  items: any[];
  plan?: unknown;
  commands?: unknown;
  modeId?: unknown;
  configOptions?: unknown;
  usage?: unknown;
  info: Record<string, unknown>;
  state?: string;
}

export function reduce(messages: { method: string; params: any }[]): Timeline {
  const t: Timeline = { items: [], info: {} };
  const byKey = new Map<string, any>();
  const upsert = (key: string, make: () => any) => {
    let item = byKey.get(key);
    if (!item) {
      item = make();
      byKey.set(key, item);
      t.items.push(item);
    }
    return item;
  };
  for (const { method, params } of messages) {
    if (method === "session/update") {
      const u = params.update;
      switch (u.sessionUpdate) {
        case "user_message_chunk":
        case "agent_message_chunk":
        case "agent_thought_chunk": {
          const mid = u._meta?.codeaw?.mid;
          const parent = parentToolCallId(u);
          const item = upsert(JSON.stringify([u.sessionUpdate, parent, mid]), () => ({ kind: u.sessionUpdate, mid, ...(parent ? { parent } : {}), parts: [] as any[] }));
          const last = item.parts[item.parts.length - 1];
          if (u.content?.type === "text" && last?.type === "text") last.text += u.content.text;
          else item.parts.push({ ...u.content });
          break;
        }
        case "tool_call":
        case "tool_call_update": {
          const item = upsert(`tool:${u.toolCallId}`, () => ({ kind: "tool", state: emptyToolCall(u.toolCallId) }));
          item.state = mergeToolCall(item.state as ToolCallState, u);
          break;
        }
        case "plan":
          t.plan = u.entries;
          break;
        case "available_commands_update":
          t.commands = u.availableCommands;
          break;
        case "current_mode_update":
          t.modeId = u.currentModeId;
          break;
        case "config_option_update":
          t.configOptions = u.configOptions;
          break;
        case "usage_update":
          t.usage = { used: u.used, size: u.size, cost: u.cost };
          break;
        case "session_info_update":
          if (u.title !== undefined) t.info.title = u.title;
          if (u.updatedAt !== undefined) t.info.updatedAt = u.updatedAt;
          break;
        case "notice":
          t.items.push({ kind: "notice", notice: u });
          break;
      }
    } else if (method === "_codeaw/event") {
      const e = params.event;
      switch (e.type) {
        case "state":
          t.state = e.state;
          if (e.state === "idle" && e.stopReason && e.stopReason !== "end_turn") t.items.push({ kind: "stop", stopReason: e.stopReason });
          if (e.state === "idle" && e.completedTurn) t.items.push({ kind: "turn", ...e.completedTurn });
          break;
        case "permission_request":
          upsert(`perm:${e.requestId}`, () => ({ kind: "permission", requestId: e.requestId })).request = e;
          break;
        case "permission_resolved":
          upsert(`perm:${e.requestId}`, () => ({ kind: "permission", requestId: e.requestId })).resolved = e;
          break;
        case "elicitation_request":
          upsert(`elicit:${e.requestId}`, () => ({ kind: "elicitation", requestId: e.requestId })).request = e;
          break;
        case "elicitation_resolved":
          upsert(`elicit:${e.requestId}`, () => ({ kind: "elicitation", requestId: e.requestId })).resolved = e;
          break;
        case "error":
          t.items.push({ kind: "error", message: e.message });
          break;
        case "dequeued":
          for (const item of t.items) if (item.kind === "user_message_chunk" && item.mid === `u-${e.promptId}`) item.dequeued = e.cancelled ? "cancelled" : "started";
          break;
      }
    }
  }
  return t;
}
