import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import zlib from "node:zlib";
import type * as acp from "@agentclientprotocol/sdk";
import type { DesktopRecord } from "./codex-desktop-state.js";

/**
 * Codex Desktop shares only a parent thread's own turns with followers: a
 * spawned agent's messages, commands and edits live in that child's rollout
 * file. Reading it shows what the child is doing under its delegation card.
 */
export interface ChildTranscript {
  nickname?: string;
  role?: string;
  /** From the child's own turn events; a parent's wait/close report may arrive much later. */
  state?: "running" | "completed" | "interrupted";
  lastMessage?: string;
  /** Completed items in order, without attribution to a parent tool call. */
  items: { id: string; update: Record<string, any> }[];
}

const ROLLOUT = /^rollout-.*-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl(\.zst)?$/i;
const MAX_FILE_BYTES = 64 * 1024 * 1024;
const MAX_ITEMS = 600;
const MAX_TEXT = 16000;

function clip(text: string): string {
  return text.length > MAX_TEXT ? `${text.slice(0, MAX_TEXT)}\n…` : text;
}

function texts(value: unknown): string {
  if (typeof value === "string") return value;
  if (!Array.isArray(value)) return "";
  return value.map((part: any) => (typeof part === "string" ? part : typeof part?.text === "string" ? part.text : "")).filter(Boolean).join("\n");
}

/** One completed rollout item as the ACP update a client already knows how to show. */
export function childItemUpdate(threadId: string, item: any): { id: string; update: Record<string, any> } | undefined {
  if (!item || typeof item !== "object" || typeof item.id !== "string" || !item.id) return undefined;
  const id = `child:${threadId}:${item.id}`;
  const type = String(item.type ?? "").toLowerCase();
  if (type === "agentmessage") {
    const text = texts(item.content ?? item.text);
    return text ? { id, update: { sessionUpdate: "agent_message_chunk", messageId: id, content: { type: "text", text } } } : undefined;
  }
  if (type === "reasoning") {
    const text = texts(item.summary_text ?? item.summary);
    return text ? { id, update: { sessionUpdate: "agent_thought_chunk", messageId: id, content: { type: "text", text } } } : undefined;
  }
  const failed = ["failed", "error", "declined"].includes(item.status) || (typeof item.exit_code === "number" && item.exit_code !== 0);
  const tool = (fields: Record<string, any>) => ({ id, update: { sessionUpdate: "tool_call", toolCallId: id, status: failed ? "failed" : "completed", ...fields } });
  const output = (text: unknown): acp.ToolCallContent[] => (typeof text === "string" && text ? [{ type: "content", content: { type: "text", text: clip(text) } }] : []);
  if (type === "commandexecution") {
    const parsed = Array.isArray(item.parsed_cmd) ? item.parsed_cmd.map((part: any) => part?.cmd).filter((cmd: unknown) => typeof cmd === "string").join("; ") : "";
    const command = parsed || (Array.isArray(item.command) ? item.command.join(" ") : String(item.command ?? "command"));
    return tool({ title: command, kind: "execute", content: output(item.aggregated_output), rawInput: { command }, rawOutput: { exitCode: item.exit_code } });
  }
  if (type === "filechange") {
    const paths = item.changes && typeof item.changes === "object" ? Object.keys(item.changes) : [];
    return tool({ title: paths.length === 1 ? path.basename(paths[0]) : "檔案變更", kind: "edit", content: output(item.stdout), locations: paths.map((file) => ({ path: file })), rawInput: {} });
  }
  if (type === "websearch") {
    return tool({ title: typeof item.query === "string" && item.query ? item.query : "網路搜尋", kind: "search", content: [], rawInput: { query: item.query } });
  }
  if (type === "mcptoolcall" || type === "dynamictoolcall") {
    const title = typeof item.server === "string" && typeof item.tool === "string" ? `mcp.${item.server}.${item.tool}` : String(item.tool ?? item.name ?? item.type);
    return tool({ title, kind: "other", content: output(texts(item.result?.content ?? item.output)), rawInput: item.arguments ?? {} });
  }
  // The task itself is already on the card, and nested spawns have their own files.
  return undefined;
}

export function parseChildTranscript(threadId: string, text: string): ChildTranscript {
  const transcript: ChildTranscript = { items: [] };
  const seen = new Set<string>();
  for (const line of text.split("\n")) {
    if (!line.includes('"session_meta"') && !line.includes('"event_msg"')) continue;
    let record: any;
    try { record = JSON.parse(line); } catch { continue; /* A line still being written. */ }
    const payload = record?.payload;
    if (record?.type === "session_meta") {
      if (typeof payload?.agent_nickname === "string" && payload.agent_nickname) transcript.nickname = payload.agent_nickname;
      if (typeof payload?.agent_role === "string" && payload.agent_role) transcript.role = payload.agent_role;
    } else if (record?.type !== "event_msg") {
      continue;
    } else if (payload?.type === "task_started") {
      transcript.state = "running";
    } else if (payload?.type === "task_complete") {
      transcript.state = "completed";
    } else if (payload?.type === "turn_aborted") {
      transcript.state = "interrupted";
    } else if (payload?.type === "item_completed") {
      const entry = childItemUpdate(threadId, payload.item);
      if (!entry || seen.has(entry.id)) continue;
      seen.add(entry.id);
      transcript.items.push(entry);
      if (entry.update.sessionUpdate === "agent_message_chunk") transcript.lastMessage = clip(entry.update.content.text);
    }
  }
  // Keep the opening and the most recent work of a very long child.
  if (transcript.items.length > MAX_ITEMS) transcript.items = [...transcript.items.slice(0, 50), ...transcript.items.slice(50 - MAX_ITEMS)];
  return transcript;
}

export class CodexChildTranscripts {
  private readonly cache = new Map<string, { mtimeMs: number; size: number; transcript: ChildTranscript }>();
  private files = new Map<string, string>();
  private indexedAt = 0;

  constructor(private readonly home: () => string = () => process.env.CODEX_HOME ?? path.join(os.homedir(), ".codex")) {}

  /** The child's transcript so far, or undefined while it has no rollout file. */
  read(threadId: string): ChildTranscript | undefined {
    if (!/^[0-9a-f-]{36}$/i.test(threadId)) return undefined;
    const file = this.locate(threadId);
    if (!file) return undefined;
    let stat: fs.Stats;
    try { stat = fs.statSync(file); } catch { this.files.delete(threadId); return undefined; }
    const cached = this.cache.get(file);
    if (cached && cached.mtimeMs === stat.mtimeMs && cached.size === stat.size) return cached.transcript;
    if (stat.size > MAX_FILE_BYTES) return cached?.transcript;
    let text: string;
    try {
      const raw = fs.readFileSync(file);
      text = file.endsWith(".zst") ? (zlib as any).zstdDecompressSync(raw).toString("utf8") : raw.toString("utf8");
    } catch { return cached?.transcript; }
    const transcript = parseChildTranscript(threadId, text);
    this.cache.set(file, { mtimeMs: stat.mtimeMs, size: stat.size, transcript });
    return transcript;
  }

  /** Attributes a child's items to the delegation card that spawned it. */
  records(threadId: string, parentToolCallId: string): DesktopRecord[] {
    const transcript = this.read(threadId);
    if (!transcript) return [];
    const records: DesktopRecord[] = [];
    if (transcript.state) {
      // Same shape as a parent's own agent-state report, so the card follows the
      // child while its parent is busy elsewhere. Clients fold it into the card.
      const key = `child:${threadId}:lifecycle`;
      records.push({ key, update: {
        sessionUpdate: "tool_call", toolCallId: key, title: "subAgentActivity", kind: "other", status: "completed",
        rawInput: { agentThreadId: threadId, agentPath: transcript.nickname ?? "agent", agentsStates: { [threadId]: {
          status: transcript.state, ...(transcript.state === "completed" && transcript.lastMessage ? { message: transcript.lastMessage } : {}) } } },
        _meta: { parentToolCallId },
      } as acp.SessionUpdate });
    }
    for (const { id, update } of transcript.items) records.push({ key: id, update: { ...update, _meta: { parentToolCallId } } as unknown as acp.SessionUpdate });
    return records;
  }

  private locate(threadId: string): string | undefined {
    const known = this.files.get(threadId);
    if (known) return known;
    // A child's file appears moments after it is spawned; look again soon, not on every poll.
    if (Date.now() - this.indexedAt < 2000) return undefined;
    this.indexedAt = Date.now();
    const files = new Map<string, string>();
    const walk = (dir: string, left: number): void => {
      let entries: fs.Dirent[];
      try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
      for (const entry of entries) {
        if (entry.isDirectory()) { if (left > 0) walk(path.join(dir, entry.name), left - 1); }
        else if (left === 0) {
          const id = ROLLOUT.exec(entry.name)?.[1]?.toLowerCase();
          if (id) files.set(id, path.join(dir, entry.name));
        }
      }
    };
    const home = this.home();
    walk(path.join(home, "archived_sessions"), 0);
    walk(path.join(home, "sessions"), 3);
    this.files = files;
    return files.get(threadId.toLowerCase());
  }
}
