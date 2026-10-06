import { afterEach, describe, expect, it } from "vitest";
import { compactLog } from "../src/session/compact.js";
import { lazyToolEntry } from "../src/session/history.js";
import type { LogEntry } from "../src/session/types.js";
import { startTestBridge, TestClient, newFakeSession, type TestBridge } from "./helpers.js";

const output = "完整輸出\n".repeat(20_000);
function tool(seq: number, extra: object = {}): LogEntry {
  return { seq, t: seq, kind: "update", update: { sessionUpdate: "tool_call", toolCallId: "tool", title: "Read file", kind: "read", status: "completed",
    rawInput: { command: "Get-Content file" }, content: [{ type: "content", content: { type: "text", text: output } }], rawOutput: { formatted_output: output, exit_code: 0 }, ...extra } } as LogEntry;
}
let bridge: TestBridge | undefined;
const clients: TestClient[] = [];
afterEach(async () => { clients.splice(0).forEach((c) => c.close()); await bridge?.stop(); bridge = undefined; });

describe("lazy tool history", () => {
  it("defers bulky output without changing source log, attribution, status, input or exit code", () => {
    const original = tool(30, { _meta: { parentToolCallId: "parent", codeaw: { toolStatusSeq: 20 } } });
    const projected: any = lazyToolEntry(original);
    expect(projected.update).toMatchObject({ toolCallId: "tool", rawInput: { command: "Get-Content file" }, status: "completed",
      _meta: { parentToolCallId: "parent", codeaw: { toolStatusSeq: 20, deferredTool: { seq: 30, exitCode: 0 } } } });
    expect(projected.update.rawOutput).toBeUndefined();
    expect(projected.update.content).toBeUndefined();
    expect(JSON.stringify(projected).length).toBeLessThan(JSON.stringify(original).length / 100);
    expect((original as any).update.rawOutput.formatted_output).toBe(output);
  });

  it("retains inline collaboration lifecycle reports and marks deferred edit diffs", () => {
    const collaboration = tool(1, { name: "spawn_agent", rawOutput: { agent_id: "child", status: "running", output } });
    expect(lazyToolEntry(collaboration)).toBe(collaboration);
    const states = tool(2, { rawInput: { agentsStates: { child: { status: "completed" } } } });
    expect(lazyToolEntry(states)).toBe(states);
    const edit: any = lazyToolEntry(tool(3, { kind: "edit", content: [{ type: "diff", path: "a", oldText: "", newText: output }] }));
    expect(edit.update._meta.codeaw.deferredTool.hasDiff).toBe(true);
  });

  it("does not mistake ordinary commands mentioning agents or tasks for collaboration", () => {
    for (const title of ["Get-Content agent.md", "rg task src", "npm install spawn-package", "Get-Content subagent.ts", "node send_input-test.js"]) {
      const projected: any = lazyToolEntry(tool(3, { title }));
      expect(projected.update._meta.codeaw.deferredTool).toBeDefined();
      expect(projected.update.content).toBeUndefined();
    }
    for (const name of ["functions.spawn_agent", "Task", "Agent", "collabAgentToolCall"]) {
      const original = tool(4, { name });
      expect(lazyToolEntry(original)).toBe(original);
    }
  });

  it("bounds large inputs, titles and duplicated Claude metadata, retaining originals for expansion", () => {
    const original = tool(30, { title: output, rawInput: { patch: output },
      _meta: { claudeCode: { toolName: "Bash", parentToolUseId: "parent", toolResponse: { stdout: output } }, terminal_output: { data: output } } });
    const projected: any = lazyToolEntry(original);
    expect(Buffer.byteLength(JSON.stringify(projected))).toBeLessThan(1024);
    expect(projected.update.rawInput).toBeUndefined();
    expect(projected.update._meta.claudeCode).toEqual({ toolName: "Bash", parentToolUseId: "parent" });
    expect((original as any).update.rawInput.patch).toBe(output);
    expect((original as any).update._meta.claudeCode.toolResponse.stdout).toBe(output);
    expect(lazyToolEntry(tool(1, { rawInput: { command: "pwd" }, content: [], rawOutput: { output: "small" } }))).toMatchObject({ update: { rawOutput: { output: "small" } } });
    const medium: any = lazyToolEntry(tool(2, { rawOutput: { output: "x".repeat(3000), exitCode: 0 }, content: [{ type: "content", content: { type: "text", text: "x".repeat(3000) } }] }));
    expect(medium.update._meta.codeaw.deferredTool.exitCode).toBe(0);
  });

  it("hydrates exact folded output, rejects stale epochs and preserves old-client full replay", async () => {
    bridge = await startTestBridge();
    const a = await TestClient.connect(bridge.url, bridge.tokenFor("A")); clients.push(a);
    const session = await newFakeSession(a, bridge.home);
    const id = session.sessionId;
    const backend = id.slice(id.indexOf(":") + 1);
    const original = tool(1);
    if (original.kind !== "update") throw new Error("tool fixture");
    bridge.bridge.manager.onUpdate("fake", { sessionId: backend, update: original.update });
    bridge.bridge.manager.onUpdate("fake", { sessionId: backend, update: {
      sessionUpdate: "tool_call_update", toolCallId: "tool", _meta: { terminal_output_delta: { terminal_id: "term", data: output } },
    } });
    const b = await TestClient.connect(bridge.url, bridge.tokenFor("B")); clients.push(b);
    const loaded = await b.request("session/load", { sessionId: id, cwd: bridge.home, mcpServers: [], _meta: { codeaw: { lazyHistory: true } } });
    const header = b.updates(id).find((p) => p.update.toolCallId === "tool");
    expect(header.update._meta.codeaw.deferredTool).toBeDefined();
    const detail = await b.request("_codeaw/history/tool", { sessionId: id, epoch: loaded._meta.codeaw.epoch, toolCallId: "tool" });
    expect(detail.update.content[0].content.text).toBe(output);
    expect(detail.update.rawOutput.formatted_output).toBe(output);
    expect(detail.update._meta.terminal_output.data).toBe(output);
    expect(detail.seq).toBe(header._meta.codeaw.seq);
    await expect(b.request("_codeaw/history/tool", { sessionId: id, epoch: "stale", toolCallId: "tool" })).rejects.toThrow(/History changed/);
    await expect(b.request("_codeaw/history/tool", { sessionId: id, epoch: loaded._meta.codeaw.epoch, toolCallId: "missing" })).rejects.toThrow(/no longer exists/);
    const c = await TestClient.connect(bridge.url, bridge.tokenFor("C")); clients.push(c);
    await c.request("session/load", { sessionId: id, cwd: bridge.home, mcpServers: [] });
    const full = c.updates(id).find((p) => p.update.toolCallId === "tool");
    expect(full.update).toEqual(detail.update);
    expect((compactLog([original])[0] as any).update.rawOutput).toEqual((original as any).update.rawOutput);
    // Delta and native epoch rebuilds use the same negotiated projection.
    b.received.length = 0;
    await b.request("session/load", { sessionId: id, cwd: bridge.home, mcpServers: [], _meta: { codeaw: { lazyHistory: true, epoch: loaded._meta.codeaw.epoch, afterSeq: 0 } } });
    expect(b.updates(id).find((p) => p.update.toolCallId === "tool").update._meta.codeaw.deferredTool).toBeDefined();
    b.received.length = 0;
    bridge.bridge.manager.onHistoryReset("fake", backend, [original.update]);
    await b.waitFor(() => b.received.some((r) => r.method === "_codeaw/replay" && r.params.mode === "complete"));
    expect(b.updates(id).find((p) => p.update.toolCallId === "tool").update._meta.codeaw.deferredTool).toBeDefined();
  });
});
