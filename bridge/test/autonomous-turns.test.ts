import fs from "node:fs";
import path from "node:path";
import type * as acp from "@agentclientprotocol/sdk";
import { afterEach, describe, expect, it, vi } from "vitest";
import { newFakeSession, promptText, rawLog, startTestBridge, TestClient, type TestBridge } from "./helpers.js";

let tb: TestBridge | undefined;
const clients: TestClient[] = [];

afterEach(async () => {
  clients.splice(0).forEach((c) => c.close());
  await tb?.stop();
  tb = undefined;
  vi.restoreAllMocks();
});

async function setup(claude = true) {
  tb = await startTestBridge();
  const agent = tb.bridge.registry.get("fake");
  if (claude) {
    const describe = agent.describe.bind(agent);
    vi.spyOn(agent, "describe").mockImplementation(() => ({ ...describe(),
      agentInfo: { name: "@agentclientprotocol/claude-agent-acp", version: "0.85.0" } }));
  }
  const c = await TestClient.connect(tb.url, tb.tokenFor("phone"));
  clients.push(c);
  const session = await newFakeSession(c, tb.home);
  const id = session.sessionId as string;
  const backendId = id.slice(id.indexOf(":") + 1);
  const emit = (update: object) => tb!.bridge.manager.onUpdate("fake", { sessionId: backendId, update: update as acp.SessionUpdate });
  const snapshot = () => tb!.bridge.manager.activitySnapshot(id)!;
  return { c, id, agent, emit, snapshot };
}

const thought = { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "Checking the triggered task" } };
const usage = { sessionUpdate: "usage_update", used: 100, size: 200_000 };
const result = { ...usage, cost: { amount: 0, currency: "USD" }, _meta: { "_claude/origin": { kind: "task-notification" } } };

describe("Claude autonomous turns", () => {
  it.each(["monitor", "cron"])("reports a %s cycle as running and completes it without inventing a user message", async (trigger) => {
    const { c, id, emit, snapshot } = await setup();
    const receipts = rawLog(tb!, id).filter((e) => e.params.event?.type === "prompt_receipt").length;
    emit({ ...thought, content: { type: "text", text: `Handling ${trigger}` } });
    const running = snapshot();
    expect(running).toMatchObject({ state: "running", work: { phase: "thinking", summary: `Handling ${trigger}` } });
    expect(running.turnPromptId).toMatch(/^[0-9a-f-]{36}$/);
    expect(running.turnStartedAt).toBeTypeOf("number");
    emit({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Done" } });
    emit(result);
    expect(snapshot()).toMatchObject({ state: "idle", completedTurn: { promptId: running.turnPromptId, startedAt: running.turnStartedAt } });
    await c.waitFor(() => c.events(id, "state").at(-1)?.event.state === "idle");
    expect(c.events(id, "state").map((e) => e.event.state)).toEqual(["running", "idle"]);
    expect(c.events(id, "state")[1].event.completedTurn.endedAt).toBeGreaterThanOrEqual(running.turnStartedAt!);
    const log = rawLog(tb!, id);
    expect(log.some((e) => e.params.update?.sessionUpdate === "user_message_chunk")).toBe(false);
    expect(log.filter((e) => e.params.event?.type === "prompt_receipt")).toHaveLength(receipts);
    const activity = c.received.filter((e) => e.method === "_codeaw/activity" && e.params.sessionId === id);
    expect(activity.some((e) => e.params.state === "running" && e.params.turnPromptId === running.turnPromptId)).toBe(true);
  });

  it("keeps a long tool running through streaming usage, rate limits, and child results", async () => {
    const { id, emit, snapshot } = await setup();
    emit({ sessionUpdate: "tool_call", toolCallId: "command", title: "Long command", kind: "execute", status: "in_progress" });
    const running = snapshot();
    expect(running).toMatchObject({ state: "running", work: { phase: "command", summary: "Long command" } });
    emit(usage);
    emit({ ...usage, _meta: { "_claude/rateLimit": { status: "allowed" } } });
    emit({ ...result, _meta: { parentToolCallId: "child" } });
    emit({ sessionUpdate: "tool_call_update", toolCallId: "command", status: "completed" });
    await tb!.bridge.manager.sweep(Date.now() + 24 * 60 * 60_000);
    expect(snapshot()).toMatchObject({ state: "running", turnPromptId: running.turnPromptId, turnStartedAt: running.turnStartedAt });
    // Another device receives the same active cycle and timer.
    const other = await TestClient.connect(tb!.url, tb!.tokenFor("tablet"));
    clients.push(other);
    const loaded = await other.request("session/load", { sessionId: id, cwd: tb!.home, mcpServers: [] });
    expect(loaded._meta.codeaw).toMatchObject({ state: "running", turnPromptId: running.turnPromptId, turnStartedAt: running.turnStartedAt });
    emit(result);
    expect(snapshot().state).toBe("idle");
  });

  it("queues a user prompt until the autonomous cycle ends", async () => {
    const { c, id, emit, snapshot } = await setup();
    emit(thought);
    const backgroundId = snapshot().turnPromptId;
    const queued = c.request("session/prompt", promptText(id, "echo queued"));
    await c.waitFor(() => c.events(id, "state").some((e) => e.event.queued === 1));
    expect(c.text(id)).toBe("");
    emit(result);
    await queued;
    await c.waitFor(() => c.text(id) === "queued" && c.events(id, "state").at(-1)?.event.state === "idle");
    const completed = c.events(id, "state").filter((e) => e.event.completedTurn).map((e) => e.event.completedTurn);
    expect(completed).toHaveLength(2);
    expect(completed[0].promptId).toBe(backgroundId);
    expect(completed[1].promptId).not.toBe(backgroundId);
  });

  it("does not let an autonomous result finish a user-requested turn", async () => {
    const { c, id, emit, snapshot } = await setup();
    const prompted = c.request("session/prompt", promptText(id, "slow 10"));
    await c.waitFor(() => c.text(id).length > 0);
    const running = snapshot();
    emit(result);
    expect(snapshot()).toMatchObject({ state: "running", turnPromptId: running.turnPromptId });
    await prompted;
    await c.waitFor(() => c.events(id, "state").at(-1)?.event.state === "idle");
    expect(c.events(id, "state").map((e) => e.event.state)).toEqual(["running", "idle"]);
  });

  it("allows stopping the autonomous cycle and ignores late terminal tool output", async () => {
    const { c, id, agent, emit, snapshot } = await setup();
    const notify = vi.spyOn(agent, "notify");
    emit(thought);
    await c.notify("session/cancel", { sessionId: id });
    await c.waitFor(() => c.events(id, "state").at(-1)?.event.stopReason === "cancelled");
    expect(notify).toHaveBeenCalledWith("session/cancel", { sessionId: id.slice(id.indexOf(":") + 1) });
    emit({ sessionUpdate: "tool_call_update", toolCallId: "old-command", status: "completed", _meta: { terminal_exit: { exit_code: 0 } } });
    emit(result);
    expect(snapshot()).toMatchObject({ state: "idle", work: { phase: "cancelled" } });
  });

  it("ends the cycle if the agent process exits", async () => {
    const { c, id, agent, emit, snapshot } = await setup();
    emit(thought);
    await agent.stop("test autonomous exit");
    await c.waitFor(() => c.events(id, "state").at(-1)?.event.stopReason === "error");
    expect(snapshot()).toMatchObject({ state: "idle", work: { phase: "error" } });
  });

  it("ignores child work and background tool updates until the parent starts a new cycle", async () => {
    const { emit, snapshot } = await setup();
    emit({ ...thought, _meta: { claudeCode: { parentToolUseId: "delegation" } } });
    emit({ sessionUpdate: "tool_call_update", toolCallId: "monitor", status: "in_progress" });
    emit({ sessionUpdate: "tool_call", toolCallId: "old-command", title: "Finished command", status: "completed" });
    emit({ ...thought, content: { type: "text", text: "" } });
    emit(usage);
    emit(result);
    expect(snapshot().state).toBe("idle");
    emit(thought);
    expect(snapshot().state).toBe("running");
  });

  it("does not infer Claude lifecycle events for other ACP adapters", async () => {
    const { emit, snapshot } = await setup(false);
    emit(thought);
    expect(snapshot().state).toBe("idle");
  });

  it("does not treat imported Claude history as live work", async () => {
    tb = await startTestBridge();
    fs.writeFileSync(path.join(tb.home, "fake-state.json"), JSON.stringify({ native: {
      cwd: tb.home, updatedAt: new Date().toISOString(), mode: "ask", history: [thought],
    } }));
    const agent = tb.bridge.registry.get("fake");
    const describe = agent.describe.bind(agent);
    vi.spyOn(agent, "describe").mockImplementation(() => ({ ...describe(),
      agentInfo: { name: "@agentclientprotocol/claude-agent-acp", version: "0.85.0" } }));
    const c = await TestClient.connect(tb.url, tb.tokenFor("phone"));
    clients.push(c);
    const loaded = await c.request("session/load", { sessionId: "fake:native", cwd: tb.home, mcpServers: [] });
    expect(loaded._meta.codeaw.state).toBe("idle");
    expect(tb.bridge.manager.activitySnapshot("fake:native")!.state).toBe("idle");
    expect(c.events("fake:native", "state").some((e) => e.event.state === "running")).toBe(false);
  });
});
