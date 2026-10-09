import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { afterEach, describe, expect, it } from "vitest";
import { supportsForkPoint } from "../src/backend/agent-process.js";
import { planFork } from "../src/session/fork.js";
import type { LogEntry } from "../src/session/types.js";
import { startTestBridge, TestClient, newFakeSession, promptText, rawLog, type TestBridge } from "./helpers.js";

let bridge: TestBridge | undefined;
const clients: TestClient[] = [];
afterEach(async () => {
  for (const client of clients.splice(0)) client.close();
  await bridge?.stop(); bridge = undefined;
});
async function connect(name = "phone") {
  const client = await TestClient.connect(bridge!.url, bridge!.tokenFor(name));
  clients.push(client); return client;
}
async function send(c: TestClient, sessionId: string, text: string): Promise<string> {
  const id = randomUUID();
  await c.request("session/prompt", promptText(sessionId, text, { clientPromptId: id }));
  return id;
}
const edit = (c: TestClient, sessionId: string, promptId: string, text: string, extra: Record<string, unknown> = {}) =>
  c.request("_codeaw/session/fork", { sessionId, messageId: `u-${promptId}`, prompt: [{ type: "text", text }], clientPromptId: randomUUID(), ...extra });
const userTexts = (tb: TestBridge, id: string) => rawLog(tb, id)
  .filter((r) => r.params.update?.sessionUpdate === "user_message_chunk")
  .map((r) => r.params.update.content.text).filter(Boolean);

it("branches before an edited message, restores settings and keeps the original chat", async () => {
  bridge = await startTestBridge({ fork: true });
  const a = await connect(), s = await newFakeSession(a, bridge.home), id = s.sessionId;
  expect((await a.request("_codeaw/agents/list", {})).agents.find((x: any) => x.id === "fake").forkAtMessage).toBe(true);
  await send(a, id, "echo FIRST");
  const second = await send(a, id, "echo SECOND");
  await a.request("session/set_config_option", { sessionId: id, configId: "mode", value: "code" });
  expect(await a.request("_codeaw/session/fork", { sessionId: id, messageId: `u-${second}`, dryRun: true })).toEqual({ ok: true, newSession: false });
  const promptId = randomUUID();
  const params = { sessionId: id, messageId: `u-${second}`, prompt: [{ type: "text", text: "history" }], clientPromptId: promptId };
  const branch = await a.request("_codeaw/session/fork", params);
  expect(branch.sessionId).not.toBe(id);
  expect(branch.configOptions.find((o: any) => o.id === "mode").currentValue).toBe("code");

  const b = await connect("tablet");
  await b.request("session/load", { sessionId: branch.sessionId, cwd: bridge.home, mcpServers: [] });
  await b.waitFor(() => b.text(branch.sessionId).includes("remembers:"));
  expect(b.text(branch.sessionId)).toContain("FIRST");
  expect(b.text(branch.sessionId)).toContain("remembers: echo FIRST");
  expect(b.text(branch.sessionId)).not.toContain("SECOND");
  expect(userTexts(bridge, branch.sessionId)).toEqual(["echo FIRST", "history"]);
  expect(userTexts(bridge, id)).toEqual(["echo FIRST", "echo SECOND"]);
  expect(b.events(branch.sessionId, "prompt_receipt").some((e) => e.event.promptId === second)).toBe(false);

  // A retried request (e.g. after a dropped connection) returns the same branch.
  expect((await a.request("_codeaw/session/fork", params)).sessionId).toBe(branch.sessionId);
  const list = await a.request("session/list", {});
  expect(list.sessions.map((x: any) => x.sessionId).filter((x: string) => x !== id && x !== branch.sessionId)).toEqual([]);
});

it("can replace the original chat in Codeaw while keeping the agent's own history", async () => {
  bridge = await startTestBridge({ fork: true });
  const a = await connect(), s = await newFakeSession(a, bridge.home), id = s.sessionId;
  await send(a, id, "echo KEEP");
  const second = await send(a, id, "echo DROP");
  const branch = await edit(a, id, second, "echo NEW", { replace: true });
  expect(branch.replaced).toBe(true);
  await a.waitFor(() => a.received.some((r) => r.method === "_codeaw/activity" && r.params.sessionId === id && r.params.deleted));
  const list = await a.request("session/list", {});
  expect(list.sessions.map((x: any) => x.sessionId)).toEqual([branch.sessionId]);
  await expect(a.request("session/load", { sessionId: id, cwd: bridge.home, mcpServers: [] })).rejects.toThrow(/deleted/);
  const backendId = id.slice("fake:".length);
  expect(Object.keys(JSON.parse(fs.readFileSync(path.join(bridge.home, "fake-state.json"), "utf8")))).toContain(backendId);
});

it("edits only the first message of agents without fork points", async () => {
  bridge = await startTestBridge();
  const a = await connect(), s = await newFakeSession(a, bridge.home), id = s.sessionId;
  await a.request("session/set_config_option", { sessionId: id, configId: "mode", value: "code" });
  const first = await send(a, id, "echo ONE");
  const second = await send(a, id, "echo TWO");
  expect(a.init._meta.codeaw.editPrompts).toBe(true);
  expect(await a.request("_codeaw/session/fork", { sessionId: id, messageId: `u-${first}`, dryRun: true })).toEqual({ ok: true, newSession: true });
  await expect(a.request("_codeaw/session/fork", { sessionId: id, messageId: `u-${second}`, dryRun: true })).rejects.toThrow(/only the first message/);
  await expect(edit(a, id, second, "echo X")).rejects.toThrow(/only the first message/);
  const branch = await edit(a, id, first, "history");
  expect(branch.configOptions.find((o: any) => o.id === "mode").currentValue).toBe("code");
  await a.request("session/load", { sessionId: branch.sessionId, cwd: bridge.home, mcpServers: [] });
  await a.waitFor(() => a.text(branch.sessionId).includes("remembers:"));
  expect(a.text(branch.sessionId)).toBe("remembers: ");
  expect(userTexts(bridge, branch.sessionId)).toEqual(["history"]);
});

it("rejects edits while the chat is busy", async () => {
  bridge = await startTestBridge({ fork: true });
  const a = await connect(), s = await newFakeSession(a, bridge.home), id = s.sessionId;
  const first = await send(a, id, "echo ONE");
  const running = a.request("session/prompt", promptText(id, "perm"));
  await a.waitFor(() => a.events(id, "permission_request").length === 1);
  await expect(edit(a, id, first, "echo X")).rejects.toThrow(/busy/);
  await a.notify("session/cancel", { sessionId: id });
  await running;
  await expect(a.request("_codeaw/session/fork", { sessionId: id, messageId: "u-missing", prompt: [{ type: "text", text: "x" }], clientPromptId: randomUUID() }))
    .rejects.toThrow(/not in the chat history/);
});

it("resends an image kept from the edited message", async () => {
  bridge = await startTestBridge({ fork: true });
  const a = await connect(), s = await newFakeSession(a, bridge.home), id = s.sessionId;
  const png = Buffer.from("89504e470d0a1a0a0000000d49484452", "hex").toString("base64");
  const promptId = randomUUID();
  await a.request("session/prompt", { sessionId: id, prompt: [{ type: "text", text: "image" }, { type: "image", mimeType: "image/png", data: png }], _meta: { codeaw: { clientPromptId: promptId } } });
  const logged = rawLog(bridge, id).find((r) => r.params.update?.content?.type === "image")!.params.update.content;
  expect(logged.uri).toMatch(/^codeaw-blob:/);
  const branch = await a.request("_codeaw/session/fork", {
    sessionId: id, messageId: `u-${promptId}`, clientPromptId: randomUUID(),
    prompt: [{ type: "text", text: "image" }, { type: "image", mimeType: "image/png", data: "", uri: logged.uri }],
  });
  await a.request("session/load", { sessionId: branch.sessionId, cwd: bridge.home, mcpServers: [] });
  await a.waitFor(() => a.text(branch.sessionId).includes("got image"));
  expect(a.text(branch.sessionId)).toBe(`got image image/png ${png.length}`);
});

describe("planFork", () => {
  let seq = 0;
  const user = (mid: string, text: string, codeaw: Record<string, unknown> = {}): LogEntry =>
    ({ seq: ++seq, t: 0, kind: "update", update: { sessionUpdate: "user_message_chunk", content: { type: "text", text }, _meta: { codeaw: { mid, ...codeaw } } } as any });
  const prompt = (id: string, text: string, flags: Record<string, unknown> = {}) => user(`u-${id}`, text, { promptId: id, ...flags });
  const agent = (messageId: string, text: string, meta: Record<string, unknown> = {}): LogEntry =>
    ({ seq: ++seq, t: 0, kind: "update", update: { sessionUpdate: "agent_message_chunk", messageId, content: { type: "text", text }, _meta: { ...meta, codeaw: { mid: messageId } } } as any });
  const state = (state: "running" | "idle", turnPromptId?: string): LogEntry =>
    ({ seq: ++seq, t: 0, kind: "event", event: { type: "state", state, queued: 0, ...(turnPromptId ? { turnPromptId } : {}) } });
  const receipt = (promptId: string, status: "received" | "read"): LogEntry => ({ seq: ++seq, t: 0, kind: "event", event: { type: "prompt_receipt", promptId, status } });
  const texts = (entries: LogEntry[]) => entries.map((e) => (e.kind === "update" ? (e.update as any).content.text : e.event.type));

  it("ends at the previous turn when the edited prompt was queued during it", () => {
    const log = [prompt("a", "A"), state("running", "a"), agent("m1", "one"), prompt("b", "B", { queued: true }), receipt("b", "received"),
      agent("m2", "two"), state("idle"), { seq: ++seq, t: 0, kind: "event", event: { type: "dequeued", promptId: "b" } } as LogEntry,
      state("running", "b"), agent("m3", "three")];
    const plan = planFork(log, "u-b");
    expect(plan.messageId).toBe("m2");
    expect(texts(plan.entries)).toEqual(["A", "state", "one", "two", "state"]);
  });

  it("leaves out turns without agent message ids after the fork point", () => {
    const log = [prompt("a", "A"), state("running", "a"), agent("m1", "one"), state("idle"),
      prompt("b", "B"), state("running", "b"), state("idle"), prompt("c", "C"), state("running", "c")];
    const plan = planFork(log, "u-c");
    expect(plan.messageId).toBe("m1");
    expect(texts(plan.entries)).toEqual(["A", "state", "one", "state"]);
  });

  it("uses native message boundaries for imported history and ignores subagent messages", () => {
    const log = [user("n1", "hello"), agent("g1", "hi"), user("n2", "again"), agent("child", "sub", { claudeCode: { parentToolUseId: "t1" } }), user("n3", "edit me")];
    const plan = planFork(log, "n3");
    expect(plan.messageId).toBe("g1");
    expect(texts(plan.entries)).toEqual(["hello", "hi"]);
  });

  it("starts a new session for the first prompt and rejects messages that cannot branch", () => {
    expect(planFork([prompt("a", "A"), state("running", "a")], "u-a")).toEqual({ entries: [] });
    expect(() => planFork([prompt("a", "A"), state("running", "a"), prompt("b", "B", { queued: true, steered: true }), receipt("b", "read")], "u-b"))
      .toThrow(/inserted into a running turn/);
    expect(() => planFork([prompt("a", "A"), state("running", "a"), prompt("b", "B", { queued: true })], "u-b")).toThrow(/not started/);
    expect(() => planFork([prompt("a", "A"), state("running", "a"), state("idle"), prompt("b", "B"), state("running", "b")], "u-b"))
      .toThrow(/no message ids/);
  });
});

it("recognises adapters whose fork honours a fork point", () => {
  const init = (name: string, version: string, fork = true) => ({ protocolVersion: 1, agentInfo: { name, version }, agentCapabilities: { sessionCapabilities: fork ? { fork: {} } : {} } }) as any;
  expect(supportsForkPoint(init("@agentclientprotocol/claude-agent-acp", "0.71.0"))).toBe(true);
  expect(supportsForkPoint(init("@agentclientprotocol/claude-agent-acp", "0.70.9"))).toBe(false);
  expect(supportsForkPoint(init("@agentclientprotocol/codex-acp", "2.1.2-preview.3"))).toBe(true);
  expect(supportsForkPoint(init("@agentclientprotocol/codex-acp", "1.7.0"))).toBe(false);
  expect(supportsForkPoint(init("@agentclientprotocol/codex-acp", "2.1.1", false))).toBe(false);
  expect(supportsForkPoint(init("kimi", "9.9.9"))).toBe(false);
});
