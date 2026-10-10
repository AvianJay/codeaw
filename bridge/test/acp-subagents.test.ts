import { describe, expect, it } from "vitest";
import type * as acp from "@agentclientprotocol/sdk";
import { AcpSubagents } from "../src/backend/acp-subagents.js";

function update(router: AcpSubagents, sessionId: string, value: Record<string, unknown>): any[] {
  return router.transform({ jsonrpc: "2.0", method: "session/update", params: { sessionId, update: value } })
    .map((message) => (message as acp.AnyNotification).params);
}
function spawn(router: AcpSubagents, id: string, parent = "root"): any[] {
  return update(router, parent, { sessionUpdate: "subagent_spawned", subagentSessionId: id, name: "Providers", task: "Implement providers", capabilities: {} });
}

describe("native ACP subagent translation", () => {
  it("applies current ACP child metadata/state patches without guessing completion", () => {
    const router = new AcpSubagents();
    const [first] = update(router, "root", { sessionUpdate: "subagent_update", sessionId: "child", title: "Providers", description: "Review" });
    expect(first.update.rawInput.agentsStates.child.status).toBe("unknown");
    const [running] = update(router, "root", { sessionUpdate: "subagent_update", sessionId: "child", state: { state: "running" } });
    expect(running.update.rawInput.name).toBe("Providers");
    expect(running.update.rawInput.agentsStates.child.status).toBe("running");
    const [renamed] = update(router, "root", { sessionUpdate: "subagent_update", sessionId: "child", title: "New title" });
    expect(renamed.update.rawInput.agentsStates.child.status).toBe("running");
    const [ended] = update(router, "root", { sessionUpdate: "subagent_update", sessionId: "child", state: { state: "idle", stopReason: "cancelled" } });
    expect(ended.update.rawInput.agentsStates.child.status).toBe("cancelled");
    const [unset] = update(router, "root", { sessionUpdate: "subagent_update", sessionId: "child", state: null, title: null });
    expect(unset.update.rawInput.name).toBeNull();
    expect(unset.update.rawInput.agentsStates.child.status).toBe("unknown");
  });

  it("keeps one delegation and finishes only on the child's lifecycle report", () => {
    const router = new AcpSubagents();
    const [started] = spawn(router, "child");
    expect(started.sessionId).toBe("root");
    expect(started.update.rawInput.agentsStates.child.status).toBe("running");
    expect(spawn(router, "child")).toEqual([]);
    const [activity] = update(router, "child", { sessionUpdate: "tool_call", toolCallId: "read", title: "Read providers", status: "completed" });
    expect(activity.update._meta.parentToolCallId).toBe(started.update.toolCallId);
    expect(activity.update.toolCallId).not.toBe(started.update.toolCallId);
    const [ended] = update(router, "root", { sessionUpdate: "subagent_state_update", subagentSessionId: "child", state: "completed" });
    expect(ended.update.toolCallId).toBe(started.update.toolCallId);
    expect(ended.update.rawInput.agentsStates.child.status).toBe("completed");
  });

  it("scopes parallel tool/message IDs and attributes nested children", () => {
    const router = new AcpSubagents();
    spawn(router, "a"); spawn(router, "b");
    const [nested] = spawn(router, "nested", "a");
    expect(nested.sessionId).toBe("root");
    expect(nested.update._meta.parentToolCallId).toBe("subagent:a");
    const tools = ["a", "b", "nested"].map((id) => update(router, id, { sessionUpdate: "tool_call_update", toolCallId: "same", status: "completed" })[0]);
    expect(new Set(tools.map((t) => t.update.toolCallId)).size).toBe(3);
    expect(tools.map((t) => t.update._meta.parentToolCallId)).toEqual(["subagent:a", "subagent:b", "subagent:nested"]);
    const [message] = update(router, "a", { sessionUpdate: "agent_message_chunk", messageId: "same", content: { type: "text", text: "Working" } });
    expect(message.update.messageId).toBe("a:same");
    expect(message.update._meta.parentToolCallId).toBe("subagent:a");
    const [attributed] = update(router, "a", { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Nested tool" }, _meta: { claudeCode: { parentToolUseId: "delegate" } } });
    expect(attributed.update._meta.claudeCode.parentToolUseId).toBe("subagent:a:delegate");
    expect(update(router, "a", { sessionUpdate: "config_option_update", configOptions: [] })).toEqual([]);
  });

  it("reuses the card on resume and ignores late events from its previous generation", () => {
    const router = new AcpSubagents();
    const [first] = spawn(router, "child");
    update(router, "root", { sessionUpdate: "subagent_state_update", subagentSessionId: "child", state: "completed" });
    const [resumed] = spawn(router, "child:generation:2");
    expect(resumed.update.toolCallId).toBe(first.update.toolCallId);
    expect(resumed.update.rawInput.agentsStates.child.status).toBe("running");
    expect(update(router, "root", { sessionUpdate: "subagent_state_update", subagentSessionId: "child", state: "failed" })).toEqual([]);
    expect(update(router, "child", { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Late" } })).toEqual([]);
  });

  it("routes child approval/input requests without changing JSON-RPC response IDs", () => {
    const router = new AcpSubagents();
    spawn(router, "child");
    const [permission] = router.transform({ jsonrpc: "2.0", id: 17, method: "session/request_permission", params: { sessionId: "child", toolCall: { toolCallId: "write" }, options: [] } }) as any[];
    expect(permission.id).toBe(17);
    expect(permission.params.sessionId).toBe("root");
    expect(permission.params.toolCall.toolCallId).toBe("subagent:child:write");
    expect(permission.params.toolCall._meta.parentToolCallId).toBe("subagent:child");
    const [question] = router.transform({ jsonrpc: "2.0", id: 18, method: "elicitation/create", params: { sessionId: "child", mode: "form" } }) as any[];
    expect(question.id).toBe(18);
    expect(question.params.sessionId).toBe("root");
  });

  it("clears only the closed root's child routes", () => {
    const router = new AcpSubagents();
    spawn(router, "a", "root-a"); spawn(router, "b", "root-b");
    router.clear("root-a");
    expect(spawn(router, "a", "root-a")).toHaveLength(1);
    router.clear("root-a");
    const msg = { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Hello" } };
    expect(update(router, "a", msg)[0].sessionId).toBe("a");
    expect(update(router, "b", msg)[0].sessionId).toBe("root-b");
  });
});
