import type * as acp from "@agentclientprotocol/sdk";

export type TurnState = "idle" | "running" | "requires_action";

export interface CompletedTurn {
  promptId: string;
  startedAt: number;
  endedAt: number;
}

/** Bridge-synthesized events, sent to clients as `_codeaw/event` (see docs/protocol.md). */
export type CodeawEvent =
  | { type: "state"; state: TurnState; stopReason?: string; queued: number; turnStartedAt?: number; turnPromptId?: string; completedTurn?: CompletedTurn; connection?: "desktop" | "acp"; desktopConnected?: boolean }
  | { type: "permission_request"; requestId: string; toolCall: acp.ToolCallUpdate; options: acp.PermissionOption[] }
  | { type: "permission_resolved"; requestId: string; outcome: acp.RequestPermissionOutcome; optionName?: string; by?: string }
  | { type: "elicitation_request"; requestId: string; request: acp.CreateElicitationRequest }
  | { type: "elicitation_resolved"; requestId: string; action: string; by?: string }
  | { type: "dequeued"; promptId: string; cancelled?: boolean }
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
  title?: string;
  createdAt: string;
  updatedAt: string;
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
}

export function isChunk(u: acp.SessionUpdate): u is Extract<acp.SessionUpdate, { sessionUpdate: "user_message_chunk" | "agent_message_chunk" | "agent_thought_chunk" }> {
  return u.sessionUpdate === "user_message_chunk" || u.sessionUpdate === "agent_message_chunk" || u.sessionUpdate === "agent_thought_chunk";
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
