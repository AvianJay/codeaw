import { randomUUID } from "node:crypto";
import * as acp from "@agentclientprotocol/sdk";
import type { AgentConfig } from "../config.js";
import type { AgentBackend } from "./backend.js";
import { AgentProcess, type AgentHandlers, type AgentInfo } from "./agent-process.js";
import { CodexDesktopIpc, DesktopIpcRequestError, type DesktopIpcMessage } from "./codex-desktop-ipc.js";
import { applyDesktopPatches, codexInput, inputBlocks, desktopRecordChanges, desktopRequests, projectDesktopConversation, type DesktopRecord, type DesktopState } from "./codex-desktop-state.js";
import { desktopConfigOptions, desktopModels, desktopRestoreMessage, desktopSettingsPatch } from "./codex-desktop-settings.js";
import { desktopAsyncReply, desktopAsyncRequests, type DesktopAsyncQuestion } from "./codex-desktop-questions.js";

interface DesktopSession {
  id: string;
  owner?: string;
  revision: number;
  conversation?: any;
  records?: DesktopRecord[];
  configOptions?: acp.SessionConfigOption[];
  connected: boolean;
  attaching?: Promise<void>;
  loadingHistory?: Promise<void>;
  snapshotWaiters: Set<{ revision: number; resolve: () => void; reject: (error: Error) => void; timer: NodeJS.Timeout }>;
  prompts: Set<{ turnId?: string; clientUserMessageId: string; before: Set<string>; resolve: (response: acp.PromptResponse) => void; reject: (error: Error) => void }>;
  requests: Map<string, AbortController>;
  messagePromptIds?: Map<string, string>;
  steering?: Map<string, { before: Set<string>; blocks: string }>;
  answeredQuestions?: Set<string>;
}

/** Prefer the current desktop owner; retain ACP for sessions the desktop does not own. */
export class CodexDesktopBackend implements AgentBackend {
  readonly ipc: CodexDesktopIpc;
  private readonly acp: AgentProcess;
  private readonly sessions = new Map<string, DesktopSession>();
  private readonly forcedDesktop = new Set<string>();
  private closed = false;
  private lastActivity = Date.now();
  private recoveryTimer?: NodeJS.Timeout;

  constructor(readonly id: string, readonly config: AgentConfig, private readonly handlers: AgentHandlers, logDir: string, startTimeoutMs?: number) {
    this.acp = new AgentProcess(id, config, handlers, logDir, startTimeoutMs);
    this.ipc = new CodexDesktopIpc(typeof config.desktopSync === "object" ? config.desktopSync : {});
    this.ipc.on("message", (message) => this.onMessage(message));
    this.ipc.on("disconnected", () => {
      for (const session of this.sessions.values()) {
        session.connected = false;
        this.rejectWaiting(session, new Error("Codex desktop disconnected; no replacement session was started"));
        this.publishState(session);
      }
      this.scheduleRecovery();
    });
    this.ipc.on("connected", () => {
      if (this.closed) return;
      for (const session of this.sessions.values()) {
        if (!session.attaching) void this.attach(session).catch(() => this.publishState(session));
      }
    });
  }

  get generation(): number { return Math.max(1, this.acp.generation); }
  get running(): boolean { return this.acp.running || this.ipc.connected; }
  get capabilities(): acp.AgentCapabilities | undefined {
    return this.acp.capabilities ?? (this.ipc.connected ? { loadSession: true, promptCapabilities: { image: true }, sessionCapabilities: { list: {}, resume: {}, close: {} } } : undefined);
  }
  get supportsSteering(): boolean { return this.acp.supportsSteering || this.sessions.size > 0; }
  get inflight(): number { return this.acp.inflight + [...this.sessions.values()].reduce((n, session) => n + session.prompts.size, 0); }
  get lastUsed(): number { return Math.max(this.lastActivity, this.acp.lastUsed); }
  describe(): AgentInfo { return { ...this.acp.describe(), ...(this.ipc.connected ? { status: "ready" as const, capabilities: this.capabilities } : {}), steering: this.supportsSteering }; }
  async ensureStarted(): Promise<void> {
    this.closed = false;
    try { await this.ipc.ensureReady(); }
    catch { await this.acp.ensureStarted(); }
  }
  sessionConnection(id: string): "desktop" | "acp" { return this.forcedDesktop.has(id) ? "desktop" : "acp"; }
  sessionConnected(id: string): boolean { return this.sessions.get(id)?.connected === true; }

  async request<T = unknown>(method: string, raw: unknown, options?: acp.SendRequestOptions): Promise<T> {
    try {
      return await this.routeRequest<T>(method, raw, options);
    } catch (error) {
      if (error instanceof acp.RequestError) throw error;
      const message = error instanceof Error ? error.message : "";
      if (/^(Codex desktop|This session is linked to Codex desktop|Reconnect this Codex desktop|This operation is not available)/.test(message)) throw acp.RequestError.invalidRequest(undefined, message);
      throw error;
    }
  }

  private async routeRequest<T = unknown>(method: string, raw: unknown, options?: acp.SendRequestOptions): Promise<T> {
    this.closed = false;
    this.lastActivity = Date.now();
    const params = raw as any;
    const id = params?.sessionId;
    if (typeof id === "string" && params?._meta?.codeaw?.connection === "desktop") this.forcedDesktop.add(id);
    if ((method === "session/load" || method === "session/resume") && typeof id === "string") {
      const force = params?._meta?.codeaw?.connection === "desktop" || this.forcedDesktop.has(id);
      let owner: string | undefined;
      try {
        const response = await this.ipc.request("thread-owner-discovery", { hostId: "local", conversationId: id });
        owner = response.handledByClientId;
      } catch (error) {
        if (force) throw new Error("This session is linked to Codex desktop. Reopen it there to reconnect; no separate session was started");
        if (error instanceof DesktopIpcRequestError && error.response.error !== "no-client-found") throw error;
      }
      if (owner) {
        this.forcedDesktop.add(id);
        let session = this.sessions.get(id);
        if (!session) {
          session = { id, owner, revision: -1, connected: false, snapshotWaiters: new Set(), prompts: new Set(), requests: new Map() };
          this.sessions.set(id, session);
        }
        session.owner = owner;
        await this.attach(session);
        return { configOptions: this.configOptions(session), _meta: { codeaw: { connection: "desktop", desktopConnected: true } } } as T;
      }
      if (force) throw new Error("Codex desktop no longer owns this session. Reopen it on desktop before reconnecting");
    }
    if (typeof id === "string" && this.forcedDesktop.has(id)) {
      const session = this.sessions.get(id);
      if (method === "session/close") {
        if (session) await this.detach(session);
        return {} as T;
      }
      if (!session) throw new Error("Reconnect this Codex desktop session before sending");
      await this.attach(session);
      if (method === "session/prompt") return await this.prompt(session, params.prompt, params._meta?.codeaw?.promptId) as T;
      if (method === "session/set_config_option" || method === "session/set_mode") {
        const patch = desktopSettingsPatch(session.conversation, method === "session/set_mode" ? "mode" : params.configId, method === "session/set_mode" ? params.modeId : params.value);
        const response = await this.ipc.request("thread-follower-update-thread-settings", { conversationId: id, threadSettings: patch }, { targetClientId: session.owner });
        const result = response.result?.result ?? response.result;
        if (result?.applied !== true) throw new Error("Codex desktop did not apply the settings; reconnect and try again");
        // Owner broadcasts are authoritative. Do not claim a change until observed.
        const deadline = Date.now() + (this.ipc.options.timeoutMs ?? 12000);
        while (!this.settingsMatch(session, patch)) {
          const remaining = deadline - Date.now();
          if (remaining <= 0) throw new Error("Codex desktop has not confirmed the changed settings");
          await this.waitForRevision(session, session.revision + 1, remaining);
        }
        return { configOptions: this.configOptions(session) } as T;
      }
      if (method === "_session/steering") {
        return await this.steer(session, codexInput(params.prompt), params._meta?.codeaw?.promptId ?? randomUUID()) as T;
      }
      throw new Error("This operation is not available for a desktop-linked session");
    }
    return this.acp.request<T>(method, raw, options);
  }

  async notify(method: string, raw: unknown): Promise<void> {
    const id = (raw as any)?.sessionId;
    if (method === "session/cancel" && this.forcedDesktop.has(id)) {
      const session = this.sessions.get(id);
      if (!session) return;
      await this.attach(session);
      const state = projectDesktopConversation(session.conversation).state;
      await this.ipc.request("thread-follower-interrupt-turn", { conversationId: id, ...(state.turnId ? { expectedTurnId: state.turnId } : {}) }, { targetClientId: session.owner });
      return;
    }
    await this.acp.notify(method, raw);
  }

  private attach(session: DesktopSession): Promise<void> {
    if (session.connected && this.ipc.connected) return Promise.resolve();
    if (!session.attaching) {
      session.attaching = (async () => {
        await this.ipc.ensureReady();
        const owner = await this.ipc.request("thread-owner-discovery", { hostId: "local", conversationId: session.id });
        if (!owner.handledByClientId) throw new Error("Codex desktop session owner is unavailable");
        session.owner = owner.handledByClientId;
        session.revision = -1;
        const snapshot = this.waitForRevision(session, 0);
        snapshot.catch(() => undefined);
        try {
          await this.follow(session, true);
          await snapshot;
          const state = session.conversation;
          const incomplete = state?.turnHistory?.kind === "canonical" ? state.turnHistory.history?.isComplete === false : state?.turnsPagination?.hasLoadedOldest === false;
          session.connected = true;
          this.ipc.setReconnectWanted(true);
          this.publishState(session);
          // Show the current snapshot immediately; older turns can arrive afterwards.
          if (incomplete && !session.loadingHistory) {
            session.loadingHistory = (async () => {
              const response = await this.ipc.request("thread-follower-load-complete-history", { conversationId: session.id }, { targetClientId: session.owner, timeoutMs: 60000 });
              const result = response.result?.result ?? response.result;
              if (typeof result?.revision === "number") await this.waitForRevision(session, result.revision);
            })().catch(() => {
              this.handlers.onSessionError?.(this.id, session.id, "Older desktop history could not be loaded; reconnect to retry");
            }).finally(() => { session.loadingHistory = undefined; });
          }
        } catch (error) {
          this.rejectWaiting(session, new Error("Codex desktop synchronization failed"));
          session.connected = false;
          this.publishState(session);
          throw error;
        }
      })().finally(() => { session.attaching = undefined; });
      void session.attaching.catch(() => this.scheduleRecovery());
    }
    return session.attaching;
  }

  private waitForRevision(session: DesktopSession, revision: number, timeoutMs?: number): Promise<void> {
    if (session.conversation && session.revision >= revision) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const waiter = { revision, resolve, reject, timer: setTimeout(() => { session.snapshotWaiters.delete(waiter); reject(new Error("Codex desktop snapshot timed out")); }, timeoutMs ?? (this.config.desktopSync && typeof this.config.desktopSync === "object" ? this.config.desktopSync.timeoutMs ?? 12000 : 12000)) };
      session.snapshotWaiters.add(waiter);
    });
  }

  private follow(session: DesktopSession, following: boolean): Promise<void> {
    return this.ipc.broadcast("thread-stream-following-changed", { hostId: "local", conversationId: session.id, following }, session.owner ? [session.owner] : undefined);
  }

  private onMessage(message: DesktopIpcMessage): void {
    if (message.type !== "broadcast") return;
    if (message.method === "client-status-changed" && message.params?.status === "disconnected") {
      for (const session of this.sessions.values()) {
        if (session.owner === message.params.clientId) {
          session.connected = false;
          this.rejectWaiting(session, new Error("Codex desktop session owner disconnected"));
          this.publishState(session);
          this.scheduleRecovery();
        }
      }
      return;
    }
    const params = message.params;
    if (params?.hostId !== "local" || typeof params.conversationId !== "string") return;
    const session = this.sessions.get(params.conversationId);
    if (!session || message.sourceClientId !== session.owner) return;
    if (message.method === "thread-stream-state-changed") {
      if (message.version !== undefined && message.version !== this.ipc.versions[message.method]) {
        session.connected = false;
        this.rejectWaiting(session, new Error("Codex desktop IPC version changed; update the bridge"));
        this.publishState(session);
        return;
      }
      const change = params.change;
      if (!change || typeof change.revision !== "number") return;
      try {
        if (change.type === "snapshot") {
          if (!change.conversationState || typeof change.conversationState !== "object") throw new Error("Invalid desktop snapshot");
          if (session.revision >= change.revision && session.connected) return;
          session.conversation = change.conversationState;
        } else if (change.type === "patches") {
          if (change.revision <= session.revision) return;
          if (!session.conversation || change.baseRevision !== session.revision) {
            void this.follow(session, true).catch(() => this.publishState(session));
            return;
          }
          session.conversation = applyDesktopPatches(session.conversation, change.patches);
        } else return;
        session.revision = change.revision;
        session.connected = true;
        this.project(session);
        for (const waiter of session.snapshotWaiters) {
          if (session.revision >= waiter.revision) { clearTimeout(waiter.timer); session.snapshotWaiters.delete(waiter); waiter.resolve(); }
        }
      } catch {
        session.connected = false;
        void this.follow(session, true).catch(() => this.publishState(session));
      }
    } else if (message.method === "thread-stream-following-status-requested") {
      void this.follow(session, true).catch(() => undefined);
    }
  }

  private project(session: DesktopSession): void {
    let projection = projectDesktopConversation(session.conversation, session.messagePromptIds);
    for (const [promptId, pending] of session.steering ?? []) {
      const messages = new Map<string, acp.ContentBlock[]>();
      for (const record of projection.records) {
        const update = record.update as any;
        if (pending.before.has(record.key) || update.sessionUpdate !== "user_message_chunk" || !update._meta?.codeaw?.steered) continue;
        const blocks = messages.get(update.messageId) ?? [];
        blocks.push(update.content); messages.set(update.messageId, blocks);
      }
      const match = [...messages].find(([key, blocks]) => !session.messagePromptIds?.has(key) && JSON.stringify(blocks) === pending.blocks);
      if (match) {
        (session.messagePromptIds ??= new Map()).set(match[0], promptId);
        session.steering!.delete(promptId);
        projection = projectDesktopConversation(session.conversation, session.messagePromptIds);
      }
    }
    const changes = desktopRecordChanges(session.records, projection.records);
    session.records = projection.records;
    if (changes.reset) this.handlers.onHistoryReset?.(this.id, session.id, changes.updates);
    else for (const update of changes.updates) this.handlers.onUpdate(this.id, { sessionId: session.id, update });
    const configOptions = this.configOptions(session);
    if (changes.reset || JSON.stringify(configOptions) !== JSON.stringify(session.configOptions)) {
      session.configOptions = configOptions;
      this.handlers.onUpdate(this.id, { sessionId: session.id, update: { sessionUpdate: "config_option_update", configOptions } });
    }
    this.publishState(session, projection.state);
    this.syncRequests(session);
    for (const prompt of session.prompts) {
      const turn = projection.turns.find((turn) => turn.turnId === prompt.turnId || turn.params?.clientUserMessageId === prompt.clientUserMessageId);
      if (!turn || ["inProgress", "in_progress", "running", "requires_action"].includes(turn.status)) continue;
      session.prompts.delete(prompt);
      prompt.resolve({ stopReason: ["interrupted", "cancelled"].includes(turn.status) ? "cancelled" : "end_turn" });
    }
  }

  private configOptions(session: DesktopSession): acp.SessionConfigOption[] {
    return desktopConfigOptions(session.conversation, desktopModels(this.ipc.options.modelCatalogPath));
  }

  private settingsMatch(session: DesktopSession, patch: Record<string, unknown>): boolean {
    const settings = session.conversation?.latestThreadSettings ?? {};
    return Object.entries(patch).every(([key, value]) => {
      if (key === "permissions") return value !== null || settings.activePermissionProfile == null;
      // The app may add its own writable artifact roots and mode instructions.
      if (key === "sandboxPolicy") return settings.sandboxPolicy?.type === (value as any).type &&
        ((value as any).networkAccess === undefined || settings.sandboxPolicy?.networkAccess === (value as any).networkAccess);
      if (key === "collaborationMode") {
        const wanted = value as any, actual = settings.collaborationMode;
        return actual?.mode === wanted.mode && actual?.settings?.model === wanted.settings.model && actual?.settings?.reasoning_effort === wanted.settings.reasoning_effort;
      }
      return JSON.stringify(settings[key]) === JSON.stringify(value);
    });
  }

  private publishState(session: DesktopSession, state?: DesktopState): void {
    state ??= session.conversation ? projectDesktopConversation(session.conversation).state : { connection: "desktop", connected: false, state: "idle" };
    this.handlers.onSessionState?.(this.id, session.id, { ...state, connected: session.connected && this.ipc.connected });
  }

  private syncRequests(session: DesktopSession): void {
    const asyncRequests = desktopAsyncRequests(session.conversation).map((request) => ({ ...request,
      params: { questions: request.params.questions.filter((question) => !session.answeredQuestions?.has(question.id)) } })).filter((request) => request.params.questions.length);
    const requests = [...desktopRequests(session.conversation), ...asyncRequests];
    // A partial desktop reply withdraws the old form; unanswered questions reopen.
    const requestKey = (request: any) => JSON.stringify([request.method, request.id,
      ...(request.method === "codeaw/async-question" ? [request.params.questions.map((question: DesktopAsyncQuestion) => question.id)] : [])]);
    const keys = new Set(requests.map(requestKey));
    for (const [key, controller] of session.requests) {
      if (!keys.has(key)) { controller.abort("desktop-resolved"); session.requests.delete(key); }
    }
    for (const request of requests) {
      if (typeof request.id !== "string" && typeof request.id !== "number") continue;
      const key = requestKey(request);
      if (session.requests.has(key)) continue;
      const params = request.params ?? {};
      const controller = new AbortController();
      let answer: Promise<{ method: string; payload: any } | undefined>;
      const approvals: Record<string, string> = {
        "item/commandExecution/requestApproval": "thread-follower-command-approval-decision",
        "item/fileChange/requestApproval": "thread-follower-file-approval-decision",
        "item/permissions/requestApproval": "thread-follower-permissions-request-approval-response",
      };
      const approval = approvals[request.method];
      if (approval) {
        const options: acp.PermissionOption[] = [{ optionId: "allow", name: "允許一次", kind: "allow_once" }, { optionId: "reject", name: "拒絕", kind: "reject_once" }];
        const command = Array.isArray(params.command) ? params.command.join(" ") : params.command;
        const toolCall: acp.ToolCallUpdate = {
          toolCallId: `${params.turnId ?? "turn"}:${params.itemId ?? request.id}`,
          title: command ?? params.reason ?? (request.method.includes("fileChange") ? "批准檔案變更" : "批准工具操作"),
          kind: request.method.includes("commandExecution") ? "execute" : request.method.includes("fileChange") ? "edit" : "other",
          status: "pending", rawInput: command ? { command, cwd: params.cwd } : undefined,
        };
        answer = this.handlers.onPermission(this.id, { sessionId: session.id, toolCall, options }, controller.signal).then((response) => {
          const accepted = response.outcome.outcome === "selected" && response.outcome.optionId === "allow";
          return { method: approval, payload: approval.includes("permissions-request") ? { response: { permissions: accepted ? params.permissions ?? {} : {}, scope: "turn" } } : { decision: accepted ? "accept" : "decline" } };
        });
      } else if (request.method === "codeaw/async-question") {
        const properties = Object.fromEntries(params.questions.map((question: DesktopAsyncQuestion) => [question.id, {
          type: "string", title: question.title, ...(question.options.length ? { enum: question.options, default: question.options[0], _meta: { codeaw: { allowCustom: true } } } : {}),
        }]));
        answer = this.handlers.onElicitation(this.id, { sessionId: session.id, mode: "form", message: "請回答",
          requestedSchema: { type: "object", properties, required: params.questions.map((question: DesktopAsyncQuestion) => question.id) },
          _meta: { codeaw: { async: true, questionIds: params.questions.map((question: DesktopAsyncQuestion) => question.id) } },
        } as any, controller.signal).then((response) => ({ method: "codeaw/async-question", payload: { response, questions: params.questions } }));
      } else if (request.method === "item/tool/requestUserInput" && Array.isArray(params.questions) && !params.questions.some((question: any) => question.isSecret)) {
        const properties = Object.fromEntries(params.questions.map((question: any) => [question.id, {
          type: "string", title: question.header ?? question.question, description: question.question,
          ...(Array.isArray(question.options) && question.options.length ? { oneOf: question.options.map((option: any) => ({ const: option.label, title: option.label, ...(option.description ? { description: option.description } : {}) })),
            ...(question.isOther ? { _meta: { codeaw: { allowCustom: true } } } : {}) } : {}),
        }]));
        answer = this.handlers.onElicitation(this.id, { sessionId: session.id, mode: "form", message: params.questions.map((question: any) => question.question).join("\n"), requestedSchema: { type: "object", properties, required: params.questions.map((question: any) => question.id) } } as any, controller.signal).then((response) => {
          const content = (response as any).content ?? {};
          return { method: "thread-follower-submit-user-input", payload: { response: { answers: Object.fromEntries(params.questions.map((question: any) => [question.id, { answers: response.action === "accept" && typeof content[question.id] === "string" ? [content[question.id]] : [] }])) } } };
        });
      } else if (request.method === "mcpServer/elicitation/request" && params.mode !== "url" && params.requestedSchema) {
        answer = this.handlers.onElicitation(this.id, { sessionId: session.id, mode: "form", message: params.message, requestedSchema: params.requestedSchema } as any, controller.signal).then((response) => ({ method: "thread-follower-submit-mcp-server-elicitation-response", payload: { response } }));
      } else continue;
      session.requests.set(key, controller);
      void answer.then(async (result) => {
        if (!result || controller.signal.aborted || session.requests.get(key) !== controller || !session.connected) return;
        if (result.method === "codeaw/async-question") {
          await this.replyAsync(session, result.payload.questions, result.payload.response);
          return;
        }
        await this.ipc.request(result.method, { conversationId: session.id, requestId: request.id, ...result.payload }, { targetClientId: session.owner });
      }).catch(() => {
        if (!controller.signal.aborted) this.handlers.onSessionError?.(this.id, session.id, "Codex desktop did not confirm the reply. Check desktop before answering again");
      });
    }
  }

  private async steer(session: DesktopSession, input: any[], clientUserMessageId: string, restore?: Record<string, any>): Promise<{ outcome: "promptRequired" | "injected" }> {
    (session.steering ??= new Map()).set(clientUserMessageId, { before: new Set(session.records?.map((r) => r.key)), blocks: JSON.stringify(inputBlocks(input)) });
    const response = await this.ipc.request("thread-follower-steer-turn", { conversationId: session.id, input, attachments: [], clientUserMessageId,
      restoreMessage: restore ?? desktopRestoreMessage(session.conversation, input, clientUserMessageId) }, { targetClientId: session.owner });
    const wrapper = response.result?.result ?? response.result;
    const result = wrapper?.result ?? wrapper;
    if (result === false || result?.outcome === "promptRequired") { session.steering?.delete(clientUserMessageId); return { outcome: "promptRequired" }; }
    if (!result || (typeof result.turnId !== "string" && result !== true && result.outcome !== "injected")) throw new Error("Codex desktop did not confirm steering; check desktop before sending again");
    return { outcome: "injected" };
  }

  private async replyAsync(session: DesktopSession, questions: DesktopAsyncQuestion[], response: any): Promise<void> {
    const reply = desktopAsyncReply(questions, response);
    const blocks: acp.ContentBlock[] = [{ type: "text", text: reply.text }];
    const input = codexInput(blocks);
    const id = randomUUID();
    if (projectDesktopConversation(session.conversation).state.turnId) {
      const restore = desktopRestoreMessage(session.conversation, input, id) as Record<string, any>;
      restore.text = reply.summary;
      restore.context.prompt = reply.summary;
      restore.context.turnTrigger = "send_user_message_async_question";
      const result = await this.steer(session, input, id, restore);
      // Only an explicit idle result permits starting a turn. A timeout might
      // already have delivered the answer, so never retry it as a new prompt.
      if (result.outcome === "promptRequired") await this.prompt(session, blocks, id);
    } else await this.prompt(session, blocks, id);
    for (const question of questions) (session.answeredQuestions ??= new Set()).add(question.id);
    this.syncRequests(session);
  }

  private async prompt(session: DesktopSession, blocks: acp.ContentBlock[], promptId?: string): Promise<acp.PromptResponse> {
    const input = codexInput(blocks);
    const clientUserMessageId = promptId ?? randomUUID();
    const before = new Set(projectDesktopConversation(session.conversation).turns.map((turn) => String(turn.turnId ?? turn.id)));
    let pending!: DesktopSession["prompts"] extends Set<infer T> ? T : never;
    const completed = new Promise<acp.PromptResponse>((resolve, reject) => { pending = { clientUserMessageId, before, resolve, reject }; session.prompts.add(pending); });
    // The result may arrive after a very fast turn's final snapshot.
    completed.catch(() => undefined);
    try {
      const params = (this.ipc.versions["thread-follower-start-turn"] ?? 2) >= 2
        ? { conversationId: session.id, hostId: "local", turnStart: { request: { threadId: session.id, input, clientUserMessageId }, context: { attachments: [], inheritThreadSettings: true } } }
        : { conversationId: session.id, hostId: "local", turnStartParams: { input, attachments: [] } };
      const response = await this.ipc.request("thread-follower-start-turn", params, { targetClientId: session.owner });
      const wrapper = response.result?.result ?? response.result;
      const result = wrapper?.result ?? wrapper;
      pending.turnId = result?.turnId ?? result?.turn?.id ?? result?.id;
      if (!pending.turnId) {
        const turns = projectDesktopConversation(session.conversation).turns;
        pending.turnId = turns.find((turn) => turn.params?.clientUserMessageId === clientUserMessageId)?.turnId ?? turns.findLast((turn) => !before.has(String(turn.turnId ?? turn.id)))?.turnId;
      }
      this.project(session);
      return await completed;
    } catch (error) {
      session.prompts.delete(pending);
      pending.reject(error instanceof Error ? error : new Error("Codex desktop send failed"));
      throw error;
    }
  }

  private rejectWaiting(session: DesktopSession, error: Error): void {
    for (const waiter of session.snapshotWaiters) { clearTimeout(waiter.timer); waiter.reject(error); }
    session.snapshotWaiters.clear();
    for (const prompt of session.prompts) prompt.reject(error);
    session.prompts.clear();
    for (const controller of session.requests.values()) controller.abort();
    session.requests.clear();
  }

  private async detach(session: DesktopSession): Promise<void> {
    if (this.ipc.connected) await this.follow(session, false).catch(() => undefined);
    this.rejectWaiting(session, new Error("Desktop synchronization was detached"));
    session.connected = false;
    this.sessions.delete(session.id);
    this.publishState(session);
    this.ipc.setReconnectWanted(this.sessions.size > 0);
  }

  private scheduleRecovery(): void {
    if (this.closed || this.recoveryTimer || ![...this.sessions.values()].some((session) => !session.connected)) return;
    this.recoveryTimer = setTimeout(() => {
      this.recoveryTimer = undefined;
      for (const session of this.sessions.values()) {
        if (!session.connected && !session.attaching) void this.attach(session).catch(() => this.scheduleRecovery());
      }
    }, 2000);
    this.recoveryTimer.unref();
  }

  async stop(reason?: string): Promise<void> {
    this.closed = true;
    if (this.recoveryTimer) clearTimeout(this.recoveryTimer);
    this.recoveryTimer = undefined;
    for (const session of [...this.sessions.values()]) await this.detach(session);
    this.ipc.close();
    await this.acp.stop(reason);
  }
}
