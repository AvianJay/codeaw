import crypto from "node:crypto";
import fs from "node:fs";
import * as acp from "@agentclientprotocol/sdk";
import type { AgentHandlers } from "../backend/agent-process.js";
import type { AgentBackend } from "../backend/backend.js";
import type { DesktopState } from "../backend/codex-desktop-state.js";
import type { AgentRegistry } from "../backend/registry.js";
import type { PushNotifier, PushKind } from "../notify/ntfy.js";
import { logger } from "../util/log.js";
import { VERSION } from "../version.js";
import { compactGroups, compactLog, type CompactGroup } from "./compact.js";
import { planFork, type ForkPlan } from "./fork.js";
import { historyOptions, olderPage, preferFullReplay, projectEntry, tailPage, type HistoryOptions, type HistoryPage } from "./history.js";
import { parentToolCallId } from "./subagent.js";
import { WorkTracker } from "./work-status.js";
import type { LiveActivityPush, ActivitySnapshot } from "../notify/live-activity.js";
import { newEpoch, type SessionStore } from "./store.js";
import {
  codeawMeta,
  isChunk,
  withCodeawMeta,
  type CodeawEvent,
  type CompletedTurn,
  type LogEntry,
  type SessionMeta,
  type TurnState,
} from "./types.js";

const log = logger("sessions");

/** One connected app (or any ACP client) as seen by the session layer. */
export interface ClientHandle {
  readonly id: string;
  readonly deviceName: string;
  foreground: boolean;
  activeSessionId?: string;
  /** Sends a notification; calls are delivered in order. */
  notify(method: string, params: unknown): Promise<void>;
  /** Sends a request after everything queued before it; resolves with the client's answer. */
  request<T>(method: string, params: unknown, signal: AbortSignal): Promise<T>;
  /** Resolves once everything queued so far has been handed to the transport. */
  flush(): Promise<void>;
}

interface Turn {
  promptId: string;
  startedAt: number;
  done: Promise<acp.PromptResponse>;
}

interface QueuedPrompt {
  promptId: string;
  blocks: acp.ContentBlock[];
  resolve: (r: acp.PromptResponse) => void;
  reject: (e: unknown) => void;
}

interface PendingRequest {
  id: string;
  kind: "permission" | "elicitation";
  method: string;
  params: Record<string, any>;
  cancelValue: unknown;
  settled: boolean;
  resolve: (value: any) => void;
  dispatched: Map<string, AbortController>;
  title?: string;
  resolvedOnDesktop?: boolean;
}

class BridgeSession {
  readonly work = new WorkTracker();
  workTimer?: NodeJS.Timeout;
  completedTurn?: CompletedTurn;
  stopReason?: string;
  entries?: LogEntry[];
  readonly subscribers = new Set<ClientHandle>();
  turn?: Turn;
  desktop?: DesktopState;
  queue: QueuedPrompt[] = [];
  readonly steering = new Set<string>();
  dequeues?: Map<string, Extract<CodeawEvent, { type: "dequeued" }>>;
  readonly pending = new Map<string, PendingRequest>();
  receipts?: Map<string, "received" | "read" | "failed">;
  /** Agent process generation in which this session is live; 0 = not live. */
  backendGen = 0;
  suppressUpdates = false;
  activating?: Promise<void>;
  midRun?: { type: string; mid: string; parent?: string };
  lastActivity = Date.now();
  stale = false;
  emitted?: { state: TurnState; queued: number; desktopConnected?: boolean; nativeTurnId?: string };
  metaTimer?: NodeJS.Timeout;

  constructor(public meta: SessionMeta) {}

  get id(): string {
    return this.meta.id;
  }

  get state(): TurnState {
    if ([...this.pending.values()].some((request) => codeawMeta(request.params).async !== true)) return "requires_action";
    if (this.desktop?.connected && this.desktop.state !== "idle") return this.desktop.state;
    return this.turn ? "running" : this.pending.size ? "requires_action" : "idle";
  }
}

export interface ManagerOptions {
  idleSessionCloseMs: number;
  idleAgentStopMs: number;
  hostName: string;
}

/** Updates that only change session-level snapshot state. They do not split a run of chunks. */
const SNAPSHOT_UPDATES = new Set(["usage_update", "available_commands_update", "config_option_update", "current_mode_update", "session_info_update"]);
const ORPHAN_TTL_MS = 30_000;

export function extId(agentId: string, backendId: string): string {
  return `${agentId}:${backendId}`;
}

export function parseExtId(id: string): { agentId: string; backendId: string } {
  const i = id.indexOf(":");
  if (i <= 0) throw acp.RequestError.invalidParams(undefined, `Malformed session id "${id}"`);
  return { agentId: id.slice(0, i), backendId: id.slice(i + 1) };
}

function sameJson(a: unknown, b: unknown): boolean {
  return JSON.stringify(a ?? null) === JSON.stringify(b ?? null);
}

function errorMessage(err: unknown): string {
  if (err instanceof acp.RequestError) {
    const details = (err.data as any)?.details ?? (err.data as any)?.message;
    return details && typeof details === "string" && !err.message.includes(details) ? `${err.message}: ${details}` : err.message;
  }
  return err instanceof Error ? err.message : String(err);
}

function toRequestError(err: unknown): acp.RequestError {
  if (err instanceof acp.RequestError) return err;
  return acp.RequestError.internalError(undefined, errorMessage(err));
}

const DEFAULT_PAGE_BYTES = 192 * 1024;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function beforeOf(page: { before?: number }): { before?: number } {
  return page.before === undefined ? {} : { before: page.before };
}

function modeOf(meta: SessionMeta): string | undefined {
  const opt = meta.configOptions?.find((o: any) => o.category === "mode" || o.id === "mode") as any;
  if (opt && typeof opt.currentValue === "string") return opt.currentValue;
  return meta.modes?.currentModeId ?? undefined;
}

export class SessionManager implements AgentHandlers {
  private readonly sessions = new Map<string, BridgeSession>();
  private readonly deleting = new Set<string>();
  private readonly clients = new Set<ClientHandle>();
  private readonly attachedTo = new Map<ClientHandle, Set<BridgeSession>>();
  private readonly history = new Map<ClientHandle, Map<string, HistoryOptions>>();
  private readonly importing = new Map<string, Promise<BridgeSession>>();
  private readonly orphans = new Map<string, { at: number; params: acp.SessionNotification }[]>();
  private readonly nativeInfo = new Map<string, acp.SessionInfo>();
  private readonly forking = new Map<string, Promise<Record<string, unknown>>>();
  private sweepTimer?: NodeJS.Timeout;
  private shuttingDown = false;
  notifier?: PushNotifier;
  liveActivity?: LiveActivityPush;

  constructor(
    private readonly registry: AgentRegistry,
    private readonly store: SessionStore,
    private readonly opts: ManagerOptions,
  ) {}

  start(): void {
    this.sweepTimer = setInterval(() => void this.sweep(), 60_000);
    this.sweepTimer.unref();
  }

  async shutdown(): Promise<void> {
    this.shuttingDown = true;
    if (this.sweepTimer) clearInterval(this.sweepTimer);
    for (const s of this.sessions.values()) {
      if (s.workTimer) clearTimeout(s.workTimer);
      for (const q of s.queue.splice(0)) {
        this.appendEvent(s, { type: "dequeued", promptId: q.promptId, cancelled: true });
        q.resolve({ stopReason: "cancelled" });
      }
      this.saveMeta(s, true);
    }
    this.store.closeAll();
  }

  // ───────────────────────────── clients ─────────────────────────────

  get clientCount(): number {
    return this.clients.size;
  }

  addClient(c: ClientHandle): void {
    this.clients.add(c);
    this.attachedTo.set(c, new Set());
  }

  removeClient(c: ClientHandle): void {
    this.clients.delete(c);
    for (const s of this.attachedTo.get(c) ?? []) {
      s.subscribers.delete(c);
      s.lastActivity = Date.now();
      for (const pr of s.pending.values()) {
        pr.dispatched.get(c.id)?.abort();
        pr.dispatched.delete(c.id);
      }
    }
    this.attachedTo.delete(c);
    this.history.delete(c);
    // Anything still waiting for an answer now may need a push.
    if (this.clients.size === 0) {
      for (const s of this.sessions.values()) {
        for (const pr of s.pending.values()) this.push(s, "permission", pr.title, () => !pr.settled);
      }
    }
  }

  /** Stops pushing a session's updates to this client (it closed the screen). */
  detach(c: ClientHandle, sessionId: unknown): void {
    const s = typeof sessionId === "string" ? this.sessions.get(sessionId) : undefined;
    if (!s) return;
    s.subscribers.delete(c);
    this.attachedTo.get(c)?.delete(s);
    this.history.get(c)?.delete(s.id);
    for (const pr of s.pending.values()) {
      pr.dispatched.get(c.id)?.abort();
      pr.dispatched.delete(c.id);
    }
    s.lastActivity = Date.now();
  }

  setClientState(c: ClientHandle, params: { foreground?: unknown; activeSessionId?: unknown }): void {
    if (typeof params.foreground === "boolean") c.foreground = params.foreground;
    c.activeSessionId = typeof params.activeSessionId === "string" ? params.activeSessionId : undefined;
  }

  initializeResponse(): acp.InitializeResponse {
    return {
      protocolVersion: acp.PROTOCOL_VERSION,
      agentCapabilities: {
        loadSession: true,
        promptCapabilities: { image: true, embeddedContext: true, audio: false },
        mcpCapabilities: { http: false, sse: false },
        sessionCapabilities: { list: {}, resume: {}, close: {}, delete: {} },
      },
      agentInfo: { name: "codeaw-bridge", title: "codeaw", version: VERSION },
      authMethods: [],
      _meta: { codeaw: { version: 1, host: this.opts.hostName, agents: this.registry.describe(), projectless: true, editPrompts: true } },
    };
  }

  // ───────────────────────────── agent → bridge ─────────────────────────────

  onUpdate(agentId: string, params: acp.SessionNotification): void {
    if (this.shuttingDown) return;
    const id = extId(agentId, params.sessionId);
    if (this.store.isDeleted(id) || this.deleting.has(id)) return;
    const s = this.sessions.get(id) ?? this.fromDisk(id);
    if (!s) {
      // e.g. available_commands_update racing the session/new response
      const list = this.orphans.get(id) ?? [];
      list.push({ at: Date.now(), params });
      this.orphans.set(id, list);
      return;
    }
    if (s.suppressUpdates) return;
    if (s.meta.connection !== "desktop" && s.turn && ["agent_message_chunk", "agent_thought_chunk", "tool_call", "tool_call_update"].includes(params.update.sessionUpdate)) {
      this.receipt(s, s.turn.promptId, "read");
    }
    this.ingest(s, params.update);
  }

  /** Desktop snapshots are authoritative; an edited history gets a new replay epoch. */
  onHistoryReset(agentId: string, backendId: string, updates: acp.SessionUpdate[]): void {
    if (this.shuttingDown) return;
    const s = this.sessions.get(extId(agentId, backendId)) ?? this.fromDisk(extId(agentId, backendId));
    if (!s) return;
    const entries = this.ensureEntries(s);
    const receipts = this.receiptStates(s);
    const dequeues = this.dequeueStates(s);
    const nativeIds = new Set(updates.filter((u) => u.sessionUpdate === "user_message_chunk").map((u) => codeawMeta(u).promptId));
    // A native snapshot has no unsent codeaw queue. Preserve those messages and
    // receipt states across its epoch rebuild, including after reconnect.
    const waiting = entries.filter((entry) => entry.kind === "update" && entry.update.sessionUpdate === "user_message_chunk" &&
      dequeues.get(codeawMeta(entry.update).promptId)?.removed !== true &&
      ["received", "failed"].includes(receipts.get(codeawMeta(entry.update).promptId) ?? "") && !nativeIds.has(codeawMeta(entry.update).promptId));
    this.store.truncate(s.id);
    s.entries = [];
    s.meta.lastSeq = 0;
    s.meta.epoch = newEpoch();
    s.meta.connection = "desktop";
    s.meta.configOptions = [];
    s.meta.modes = null;
    s.midRun = undefined;
    s.emitted = undefined;
    s.work.reset();
    for (const c of s.subscribers) void c.notify("_codeaw/replay", { sessionId: s.id, mode: "full", epoch: s.meta.epoch, lastSeq: 0 });
    // Build the authoritative log first, then send its compact transport projection.
    const subscribers = [...s.subscribers];
    s.subscribers.clear();
    try {
      for (const update of updates) this.ingest(s, update);
      for (const entry of waiting) if (entry.kind === "update") this.append(s, { kind: "update", update: entry.update });
      for (const [promptId, status] of receipts) this.appendEvent(s, { type: "prompt_receipt", promptId, status });
      for (const event of dequeues.values()) this.appendEvent(s, event);
      for (const pending of s.pending.values()) {
        if (pending.kind === "permission") this.appendEvent(s, { type: "permission_request", requestId: pending.id, toolCall: pending.params.toolCall, options: pending.params.options });
        else this.appendEvent(s, { type: "elicitation_request", requestId: pending.id, request: pending.params as any });
      }
    } finally {
      for (const c of subscribers) s.subscribers.add(c);
    }
    const groups = compactGroups(this.ensureEntries(s));
    for (const c of subscribers) {
      const page = this.replayPage(c, s, groups);
      for (const entry of page.entries) this.sendEntry(c, s, this.historyEntry(c, s, entry));
      void c.notify("_codeaw/replay", { sessionId: s.id, mode: "complete", epoch: s.meta.epoch, lastSeq: s.meta.lastSeq, ...beforeOf(page) });
    }
    this.saveMeta(s, true);
  }

  onSessionState(agentId: string, backendId: string, state: DesktopState): void {
    if (this.shuttingDown) return;
    const s = this.sessions.get(extId(agentId, backendId)) ?? this.fromDisk(extId(agentId, backendId));
    if (!s) return;
    const previous = s.desktop;
    s.desktop = state;
    s.meta.connection = "desktop";
    if (state.title !== undefined) s.meta.title = state.title;
    if (state.cwd) s.meta.cwd = state.cwd;
    const completed = previous?.turnId && previous.startedAt !== undefined && state.state === "idle" && state.connected
      ? { promptId: previous.turnId, startedAt: previous.startedAt, endedAt: Date.now() } : undefined;
    this.emitState(s, completed ? state.stopReason : undefined, completed);
    this.saveMeta(s);
    if (state.connected && state.state === "idle" && !s.turn) setImmediate(() => this.startNext(s));
  }

  onSessionError(agentId: string, backendId: string, message: string): void {
    if (this.shuttingDown) return;
    const s = this.sessions.get(extId(agentId, backendId));
    if (s) this.appendEvent(s, { type: "error", message });
  }

  private ingest(s: BridgeSession, raw: acp.SessionUpdate): void {
    let update = raw as any;
    switch (update.sessionUpdate) {
      case "config_option_update":
        if (sameJson(update.configOptions, s.meta.configOptions)) return;
        s.meta.configOptions = update.configOptions;
        break;
      case "current_mode_update":
        if (s.meta.modes) {
          if (s.meta.modes.currentModeId === update.currentModeId) return;
          s.meta.modes = { ...s.meta.modes, currentModeId: update.currentModeId };
        }
        break;
      case "session_info_update":
        if (typeof update.title === "string") s.meta.title = update.title;
        break;
    }
    if (isChunk(update)) {
      update = this.externalizeImages(update);
      const type = update.sessionUpdate as string;
      const parent = parentToolCallId(update);
      let mid: string;
      const meta = codeawMeta(update);
      if (type === "user_message_chunk" && typeof meta.promptId === "string") {
        mid = `u-${meta.promptId}`;
        if (meta.receipt === "read") this.receipt(s, meta.promptId, "read");
        if (meta.replace && (s.entries ?? []).some((entry) => entry.kind === "update" && entry.update.sessionUpdate === "user_message_chunk" && codeawMeta(entry.update).promptId === meta.promptId && !codeawMeta(entry.update).replace)) return;
      } else if (typeof update.messageId === "string" && update.messageId) mid = update.messageId;
      else if (s.midRun?.type === type && s.midRun.parent === parent) mid = s.midRun.mid;
      else mid = `m${s.meta.lastSeq + 1}`;
      s.midRun = { type, mid, parent };
      update = withCodeawMeta(update, { mid });
    } else if (!SNAPSHOT_UPDATES.has(update.sessionUpdate)) {
      s.midRun = undefined;
    }
    this.append(s, { kind: "update", update });
    if (s.work.ingest(update) && s.state !== "idle" && !s.workTimer) {
      s.workTimer = setTimeout(() => { s.workTimer = undefined; this.activity(s); }, 500);
      s.workTimer.unref();
    }
    if (update.sessionUpdate === "session_info_update") this.activity(s);
  }

  async onPermission(agentId: string, params: acp.RequestPermissionRequest, signal: AbortSignal): Promise<acp.RequestPermissionResponse> {
    const s = this.sessions.get(extId(agentId, params.sessionId));
    if (!s) return { outcome: { outcome: "cancelled" } };
    if (s.turn) this.receipt(s, s.turn.promptId, "read");
    const toolTitle = (params.toolCall as any)?.title as string | undefined;
    return this.openRequest(s, {
      kind: "permission",
      method: "session/request_permission",
      params: { ...params, sessionId: s.id },
      cancelValue: { outcome: { outcome: "cancelled" } },
      event: (requestId) => ({ type: "permission_request", requestId, toolCall: params.toolCall, options: params.options }),
      title: toolTitle,
      signal,
    });
  }

  async onElicitation(agentId: string, params: acp.CreateElicitationRequest, signal: AbortSignal): Promise<acp.CreateElicitationResponse> {
    const backendSession = (params as any).sessionId as string | undefined;
    const s = backendSession ? this.sessions.get(extId(agentId, backendSession)) : undefined;
    if (!s) return { action: "decline" } as acp.CreateElicitationResponse;
    if (s.turn) this.receipt(s, s.turn.promptId, "read");
    return this.openRequest(s, {
      kind: "elicitation",
      method: "elicitation/create",
      params: { ...params, sessionId: s.id },
      cancelValue: { action: "cancel" },
      event: (requestId) => ({ type: "elicitation_request", requestId, request: { ...params, sessionId: s.id } as any }),
      title: (params as any).message,
      signal,
    });
  }

  onExit(agentId: string, generation: number, detail: string): void {
    for (const s of this.sessions.values()) {
      if (s.meta.connection === "desktop") continue;
      if (s.meta.agentId !== agentId || s.backendGen !== generation) continue;
      s.backendGen = 0;
      for (const pr of [...s.pending.values()]) this.settle(s, pr, pr.cancelValue, undefined);
      const queued = s.queue.splice(0);
      for (const q of queued) {
        this.appendEvent(s, { type: "dequeued", promptId: q.promptId, cancelled: true });
        q.reject(acp.RequestError.internalError(undefined, `Agent ${detail}`));
      }
      if (s.turn) this.appendEvent(s, { type: "error", message: `Agent process ${detail}` });
    }
  }

  // ───────────────────────────── permission / elicitation ─────────────────────────────

  private openRequest<T>(
    s: BridgeSession,
    spec: {
      kind: PendingRequest["kind"];
      method: string;
      params: Record<string, any>;
      cancelValue: unknown;
      event: (requestId: string) => CodeawEvent;
      title?: string;
      signal: AbortSignal;
    },
  ): Promise<T> {
    return new Promise<T>((resolve) => {
      const pr: PendingRequest = {
        id: "r_" + crypto.randomBytes(6).toString("hex"),
        kind: spec.kind,
        method: spec.method,
        params: spec.params,
        cancelValue: spec.cancelValue,
        settled: false,
        resolve,
        dispatched: new Map(),
        title: spec.title,
      };
      s.pending.set(pr.id, pr);
      this.appendEvent(s, spec.event(pr.id));
      this.emitState(s);
      for (const c of s.subscribers) this.dispatch(s, pr, c);
      const cancelled = () => {
        pr.resolvedOnDesktop = spec.signal.reason === "desktop-resolved";
        this.settle(s, pr, pr.cancelValue, undefined);
      };
      if (spec.signal.aborted) cancelled();
      else spec.signal.addEventListener("abort", cancelled, { once: true });
      this.push(s, "permission", spec.title, () => !pr.settled);
    });
  }

  private dispatch(s: BridgeSession, pr: PendingRequest, c: ClientHandle): void {
    if (pr.settled || pr.dispatched.has(c.id)) return;
    const ac = new AbortController();
    pr.dispatched.set(c.id, ac);
    const params = withCodeawMeta(pr.params as any, { requestId: pr.id });
    c.request<any>(pr.method, params, ac.signal).then(
      (answer) => {
        if (ac.signal.aborted || pr.settled) return;
        this.settle(s, pr, answer, c);
      },
      () => {
        // client disconnected or the request was withdrawn
        pr.dispatched.delete(c.id);
      },
    );
  }

  private settle(s: BridgeSession, pr: PendingRequest, answer: any, by: ClientHandle | undefined): void {
    if (pr.settled) return;
    pr.settled = true;
    s.pending.delete(pr.id);
    for (const [clientId, ac] of pr.dispatched) if (clientId !== by?.id) ac.abort();
    pr.dispatched.clear();
    if (pr.kind === "permission") {
      const outcome = answer?.outcome ?? { outcome: "cancelled" };
      const option = (pr.params.options as acp.PermissionOption[] | undefined)?.find((o) => o.optionId === outcome.optionId);
      this.appendEvent(s, { type: "permission_resolved", requestId: pr.id, outcome, optionName: pr.resolvedOnDesktop ? "已在桌面處理" : option?.name, by: pr.resolvedOnDesktop ? "桌面" : by?.deviceName });
      pr.resolve({ outcome });
    } else {
      const action = typeof answer?.action === "string" ? answer.action : "cancel";
      this.appendEvent(s, { type: "elicitation_resolved", requestId: pr.id, action, by: by?.deviceName });
      pr.resolve(answer?.action ? answer : { action: "cancel" });
    }
    this.emitState(s);
  }

  // ───────────────────────────── log & broadcast ─────────────────────────────

  private ensureEntries(s: BridgeSession): LogEntry[] {
    if (!s.entries) {
      s.entries = this.store.readEntries(s.id);
      // Queue promises cannot survive a bridge restart. Older versions left the
      // saved user bubbles queued forever; settle them without redelivering them.
      const waiting = new Map<string, boolean>();
      for (const entry of s.entries) {
        if (entry.kind !== "update" || entry.update.sessionUpdate !== "user_message_chunk") continue;
        const meta = codeawMeta(entry.update);
        if (typeof meta.promptId === "string" && typeof meta.queued === "boolean") waiting.set(meta.promptId, meta.queued && meta.steered !== true);
      }
      const receipts = this.receiptStates(s), dequeues = this.dequeueStates(s);
      for (const [promptId, queued] of waiting) {
        if (queued && !dequeues.has(promptId) && receipts.get(promptId) !== "read") {
          this.appendEvent(s, { type: "dequeued", promptId, cancelled: true });
        }
      }
    }
    return s.entries;
  }

  private append(s: BridgeSession, partial: { kind: "update"; update: any } | { kind: "event"; event: CodeawEvent }): LogEntry {
    const entries = this.ensureEntries(s);
    const entry = { seq: ++s.meta.lastSeq, t: Date.now(), ...partial } as LogEntry;
    entries.push(entry);
    this.store.append(s.id, entry);
    s.meta.updatedAt = new Date(entry.t).toISOString();
    s.lastActivity = entry.t;
    this.saveMeta(s);
    for (const c of s.subscribers) this.sendEntry(c, s, entry);
    return entry;
  }

  private appendEvent(s: BridgeSession, event: CodeawEvent): void {
    if (event.type !== "dequeued" && event.type !== "prompt_receipt") s.midRun = undefined;
    if (event.type === "dequeued") this.dequeueStates(s).set(event.promptId, event);
    this.append(s, { kind: "event", event });
  }

  private dequeueStates(s: BridgeSession): Map<string, Extract<CodeawEvent, { type: "dequeued" }>> {
    if (!s.dequeues) {
      s.dequeues = new Map();
      for (const entry of s.entries ?? this.store.readEntries(s.id)) {
        if (entry.kind === "event" && entry.event.type === "dequeued") s.dequeues.set(entry.event.promptId, entry.event);
      }
    }
    return s.dequeues;
  }

  private receiptStates(s: BridgeSession): Map<string, "received" | "read" | "failed"> {
    if (!s.receipts) {
      s.receipts = new Map();
      for (const entry of s.entries ?? this.store.readEntries(s.id)) {
        if (entry.kind === "event" && entry.event.type === "prompt_receipt") s.receipts.set(entry.event.promptId, entry.event.status);
      }
    }
    return s.receipts;
  }

  private receipt(s: BridgeSession, promptId: string, status: "received" | "read" | "failed"): void {
    const receipts = this.receiptStates(s);
    const before = receipts.get(promptId);
    if (before === status || (before === "read" && status !== "read")) return;
    receipts.set(promptId, status);
    this.appendEvent(s, { type: "prompt_receipt", promptId, status });
  }

  private sendEntry(c: ClientHandle, s: BridgeSession, entry: LogEntry): void {
    const _meta = { codeaw: { seq: entry.seq, t: entry.t } };
    if (entry.kind === "update") void c.notify("session/update", { sessionId: s.id, update: entry.update, _meta });
    else void c.notify("_codeaw/event", { sessionId: s.id, event: entry.event, _meta });
  }

  private historyEntry(c: ClientHandle, s: BridgeSession, entry: LogEntry): LogEntry {
    return projectEntry(entry, this.history.get(c)?.get(s.id));
  }

  /** Clients that negotiated paging get the newest part of a full replay first. */
  private replayPage(c: ClientHandle, s: BridgeSession, groups: CompactGroup[]): HistoryPage {
    const options = this.history.get(c)?.get(s.id);
    return options?.pageBytes ? tailPage(groups, { ...options, pageBytes: options.pageBytes }) : { entries: groups.flatMap((g) => g.entries) };
  }

  /**
   * Sends history older than `before` as one `_codeaw/history/page` notification. It is
   * queued with this client's live updates, so the page reflects everything sent before it.
   */
  historyPage(c: ClientHandle, params: { sessionId?: unknown; epoch?: unknown; before?: unknown; pageBytes?: unknown }): object {
    const s = this.requireLoaded(params.sessionId);
    if (params.epoch !== s.meta.epoch) throw acp.RequestError.invalidParams(undefined, "History changed; reconnect before loading older messages");
    if (!s.subscribers.has(c)) throw acp.RequestError.invalidParams(undefined, "Load the session before paging its history");
    const before = params.before;
    if (typeof before !== "number" || !Number.isInteger(before) || before < 1) throw acp.RequestError.invalidParams(undefined, "before is required");
    const options = this.history.get(c)?.get(s.id);
    const pageBytes = historyOptions({ pageBytes: params.pageBytes })?.pageBytes ?? options?.pageBytes ?? DEFAULT_PAGE_BYTES;
    const page = olderPage(compactGroups(this.ensureEntries(s)), before, { ...options, pageBytes });
    void c.notify("_codeaw/history/page", {
      sessionId: s.id, epoch: s.meta.epoch, requested: before, ...beforeOf(page),
      entries: page.entries.map((entry) => {
        const projected = this.historyEntry(c, s, entry);
        return projected.kind === "update" ? { seq: projected.seq, t: projected.t, update: projected.update } : { seq: projected.seq, t: projected.t, event: projected.event };
      }),
    });
    return {};
  }

  /** Authenticated, read-only expansion of a deferred tool, including every output byte. */
  toolHistory(params: { sessionId?: unknown; epoch?: unknown; toolCallId?: unknown }): object {
    const s = this.requireLoaded(params.sessionId);
    if (params.epoch !== s.meta.epoch) throw acp.RequestError.invalidParams(undefined, "History changed; reconnect before expanding this tool");
    if (typeof params.toolCallId !== "string" || !params.toolCallId) throw acp.RequestError.invalidParams(undefined, "toolCallId is required");
    const entries = this.ensureEntries(s).filter((e) => e.kind === "update" &&
      ["tool_call", "tool_call_update"].includes(e.update.sessionUpdate) && (e.update as any).toolCallId === params.toolCallId);
    const entry = compactLog(entries)[0];
    if (!entry || entry.kind !== "update") throw acp.RequestError.invalidParams(undefined, "Tool no longer exists");
    return { epoch: s.meta.epoch, seq: entry.seq, t: entry.t, update: entry.update };
  }

  private emitState(s: BridgeSession, stopReason?: string, completedTurn?: CompletedTurn): void {
    const state = s.state;
    const queued = s.queue.length;
    const desktopConnected = s.desktop?.connected;
    const nativeTurnId = s.desktop?.turnId;
    if (!stopReason && s.emitted && s.emitted.state === state && s.emitted.queued === queued && s.emitted.desktopConnected === desktopConnected && s.emitted.nativeTurnId === nativeTurnId) return;
    s.emitted = { state, queued, desktopConnected, nativeTurnId };
    if (completedTurn) s.completedTurn = completedTurn;
    if (state === "idle") s.stopReason = stopReason;
    this.appendEvent(s, {
      type: "state", state, queued,
      ...(s.desktop?.connected && s.desktop.turnId ? { turnStartedAt: s.desktop.startedAt, turnPromptId: s.desktop.turnId } : s.turn ? { turnStartedAt: s.turn.startedAt, turnPromptId: s.turn.promptId } : {}),
      ...(s.meta.connection === "desktop" ? { connection: "desktop", desktopConnected: desktopConnected === true } : {}),
      ...(completedTurn ? { completedTurn } : {}),
      ...(stopReason && state === "idle" ? { stopReason } : {}),
    });
    this.activity(s);
  }

  activitySnapshot(sessionId: string): ActivitySnapshot | undefined {
    const s = this.sessions.get(sessionId);
    if (!s) return undefined;
    return this.snapshot(s);
  }

  activitySnapshots(): ActivitySnapshot[] { return [...this.sessions.values()].map((s) => this.snapshot(s)); }

  private snapshot(s: BridgeSession): ActivitySnapshot {
    const native = s.desktop?.turnId ? s.desktop : undefined;
    const disconnected = native?.connected === false;
    const state = disconnected ? "running" : s.state;
    const work = s.work.view(s.meta.cwd, state, native?.turnId, s.stopReason);
    if (s.meta.projectless) work.project = "無專案";
    return {
      sessionId: s.id, agentId: s.meta.agentId, title: s.meta.title,
      projectless: s.meta.projectless === true,
      state, turnPromptId: native?.turnId ?? s.turn?.promptId,
      turnStartedAt: native?.startedAt ?? s.turn?.startedAt,
      completedTurn: state === "idle" ? s.completedTurn : undefined,
      work: disconnected ? { project: work.project, phase: "disconnected", summary: "桌面連線中斷，等待重新同步", updatedAt: Date.now() } : work,
    };
  }

  private activity(s: BridgeSession): void {
    const params = {
      ...this.snapshot(s),
      pending: s.pending.size,
      queued: s.queue.length,
      title: s.meta.title,
      updatedAt: s.meta.updatedAt,
      lastSeq: s.meta.lastSeq,
      ...(s.meta.connection === "desktop" ? { connection: "desktop", desktopConnected: s.desktop?.connected === true } : {}),
    };
    for (const c of this.clients) void c.notify("_codeaw/activity", params);
    this.liveActivity?.observe(params);
  }

  private saveMeta(s: BridgeSession, now = false): void {
    if (now) {
      if (s.metaTimer) clearTimeout(s.metaTimer);
      s.metaTimer = undefined;
      this.store.writeMeta(s.meta);
      return;
    }
    if (s.metaTimer) return;
    s.metaTimer = setTimeout(() => {
      s.metaTimer = undefined;
      try {
        this.store.writeMeta(s.meta);
      } catch (err) {
        log.warn(`could not save meta for ${s.id}`, err);
      }
    }, 1000);
    s.metaTimer.unref();
  }

  private externalizeImages(update: any): any {
    const content = update.content;
    if (content?.type !== "image" || typeof content.data !== "string" || !content.data) return update;
    try {
      const sha = this.store.putBlob(content.data, content.mimeType ?? "image/png");
      return { ...update, content: { ...content, data: "", uri: `codeaw-blob:${sha}` } };
    } catch {
      return update;
    }
  }

  private logUserMessage(s: BridgeSession, blocks: acp.ContentBlock[], promptId: string, flags: Record<string, unknown> = {}): void {
    const mid = `u-${promptId}`;
    for (const block of blocks) {
      const update = this.externalizeImages({ sessionUpdate: "user_message_chunk", content: block });
      this.append(s, { kind: "update", update: withCodeawMeta(update, { mid, promptId, ...flags }) });
    }
    s.midRun = undefined;
  }

  // ───────────────────────────── session bookkeeping ─────────────────────────────

  private createSession(fields: Omit<SessionMeta, "createdAt" | "updatedAt" | "epoch" | "lastSeq">): BridgeSession {
    const now = new Date().toISOString();
    const s = new BridgeSession({ ...fields, createdAt: now, updatedAt: now, epoch: newEpoch(), lastSeq: 0 });
    s.entries = [];
    this.sessions.set(s.id, s);
    this.saveMeta(s, true);
    return s;
  }

  private fromDisk(id: string): BridgeSession | undefined {
    const meta = this.store.readMeta(id);
    if (!meta) return undefined;
    const s = new BridgeSession(meta);
    this.sessions.set(id, s);
    return s;
  }

  private flushOrphans(s: BridgeSession): void {
    const list = this.orphans.get(s.id);
    if (!list) return;
    this.orphans.delete(s.id);
    for (const o of list) this.ingest(s, o.params.update);
  }

  /** Copies setup state (config options, modes) from a new/load/resume response into the session. */
  private applySetup(s: BridgeSession, resp: any): void {
    if (!resp) return;
    if (resp._meta?.codeaw?.connection === "desktop") s.meta.connection = "desktop";
    if (Array.isArray(resp.configOptions) && !sameJson(resp.configOptions, s.meta.configOptions)) {
      this.ingest(s, { sessionUpdate: "config_option_update", configOptions: resp.configOptions } as any);
    }
    if (resp.modes && typeof resp.modes === "object") {
      const changed = s.meta.modes?.currentModeId !== resp.modes.currentModeId;
      s.meta.modes = resp.modes;
      if (changed) this.append(s, { kind: "update", update: { sessionUpdate: "current_mode_update", currentModeId: resp.modes.currentModeId } });
    }
    this.saveMeta(s);
  }

  private setupView(s: BridgeSession): Record<string, unknown> {
    return {
      ...(s.meta.configOptions ? { configOptions: s.meta.configOptions } : {}),
      ...(s.meta.modes ? { modes: s.meta.modes } : {}),
      _meta: {
        codeaw: {
          agentId: s.meta.agentId,
          lastSeq: s.meta.lastSeq,
          epoch: s.meta.epoch,
          state: s.state,
          queued: s.queue.length,
          ...(s.desktop?.connected && s.desktop.turnId ? { turnStartedAt: s.desktop.startedAt, turnPromptId: s.desktop.turnId } : s.turn ? { turnStartedAt: s.turn.startedAt, turnPromptId: s.turn.promptId } : {}),
          ...(s.meta.connection === "desktop" ? { connection: "desktop", desktopConnected: s.desktop?.connected === true } : {}),
          title: s.meta.title,
          cwd: s.meta.cwd,
          projectless: s.meta.projectless === true,
        },
      },
    };
  }

  private requireAgent(agentId: string): AgentBackend {
    return this.registry.get(agentId);
  }

  /** Makes sure the agent process holds this session live, resuming it after restarts. */
  private async ensureActive(s: BridgeSession, allowDisconnected = false): Promise<AgentBackend> {
    const agent = this.requireAgent(s.meta.agentId);
    if (s.meta.connection === "desktop" && !agent.sessionConnection) throw acp.RequestError.invalidRequest(undefined, "Enable Codex desktop synchronization to reopen this desktop-linked conversation");
    // A remembered desktop session must never start ACP merely because desktop
    // has not started yet. Its saved log is independent of the owner's readiness.
    if (s.meta.connection !== "desktop") await agent.ensureStarted();
    if (s.meta.connection === "desktop" ? agent.sessionConnected?.(s.meta.backendId) : s.backendGen === agent.generation) return agent;
    if (!s.activating) {
      s.activating = this.activate(s, agent, allowDisconnected).finally(() => {
        s.activating = undefined;
      });
    }
    await s.activating;
    if (s.meta.connection === "desktop" && !allowDisconnected && !agent.sessionConnected?.(s.meta.backendId)) {
      throw acp.RequestError.invalidRequest(undefined, "Codex desktop is disconnected. Open this chat in Codex desktop; the bridge will reconnect automatically");
    }
    return agent;
  }

  private async activate(s: BridgeSession, agent: AgentBackend, allowDisconnected = false): Promise<void> {
    const caps = agent.capabilities;
    const base = { sessionId: s.meta.backendId, cwd: s.meta.cwd, mcpServers: [], ...(s.meta.connection === "desktop" ? { _meta: { codeaw: { connection: "desktop", allowDisconnected } } } : {}) };
    const lastMode = modeOf(s.meta);
    let resp: any;
    if (s.meta.connection === "desktop" || caps?.sessionCapabilities?.resume) {
      resp = await agent.request("session/resume", base);
    } else if (caps?.loadSession) {
      // We already have the history; drop the agent's replay.
      s.suppressUpdates = true;
      try {
        resp = await agent.request("session/load", base);
      } finally {
        s.suppressUpdates = false;
      }
    } else {
      throw acp.RequestError.invalidRequest(undefined, `${agent.config.name} cannot reopen sessions after a restart`);
    }
    s.backendGen = agent.generation;
    this.applySetup(s, resp);
    // The owner's next snapshot supplies its current settings. Saved bridge
    // settings must not overwrite changes made on desktop while disconnected.
    if (s.meta.connection === "desktop") return;
    // Some agents (Codex) reset the mode on resume; put back what the user had.
    const nowMode = modeOf(s.meta);
    if (lastMode && nowMode && lastMode !== nowMode) {
      const modeOpt = s.meta.configOptions?.find((o: any) => o.category === "mode" || o.id === "mode") as any;
      try {
        if (modeOpt) {
          const r = await agent.request<any>("session/set_config_option", { sessionId: s.meta.backendId, configId: modeOpt.id, value: lastMode });
          this.applySetup(s, r);
        } else {
          await agent.request("session/set_mode", { sessionId: s.meta.backendId, modeId: lastMode });
          this.applySetup(s, { modes: { ...s.meta.modes, currentModeId: lastMode } });
        }
      } catch (err) {
        log.warn(`could not restore mode ${lastMode} for ${s.id}: ${errorMessage(err)}`);
      }
    }
  }

  private async importNative(id: string, cwd: string | undefined): Promise<BridgeSession> {
    const { agentId, backendId } = parseExtId(id);
    const agent = this.requireAgent(agentId);
    await agent.ensureStarted();
    const info = this.nativeInfo.get(id);
    const sessionCwd = info?.cwd ?? cwd;
    if (!sessionCwd) throw acp.RequestError.invalidParams(undefined, "cwd is required to open this session");
    const existing = this.sessions.get(id);
    const s =
      existing ??
      this.createSession({ id, agentId, backendId, cwd: sessionCwd, origin: "native", title: info?.title ?? undefined });
    s.entries = [];
    s.midRun = undefined;
    const caps = agent.capabilities;
    const base = { sessionId: backendId, cwd: sessionCwd, mcpServers: [], ...(s.meta.connection === "desktop" ? { _meta: { codeaw: { connection: "desktop" } } } : {}) };
    let resp: any;
    if (caps?.loadSession) resp = await agent.request("session/load", base);
    else if (caps?.sessionCapabilities?.resume) resp = await agent.request("session/resume", base);
    else throw acp.RequestError.invalidRequest(undefined, `${agent.config.name} cannot open existing sessions`);
    s.backendGen = agent.generation;
    s.stale = false;
    this.applySetup(s, resp);
    this.saveMeta(s, true);
    log.info(`imported ${id} (${s.meta.lastSeq} events)`);
    return s;
  }

  /** Finds a session in memory, on disk, or imports it from the agent's own history. */
  private async sessionForAttach(id: string, cwd?: string): Promise<BridgeSession> {
    if (this.store.isDeleted(id) || this.deleting.has(id)) throw acp.RequestError.invalidRequest(undefined, "This chat has been deleted from Codeaw");
    const s = this.sessions.get(id) ?? this.fromDisk(id);
    if (s && (s.meta.connection === "desktop" || !s.stale)) {
      if (s.meta.connection === "desktop") {
        s.stale = false; // The authoritative desktop snapshot rebuilds history when it arrives.
        await this.ensureActive(s, true);
      } else if (s.meta.origin === "native" && s.backendGen === 0) await this.ensureActive(s);
      return s;
    }
    if (s?.stale && (s.turn || s.pending.size > 0)) return s;
    let p = this.importing.get(id);
    if (!p) {
      p = (async () => {
        if (s?.stale) await this.resetLog(s);
        return this.importNative(id, cwd ?? s?.meta.cwd);
      })().finally(() => this.importing.delete(id));
      this.importing.set(id, p);
    }
    return p;
  }

  private async resetLog(s: BridgeSession): Promise<void> {
    const agent = this.requireAgent(s.meta.agentId);
    if ((s.meta.connection === "desktop" || s.backendGen === agent.generation) && agent.capabilities?.sessionCapabilities?.close) {
      try {
        await agent.request("session/close", { sessionId: s.meta.backendId });
      } catch {
        // not live anyway
      }
    }
    s.backendGen = 0;
    this.store.truncate(s.id);
    s.entries = [];
    s.meta = { ...s.meta, lastSeq: 0, epoch: newEpoch() };
    s.emitted = undefined;
    s.midRun = undefined;
  }

  private attach(c: ClientHandle, s: BridgeSession, replay?: { mode: "full" } | { mode: "delta"; afterSeq: number }): Promise<void> {
    const entries = this.ensureEntries(s);
    s.subscribers.add(c);
    this.attachedTo.get(c)?.add(s);
    s.lastActivity = Date.now();
    if (replay) {
      const page = replay.mode === "delta" ? { entries: entries.filter((e) => e.seq > replay.afterSeq) } : this.replayPage(c, s, compactGroups(entries));
      void c.notify("_codeaw/replay", { sessionId: s.id, mode: replay.mode, epoch: s.meta.epoch, lastSeq: s.meta.lastSeq, ...beforeOf(page) });
      for (const e of page.entries) this.sendEntry(c, s, this.historyEntry(c, s, e));
    }
    // Open requests go out after the response to load/resume (and after the replay).
    setImmediate(() => {
      for (const pr of s.pending.values()) this.dispatch(s, pr, c);
    });
    return c.flush();
  }

  private requireLoaded(id: unknown): BridgeSession {
    if (typeof id !== "string") throw acp.RequestError.invalidParams(undefined, "sessionId is required");
    if (this.store.isDeleted(id) || this.deleting.has(id)) throw acp.RequestError.invalidRequest(undefined, "This chat has been deleted from Codeaw");
    const s = this.sessions.get(id) ?? this.fromDisk(id);
    if (!s) throw acp.RequestError.invalidParams(undefined, `Unknown session ${id}; load it first`);
    return s;
  }

  uploadCwd(id: unknown): string { return this.requireLoaded(id).meta.cwd; }

  // ───────────────────────────── client → bridge ─────────────────────────────

  async newSession(c: ClientHandle, params: acp.NewSessionRequest): Promise<acp.NewSessionResponse> {
    const m = codeawMeta(params as any);
    const agentId: string = m.agentId ?? (this.registry.ids().length === 1 ? this.registry.ids()[0] : undefined);
    if (!agentId) throw acp.RequestError.invalidParams(undefined, "_meta.codeaw.agentId is required");
    const agent = this.requireAgent(agentId);
    await agent.ensureStarted();
    const projectless = m.projectless === true;
    const cwd = projectless ? this.store.createChatDirectory() : params.cwd;
    const req: Record<string, unknown> = { cwd, mcpServers: [] };
    if (!projectless && params.additionalDirectories?.length && agent.capabilities?.sessionCapabilities?.additionalDirectories) {
      req.additionalDirectories = params.additionalDirectories;
    }
    let resp: any;
    let s: BridgeSession;
    try {
      resp = await agent.request<any>("session/new", req);
      s = this.createSession({ id: extId(agentId, resp.sessionId), agentId, backendId: resp.sessionId, cwd, ...(projectless ? { projectless: true } : {}), origin: "bridge" });
    } catch (error) {
      if (projectless) this.store.discardEmptyChatDirectory(cwd);
      throw error;
    }
    s.backendGen = agent.generation;
    this.applySetup(s, resp);
    this.flushOrphans(s);
    const initial = m.initialConfig && typeof m.initialConfig === "object" ? (m.initialConfig as Record<string, unknown>) : {};
    for (const [configId, value] of Object.entries(initial)) {
      try {
        await this.applyConfigOption(s, agent, configId, value);
      } catch (err) {
        log.warn(`initial ${configId}=${String(value)} failed for ${s.id}: ${errorMessage(err)}`);
      }
    }
    await this.attach(c, s);
    this.activity(s);
    const { models: _models, sessionId: _sid, configOptions: _co, modes: _modes, _meta: agentMeta, ...rest } = resp;
    const view = this.setupView(s) as any;
    return { ...rest, sessionId: s.id, ...view, _meta: { ...(agentMeta ?? {}), ...view._meta } } as acp.NewSessionResponse;
  }

  async loadSession(c: ClientHandle, params: acp.LoadSessionRequest): Promise<acp.LoadSessionResponse> {
    const s = await this.sessionForAttach(params.sessionId, params.cwd);
    const m = codeawMeta(params as any);
    let history = this.history.get(c);
    if (!history) this.history.set(c, history = new Map());
    const options = historyOptions(m);
    if (options) history.set(s.id, options); else history.delete(s.id);
    const delta =
      typeof m.afterSeq === "number" && m.epoch === s.meta.epoch && m.afterSeq >= 0 && m.afterSeq <= s.meta.lastSeq &&
      !preferFullReplay(this.ensureEntries(s), m.afterSeq, options);
    await this.attach(c, s, delta ? { mode: "delta", afterSeq: m.afterSeq } : { mode: "full" });
    return this.setupView(s) as acp.LoadSessionResponse;
  }

  async resumeSession(c: ClientHandle, params: acp.ResumeSessionRequest): Promise<acp.ResumeSessionResponse> {
    const s = await this.sessionForAttach(params.sessionId, params.cwd);
    await this.attach(c, s);
    return this.setupView(s) as acp.ResumeSessionResponse;
  }

  async listSessions(_c: ClientHandle, params: acp.ListSessionsRequest): Promise<acp.ListSessionsResponse> {
    const filter: string | undefined = codeawMeta(params as any).agentId;
    let cursors: Record<string, string> | undefined;
    if (params.cursor) {
      try {
        cursors = JSON.parse(Buffer.from(params.cursor, "base64url").toString("utf8"));
      } catch {
        throw acp.RequestError.invalidParams(undefined, "Invalid cursor");
      }
    }
    const agents = this.registry.all().filter((a) => (!filter || a.id === filter) && (!cursors || a.id in cursors));
    const errors: { agentId: string; message: string }[] = [];
    const next: Record<string, string> = {};
    const out = new Map<string, acp.SessionInfo>();

    await Promise.all(
      agents.map(async (agent) => {
        try {
          await agent.ensureStarted();
          if (!agent.capabilities?.sessionCapabilities?.list) return;
          const r = await agent.request<acp.ListSessionsResponse>("session/list", {
            ...(params.cwd ? { cwd: params.cwd } : {}),
            ...(cursors?.[agent.id] ? { cursor: cursors[agent.id] } : {}),
          });
          if (r.nextCursor) next[agent.id] = r.nextCursor;
          for (const info of r.sessions ?? []) {
            const id = extId(agent.id, info.sessionId);
            if (this.store.isDeleted(id) || this.deleting.has(id)) continue;
            this.nativeInfo.set(id, info);
            out.set(id, { ...info, sessionId: id });
          }
        } catch (err) {
          errors.push({ agentId: agent.id, message: errorMessage(err) });
        }
      }),
    );

    // Sessions only the bridge knows about (agent doesn't list them, or hasn't written them yet).
    if (!cursors) {
      const metas = new Map<string, SessionMeta>();
      for (const meta of this.store.listMetas()) metas.set(meta.id, meta);
      for (const s of this.sessions.values()) metas.set(s.id, s.meta);
      for (const meta of metas.values()) {
        if (this.store.isDeleted(meta.id) || this.deleting.has(meta.id)) continue;
        if (out.has(meta.id) || (filter && meta.agentId !== filter) || !this.registry.has(meta.agentId)) continue;
        if (params.cwd && meta.cwd !== params.cwd) continue;
        out.set(meta.id, { sessionId: meta.id, cwd: meta.cwd, title: meta.title ?? null, updatedAt: meta.updatedAt });
      }
    }

    const sessions = [...out.values()].map((info) => {
      const s = this.sessions.get(info.sessionId);
      const meta = s?.meta ?? this.store.readMeta(info.sessionId);
      if (s && meta && info.updatedAt && Date.parse(info.updatedAt) > Date.parse(meta.updatedAt) + 60_000 && !s.turn) {
        s.stale = true; // continued elsewhere (e.g. in a terminal); re-import on next open
      }
      const title = info.title ?? meta?.title ?? null;
      if (s && typeof title === "string" && title !== s.meta.title) {
        s.meta.title = title;
        this.saveMeta(s);
        this.activity(s); // Native list titles must reach unopened chats' Live Activities too.
      }
      return {
        ...info,
        title,
        updatedAt: meta && (!info.updatedAt || meta.updatedAt > info.updatedAt) ? meta.updatedAt : info.updatedAt,
        _meta: {
          ...(info._meta ?? {}),
          codeaw: {
            agentId: parseExtId(info.sessionId).agentId,
            state: s?.state ?? "idle",
            pending: s?.pending.size ?? 0,
            queued: s?.queue.length ?? 0,
            lastSeq: meta?.lastSeq ?? 0,
            known: !!meta,
            projectless: meta?.projectless === true,
            ...(meta?.connection === "desktop" ? { connection: "desktop", desktopConnected: s?.desktop?.connected === true } : {}),
          },
        },
      } as acp.SessionInfo;
    });
    sessions.sort((a, b) => (b.updatedAt ?? "").localeCompare(a.updatedAt ?? ""));
    return {
      sessions,
      ...(Object.keys(next).length ? { nextCursor: Buffer.from(JSON.stringify(next)).toString("base64url") } : {}),
      _meta: { codeaw: { errors } },
    };
  }

  async prompt(c: ClientHandle, params: acp.PromptRequest): Promise<acp.PromptResponse> {
    const s = this.requireLoaded(params.sessionId);
    if (!s.subscribers.has(c)) await this.attach(c, s);
    const delivery: string = codeawMeta(params as any).delivery ?? "auto";
    const clientPromptId = codeawMeta(params as any).clientPromptId;
    if (clientPromptId !== undefined && (typeof clientPromptId !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(clientPromptId))) {
      throw acp.RequestError.invalidParams(undefined, "Invalid clientPromptId");
    }
    const promptId = clientPromptId ?? crypto.randomUUID();
    if (this.dequeueStates(s).get(promptId)?.cancelled) return { stopReason: "cancelled", _meta: { codeaw: { duplicate: true, promptId } } };
    if (this.receiptStates(s).has(promptId)) {
      if (s.turn && s.turn.promptId === promptId) return s.turn.done;
      return { stopReason: "end_turn", _meta: { codeaw: { duplicate: true, promptId } } };
    }
    const agent = await this.ensureActive(s);
    // A removal request can race the asynchronous owner/agent connection.
    if (this.dequeueStates(s).get(promptId)?.cancelled) return { stopReason: "cancelled", _meta: { codeaw: { duplicate: true, promptId } } };
    if (this.receiptStates(s).has(promptId)) {
      if (s.turn && s.turn.promptId === promptId) return s.turn.done;
      return { stopReason: "end_turn", _meta: { codeaw: { duplicate: true, promptId } } };
    }
    const blocks = params.prompt;

    const busy = s.turn !== undefined || (s.desktop?.connected && s.desktop.state !== "idle");
    this.logUserMessage(s, blocks, promptId, { queued: busy, steered: busy && delivery !== "queue" && agent.supportsSteering });
    this.receipt(s, promptId, "received");
    if (busy && delivery !== "queue" && agent.supportsSteering && (s.meta.connection === "desktop" || s.backendGen === agent.generation)) {
      s.steering.add(promptId);
      try {
        const r = await agent.request<any>("_session/steering", {
          sessionId: s.meta.backendId,
          prompt: this.withImageData(blocks),
          _meta: { steering: { idleBehavior: "promptRequired" }, codeaw: { promptId } },
        });
        if (r?.outcome === "injected") {
          this.logUserMessage(s, [{ type: "text", text: "" }], promptId, { queued: false, steered: true });
          this.receipt(s, promptId, "read");
          return s.turn ? s.turn.done : { stopReason: "end_turn" };
        }
      } catch (err) {
        if (s.meta.connection === "desktop") { this.receipt(s, promptId, "failed"); throw err; }
        log.warn(`steering failed for ${s.id}, queueing instead: ${errorMessage(err)}`);
      } finally {
        s.steering.delete(promptId);
      }
      this.logUserMessage(s, [{ type: "text", text: "" }], promptId, { queued: true, steered: false });
    }
    if (busy) {
      return new Promise<acp.PromptResponse>((resolve, reject) => {
        s.queue.push({ promptId, blocks, resolve, reject });
        this.emitState(s);
        // Steering can decline after the previous turn has already finished.
        this.startNext(s);
      });
    }
    return this.runTurn(s, promptId, blocks);
  }

  private runTurn(s: BridgeSession, promptId: string, blocks: acp.ContentBlock[]): Promise<acp.PromptResponse> {
    let resolveDone!: (r: acp.PromptResponse) => void;
    let rejectDone!: (e: unknown) => void;
    const done = new Promise<acp.PromptResponse>((res, rej) => {
      resolveDone = res;
      rejectDone = rej;
    });
    done.catch(() => undefined);
    s.turn = { promptId, startedAt: Date.now(), done };
    s.work.reset();
    s.completedTurn = undefined;
    s.stopReason = undefined;
    this.emitState(s);
    void (async () => {
      let result: acp.PromptResponse | undefined;
      let error: unknown;
      try {
        const agent = await this.ensureActive(s);
        result = await agent.request<acp.PromptResponse>("session/prompt", { sessionId: s.meta.backendId, prompt: this.withImageData(blocks), _meta: { codeaw: { promptId } } });
      } catch (err) {
        error = err;
      }
      const completedTurn = s.turn && { promptId: s.turn.promptId, startedAt: s.turn.startedAt, endedAt: Date.now() };
      s.turn = undefined;
      if (this.shuttingDown) { rejectDone(toRequestError(error ?? new Error("Bridge stopped"))); return; }
      if (result) {
        if (result.stopReason !== "cancelled") this.receipt(s, promptId, "read");
        this.emitState(s, result.stopReason, completedTurn);
        this.push(s, "turn_end", undefined, () => !s.turn);
        resolveDone(result);
      } else {
        this.receipt(s, promptId, "failed");
        const e = toRequestError(error);
        this.appendEvent(s, { type: "error", message: errorMessage(error), code: e.code });
        this.emitState(s, "error", completedTurn);
        this.push(s, "error", errorMessage(error), () => true);
        rejectDone(e);
      }
      this.startNext(s);
    })();
    return done;
  }

  private startNext(s: BridgeSession): void {
    if (s.turn || (s.desktop?.connected && s.desktop.state !== "idle") || (s.meta.connection === "desktop" && !s.desktop?.connected)) return;
    const next = s.queue.shift();
    if (!next) return;
    this.appendEvent(s, { type: "dequeued", promptId: next.promptId });
    this.runTurn(s, next.promptId, next.blocks).then(next.resolve, next.reject);
  }

  /** Remove one unsent prompt without interrupting a turn or opening the backend. */
  removePrompt(params: { sessionId?: unknown; promptId?: unknown }): { removed: boolean; reason?: "processing" } {
    const s = this.requireLoaded(params.sessionId);
    const promptId = params.promptId;
    if (typeof promptId !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(promptId)) {
      throw acp.RequestError.invalidParams(undefined, "Invalid promptId");
    }
    this.ensureEntries(s);
    const previous = this.dequeueStates(s).get(promptId);
    if (previous?.removed) return { removed: true };
    const dispatched = this.ensureEntries(s).some((entry) => entry.kind === "event" && entry.event.type === "state" && entry.event.turnPromptId === promptId);
    if (this.receiptStates(s).get(promptId) === "read" || dispatched || s.turn?.promptId === promptId || s.steering.has(promptId) || (previous && !previous.cancelled)) {
      return { removed: false, reason: "processing" };
    }
    const index = s.queue.findIndex((q) => q.promptId === promptId);
    const queued = index < 0 ? undefined : s.queue.splice(index, 1)[0];
    // Persist even an unknown id: a late in-flight request must not resurrect it.
    this.appendEvent(s, { type: "dequeued", promptId, cancelled: true, removed: true });
    queued?.resolve({ stopReason: "cancelled" });
    this.emitState(s);
    return { removed: true };
  }

  /**
   * Edits a sent prompt: branches the chat just before it (see fork.ts) and sends the
   * new text there. The original chat is kept unless `replace` hides it from Codeaw.
   * Retrying with the same `clientPromptId` returns the branch created the first time.
   * `dryRun` only reports whether the message can be edited (starting the agent if needed).
   */
  async forkFromMessage(params: { sessionId?: unknown; messageId?: unknown; prompt?: unknown; clientPromptId?: unknown; replace?: unknown; dryRun?: unknown }): Promise<Record<string, unknown>> {
    if (typeof params.messageId !== "string" || !params.messageId) throw acp.RequestError.invalidParams(undefined, "messageId is required");
    if (params.dryRun === true) {
      const { plan } = await this.checkFork(this.requireLoaded(params.sessionId), params.messageId);
      return { ok: true, newSession: !plan.messageId };
    }
    const promptId = params.clientPromptId;
    if (typeof promptId !== "string" || !UUID.test(promptId)) throw acp.RequestError.invalidParams(undefined, "Invalid clientPromptId");
    if (!Array.isArray(params.prompt) || params.prompt.length === 0) throw acp.RequestError.invalidParams(undefined, "prompt is required");
    const replace = params.replace === true;
    const running = this.forking.get(promptId);
    if (running) return running;
    const existing = this.findFork(promptId);
    if (existing) return Promise.resolve(this.forkView(existing, replace));
    const s = this.requireLoaded(params.sessionId);
    const operation = this.fork(s, params.messageId, params.prompt as acp.ContentBlock[], promptId, replace).finally(() => this.forking.delete(promptId));
    this.forking.set(promptId, operation);
    return operation;
  }

  private findFork(promptId: string): BridgeSession | undefined {
    const metas = [...[...this.sessions.values()].map((s) => s.meta), ...this.store.listMetas()];
    const meta = metas.find((m) => m.forkedFrom?.promptId === promptId && !this.store.isDeleted(m.id));
    return meta && (this.sessions.get(meta.id) ?? this.fromDisk(meta.id));
  }

  private forkView(fork: BridgeSession, replace: boolean): Record<string, unknown> {
    const source = fork.meta.forkedFrom?.sessionId;
    return { ...this.setupView(fork), sessionId: fork.id, ...(replace ? { replaced: !!source && this.store.isDeleted(source) } : {}) };
  }

  private async checkFork(s: BridgeSession, messageId: string): Promise<{ plan: ForkPlan; agent: AgentBackend }> {
    if (s.meta.connection === "desktop") throw acp.RequestError.invalidRequest(undefined, "Messages in a Codex desktop chat cannot be edited from Codeaw");
    if (this.isBusy(s)) throw acp.RequestError.invalidRequest(undefined, "Chat is busy; stop the turn before editing a message");
    const plan = planFork(this.ensureEntries(s), messageId);
    const agent = this.requireAgent(s.meta.agentId);
    await (agent.ensureForkRuntime?.() ?? agent.ensureStarted());
    if (plan.messageId && !agent.supportsForkAtMessage) {
      throw acp.RequestError.invalidRequest(undefined, `${agent.config.name} cannot branch from an earlier message; only the first message can be edited`);
    }
    return { plan, agent };
  }

  private isBusy(s: BridgeSession): boolean {
    return s.turn !== undefined || s.state !== "idle" || s.pending.size > 0 || s.queue.length > 0;
  }

  private async fork(s: BridgeSession, messageId: string, prompt: acp.ContentBlock[], promptId: string, replace: boolean): Promise<Record<string, unknown>> {
    const { plan, agent } = await this.checkFork(s, messageId);
    let resp: any;
    if (plan.messageId) {
      resp = await agent.request("session/fork", {
        sessionId: s.meta.backendId, cwd: s.meta.cwd, mcpServers: [],
        _meta: { jetbrains: { air: { fork: { version: 1, messageId: plan.messageId } } } },
      });
    } else {
      resp = await agent.request("session/new", { cwd: s.meta.cwd, mcpServers: [] });
    }
    if (typeof resp?.sessionId !== "string" || !resp.sessionId) throw acp.RequestError.internalError(undefined, "The agent did not return the new session");
    const fork = this.createSession({
      id: extId(s.meta.agentId, resp.sessionId), agentId: s.meta.agentId, backendId: resp.sessionId, cwd: s.meta.cwd,
      ...(s.meta.projectless ? { projectless: true } : {}), origin: "bridge", title: s.meta.title,
      forkedFrom: { sessionId: s.id, messageId, promptId },
    });
    const entries = this.ensureEntries(fork);
    for (const entry of plan.entries) {
      const copy = { ...entry, seq: ++fork.meta.lastSeq } as LogEntry;
      entries.push(copy);
      this.store.append(fork.id, copy);
    }
    // A new session is live right away; a fork is resumed like any reopened chat.
    if (!plan.messageId) fork.backendGen = agent.generation;
    try {
      this.applySetup(fork, resp);
      this.flushOrphans(fork);
      await this.ensureActive(fork);
      await this.restoreSettings(fork, agent, s.meta);
    } catch (err) {
      log.warn(`could not open branch ${fork.id} of ${s.id}: ${errorMessage(err)}`);
      await this.removeChat(fork.id, fork, { native: true });
      throw err;
    }
    this.logUserMessage(fork, prompt, promptId, { queued: false, steered: false });
    this.receipt(fork, promptId, "received");
    void this.runTurn(fork, promptId, prompt);
    this.activity(fork);
    if (replace) {
      if (this.isBusy(s)) log.info(`kept ${s.id}: it became busy while its edited branch was created`);
      else await this.removeChat(s.id, s, { native: false });
    }
    return this.forkView(fork, replace);
  }

  /** Puts the original chat's model, effort, mode and other settings back on a branch. */
  private async restoreSettings(fork: BridgeSession, agent: AgentBackend, source: SessionMeta): Promise<void> {
    for (const wanted of (source.configOptions ?? []) as any[]) {
      if (wanted.type !== "select" && wanted.type !== "boolean") continue;
      const current = fork.meta.configOptions?.find((o: any) => o.id === wanted.id) as any;
      if (!current || current.type !== wanted.type || sameJson(current.currentValue, wanted.currentValue)) continue;
      try {
        await this.applyConfigOption(fork, agent, wanted.id, wanted.currentValue);
      } catch (err) {
        log.warn(`could not restore ${wanted.id} on ${fork.id}: ${errorMessage(err)}`);
      }
    }
    const mode = source.modes?.currentModeId;
    if (!mode || !fork.meta.modes || fork.meta.modes.currentModeId === mode || modeOf(fork.meta) === mode) return;
    try {
      await agent.request("session/set_mode", { sessionId: fork.meta.backendId, modeId: mode });
      this.applySetup(fork, { modes: { ...fork.meta.modes, currentModeId: mode } });
    } catch (err) {
      log.warn(`could not restore mode ${mode} on ${fork.id}: ${errorMessage(err)}`);
    }
  }

  /** Prompts may reuse an image already in the log (e.g. an edited message) by its blob URI. */
  private withImageData(blocks: acp.ContentBlock[]): acp.ContentBlock[] {
    return blocks.map((block: any) => {
      if (block?.type !== "image" || block.data || typeof block.uri !== "string" || !block.uri.startsWith("codeaw-blob:")) return block;
      const blob = this.store.blob(block.uri.slice("codeaw-blob:".length));
      if (!blob) throw acp.RequestError.invalidParams(undefined, "An attached image is no longer stored on this PC; attach it again");
      const { uri: _uri, ...rest } = block;
      return { ...rest, mimeType: block.mimeType ?? blob.mimeType, data: fs.readFileSync(blob.file).toString("base64") };
    });
  }

  async cancel(_c: ClientHandle, params: acp.CancelNotification): Promise<void> {
    const s = this.sessions.get(params.sessionId);
    if (!s) return;
    for (const pr of [...s.pending.values()]) this.settle(s, pr, pr.cancelValue, undefined);
    for (const q of s.queue.splice(0)) {
      this.appendEvent(s, { type: "dequeued", promptId: q.promptId, cancelled: true });
      q.resolve({ stopReason: "cancelled" });
    }
    this.emitState(s);
    if ((s.turn || (s.desktop?.connected && s.desktop.state !== "idle")) && this.registry.has(s.meta.agentId)) {
      const agent = this.requireAgent(s.meta.agentId);
      if (s.meta.connection === "desktop" || s.backendGen === agent.generation) {
        try { await agent.notify("session/cancel", { sessionId: s.meta.backendId }); }
        catch (error) {
          if (s.meta.connection !== "desktop") throw error;
          this.appendEvent(s, { type: "error", message: errorMessage(error) });
        }
      }
    }
  }

  private async applyConfigOption(s: BridgeSession, agent: AgentBackend, configId: string, value: unknown): Promise<any> {
    const r = await agent.request<any>("session/set_config_option", {
      sessionId: s.meta.backendId,
      configId,
      value,
      ...(typeof value === "boolean" ? { type: "boolean" } : {}),
    });
    this.applySetup(s, r);
    return r;
  }

  async setConfigOption(_c: ClientHandle, params: acp.SetSessionConfigOptionRequest): Promise<acp.SetSessionConfigOptionResponse> {
    const s = this.requireLoaded(params.sessionId);
    const agent = await this.ensureActive(s);
    const r = await this.applyConfigOption(s, agent, params.configId, (params as any).value);
    return { ...r, configOptions: s.meta.configOptions ?? r.configOptions };
  }

  async setMode(_c: ClientHandle, params: acp.SetSessionModeRequest): Promise<acp.SetSessionModeResponse> {
    const s = this.requireLoaded(params.sessionId);
    const agent = await this.ensureActive(s);
    const r = await agent.request<any>("session/set_mode", { sessionId: s.meta.backendId, modeId: params.modeId });
    if (s.meta.modes) this.applySetup(s, { modes: { ...s.meta.modes, currentModeId: params.modeId } });
    else this.append(s, { kind: "update", update: { sessionUpdate: "current_mode_update", currentModeId: params.modeId } });
    return r ?? {};
  }

  async closeSession(c: ClientHandle, params: acp.CloseSessionRequest): Promise<acp.CloseSessionResponse> {
    const s = this.requireLoaded(params.sessionId);
    if (s.meta.connection !== "desktop") await this.cancel(c, { sessionId: s.id });
    else {
      for (const queued of s.queue.splice(0)) {
        this.appendEvent(s, { type: "dequeued", promptId: queued.promptId, cancelled: true });
        queued.resolve({ stopReason: "cancelled" });
      }
    }
    await this.releaseBackend(s);
    return {};
  }

  private async releaseBackend(s: BridgeSession): Promise<void> {
    if (!this.registry.has(s.meta.agentId)) return;
    const agent = this.requireAgent(s.meta.agentId);
    if ((s.meta.connection !== "desktop" && s.backendGen !== agent.generation) || !agent.capabilities?.sessionCapabilities?.close) return;
    try {
      await agent.request("session/close", { sessionId: s.meta.backendId });
    } catch (err) {
      log.debug(`close ${s.id}: ${errorMessage(err)}`);
    }
    s.backendGen = 0;
  }

  async deleteSession(_c: ClientHandle, params: acp.DeleteSessionRequest): Promise<acp.DeleteSessionResponse> {
    const id = params.sessionId;
    const { backendId } = parseExtId(id);
    if (!backendId) throw acp.RequestError.invalidParams(undefined, "sessionId is required");
    if (this.store.isDeleted(id)) return {};
    if (this.deleting.has(id)) throw acp.RequestError.invalidRequest(undefined, "Chat deletion is already in progress");
    let s = this.sessions.get(id) ?? this.fromDisk(id);
    if (!s && this.nativeInfo.has(id)) s = await this.sessionForAttach(id);
    if (!s) throw acp.RequestError.invalidParams(undefined, "Unknown session; list or load it before deletion");
    if (s?.meta.connection === "desktop") await this.ensureActive(s);
    if (this.store.isDeleted(id)) return {};
    if (this.deleting.has(id)) throw acp.RequestError.invalidRequest(undefined, "Chat deletion is already in progress");
    if (s && (s.turn || s.state !== "idle" || s.pending.size || s.queue.length)) {
      throw acp.RequestError.invalidRequest(undefined, "Chat is busy; stop the turn before deleting it");
    }
    await this.removeChat(id, s, { native: true });
    return {};
  }

  /**
   * Removes a chat from Codeaw and leaves a deletion marker. `native: false` keeps the
   * agent's own history (a chat replaced by an edited branch).
   */
  private async removeChat(id: string, s: BridgeSession | undefined, opts: { native: boolean }): Promise<void> {
    const { agentId, backendId } = parseExtId(id);
    this.deleting.add(id);
    try {
      if (s) await this.releaseBackend(s);
      // Desktop close only detaches our follower; the desktop conversation is retained.
      if (opts.native && s?.meta.connection !== "desktop") {
        try {
          const agent = this.requireAgent(agentId);
          await agent.ensureStarted();
          if (agent.capabilities?.sessionCapabilities?.delete) await agent.request("session/delete", { sessionId: backendId });
        } catch (err) {
          log.debug(`native delete ${id}: ${errorMessage(err)}`);
        }
      }
      if (s) {
        if (s.metaTimer) clearTimeout(s.metaTimer);
        if (s.workTimer) clearTimeout(s.workTimer);
        for (const sub of s.subscribers) this.attachedTo.get(sub)?.delete(s);
      }
      this.store.delete(id);
      this.sessions.delete(id);
      this.nativeInfo.delete(id);
      this.orphans.delete(id);
      for (const client of this.clients) void client.notify("_codeaw/activity", { sessionId: id, agentId, deleted: true });
    } finally {
      this.deleting.delete(id);
    }
  }

  async reimport(sessionId: string): Promise<{ epoch: string }> {
    const s = this.requireLoaded(sessionId);
    if (s.turn || s.pending.size > 0) throw acp.RequestError.invalidRequest(undefined, "Session is busy; try again when it is idle");
    s.stale = true;
    const subscribers = [...s.subscribers];
    const fresh = await this.sessionForAttach(sessionId, s.meta.cwd);
    for (const c of subscribers) await this.attach(c, fresh, { mode: "full" });
    return { epoch: fresh.meta.epoch };
  }

  /** Every cwd the bridge knows about; the file browser may read below these. */
  knownCwds(): string[] {
    const set = new Set<string>();
    for (const s of this.sessions.values()) set.add(s.meta.cwd);
    for (const info of this.nativeInfo.values()) if (info.cwd) set.add(info.cwd);
    return [...set];
  }

  sessionCwd(id: string): string | undefined {
    return (this.sessions.get(id) ?? this.fromDisk(id))?.meta.cwd;
  }

  // ───────────────────────────── push & housekeeping ─────────────────────────────

  private push(s: BridgeSession, kind: PushKind, detail: string | undefined, stillRelevant: () => boolean): void {
    if (!this.notifier?.enabled) return;
    const agentName = this.registry.has(s.meta.agentId) ? this.requireAgent(s.meta.agentId).config.name : s.meta.agentId;
    this.notifier.schedule({ kind, sessionId: s.id, agentName, sessionTitle: s.meta.title, detail, stillRelevant });
  }

  async sweep(now = Date.now()): Promise<void> {
    for (const [id, list] of this.orphans) {
      const kept = list.filter((o) => now - o.at < ORPHAN_TTL_MS);
      if (kept.length) this.orphans.set(id, kept);
      else this.orphans.delete(id);
    }
    for (const s of this.sessions.values()) {
      const idle = !s.turn && s.pending.size === 0 && s.subscribers.size === 0 && s.queue.length === 0;
      if (!idle || now - s.lastActivity < this.opts.idleSessionCloseMs) continue;
      if (s.backendGen) await this.releaseBackend(s);
      s.entries = undefined; // reloaded from disk on next attach
    }
    for (const agent of this.registry.all()) {
      if (!agent.running || agent.inflight > 0) continue;
      const live = [...this.sessions.values()].some((s) => s.meta.agentId === agent.id && s.backendGen === agent.generation);
      if (!live && now - agent.lastUsed > this.opts.idleAgentStopMs) await agent.stop("idle");
    }
  }
}
