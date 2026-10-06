import type { LogEntry } from "./types.js";
import { codeawMeta } from "./types.js";
import { parentToolCallId } from "./subagent.js";
import type { CompactGroup } from "./compact.js";

export const DETAIL_THRESHOLD = 4 * 1024;
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

const MIN_DETAIL_BYTES = 512;
const MIN_PAGE_BYTES = 8 * 1024;
const MAX_PAGE_BYTES = 8 * 1024 * 1024;
/** A page grows to the start of its turn unless that turn is much larger than the budget. */
const TURN_SLACK = 4;
const DELTA_PAGES = 2;

/** Session-level snapshots the app keeps outside the conversation; a tail page always carries them. */
const SNAPSHOTS = new Set(["plan", "available_commands_update", "current_mode_update", "config_option_update", "usage_update", "session_info_update"]);

/** Per-client, per-session replay projection negotiated by `session/load`. */
export interface HistoryOptions {
  /** Defer replayed tool output above this many bytes. */
  lazyBytes?: number;
  /** Send full replays newest-first in pages of about this many bytes. */
  pageBytes?: number;
}

export function historyOptions(meta: Record<string, unknown>): HistoryOptions | undefined {
  const options: HistoryOptions = {};
  if (meta.lazyHistory === true) {
    options.lazyBytes = typeof meta.lazyHistoryBytes === "number" && Number.isFinite(meta.lazyHistoryBytes)
      ? Math.max(MIN_DETAIL_BYTES, Math.min(DETAIL_THRESHOLD, Math.floor(meta.lazyHistoryBytes))) : DETAIL_THRESHOLD;
  }
  if (typeof meta.pageBytes === "number" && Number.isFinite(meta.pageBytes) && meta.pageBytes > 0) {
    options.pageBytes = Math.max(MIN_PAGE_BYTES, Math.min(MAX_PAGE_BYTES, Math.floor(meta.pageBytes)));
  }
  return options.lazyBytes === undefined && options.pageBytes === undefined ? undefined : options;
}

/** Only transport projections are shortened. The durable log and agent context stay intact. */
export function lazyToolEntry(entry: LogEntry, threshold = DETAIL_THRESHOLD): LogEntry {
  if (entry.kind !== "update" || !["tool_call", "tool_call_update"].includes(entry.update.sessionUpdate)) return entry;
  const u = entry.update as any;
  // Collaboration tools encode child identity/lifecycle in their output. Keep those inline.
  if (collaboration(u)) return entry;
  const bytes = Buffer.byteLength(JSON.stringify(u));
  if (bytes < threshold) return entry;
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

export function projectEntry(entry: LogEntry, options?: HistoryOptions): LogEntry {
  return options?.lazyBytes === undefined ? entry : lazyToolEntry(entry, options.lazyBytes);
}

function isSnapshot(group: CompactGroup): boolean {
  const e = group.entries[0];
  return e?.kind === "update" && SNAPSHOTS.has(e.update.sessionUpdate);
}

/** A top-level prompt that is not steered into a running turn. */
function startsTurn(group: CompactGroup): boolean {
  const e = group.entries[0];
  if (e?.kind !== "update" || e.update.sessionUpdate !== "user_message_chunk") return false;
  return !parentToolCallId(e.update) && codeawMeta(e.update).steered !== true;
}

function groupBytes(group: CompactGroup, options?: HistoryOptions): number {
  let bytes = 0;
  for (const entry of group.entries) bytes += Buffer.byteLength(JSON.stringify(projectEntry(entry, options)));
  return bytes;
}

/**
 * Newest groups of `groups` (which all precede the page) within about `budget` bytes.
 * Prefers to begin at a prompt so a turn's summary is rebuilt from one page.
 */
function newestPage(groups: CompactGroup[], budget: number, options?: HistoryOptions): number {
  let bytes = 0;
  let start = groups.length;
  let turn: number | undefined;
  for (let i = groups.length - 1; i >= 0; i--) {
    bytes += groupBytes(groups[i], options);
    if (startsTurn(groups[i])) turn = i;
    if (bytes >= budget * (turn === undefined ? TURN_SLACK : 1)) {
      // A turn start inside the budget closes the page there; otherwise this turn is
      // too large to send whole and the page begins mid-turn.
      return turn ?? i;
    }
    start = i;
  }
  return start;
}

export interface HistoryPage {
  entries: LogEntry[];
  /** First-appearance seq of the oldest group sent; older history remains when defined. */
  before?: number;
}

/**
 * The newest part of a compacted log. Session snapshots and an active turn state
 * come first wherever they appeared, so the page alone sets up the session.
 */
export function tailPage(groups: CompactGroup[], options: HistoryOptions & { pageBytes: number }): HistoryPage {
  const items = groups.filter((g) => !isSnapshot(g));
  const start = newestPage(items, options.pageBytes, options);
  if (start === 0) return { entries: groups.flatMap((g) => g.entries) };
  const before = items[start].first;
  const lastState = groups.findLast((g) => g.entries[0]?.kind === "event" && g.entries[0].event.type === "state");
  const activeState = lastState && lastState.first < before && lastState.entries[0].kind === "event" &&
    lastState.entries[0].event.type === "state" && lastState.entries[0].event.state !== "idle";
  return {
    entries: [
      ...(activeState ? lastState.entries : []),
      ...groups.filter(isSnapshot).flatMap((g) => g.entries),
      ...items.slice(start).flatMap((g) => g.entries),
    ],
    before,
  };
}

/**
 * Delta replays send raw streaming chunks. After a long absence that can be far
 * larger than a compacted first page, so paged clients get a full replay instead.
 */
export function preferFullReplay(entries: LogEntry[], afterSeq: number, options?: HistoryOptions): boolean {
  if (!options?.pageBytes) return false;
  const limit = options.pageBytes * DELTA_PAGES;
  let bytes = 0;
  for (let i = entries.length - 1; i >= 0 && entries[i].seq > afterSeq; i--) {
    bytes += Buffer.byteLength(JSON.stringify(projectEntry(entries[i], options)));
    if (bytes > limit) return true;
  }
  return false;
}

/** Conversation groups that first appeared before `before`, newest page first. */
export function olderPage(groups: CompactGroup[], before: number, options: HistoryOptions & { pageBytes: number }): HistoryPage {
  const items = groups.filter((g) => !isSnapshot(g) && g.first < before);
  const start = newestPage(items, options.pageBytes, options);
  return { entries: items.slice(start).flatMap((g) => g.entries), ...(start > 0 ? { before: items[start].first } : {}) };
}
