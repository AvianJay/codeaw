import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { PassThrough } from "node:stream";
import { afterEach, expect, it } from "vitest";
import { mcpToolNote } from "../src/mcp/instructions.js";
import { resolveMcpServers } from "../src/mcp/server.js";
import { runMcpStdio } from "../src/mcp/stdio.js";
import { isOwnToolCall } from "../src/mcp/tools.js";
import { newFakeSession, promptText, startTestBridge, TestClient, type TestBridge } from "./helpers.js";

let tb: TestBridge | undefined;
const clients: TestClient[] = [];
const scratch: string[] = [];
afterEach(async () => {
  for (const client of clients.splice(0)) client.close();
  await tb?.stop(); tb = undefined;
  for (const dir of scratch.splice(0)) fs.rmSync(dir, { recursive: true, force: true });
});

async function connect(name = "phone"): Promise<TestClient> {
  const client = await TestClient.connect(tb!.url, tb!.tokenFor(name));
  clients.push(client);
  return client;
}

const ask = (c: TestClient, sessionId: string, text: string) => c.request("session/prompt", promptText(sessionId, text));

/** The MCP servers the fake agent was handed, per session setup request. */
function setups(sessionId: string): { method: string; servers: any[] }[] {
  const state = JSON.parse(fs.readFileSync(path.join(tb!.home, "fake-state.json"), "utf8"));
  return state[sessionId.slice(sessionId.indexOf(":") + 1)].mcp;
}

/** One request to the bridge's MCP endpoint with a chat's credentials, as an agent sends it. */
async function post(sessionId: string, body: unknown, headers: Record<string, string> = {}): Promise<Response> {
  const mcp = tb!.bridge.manager.mcp!;
  return fetch(mcp.url, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${mcp.tokenFor(sessionId)}`, ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

async function rpc(sessionId: string, method: string, params?: unknown): Promise<any> {
  return (await post(sessionId, { jsonrpc: "2.0", id: 1, method, params })).json();
}

const callTool = (sessionId: string, name: string, args: unknown) => rpc(sessionId, "tools/call", { name, arguments: args });

it("gives each chat its own MCP server entry and repeats it when the chat is reopened", async () => {
  tb = await startTestBridge({ mcpHttp: true });
  const c = await connect();
  expect(c.init._meta.codeaw.agentTools).toEqual(["show_files", "suggest_replies", "notify"]);
  const a = await newFakeSession(c, tb.home), b = await newFakeSession(c, tb.home);
  const [created] = setups(a.sessionId);
  expect(created.method).toBe("session/new");
  expect(created.servers).toEqual([{
    type: "http", name: "codeaw", url: tb.bridge.manager.mcp!.url,
    headers: [{ name: "Authorization", value: expect.stringMatching(/^Bearer [0-9a-f]{64}$/) }],
  }]);
  expect(new URL(created.servers[0].url).hostname).toBe("127.0.0.1");
  expect(setups(b.sessionId)[0].servers[0].headers).not.toEqual(created.servers[0].headers);

  // Adapters rebuild a session whose MCP servers changed, so a reopened chat gets the same entry.
  await c.request("session/close", { sessionId: a.sessionId });
  await ask(c, a.sessionId, "echo again");
  const reopened = setups(a.sessionId).at(-1)!;
  expect(reopened.method).toBe("session/resume");
  expect(reopened.servers).toEqual(created.servers);
});

it("gives an edited branch its own entry", async () => {
  tb = await startTestBridge({ mcpHttp: true, fork: true });
  const c = await connect(), s = await newFakeSession(c, tb.home);
  await ask(c, s.sessionId, "echo FIRST");
  const second = randomUUID();
  await c.request("session/prompt", promptText(s.sessionId, "echo SECOND", { clientPromptId: second }));
  const branch = await c.request("_codeaw/session/fork", {
    sessionId: s.sessionId, messageId: `u-${second}`, clientPromptId: randomUUID(),
    prompt: [{ type: "text", text: 'mcp suggest_replies {"replies":["Go on"]}' }],
  });
  const forked = setups(branch.sessionId);
  expect(forked.map((setup) => setup.method)).toEqual(["session/fork", "session/resume"]);
  expect(forked[1].servers).toEqual(forked[0].servers);
  expect(forked[0].servers[0].headers).not.toEqual(setups(s.sessionId)[0].servers[0].headers);
  // The branch's tool call lands in the branch, not in the chat it came from.
  const b = await connect("tablet");
  await b.request("session/load", { sessionId: branch.sessionId, cwd: tb.home, mcpServers: [] });
  await b.waitFor(() => b.events(branch.sessionId, "card").length > 0);
  expect(c.events(s.sessionId, "card")).toEqual([]);
});

it("reaches agents that only launch stdio MCP servers through a relay", async () => {
  tb = await startTestBridge();
  const c = await connect(), s = await newFakeSession(c, tb.home);
  const [server] = setups(s.sessionId)[0].servers;
  expect(server).toMatchObject({ name: "codeaw", command: expect.any(String) });
  expect(server.type).toBeUndefined();
  expect(server._meta).toBeUndefined();
  expect(server.args.at(-1)).toBe("mcp-stdio");
  expect(server.env.map((e: any) => e.name)).toEqual(["CODEAW_MCP_URL", "CODEAW_MCP_TOKEN"]);
  await ask(c, s.sessionId, 'mcp suggest_replies {"replies":["Yes"]}');
  expect(c.text(s.sessionId)).toContain("tool-ok");
  expect(c.events(s.sessionId, "card").map((e) => e.event.card)).toEqual([{ kind: "replies", replies: ["Yes"] }]);
}, 60_000);

it("relays stdio lines to the bridge and reports an unreachable bridge to the caller", async () => {
  const seen: any[] = [];
  const fetchImpl = (async (url: string, init: any) => {
    const message = JSON.parse(init.body);
    seen.push({ url, authorization: init.headers.Authorization, method: message.method });
    if (message.method === "notifications/initialized") return new Response(null, { status: 202 });
    if (message.method === "ping") throw new Error("connect ECONNREFUSED");
    return new Response(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: { ok: true } }), { status: 200 });
  }) as unknown as typeof fetch;
  const input = new PassThrough(), output = new PassThrough();
  const lines: any[] = [];
  output.on("data", (chunk: Buffer) => lines.push(...chunk.toString().trim().split("\n").map((line) => JSON.parse(line))));
  const done = runMcpStdio(input, output, { CODEAW_MCP_URL: "http://127.0.0.1:1/mcp", CODEAW_MCP_TOKEN: "secret" }, fetchImpl);
  input.write('{"jsonrpc":"2.0","id":7,"method":"tools/list"}\n');
  input.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n\n');
  input.write('{"jsonrpc":"2.0","id":8,"method":"ping"}\n');
  input.end("not json\n");
  await done;
  expect(seen).toEqual([
    { url: "http://127.0.0.1:1/mcp", authorization: "Bearer secret", method: "tools/list" },
    { url: "http://127.0.0.1:1/mcp", authorization: "Bearer secret", method: "notifications/initialized" },
    { url: "http://127.0.0.1:1/mcp", authorization: "Bearer secret", method: "ping" },
  ]);
  expect(lines.find((line) => line.id === 7)).toEqual({ jsonrpc: "2.0", id: 7, result: { ok: true } });
  expect(lines.find((line) => line.id === 8).error.message).toContain("unreachable");
  expect(lines.find((line) => line.id === null).error.code).toBe(-32700);
  expect(lines).toHaveLength(3);
  await expect(runMcpStdio(new PassThrough(), new PassThrough(), {})).rejects.toThrow("set by the bridge");
});

it("keeps the transport the agent supports and leaves other MCP servers alone", () => {
  const stdio = { name: "codeaw", command: "codeaw-bridge", args: ["mcp-stdio"], env: [] };
  const own = { type: "http", name: "codeaw", url: "http://127.0.0.1:9/mcp", headers: [], _meta: { codeaw: { stdio } } };
  const other = { type: "http", name: "docs", url: "https://example.com/mcp", headers: [] };
  expect(resolveMcpServers([own, other], true)).toEqual([{ type: "http", name: "codeaw", url: "http://127.0.0.1:9/mcp", headers: [] }, other]);
  expect(resolveMcpServers([own, other], false)).toEqual([stdio, other]);
});

it("shows files as a card and lets paired devices read exactly what was shown", async () => {
  tb = await startTestBridge({ mcpHttp: true });
  const c = await connect(), s = await newFakeSession(c, tb.home);
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-shown-"));
  scratch.push(outside);
  const chart = path.join(outside, "chart.png"), secret = path.join(outside, "secret.txt");
  fs.writeFileSync(chart, Buffer.from([137, 80, 78, 71]));
  fs.writeFileSync(secret, "private");
  fs.writeFileSync(path.join(tb.home, "notes.txt"), "hello");
  const raw = (file: string) => fetch(`${tb!.http}/api/fs/raw?path=${encodeURIComponent(file)}`, { headers: { Authorization: `Bearer ${tb!.tokenFor("phone")}` } });
  expect((await raw(chart)).status).toBe(403);

  await ask(c, s.sessionId, `mcp show_files ${JSON.stringify({ title: "Results", files: [{ path: chart, caption: "Latency" }, "notes.txt"] })}`);
  expect(c.text(s.sessionId)).toContain("tool-ok: Shown in the user's chat: chart.png, notes.txt");
  const [shown] = c.events(s.sessionId, "card");
  expect(shown.event.cardId).toMatch(/^k_[0-9a-f]+$/);
  expect(shown.event.card).toEqual({ kind: "files", title: "Results", files: [
    { path: fs.realpathSync.native(chart), name: "chart.png", size: 4, mimeType: "image/png", caption: "Latency" },
    // Relative paths are the chat's working directory.
    { path: fs.realpathSync.native(path.join(tb.home, "notes.txt")), name: "notes.txt", size: 5, mimeType: "text/plain" },
  ] });
  const served = await raw(chart);
  expect(served.status).toBe(200);
  expect(Buffer.from(await served.arrayBuffer())).toEqual(Buffer.from([137, 80, 78, 71]));
  expect((await c.request("_codeaw/fs/read", { path: chart })).size).toBe(4);
  // Showing a file does not open the folder it is in.
  expect((await raw(secret)).status).toBe(403);
  await expect(c.request("_codeaw/fs/list", { path: outside })).rejects.toThrow();

  // The grant belongs to the chat: a restarted bridge still serves it, a deleted chat does not.
  const later = await connect("tablet");
  await later.request("session/load", { sessionId: s.sessionId, cwd: tb.home, mcpServers: [] });
  expect(later.events(s.sessionId, "card").map((e) => e.event.card.kind)).toEqual(["files"]);
  const token = tb.bridge.manager.mcp!.tokenFor(s.sessionId);
  await c.request("session/delete", { sessionId: s.sessionId });
  expect((await raw(chart)).status).toBe(403);
  const revoked = await fetch(tb.bridge.manager.mcp!.url, { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: "{}" });
  expect(revoked.status).toBe(401);
});

it("keeps what a chat showed readable after the bridge restarts", async () => {
  tb = await startTestBridge({ mcpHttp: true, keepHome: true });
  const home = tb.home;
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-shown-"));
  scratch.push(outside, home);
  const report = path.join(outside, "report.pdf");
  fs.writeFileSync(report, "%PDF");
  let c = await connect();
  const s = await newFakeSession(c, home);
  await ask(c, s.sessionId, `mcp show_files ${JSON.stringify({ files: [report] })}`);
  c.close();
  await tb.stop();

  tb = await startTestBridge({ mcpHttp: true, home });
  // The app shows its cached chat, and fetches the preview, before it reattaches.
  const served = await fetch(`${tb.http}/api/fs/raw?path=${encodeURIComponent(report)}`, { headers: { Authorization: `Bearer ${tb.tokenFor("phone")}` } });
  expect(served.status).toBe(200);
  c = await connect();
  await c.request("session/load", { sessionId: s.sessionId, cwd: home, mcpServers: [] });
  expect(c.events(s.sessionId, "card")).toHaveLength(1);
});

it("shows nothing when a path is wrong, so the agent can correct the call", async () => {
  tb = await startTestBridge({ mcpHttp: true });
  const c = await connect(), s = await newFakeSession(c, tb.home);
  fs.writeFileSync(path.join(tb.home, "ok.txt"), "x");
  fs.mkdirSync(path.join(tb.home, "out"));
  const failed = async (args: unknown) => {
    const reply = await callTool(s.sessionId, "show_files", args);
    expect(reply.result.isError).toBe(true);
    return reply.result.content[0].text as string;
  };
  expect(await failed({ files: ["ok.txt", "missing.png", "out"] })).toMatch(/^Nothing was shown\. missing\.png: not found; out: is a folder/);
  expect(await failed({ files: [] })).toContain("at least one file");
  expect(await failed({ files: Array(9).fill("ok.txt") })).toContain("at most 8");
  expect(await failed({ files: [{ caption: "no path" }] })).toContain("needs a path");
  expect(c.events(s.sessionId, "card")).toEqual([]);
  // The same file named twice is one item.
  expect((await callTool(s.sessionId, "show_files", { files: ["ok.txt", "./ok.txt"] })).result.isError).toBeUndefined();
  await c.waitFor(() => c.events(s.sessionId, "card").length === 1);
  expect(c.events(s.sessionId, "card")[0].event.card.files).toHaveLength(1);
});

it("offers quick replies as a card", async () => {
  tb = await startTestBridge({ mcpHttp: true });
  const c = await connect(), s = await newFakeSession(c, tb.home);
  await ask(c, s.sessionId, `mcp suggest_replies ${JSON.stringify({ replies: [" 好，提交 ", "先跑測試", "好，提交"] })}`);
  expect(c.text(s.sessionId)).toContain("tool-ok: The replies are shown as buttons");
  expect(c.events(s.sessionId, "card").map((e) => e.event.card)).toEqual([{ kind: "replies", replies: ["好，提交", "先跑測試"] }]);
  for (const replies of [[], ["a", "b", "c", "d", "e", "f", "g"], ["x".repeat(121)], [""], [7]]) {
    expect((await callTool(s.sessionId, "suggest_replies", { replies })).result.isError).toBe(true);
  }
  expect(c.events(s.sessionId, "card")).toHaveLength(1);
});

/** Records what the bridge publishes to ntfy. */
function pushRecorder(): { pushes: any[]; fetchImpl: typeof fetch } {
  const pushes: any[] = [];
  const fetchImpl = (async (_url: string, init: any) => {
    pushes.push(JSON.parse(init.body));
    return new Response("{}", { status: 200 });
  }) as unknown as typeof fetch;
  return { pushes, fetchImpl };
}

async function untilNobodyIsConnected(): Promise<void> {
  const started = Date.now();
  while (tb!.bridge.manager.clientCount > 0 && Date.now() - started < 5000) await new Promise((resolve) => setTimeout(resolve, 20));
}

it("notifies devices that are not showing the chat", async () => {
  const { pushes, fetchImpl } = pushRecorder();
  tb = await startTestBridge({ mcpHttp: true, ntfy: { topic: "t", delaySeconds: 0, includeDetails: true, onTurnEnd: false }, fetchImpl });
  const c = await connect(), s = await newFakeSession(c, tb.home);
  const notices = () => c.received.filter((r) => r.method === "_codeaw/notify").map((r) => r.params);

  // Reading the chat: the card it is logged as is enough.
  await c.notify("_codeaw/client/state", { foreground: true, activeSessionId: s.sessionId, notices: true });
  await ask(c, s.sessionId, 'mcp notify {"message":"Build finished","title":"CI"}');
  expect(c.text(s.sessionId)).toContain("tool-ok: The user has this chat open");
  expect(c.events(s.sessionId, "card").at(-1).event.card).toEqual({ kind: "notice", title: "CI", message: "Build finished" });
  expect(notices()).toEqual([]);

  // On another screen of the app.
  await c.notify("_codeaw/client/state", { foreground: true, notices: true });
  await ask(c, s.sessionId, 'mcp notify {"message":"Look at this"}');
  expect(notices()).toHaveLength(1);

  // In the background.
  await c.notify("_codeaw/client/state", { foreground: false, activeSessionId: s.sessionId, notices: true });
  await ask(c, s.sessionId, 'mcp notify {"message":"Deploy needs you","urgent":true}');
  expect(c.text(s.sessionId)).toContain("tool-ok: Sent to the user's connected devices.");
  expect(notices()[1]).toEqual({ sessionId: s.sessionId, agentId: "fake", agentName: "Fake", message: "Deploy needs you", urgent: true });
  expect(c.events(s.sessionId, "card")).toHaveLength(3);
  expect(pushes).toEqual([]);
});

it("pushes instead when no device confirms that it showed the notice", async () => {
  const { pushes, fetchImpl } = pushRecorder();
  tb = await startTestBridge({ mcpHttp: true, ntfy: { topic: "t", delaySeconds: 0, includeDetails: true, onTurnEnd: false }, fetchImpl });
  const pushed = async (sessionId: string, args: unknown) => {
    const before = pushes.length;
    expect((await callTool(sessionId, "notify", args)).result.content[0].text).toContain("a push notification was sent");
    expect(pushes).toHaveLength(before + 1);
    return pushes.at(-1);
  };

  // An app from before these notices is connected: it is not asked, and its idea of the open chat is not trusted.
  const old = await connect("old-phone"), s = await newFakeSession(old, tb.home);
  await old.notify("_codeaw/client/state", { foreground: true, activeSessionId: s.sessionId });
  await pushed(s.sessionId, { message: "For an older app" });
  expect(old.received.some((r) => r.method === "_codeaw/notify")).toBe(false);

  // A browser tab in the background cannot show it.
  const c = await connect();
  await c.notify("_codeaw/client/state", { foreground: false, notices: true });
  c.noticeShown = false;
  await pushed(s.sessionId, { message: "For a hidden tab" });
  expect(c.received.filter((r) => r.method === "_codeaw/notify")).toHaveLength(1);

  // A phone that was just put away keeps its socket, but the app no longer answers.
  c.noticeShown = undefined;
  tb.bridge.manager.notifyAckMs = 150;
  await pushed(s.sessionId, { message: "For a sleeping phone" });

  // Nobody connected, as when an agent works through the night.
  old.close();
  c.close();
  await untilNobodyIsConnected();
  expect(await pushed(s.sessionId, { message: "Tests passed", title: "Done" })).toEqual(expect.objectContaining({
    topic: "t", message: "Fake有訊息給你\nDone\nTests passed", priority: 3, tags: ["speech_balloon"],
    click: `codeaw://session/${encodeURIComponent(s.sessionId)}`,
  }));
});

it("keeps notification text off a public relay unless details are allowed, and limits a looping agent", async () => {
  const { pushes, fetchImpl } = pushRecorder();
  tb = await startTestBridge({ mcpHttp: true, ntfy: { topic: "t", delaySeconds: 0, onTurnEnd: false }, fetchImpl });
  const c = await connect(), s = await newFakeSession(c, tb.home), quiet = await newFakeSession(c, tb.home);
  c.close();
  await untilNobodyIsConnected();
  for (let i = 0; i < 4; i++) expect((await callTool(s.sessionId, "notify", { message: `Secret step ${i}`, urgent: true })).result.isError).toBeUndefined();
  expect(pushes).toHaveLength(4);
  expect(pushes[0]).toMatchObject({ message: "Fake有訊息給你", priority: 4 });
  const fifth = await callTool(s.sessionId, "notify", { message: "again" });
  expect(fifth.result).toMatchObject({ isError: true, content: [{ text: expect.stringContaining("Too many notifications") }] });
  expect(pushes).toHaveLength(4);
  // The limit is per chat.
  expect((await callTool(quiet.sessionId, "notify", { message: "hello" })).result.isError).toBeUndefined();
  expect((await callTool(quiet.sessionId, "notify", { message: "" })).result.isError).toBe(true);
  expect((await callTool(quiet.sessionId, "notify", { message: "x".repeat(501) })).result.isError).toBe(true);
});

it("says so when nobody can be reached", async () => {
  tb = await startTestBridge({ mcpHttp: true });
  const c = await connect(), s = await newFakeSession(c, tb.home);
  c.close();
  await untilNobodyIsConnected();
  expect((await callTool(s.sessionId, "notify", { message: "Done" })).result.content[0].text).toContain("no push service configured");
});

it("answers permission requests for its own tools without asking the user", async () => {
  tb = await startTestBridge({ mcpHttp: true });
  const c = await connect(), s = await newFakeSession(c, tb.home);
  await ask(c, s.sessionId, 'mcp-perm suggest_replies {"replies":["OK"]}');
  expect(c.text(s.sessionId)).toContain("tool-ok");
  // codex-acp asks with only the id of the call; the call it reported first says which tool it is.
  await ask(c, s.sessionId, 'mcp-codex suggest_replies {"replies":["Fine"]}');
  expect(c.events(s.sessionId, "card").map((e) => e.event.card.replies)).toEqual([["OK"], ["Fine"]]);
  expect(c.text(s.sessionId)).not.toContain("permission=");
  expect(c.received.some((r) => r.method === "session/request_permission")).toBe(false);
  expect(c.events(s.sessionId, "permission_request")).toEqual([]);
  // Everything else still asks.
  c.permissionAnswer = () => ({ outcome: { outcome: "selected", optionId: "allow" } });
  await ask(c, s.sessionId, "perm");
  expect(c.received.some((r) => r.method === "session/request_permission")).toBe(true);

  // As Claude Code, Kimi and DeepSeek Harness report their MCP calls.
  expect(isOwnToolCall({ title: "mcp__codeaw__notify" })).toBe(true);
  expect(isOwnToolCall({ title: "Notify", _meta: { claudeCode: { toolName: "mcp__codeaw__show_files" } } })).toBe(true);
  // As codex-acp reports them: an `execute` call with the server and tool in its input.
  const codex = { title: "mcp.codeaw.suggest_replies", kind: "execute", rawInput: { server: "codeaw", tool: "suggest_replies", arguments: {} } };
  expect(isOwnToolCall(codex)).toBe(true);
  // A permission request may only name the call; the logged call identifies it.
  expect(isOwnToolCall({ toolCallId: "t", title: "Approve tool call" }, codex)).toBe(true);
  expect(isOwnToolCall(undefined, { toolCallId: "t", title: "x" }, { name: "mcp__codeaw__notify" })).toBe(true);
  expect(isOwnToolCall({ title: "mcp__other__notify" })).toBe(false);
  expect(isOwnToolCall({ title: "mcp__codeaw__delete_everything" })).toBe(false);
  expect(isOwnToolCall({ title: "Tool", rawInput: { server: "codeaw", tool: "toString" } })).toBe(false);
  expect(isOwnToolCall({ title: "Tool", rawInput: { server: "other", tool: "notify" } })).toBe(false);
  // A shell command is never one of them, whatever its text says.
  expect(isOwnToolCall({ title: "echo mcp__codeaw__notify", kind: "execute" })).toBe(false);
  expect(isOwnToolCall({ title: "mcp.codeaw.notify", kind: "execute" })).toBe(false);
  expect(isOwnToolCall({ title: "mcp__codeaw__notify", rawInput: { command: "mcp__codeaw__notify" } })).toBe(false);
  expect(isOwnToolCall({ title: "mcp__codeaw__notify", _meta: { claudeCode: { toolName: "Bash" } } })).toBe(false);
  expect(isOwnToolCall({ title: "mcp__codeaw__notify" }, { title: "`mcp__codeaw__notify`", kind: "execute", rawInput: { command: "mcp__codeaw__notify" } })).toBe(false);
});

it("speaks MCP only to callers holding a chat's token", async () => {
  tb = await startTestBridge({ mcpHttp: true, mcp: { instructions: "Reply in Traditional Chinese." } });
  const c = await connect(), s = await newFakeSession(c, tb.home);
  const mcp = tb.bridge.manager.mcp!;
  const body = JSON.stringify({ jsonrpc: "2.0", id: 1, method: "ping" });
  expect((await fetch(mcp.url, { method: "POST", body })).status).toBe(401);
  expect((await fetch(mcp.url, { method: "POST", headers: { Authorization: `Bearer ${"0".repeat(64)}` }, body })).status).toBe(401);
  // A device token opens the app's API, not the agents' endpoint, and the reverse.
  expect((await fetch(mcp.url, { method: "POST", headers: { Authorization: `Bearer ${tb.tokenFor("phone")}` }, body })).status).toBe(401);
  expect((await fetch(`${tb.http}/mcp`, { method: "POST", headers: { Authorization: `Bearer ${mcp.tokenFor(s.sessionId)}` }, body })).status).toBe(401);
  expect((await fetch(`${tb.http}/api/device`, { headers: { Authorization: `Bearer ${mcp.tokenFor(s.sessionId)}` } })).status).toBe(401);
  expect((await post(s.sessionId, body, { Origin: "https://evil.example" })).status).toBe(403);
  const get = await fetch(mcp.url, { headers: { Authorization: `Bearer ${mcp.tokenFor(s.sessionId)}` } });
  expect([get.status, get.headers.get("allow")]).toEqual([405, "POST"]);
  expect((await fetch(mcp.url.replace("/mcp", "/other"), { method: "POST", body })).status).toBe(404);

  const init = await rpc(s.sessionId, "initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } });
  expect(init.result).toMatchObject({ protocolVersion: "2025-06-18", capabilities: { tools: { listChanged: false } }, serverInfo: { name: "codeaw" } });
  expect(init.result.instructions).toContain("You are running through codeaw.");
  for (const tool of ["show_files", "suggest_replies", "notify"]) expect(init.result.instructions).toContain(`- ${tool}:`);
  expect(init.result.instructions.endsWith("\n\nReply in Traditional Chinese.")).toBe(true);
  expect(mcp.clientOf(s.sessionId)).toBe("test");
  expect((await rpc(s.sessionId, "initialize", { protocolVersion: "1999-01-01" })).result.protocolVersion).toBe("2025-11-25");

  const initialized = await post(s.sessionId, { jsonrpc: "2.0", method: "notifications/initialized" });
  expect([initialized.status, await initialized.text()]).toEqual([202, ""]);
  expect(await rpc(s.sessionId, "ping")).toEqual({ jsonrpc: "2.0", id: 1, result: {} });
  const { tools } = (await rpc(s.sessionId, "tools/list")).result;
  expect(tools.map((tool: any) => tool.name)).toEqual(["show_files", "suggest_replies", "notify"]);
  for (const tool of tools) {
    expect(tool.inputSchema).toMatchObject({ type: "object", additionalProperties: false });
    expect(tool.description.length).toBeGreaterThan(80);
    expect(tool.annotations).toMatchObject({ readOnlyHint: true, destructiveHint: false });
  }
  expect((await callTool(s.sessionId, "format_disk", {})).error.code).toBe(-32602);
  expect((await rpc(s.sessionId, "tools/call", { name: "notify", arguments: [] })).error.code).toBe(-32602);
  expect((await rpc(s.sessionId, "resources/list")).error.code).toBe(-32601);
  const garbled = await post(s.sessionId, "{nope");
  expect([garbled.status, (await garbled.json() as any).error.code]).toEqual([400, -32700]);
  const batch = await (await post(s.sessionId, [{ jsonrpc: "2.0", id: "a", method: "ping" }, { jsonrpc: "2.0", method: "notifications/initialized" }, { jsonrpc: "2.0", id: "b", method: "nope" }])).json();
  expect(batch).toEqual([{ jsonrpc: "2.0", id: "a", result: {} }, { jsonrpc: "2.0", id: "b", error: { code: -32601, message: "Method not found: nope" } }]);

  // A token whose chat the agent has not named yet can list tools but not act.
  const unbound = mcp.issue();
  const early = await fetch(mcp.url, { method: "POST", headers: { Authorization: `Bearer ${unbound}` }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "notify", arguments: { message: "hi" } } }) });
  expect((await early.json() as any).result).toMatchObject({ isError: true, content: [{ text: expect.stringContaining("still starting") }] });
});

it("tells clients that drop the server's instructions about codeaw in a tool description", async () => {
  tb = await startTestBridge({ mcpHttp: true, mcp: { instructions: "Reply in Traditional Chinese." } });
  const c = await connect(), s = await newFakeSession(c, tb.home);
  const list = async (client?: string) => {
    if (client) await rpc(s.sessionId, "initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: client, version: "1" } });
    return (await rpc(s.sessionId, "tools/list")).result.tools as { name: string; description: string }[];
  };
  // Claude Code puts the instructions in its system prompt; repeating them would be noise.
  const plain = await list("claude-code");
  for (const tool of plain) expect(tool.description).not.toContain("codeaw app");
  const setting = `About this whole conversation: You are running through codeaw. The user talks to you from the codeaw app, usually on a phone, while you work on their computer "${os.hostname()}".`;
  for (const client of ["codex-mcp-client", "some-new-agent"]) {
    const noted = await list(client);
    expect(noted[0].description).toBe(`${plain[0].description}\n\n${setting}\nReply in Traditional Chinese.`);
    expect(noted.slice(1)).toEqual(plain.slice(1));
  }
  // Also before the client has said who it is.
  const unnamed = tb.bridge.manager.mcp!.issue();
  const early = await fetch(tb.bridge.manager.mcp!.url, { method: "POST", headers: { Authorization: `Bearer ${unnamed}` }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }) });
  expect((await early.json() as any).result.tools[0].description).toContain(setting);
  // The tools it is told about are the ones it gets.
  expect(tb.bridge.manager.agentInstructions("fake")).toBe(tb.bridge.manager.mcp!.instructions);
  expect(tb.bridge.manager.agentInstructions("nobody")).toBeUndefined();

  // Some model APIs reject long tool descriptions: the user's text is cut to fit, never the rest.
  const base = mcpToolNote("pc", undefined, 1000);
  expect(base).toBe('About this whole conversation: You are running through codeaw. The user talks to you from the codeaw app, usually on a phone, while you work on their computer "pc".');
  expect(mcpToolNote("pc", "  Be brief.  ", 1000)).toBe(`${base}\nBe brief.`);
  const cut = mcpToolNote("pc", "word ".repeat(200), base.length + 101);
  expect(cut).toHaveLength(base.length + 101);
  expect(cut.startsWith(`${base}\nword word`)).toBe(true);
  expect(cut.endsWith("word…")).toBe(true);
  expect(mcpToolNote("pc", "Be brief and kind to the reader, always.", base.length + 20)).toBe(base);
  expect(mcpToolNote("pc", "Be brief.", base.length - 1)).toBe("");
  await tb.stop();

  tb = await startTestBridge({ mcpHttp: true, mcp: { instructions: "Keep it short. ".repeat(260) } });
  const long = await newFakeSession(await connect(), tb.home);
  const { tools } = (await rpc(long.sessionId, "tools/list")).result;
  expect(tools[0].description.length).toBeLessThanOrEqual(1024);
  expect(tools[0].description.length).toBeGreaterThan(1000);
  expect(tools[0].description.endsWith("…")).toBe(true);
  expect((await rpc(long.sessionId, "initialize", {})).result.instructions).toContain("Keep it short. ".repeat(260).trim());
});

it("leaves agents alone when the tools are turned off", async () => {
  tb = await startTestBridge({ mcpHttp: true, mcp: { enabled: false } });
  let c = await connect();
  expect(c.init._meta.codeaw.agentTools).toBeUndefined();
  expect(tb.bridge.manager.mcp).toBeUndefined();
  expect(tb.bridge.manager.agentInstructions("fake")).toBeUndefined();
  let s = await newFakeSession(c, tb.home);
  expect(setups(s.sessionId)[0].servers).toEqual([]);
  await ask(c, s.sessionId, 'mcp notify {"message":"x"}');
  expect(c.text(s.sessionId)).toContain("no codeaw server");
  c.close();
  await tb.stop();

  // One agent can opt out while the others keep the tools.
  tb = await startTestBridge({ mcpHttp: true, agent: { mcp: false } });
  c = await connect();
  expect(c.init._meta.codeaw.agentTools).toEqual(["show_files", "suggest_replies", "notify"]);
  s = await newFakeSession(c, tb.home);
  expect(setups(s.sessionId)[0].servers).toEqual([]);
  expect(tb.bridge.manager.agentInstructions("fake")).toBeUndefined();
});
