import path from "node:path";
import type * as acp from "@agentclientprotocol/sdk";
import { desktopQuestionReplies } from "./codex-desktop-questions.js";

export interface DesktopRecord { key: string; update: acp.SessionUpdate }
export interface DesktopState {
  connection: "desktop";
  connected: boolean;
  state: "idle" | "running" | "requires_action";
  turnId?: string;
  startedAt?: number;
  title?: string;
  cwd?: string;
  completedTurnId?: string;
  stopReason?: acp.StopReason;
}

export function desktopRequests(conversation: any): any[] {
  const methods = new Set(["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval", "item/tool/requestUserInput", "mcpServer/elicitation/request", "item/plan/requestImplementation", "item/tool/requestOptionPicker"]);
  return [...(conversation?.requests ?? []), ...(conversation?.pendingRequests ?? []), ...(conversation?.externalRequests ?? [])].filter((request: any) => methods.has(request.method) && request.completed !== true && request.completedAtMs == null);
}

/** Desktop sends Immer patches with array paths, not JSON-RPC notifications. */
export function applyDesktopPatches(state: any, patches: unknown): any {
  if (!Array.isArray(patches)) throw new Error("Invalid desktop state patches");
  let next = structuredClone(state);
  for (const patch of patches) {
    if (!patch || !["add", "replace", "remove"].includes(patch.op) || !Array.isArray(patch.path) || patch.path.length > 64) throw new Error("Unsupported desktop state patch");
    if (patch.path.some((key: unknown) => (typeof key !== "string" && typeof key !== "number") || ["__proto__", "constructor", "prototype"].includes(String(key)))) throw new Error("Unsafe desktop state patch");
    if (patch.path.length === 0) {
      if (patch.op === "remove") throw new Error("Cannot remove desktop state");
      next = structuredClone(patch.value);
      continue;
    }
    let parent = next;
    for (const key of patch.path.slice(0, -1)) {
      if (parent === null || typeof parent !== "object" || !Object.hasOwn(parent, key)) throw new Error("Desktop state patch path is missing");
      parent = parent[key];
    }
    if (parent === null || typeof parent !== "object") throw new Error("Invalid desktop state patch parent");
    const key = patch.path.at(-1);
    if (Array.isArray(parent)) {
      const index = key === "-" ? parent.length : Number(key);
      if (!Number.isSafeInteger(index) || index < 0 || index > parent.length || (patch.op !== "add" && index === parent.length)) throw new Error("Invalid desktop array index");
      if (patch.op === "add") parent.splice(index, 0, structuredClone(patch.value));
      else if (patch.op === "remove") parent.splice(index, 1);
      else parent[index] = structuredClone(patch.value);
    } else if (patch.op === "remove") {
      delete parent[key];
    } else {
      if (patch.op === "replace" && !Object.hasOwn(parent, key)) throw new Error("Desktop state patch field is missing");
      parent[key] = structuredClone(patch.value);
    }
  }
  return next;
}

export function desktopTurns(conversation: any): any[] {
  const history = conversation?.turnHistory?.kind === "canonical" ? conversation.turnHistory.history : undefined;
  const stored = history?.islands?.flatMap((island: any) => (island.entries ?? []).map((entry: any) => history.entitiesByKey?.[entry.value]).filter(Boolean)) ?? [];
  const turns: any[] = [];
  const indexes = new Map<string, number>();
  for (const turn of [...stored, ...(conversation?.turns ?? [])]) {
    if (!turn || typeof turn !== "object") continue;
    const id = turn.turnId ?? turn.id ?? turn.params?.clientUserMessageId;
    if (typeof id === "string" && indexes.has(id)) turns[indexes.get(id)!] = turn;
    else { if (typeof id === "string") indexes.set(id, turns.length); turns.push(turn); }
  }
  return turns;
}

function textOf(value: any): string {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value.map(textOf).filter(Boolean).join("\n");
  if (value && typeof value.text === "string") return value.text;
  return "";
}

export function inputBlocks(input: any): acp.ContentBlock[] {
  const replies = desktopQuestionReplies(input);
  if (replies.length) return [{ type: "text", text: replies.map((reply) => reply.answer || "（略過問題）").join("\n") }];
  if (typeof input === "string") return [{ type: "text", text: input }];
  if (!Array.isArray(input)) return [];
  const blocks: acp.ContentBlock[] = [];
  for (const item of input) {
    if (item?.type === "text" && typeof item.text === "string") blocks.push({ type: "text", text: item.text });
    else if (item?.type === "image" && typeof item.url === "string") {
      const data = item.url.match(/^data:([^;,]+);base64,(.*)$/s);
      if (data) blocks.push({ type: "image", mimeType: data[1], data: data[2] });
      else blocks.push({ type: "resource_link", uri: item.url, name: "圖片" });
    } else if (item?.type === "localImage" && typeof item.path === "string") blocks.push({ type: "resource_link", uri: `file://${item.path.replace(/\\/g, "/")}`, name: path.basename(item.path) });
  }
  return blocks;
}

export function codexInput(blocks: acp.ContentBlock[]): any[] {
  return blocks.map((block) => {
    if (block.type === "text") return { type: "text", text: block.text, text_elements: [] };
    if (block.type === "image") {
      const url = block.data ? `data:${block.mimeType};base64,${block.data}` : block.uri;
      if (!url) throw new Error("This image has no data or URL");
      return { type: "image", url };
    }
    if (block.type === "resource" && "text" in block.resource) return { type: "text", text: `${block.resource.uri}\n${block.resource.text}`, text_elements: [] };
    if (block.type === "resource_link") return { type: "text", text: `${block.name}\n${block.uri}`, text_elements: [] };
    throw new Error(`Codex desktop does not support ${block.type} input`);
  });
}

function toolStatus(item: any, turn: any): acp.ToolCallStatus {
  const status = item.status ?? turn.status;
  if (["failed", "error", "declined"].includes(status)) return "failed";
  if (["completed", "interrupted", "cancelled"].includes(status)) return "completed";
  if (["pending", "requiresApproval"].includes(status)) return "pending";
  return "in_progress";
}

export function projectDesktopConversation(conversation: any, messagePromptIds: ReadonlyMap<string, string> = new Map()): { records: DesktopRecord[]; state: DesktopState; turns: any[] } {
  const turns = desktopTurns(conversation);
  const records: DesktopRecord[] = [];
  function message(key: string, type: "user_message_chunk" | "agent_message_chunk" | "agent_thought_chunk", blocks: acp.ContentBlock[], promptId?: string, steered = false) {
    blocks.forEach((content, index) => records.push({ key: `${key}:${index}`, update: { sessionUpdate: type, messageId: key, content,
      ...(type === "user_message_chunk" ? { _meta: { codeaw: { receipt: "read", ...(steered ? { steered: true } : {}), ...(promptId ? { promptId, replace: true, partIndex: index } : {}) } } } : {}),
    } as acp.SessionUpdate }));
  }
  turns.forEach((turn, index) => {
    const id = String(turn.turnId ?? turn.id ?? turn.params?.clientUserMessageId ?? `turn-${index}`);
    const input = inputBlocks(turn.params?.input ?? turn.input);
    if (input.length) message(`${id}:user`, "user_message_chunk", input, turn.params?.clientUserMessageId);
    (turn.items ?? []).forEach((item: any, itemIndex: number) => {
      const key = `${id}:${item.id ?? item.itemId ?? `${item.type}-${itemIndex}`}`;
      if (item.type === "userMessage") {
        if (!input.length) message(`${id}:user`, "user_message_chunk", inputBlocks(item.content ?? item.input), turn.params?.clientUserMessageId);
      } else if (item.type === "steeringUserMessage") {
        message(key, "user_message_chunk", inputBlocks(item.input ?? item.content ?? item.text),
          item.clientUserMessageId ?? item.serverClientUserMessageId ?? item.restoreMessage?.id ?? messagePromptIds.get(key), true);
      } else if (item.type === "agentMessage") {
        const text = textOf(item.text ?? item.content);
        if (text) message(key, "agent_message_chunk", [{ type: "text", text }]);
      } else if (item.type === "reasoning") {
        const text = textOf(item.summary ?? item.text ?? item.content);
        if (text) message(key, "agent_thought_chunk", [{ type: "text", text }]);
      } else if (["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "webSearch", "collabAgentToolCall"].includes(item.type)) {
        const command = Array.isArray(item.command) ? item.command.join(" ") : item.command;
        const changes = Array.isArray(item.changes) ? item.changes : [];
        const output = textOf(item.aggregatedOutput ?? item.output ?? item.result?.content);
        const content: acp.ToolCallContent[] = [];
        if (output) content.push({ type: "content", content: { type: "text", text: output } });
        for (const change of changes) {
          if (typeof change.diff === "string") content.push({ type: "content", content: { type: "text", text: change.diff } });
        }
        const kind: acp.ToolKind = item.type === "commandExecution" ? "execute" : item.type === "fileChange" ? "edit" : item.type === "webSearch" ? "search" : "other";
        // Same shape as codex-acp, so clients can tell the server from the tool.
        const mcp = item.type === "mcpToolCall" && typeof item.server === "string" && typeof item.tool === "string";
        records.push({ key, update: {
          sessionUpdate: "tool_call", toolCallId: key,
          title: mcp ? `mcp.${item.server}.${item.tool}` : command ?? item.title ?? item.tool ?? item.query ?? (item.type === "fileChange" ? "檔案變更" : item.type),
          kind, status: toolStatus(item, turn), content,
          locations: changes.filter((change: any) => typeof change.path === "string").map((change: any) => ({ path: change.path })),
          rawInput: mcp ? { server: item.server, tool: item.tool, arguments: item.arguments ?? {} } : item.arguments ?? (command ? { command, cwd: item.cwd ?? conversation.cwd } : item.input ?? {}),
          rawOutput: item.result ?? (output ? { output, exitCode: item.exitCode } : undefined),
        } as acp.SessionUpdate });
      }
    });
  });
  const last = turns.at(-1);
  const active = turns.findLast((turn) => ["inProgress", "in_progress", "running", "requires_action"].includes(turn.status));
  const requests = desktopRequests(conversation);
  const startedAt = Number(active?.turnStartedAtMs ?? active?.startedAt);
  const state: DesktopState = {
    connection: "desktop", connected: true,
    state: requests.length || active?.status === "requires_action" ? "requires_action" : active ? "running" : "idle",
    turnId: active?.turnId ?? active?.id,
    ...(Number.isFinite(startedAt) ? { startedAt } : {}),
    title: conversation.title ?? undefined, cwd: conversation.cwd ?? undefined,
    ...(!active && last ? { completedTurnId: last.turnId ?? last.id, stopReason: ["interrupted", "cancelled"].includes(last.status) ? "cancelled" : "end_turn" } : {}),
  };
  return { records, state, turns };
}

/** Emit only appended text / changed tools; rebuild when a historical message was edited. */
export function desktopRecordChanges(previous: DesktopRecord[] | undefined, next: DesktopRecord[]): { reset: boolean; updates: acp.SessionUpdate[] } {
  if (!previous) return { reset: true, updates: next.map((record) => record.update) };
  const old = new Map(previous.map((record) => [record.key, record.update]));
  const newKeys = new Set(next.map((record) => record.key));
  if (previous.some((record) => !newKeys.has(record.key)) || previous.some((record, index) => next[index]?.key !== record.key)) return { reset: true, updates: next.map((record) => record.update) };
  const updates: acp.SessionUpdate[] = [];
  for (const record of next) {
    const before = old.get(record.key) as any;
    const after = record.update as any;
    if (!before) { updates.push(record.update); continue; }
    if (JSON.stringify(before) === JSON.stringify(after)) continue;
    // User replacements contain the whole input, not a streamed suffix.
    if (after.sessionUpdate === "user_message_chunk") return { reset: true, updates: next.map((item) => item.update) };
    if (after.sessionUpdate.endsWith("_chunk") && after.content.type === "text" && before.content.type === "text" && after.content.text.startsWith(before.content.text)) {
      const text = after.content.text.slice(before.content.text.length);
      if (text) updates.push({ ...after, content: { type: "text", text } });
    } else if (after.sessionUpdate === "tool_call") {
      updates.push({ ...after, sessionUpdate: "tool_call_update" });
    } else return { reset: true, updates: next.map((item) => item.update) };
  }
  return { reset: false, updates };
}
