import type * as acp from "@agentclientprotocol/sdk";

interface ChildSession {
  sessionId: string;
  rootSessionId: string;
  threadId: string;
  toolCallId: string;
  parentToolCallId?: string;
  input: Record<string, unknown>;
  state: string;
}

const CHILD_ACTIVITY = new Set(["agent_message_chunk", "agent_thought_chunk", "tool_call", "tool_call_update"]);

/** Translate native ACP child sessions before the stable SDK validates updates. */
export class AcpSubagents {
  private readonly children = new Map<string, ChildSession>();
  private readonly current = new Map<string, ChildSession>();

  clear(rootSessionId?: string): void {
    if (rootSessionId === undefined) {
      this.children.clear();
      this.current.clear();
      return;
    }
    for (const [id, child] of this.children) {
      if (child.rootSessionId === rootSessionId) this.children.delete(id);
    }
    for (const [id, child] of this.current) {
      if (child.rootSessionId === rootSessionId) this.current.delete(id);
    }
  }

  transform(message: acp.AnyMessage): acp.AnyMessage[] {
    if (!("method" in message)) return [message];
    if (message.method === "session/update") {
      return this.update(message.params as acp.SessionNotification).map((params) => ({ ...message, params }));
    }
    if (message.method === "session/request_permission" || message.method === "elicitation/create") {
      const params = message.params as Record<string, any>;
      const child = this.children.get(params?.sessionId);
      if (child) {
        return [{ ...message, params: {
          ...params, sessionId: child.rootSessionId,
          ...(params.toolCall ? { toolCall: this.tool(child, params.toolCall) } : {}),
          _meta: { ...params._meta, parentToolCallId: child.toolCallId },
        } }];
      }
    }
    return [message];
  }

  private update(params: acp.SessionNotification): acp.SessionNotification[] {
    const update = params.update as any;
    // Current ACP uses patch-style subagent_update; Codex 2.1 also uses the
    // earlier spawned/state_update representation. Accept both at this edge.
    if (update?.sessionUpdate === "subagent_update") {
      const child = this.children.get(update.sessionId);
      if (!child) return this.announce(params.sessionId, update.sessionId, update.title, update.description, this.stateOf(update.state));
      if (this.current.get(this.key(child)) !== child) return [];
      if (update.title !== undefined) child.input.name = update.title;
      if (update.description !== undefined) child.input.prompt = update.description;
      if (update.state !== undefined) child.state = this.stateOf(update.state);
      return [this.report(child, false)];
    }
    if (update?.sessionUpdate === "subagent_spawned") {
      return this.announce(params.sessionId, update.subagentSessionId, update.name, update.task, "running");
    }
    if (update?.sessionUpdate === "subagent_state_update") {
      const child = this.children.get(update.subagentSessionId);
      if (!child || this.current.get(this.key(child)) !== child) return [];
      // Only child lifecycle reports can finish the delegation card.
      const state = update.state;
      if (!["running", "pending", "completed", "failed", "cancelled", "disconnected"].includes(state)) return [];
      child.state = state;
      return [this.report(child, false)];
    }
    const child = this.children.get(params.sessionId);
    if (!child) return [params];
    if (this.current.get(this.key(child)) !== child || !CHILD_ACTIVITY.has(update?.sessionUpdate)) return [];
    const attributed = update.sessionUpdate === "tool_call" || update.sessionUpdate === "tool_call_update"
      ? this.tool(child, update)
      : {
        ...update,
        ...(update.messageId ? { messageId: `${child.sessionId}:${update.messageId}` } : {}),
        _meta: this.metadata(child, update._meta),
      };
    return [{ ...params, sessionId: child.rootSessionId, update: attributed }];
  }

  private key(child: ChildSession): string {
    return JSON.stringify([child.rootSessionId, child.threadId]);
  }

  private announce(parentId: string, id: unknown, name: unknown, task: unknown, state: string): acp.SessionNotification[] {
    if (typeof id !== "string" || !id.trim() || id === parentId || this.children.has(id)) return [];
    const parent = this.children.get(parentId);
    if (parent && this.current.get(this.key(parent)) !== parent) return [];
    const threadId = id.replace(/:generation:\d+$/, "");
    const child: ChildSession = {
      sessionId: id, rootSessionId: parent?.rootSessionId ?? parentId,
      threadId, toolCallId: `subagent:${threadId}`, parentToolCallId: parent?.toolCallId, state,
      input: { name, prompt: task, receiverThreadIds: [threadId], agentThreadId: threadId },
    };
    this.children.set(id, child);
    this.current.set(this.key(child), child);
    return [this.report(child, true)];
  }

  private stateOf(state: any): string {
    if (state?.state === "running") return "running";
    if (state?.state === "requires_action") return "pending";
    if (state?.state === "idle") return state.stopReason === "cancelled" ? "cancelled" : "completed";
    return "unknown";
  }

  private report(child: ChildSession, created: boolean): acp.SessionNotification {
    return { sessionId: child.rootSessionId, update: {
      sessionUpdate: created ? "tool_call" : "tool_call_update", toolCallId: child.toolCallId,
      title: "spawnAgent", kind: "other",
      status: child.state === "running" || child.state === "pending" ? "in_progress" : child.state === "failed" ? "failed" : "completed",
      rawInput: { ...child.input, agentsStates: { [child.threadId]: { status: child.state } } },
      ...(child.parentToolCallId ? { _meta: { parentToolCallId: child.parentToolCallId } } : {}),
    } };
  }

  private tool(child: ChildSession, update: Record<string, any>): Record<string, any> {
    return {
      ...update, toolCallId: `subagent:${child.sessionId}:${update.toolCallId}`,
      _meta: this.metadata(child, update._meta),
    };
  }

  private metadata(child: ChildSession, meta: any): Record<string, unknown> {
    const parent = meta?.claudeCode?.parentToolUseId ?? meta?.parentToolCallId;
    const owner = parent ? `subagent:${child.sessionId}:${parent}` : child.toolCallId;
    return {
      ...meta, parentToolCallId: owner,
      ...(meta?.claudeCode ? { claudeCode: { ...meta.claudeCode, parentToolUseId: owner } } : {}),
    };
  }
}
