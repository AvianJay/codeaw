import type * as acp from "@agentclientprotocol/sdk";

export type TurnState = "idle" | "running" | "requires_action";

export interface CompletedTurn {
  promptId: string;
  startedAt: number;
  endedAt: number;
}

/** A file an agent put into the chat with the `show_files` tool. */
export interface CardFile {
  /** Resolved absolute path on the bridge computer. */
  path: string;
  name: string;
  size: number;
  mimeType?: string;
  caption?: string;
}

/** Something an agent asked the app to present, through the bridge's own MCP tools. */
export type Card =
  | { kind: "files"; title?: string; files: CardFile[] }
  | { kind: "replies"; replies: string[] }
  | { kind: "notice"; title?: string; message: string; urgent?: boolean };

/** Bridge-synthesized events, sent to clients as `_codeaw/event` (see docs/protocol.md). */
export type CodeawEvent =
  | { type: "card"; cardId: string; card: Card }
  | { type: "state"; state: TurnState; stopReason?: string; queued: number; turnStartedAt?: number; turnPromptId?: string; completedTurn?: CompletedTurn; connection?: "desktop" | "acp"; desktopConnected?: boolean }
  | { type: "permission_request"; requestId: string; toolCall: acp.ToolCallUpdate; options: acp.PermissionOption[] }
  | { type: "permission_resolved"; requestId: string; outcome: acp.RequestPermissionOutcome; optionName?: string; by?: string }
  | { type: "elicitation_request"; requestId: string; request: acp.CreateElicitationRequest }
  | { type: "elicitation_resolved"; requestId: string; action: string; by?: string }
  | { type: "dequeued"; promptId: string; cancelled?: boolean; removed?: boolean }
  | { type: "prompt_receipt"; promptId: string; status: "received" | "read" | "failed" }
  | { type: "error"; message: string; code?: number };

export interface UpdateEntry {
  seq: number;
  t: number;
  kind: "update";
  update: acp.SessionUpdate;
}

export interface EventEntry {
  seq: number;
  t: number;
  kind: "event";
  event: CodeawEvent;
}

export type LogEntry = UpdateEntry | EventEntry;

/** Persisted per-session metadata (`meta.json`). */
export interface SessionMeta {
  id: string;
  agentId: string;
  backendId: string;
  cwd: string;
  /** Uses a bridge-owned per-chat directory instead of a selected project. */
  projectless?: boolean;
  title?: string;
  createdAt: string;
  /** When the log was last written, including reloads; detects sessions continued elsewhere. */
  updatedAt: string;
  /** When the conversation last moved. Reopening, replaying or refreshing a chat keeps it. */
  activityAt?: string;
  /** `bridge` = created through codeaw; `native` = imported from the agent's own history. */
  origin: "bridge" | "native";
  /** Persist desktop affinity so reconnecting never silently creates a second runtime. */
  connection?: "desktop" | "acp";
  /** Changes whenever the log is rebuilt; clients with another epoch need a full replay. */
  epoch: string;
  lastSeq: number;
  /** Last known config state, so a reopened session can show selectors before reactivation. */
  configOptions?: acp.SessionConfigOption[] | null;
  modes?: acp.SessionModeState | null;
  /** Created by editing `messageId` of another chat; `promptId` deduplicates retried edits. */
  forkedFrom?: { sessionId: string; messageId: string; promptId: string };
  /** A provider quota error stopped this prompt; bridge can continue it after recovery. */
  quotaBlocked?: { provider: string; promptId: string; at: number };
  /** Files the agent showed in this chat; paired devices may read them outside the workspaces. */
  shared?: string[];
}

export function isChunk(u: acp.SessionUpdate): u is Extract<acp.SessionUpdate, { sessionUpdate: "user_message_chunk" | "agent_message_chunk" | "agent_thought_chunk" }> {
  return u.sessionUpdate === "user_message_chunk" || u.sessionUpdate === "agent_message_chunk" || u.sessionUpdate === "agent_thought_chunk";
}

const ACTIVITY_UPDATES = new Set(["user_message_chunk", "agent_message_chunk", "agent_thought_chunk", "tool_call", "tool_call_update", "plan"]);
const ACTIVITY_EVENTS = new Set(["permission_request", "elicitation_request", "error", "card"]);

/** True for entries that are the conversation itself rather than bookkeeping written when a chat is reopened. */
export function isActivity(entry: { kind: "update"; update: { sessionUpdate: string } } | { kind: "event"; event: { type: string } }): boolean {
  return entry.kind === "update" ? ACTIVITY_UPDATES.has(entry.update.sessionUpdate) : ACTIVITY_EVENTS.has(entry.event.type);
}

/** Identifies an advisory notice by what it says; agents repeat the same ones on every resume. */
export function noticeKey(update: { severity?: unknown; title?: unknown; description?: unknown }): string {
  return JSON.stringify([update.severity ?? null, update.title ?? null, update.description ?? null]);
}

export function codeawMeta(obj: { _meta?: Record<string, unknown> | null } | undefined): Record<string, any> {
  const m = obj?._meta?.codeaw;
  return m && typeof m === "object" ? (m as Record<string, any>) : {};
}

/** Returns a copy of `obj` whose `_meta.codeaw` is shallow-merged with `patch`. */
export function withCodeawMeta<T extends { _meta?: Record<string, unknown> | null }>(obj: T, patch: Record<string, unknown>): T {
  const meta = { ...(obj._meta ?? {}) };
  meta.codeaw = { ...codeawMeta(obj), ...patch };
  return { ...obj, _meta: meta };
}
