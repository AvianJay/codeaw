import { afterEach, describe, expect, it } from "vitest";
import { compactGroups, compactLog } from "../src/session/compact.js";
import { historyOptions, lazyToolEntry, olderPage, tailPage } from "../src/session/history.js";
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

let seq = 0;
const at = () => ++seq;
function update(update: Record<string, unknown>): LogEntry {
  const n = at();
  return { seq: n, t: n, kind: "update", update } as LogEntry;
}
function state(value: string, extra: Record<string, unknown> = {}): LogEntry {
  const n = at();
  return { seq: n, t: n, kind: "event", event: { type: "state", state: value, queued: 0, ...extra } } as LogEntry;
}
function turn(index: number, tools = 2, text = "回覆".repeat(200)): LogEntry[] {
  const promptId = `p${index}`;
  const startedAt = seq + 1;
  return [
    update({ sessionUpdate: "user_message_chunk", content: { type: "text", text: `問題 ${index}` }, _meta: { codeaw: { mid: `u-${promptId}`, promptId } } }),
    state("running", { turnStartedAt: startedAt, turnPromptId: promptId }),
    ...Array.from({ length: tools }, (_, tool) => [
      update({ sessionUpdate: "tool_call", toolCallId: `t${index}-${tool}`, title: "Read", status: "in_progress" }),
      update({ sessionUpdate: "tool_call_update", toolCallId: `t${index}-${tool}`, status: "completed", rawOutput: { output: "x".repeat(400) } }),
    ]).flat(),
    update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text }, _meta: { codeaw: { mid: `a${index}` } } }),
    state("idle", { stopReason: "end_turn", completedTurn: { promptId, startedAt, endedAt: seq + 1 } }),
  ];
}
const keyOf = (e: LogEntry) => e.kind === "event" ? `${e.event.type}:${e.seq}` : JSON.stringify([e.update.sessionUpdate, (e.update as any).toolCallId ?? (e.update as any)._meta?.codeaw?.mid]);

describe("paged history", () => {
  it("sends the newest turns first with session snapshots, then every older group once in order", () => {
    seq = 0;
    const log = [
      update({ sessionUpdate: "available_commands_update", availableCommands: [{ name: "review" }] }),
      update({ sessionUpdate: "session_info_update", title: "長對話" }),
      ...Array.from({ length: 30 }, (_, i) => turn(i)).flat(),
    ];
    const groups = compactGroups(log);
    expect(compactLog(log)).toEqual(groups.flatMap((g) => g.entries));
    const options = { pageBytes: 8 * 1024 };
    const tail = tailPage(groups, options);
    expect(tail.before).toBeDefined();
    const updates = tail.entries.filter((e) => e.kind === "update").map((e: any) => e.update);
    expect(updates[0].sessionUpdate).toBe("available_commands_update");
    expect(updates[1]).toMatchObject({ sessionUpdate: "session_info_update", title: "長對話" });
    // The page begins at a prompt and ends with the session's latest turn.
    expect(updates[2].sessionUpdate).toBe("user_message_chunk");
    expect(tail.entries.at(-1)).toMatchObject({ kind: "event", event: { state: "idle" } });
    expect(Buffer.byteLength(JSON.stringify(tail.entries))).toBeLessThan(16 * 1024);

    const pages = [tail.entries.slice(2)];
    let before = tail.before;
    while (before !== undefined) {
      const page = olderPage(groups, before, options);
      expect(page.entries.length).toBeGreaterThan(0);
      expect((page.entries[0] as any).update?.sessionUpdate).toBe("user_message_chunk");
      pages.unshift(page.entries);
      expect(page.before === undefined || page.before < before).toBe(true);
      before = page.before;
    }
    expect(pages.length).toBeGreaterThan(3);
    const conversation = groups.flatMap((g) => g.entries).filter((e) => e.kind === "event" || !["available_commands_update", "session_info_update"].includes(e.update.sessionUpdate));
    expect(pages.flat().map(keyOf)).toEqual(conversation.map(keyOf));
  });

  it("cuts inside a turn that is far larger than a page and keeps its active state", () => {
    seq = 0;
    const log = turn(0, 200);
    log.pop(); // still running
    const tail = tailPage(compactGroups(log), { pageBytes: 8 * 1024 });
    expect(tail.before).toBeGreaterThan(1);
    expect(tail.entries[0]).toMatchObject({ kind: "event", event: { type: "state", state: "running", turnPromptId: "p0" } });
    expect(Buffer.byteLength(JSON.stringify(tail.entries))).toBeLessThan(48 * 1024);
    const older = olderPage(compactGroups(log), tail.before!, { pageBytes: 1024 * 1024 });
    expect(older.before).toBeUndefined();
    expect((older.entries[0] as any).update).toMatchObject({ sessionUpdate: "user_message_chunk" });
  });

  it("negotiates bounded page and deferral sizes", () => {
    expect(historyOptions({})).toBeUndefined();
    expect(historyOptions({ lazyHistory: true })).toEqual({ lazyBytes: 4 * 1024 });
    expect(historyOptions({ lazyHistory: true, lazyHistoryBytes: 1, pageBytes: 1 })).toEqual({ lazyBytes: 512, pageBytes: 8 * 1024 });
    expect(historyOptions({ lazyHistoryBytes: 2048, pageBytes: 1e12 })).toEqual({ pageBytes: 8 * 1024 * 1024 });
    const small = tool(1, { rawOutput: { output: "y".repeat(3000) }, content: [] });
    expect((lazyToolEntry(small) as any).update._meta?.codeaw?.deferredTool).toBeUndefined();
    expect((lazyToolEntry(small, 2048) as any).update._meta.codeaw.deferredTool.bytes).toBeGreaterThan(3000);
  });

  it("pages a loaded session in order with live updates and rejects stale epochs", async () => {
    bridge = await startTestBridge();
    const a = await TestClient.connect(bridge.url, bridge.tokenFor("A")); clients.push(a);
    const session = await newFakeSession(a, bridge.home);
    const id = session.sessionId;
    const backend = id.slice(id.indexOf(":") + 1);
    for (let i = 0; i < 60; i++) {
      bridge.bridge.manager.onUpdate("fake", { sessionId: backend, update: {
        sessionUpdate: "agent_message_chunk", content: { type: "text", text: `訊息 ${i} ${"內容".repeat(300)}` }, messageId: `m${i}`,
      } as any });
    }
    const b = await TestClient.connect(bridge.url, bridge.tokenFor("B")); clients.push(b);
    const loaded = await b.request("session/load", { sessionId: id, cwd: bridge.home, mcpServers: [], _meta: { codeaw: { lazyHistory: true, pageBytes: 8 * 1024 } } });
    const replay = b.received.find((r) => r.method === "_codeaw/replay")!.params;
    expect(replay).toMatchObject({ mode: "full", epoch: loaded._meta.codeaw.epoch });
    expect(replay.before).toBeGreaterThan(1);
    const texts = (client: TestClient) => client.updates(id).filter((p) => p.update.sessionUpdate === "agent_message_chunk").map((p) => p.update.content.text as string);
    const tail = texts(b);
    expect(tail.length).toBeLessThan(20);
    expect(tail.at(-1)).toMatch(/^訊息 59 /);

    // A live update queued before the page request is delivered before the page.
    bridge.bridge.manager.onUpdate("fake", { sessionId: backend, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "live" }, messageId: "m0" } as any });
    await b.request("_codeaw/history/page", { sessionId: id, epoch: loaded._meta.codeaw.epoch, before: replay.before });
    // Compressed frames can finish after the small response; order among notifications holds.
    await b.waitFor(() => b.received.some((r) => r.method === "_codeaw/history/page"));
    const methods = b.received.map((r) => r.method);
    const page = b.received.find((r) => r.method === "_codeaw/history/page")!.params;
    expect(methods.lastIndexOf("session/update")).toBeLessThan(methods.indexOf("_codeaw/history/page"));
    expect(page).toMatchObject({ sessionId: id, epoch: loaded._meta.codeaw.epoch, requested: replay.before });
    expect(page.before).toBeLessThan(replay.before);
    const pageTexts = page.entries.map((e: any) => e.update?.content?.text).filter(Boolean);
    expect(pageTexts.at(-1)).toMatch(new RegExp(`^訊息 ${59 - tail.length} `));
    expect(page.entries.every((e: any) => typeof e.seq === "number" && typeof e.t === "number")).toBe(true);

    let before: number | undefined = page.before;
    let oldest = "";
    while (before !== undefined) {
      b.received.length = 0;
      await b.request("_codeaw/history/page", { sessionId: id, epoch: loaded._meta.codeaw.epoch, before, pageBytes: 64 * 1024 });
      await b.waitFor(() => b.received.some((r) => r.method === "_codeaw/history/page"));
      const next = b.received.find((r) => r.method === "_codeaw/history/page")!.params;
      oldest = next.entries.find((e: any) => e.update?.content?.text)?.update.content.text ?? oldest;
      before = next.before;
    }
    // The oldest message is folded with its later live chunk.
    expect(oldest).toMatch(/^訊息 0 .*live$/s);
    await expect(b.request("_codeaw/history/page", { sessionId: id, epoch: "stale", before: 5 })).rejects.toThrow(/History changed/);
    const c = await TestClient.connect(bridge.url, bridge.tokenFor("C")); clients.push(c);
    await expect(c.request("_codeaw/history/page", { sessionId: id, epoch: loaded._meta.codeaw.epoch, before: 5 })).rejects.toThrow(/Load the session/);
    // A small delta stays a delta; a long absence gets the compacted first page instead.
    b.received.length = 0;
    const lastSeq = loaded._meta.codeaw.lastSeq;
    await b.request("session/load", { sessionId: id, cwd: bridge.home, mcpServers: [], _meta: { codeaw: { lazyHistory: true, pageBytes: 8 * 1024, epoch: loaded._meta.codeaw.epoch, afterSeq: lastSeq - 1 } } });
    expect(b.received.find((r) => r.method === "_codeaw/replay")!.params).toMatchObject({ mode: "delta" });
    b.received.length = 0;
    await b.request("session/load", { sessionId: id, cwd: bridge.home, mcpServers: [], _meta: { codeaw: { lazyHistory: true, pageBytes: 8 * 1024, epoch: loaded._meta.codeaw.epoch, afterSeq: 0 } } });
    expect(b.received.find((r) => r.method === "_codeaw/replay")!.params).toMatchObject({ mode: "full", before: replay.before });
    expect(texts(b)).toHaveLength(tail.length);
    // Clients without paging still receive everything.
    await c.request("session/load", { sessionId: id, cwd: bridge.home, mcpServers: [] });
    expect(c.received.find((r) => r.method === "_codeaw/replay")!.params.before).toBeUndefined();
    expect(texts(c)).toHaveLength(60);
  });
});
