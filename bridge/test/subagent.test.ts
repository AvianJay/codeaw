import { describe, expect, it } from "vitest";
import { bridgeClientCapabilities } from "../src/backend/agent-process.js";
import { compactLog } from "../src/session/compact.js";
import { parentToolCallId } from "../src/session/subagent.js";
import { newFakeSession, promptText, rawLog, startTestBridge, TestClient } from "./helpers.js";
import { reduce } from "./reduce.js";

describe("subagent transcripts", () => {
  it("opts into attributed transcripts without negotiating unsupported native child sessions", () => {
    const capabilities = bridgeClientCapabilities();
    expect(capabilities._meta?.["subagent-transcript"]).toBe(true);
    expect(capabilities._meta?.terminal_output).toBe(true);
    expect(capabilities).not.toHaveProperty("subagents");
  });

  it("keeps parallel message owners and child tool metadata intact through reconnect", async () => {
    const tb = await startTestBridge();
    let a: TestClient | undefined;
    let b: TestClient | undefined;
    try {
      a = await TestClient.connect(tb.url, tb.tokenFor("A"));
      const session = await newFakeSession(a, tb.home);
      await a.request("session/prompt", promptText(session.sessionId, "subagents"));
      const raw = rawLog(tb, session.sessionId);
      const root = raw.filter((m) => m.params.update?.content?.text === "Root only")[0].params.update;
      const child = raw.filter((m) => m.params.update?.content?.text === "Child only")[0].params.update;
      expect(root._meta.codeaw.mid).not.toBe(child._meta.codeaw.mid);
      b = await TestClient.connect(tb.url, tb.tokenFor("B"));
      await b.request("session/load", { sessionId: session.sessionId, cwd: tb.home, mcpServers: [] });
      const replay = b.log(session.sessionId);
      expect(reduce(replay)).toEqual(reduce(raw));
      const messages = replay.filter((m) => m.params.update?.sessionUpdate === "agent_message_chunk");
      expect(messages.filter((m) => !parentToolCallId(m.params.update)).map((m) => m.params.update.content.text)).toEqual(["Main answer", "Root only"]);
      expect(messages.filter((m) => parentToolCallId(m.params.update)).map((m) => m.params.update.content.text)).toEqual(["Child answer", "Child only continued"]);
      const tool = replay.find((m) => m.params.update?.toolCallId === "child-read")!.params.update;
      expect(tool.status).toBe("completed");
      expect(parentToolCallId(tool)).toBe("delegate");
    } finally {
      a?.close();
      b?.close();
      await tb.stop();
    }
  });

  it("does not merge old log chunks sharing a mid across subagents", () => {
    const entries = [undefined, "a", "b", "a"].map((parent, index) => ({
      kind: "update" as const, seq: index + 1, t: index,
      update: { sessionUpdate: "agent_message_chunk" as const, content: { type: "text" as const, text: `${index}` }, _meta: { codeaw: { mid: "shared" }, ...(parent ? { claudeCode: { parentToolUseId: parent } } : {}) } },
    }));
    const result = compactLog(entries);
    expect(result.map((e: any) => e.update.content.text)).toEqual(["0", "13", "2"]);
    expect(result.map((e: any) => parentToolCallId(e.update))).toEqual([undefined, "a", "b"]);
  });

  it("retains the actual revision of a child-state snapshot after folding later tool updates", () => {
    const entries = [
      { seq: 1, update: { sessionUpdate: "tool_call", toolCallId: "spawn", title: "spawnAgent", rawInput: { agentsStates: { child: { status: "running" } } } } },
      { seq: 2, update: { sessionUpdate: "tool_call", toolCallId: "wait", title: "wait", rawInput: { agentsStates: { child: { status: "completed" } } } } },
      { seq: 3, update: { sessionUpdate: "tool_call_update", toolCallId: "spawn", status: "completed" } },
    ].map((e) => ({ ...e, kind: "update" as const, t: e.seq, update: e.update as any }));
    const result = compactLog(entries) as any[];
    expect(result[0].seq).toBe(3);
    expect(result[0].update._meta.codeaw.agentStatesSeq).toBe(1);
    expect(result[1].update._meta.codeaw.agentStatesSeq).toBe(2);
  });
});
