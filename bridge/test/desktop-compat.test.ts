import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, expect, it } from "vitest";
import { DESKTOP_TURN_SERVER, DESKTOP_TURN_TOOLS } from "../src/mcp/desktop-compat.js";
import { isOwnToolCall, OWN_SERVERS } from "../src/mcp/tools.js";
import { claudeDesktopHolder, claudeProjectSlug, NativeActivity } from "../src/session/native-activity.js";
import { newFakeSession, promptText, startTestBridge, TestClient, type TestBridge } from "./helpers.js";

let tb: TestBridge | undefined;
const clients: TestClient[] = [];
const scratch: string[] = [];
afterEach(async () => {
  for (const client of clients.splice(0)) client.close();
  await tb?.stop(); tb = undefined;
  for (const dir of scratch.splice(0)) fs.rmSync(dir, { recursive: true, force: true });
});

async function chat(): Promise<{ c: TestClient; sessionId: string }> {
  tb = await startTestBridge({ mcpHttp: true });
  const c = await TestClient.connect(tb.url, tb.tokenFor("phone"));
  clients.push(c);
  const s = await newFakeSession(c, tb.home);
  return { c, sessionId: s.sessionId };
}

/** One MCP request to a server path with a chat's token, as Claude Code sends it. */
async function rpc(sessionId: string, server: string, method: string, params?: unknown): Promise<any> {
  const mcp = tb!.bridge.manager.mcp!;
  const response = await fetch(server === "codeaw" ? mcp.url : `${mcp.url}/${server}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${mcp.tokenFor(sessionId)}` },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  return response.status === 200 ? response.json() : { status: response.status };
}

const call = (sessionId: string, name: string, args: unknown) => rpc(sessionId, DESKTOP_TURN_SERVER, "tools/call", { name, arguments: args });
const plans = (c: TestClient, sessionId: string) => c.updates(sessionId).filter((u) => u.update.sessionUpdate === "plan").map((u) => u.update.entries.map((e: any) => `${e.status}:${e.content}`));

it("serves the Claude desktop app's turn tools on their own server name, with instructions about the missing ones", async () => {
  const { sessionId } = await chat();
  const init = await rpc(sessionId, DESKTOP_TURN_SERVER, "initialize", { protocolVersion: "2025-06-18", clientInfo: { name: "claude-code" } });
  expect(init.result.serverInfo.name).toBe("ccd_turn");
  expect(init.result.instructions).toContain("began in the Claude desktop app");
  expect(init.result.instructions).toContain("ccd_session");
  const listed = await rpc(sessionId, DESKTOP_TURN_SERVER, "tools/list");
  expect(listed.result.tools.map((t: any) => t.name)).toEqual(["update_plan", "wrap_up"]);
  // The main server keeps its own tools and instructions.
  expect((await rpc(sessionId, "codeaw", "tools/list")).result.tools.map((t: any) => t.name)).toEqual(["show_files", "suggest_replies", "notify"]);
  expect((await rpc(sessionId, "codeaw", "initialize", { clientInfo: { name: "claude-code" } })).result.serverInfo.name).toBe("codeaw");
  // Other names are not served, and tools stay on their own server.
  expect((await rpc(sessionId, "ccd_session", "tools/list")).status).toBe(404);
  expect((await rpc(sessionId, "codeaw", "tools/call", { name: "update_plan", arguments: {} })).error.code).toBe(-32602);
});

it("shows the task list in the chat, accepts a JSON-encoded list and advances step by step", async () => {
  const { c, sessionId } = await chat();
  // As a model sent it from a resumed desktop chat: the list as a string, plus the app's scope.
  const items = JSON.stringify([{ content: "Map backends", status: "in_progress" }, { content: "Fix AGY", status: "pending" }, { content: "Test", status: "pending" }]);
  expect((await call(sessionId, "update_plan", { scope: "continuation", items })).result.content[0].text).toBe("Plan shown (3 steps).");
  expect((await call(sessionId, "update_plan", { advance: true })).result.content[0].text).toBe("Plan updated: step 2 of 3 is in progress.");
  // As Haiku 5.5 sends it before loading the tool's schema.
  expect((await call(sessionId, "update_plan", { items: [{ advance: true }] })).result.content[0].text).toBe("Plan updated: step 3 of 3 is in progress.");
  expect((await call(sessionId, "update_plan", { advance: true })).result.content[0].text).toBe("Plan updated: all 3 steps are done.");
  await c.waitFor(() => plans(c, sessionId).length === 4);
  expect(plans(c, sessionId)).toEqual([
    ["in_progress:Map backends", "pending:Fix AGY", "pending:Test"],
    ["completed:Map backends", "in_progress:Fix AGY", "pending:Test"],
    ["completed:Map backends", "completed:Fix AGY", "in_progress:Test"],
    ["completed:Map backends", "completed:Fix AGY", "completed:Test"],
  ]);
  // Mistakes come back as tool errors the model can correct.
  for (const args of [{ items: "not json" }, { items: [{ content: "" }] }, { items: [{ content: "x", status: "done" }] }, { items: Array(51).fill("x") }]) {
    expect((await call(sessionId, "update_plan", args)).result.isError).toBe(true);
  }
});

it("asks for the whole list before a first advance", async () => {
  const { sessionId } = await chat();
  const result = (await call(sessionId, "update_plan", { advance: true })).result;
  expect(result.isError).toBe(true);
  expect(result.content[0].text).toContain("no plan yet");
});

it("wraps up with buttons as quick replies and closes the step still in progress", async () => {
  const { c, sessionId } = await chat();
  await call(sessionId, "update_plan", { items: [{ content: "Merge", status: "completed" }, { content: "Push", status: "in_progress" }, { content: "Later", status: "pending" }] });
  const done = await call(sessionId, "wrap_up", { recap: "Merged; not pushed.", question: "Push now?", buttons: ["Push", "Not yet", "Push"] });
  expect(done.result.content[0].text).toContain("write your closing message now");
  await c.waitFor(() => c.events(sessionId, "card").length === 1);
  expect(c.events(sessionId, "card").map((e) => e.event.card)).toEqual([{ kind: "replies", replies: ["Push", "Not yet"] }]);
  expect(plans(c, sessionId).at(-1)).toEqual(["completed:Merge", "completed:Push", "pending:Later"]);
  // A recap alone shows nothing new.
  await call(sessionId, "wrap_up", { recap: "Nothing pending." });
  expect(c.events(sessionId, "card")).toHaveLength(1);
  expect((await call(sessionId, "wrap_up", { recap: "x", buttons: ["a", "b", "c", "d", "e"] })).result.isError).toBe(true);
});

it("answers permission requests for the stand-in tools only", () => {
  expect([...OWN_SERVERS[DESKTOP_TURN_SERVER]]).toEqual(DESKTOP_TURN_TOOLS.map((t) => t.name));
  expect(isOwnToolCall({ title: "mcp__ccd_turn__update_plan" })).toBe(true);
  expect(isOwnToolCall({ title: "Wrap up", _meta: { claudeCode: { toolName: "mcp__ccd_turn__wrap_up" } } })).toBe(true);
  expect(isOwnToolCall({ title: "mcp__codeaw__show_files" })).toBe(true);
  expect(isOwnToolCall({ title: "mcp__ccd_session__start_session" })).toBe(false);
  expect(isOwnToolCall({ title: "mcp__ccd_turn__delete_everything" })).toBe(false);
  expect(isOwnToolCall({ title: "mcp__ccd_turn__toString" })).toBe(false);
  expect(isOwnToolCall({ title: "Tool", rawInput: { server: "ccd_turn", tool: "update_plan" } })).toBe(true);
  expect(isOwnToolCall({ title: "Tool", rawInput: { server: "__proto__", tool: "update_plan" } })).toBe(false);
  expect(isOwnToolCall({ title: "mcp__ccd_turn__update_plan", kind: "execute", rawInput: { command: "x" } })).toBe(false);
});

it("recognizes transcripts the Claude desktop app wrote, including a marker split across read chunks", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-desktop-compat-"));
  scratch.push(root);
  const cwd = "E:\\Projects\\Demo";
  const dir = path.join(root, "projects", claudeProjectSlug(cwd));
  fs.mkdirSync(dir, { recursive: true });
  const line = (entrypoint: string) => JSON.stringify({ type: "user", entrypoint, timestamp: "2026-11-23T00:00:00Z" }) + "\n";
  fs.writeFileSync(path.join(dir, "desktop.jsonl"), line("claude-desktop-3p"));
  fs.writeFileSync(path.join(dir, "cli.jsonl"), line("cli") + line("sdk-ts"));
  const marker = '"entrypoint":"claude-desktop';
  // Puts the marker across the 64 KiB boundary of the scan.
  const pad = 64 * 1024 - 10 - '{"pad":"'.length - '"}\n{'.length;
  fs.writeFileSync(path.join(dir, "split.jsonl"), `{"pad":"${"x".repeat(pad)}"}\n{${marker}"}\n`);
  const native = new NativeActivity();
  const claude = { command: "claude-agent-acp.exe", env: { CLAUDE_CONFIG_DIR: root } };
  expect(native.fromClaudeDesktop("claude", claude, "desktop", cwd)).toBe(true);
  expect(native.fromClaudeDesktop("claude", claude, "cli", cwd)).toBe(false);
  expect(native.fromClaudeDesktop("claude", claude, "split", cwd)).toBe(true);
  expect(native.fromClaudeDesktop("claude", claude, "missing", cwd)).toBe(false);
  expect(native.fromClaudeDesktop("claude", claude, "../desktop", cwd)).toBe(false);
  expect(native.fromClaudeDesktop("codex", { command: "codex-acp", env: { CLAUDE_CONFIG_DIR: root } }, "desktop", cwd)).toBe(false);
  // A CLI chat later opened in the desktop app counts once the app writes to it.
  fs.appendFileSync(path.join(dir, "cli.jsonl"), line("claude-desktop"));
  expect(native.fromClaudeDesktop("claude", claude, "cli", cwd)).toBe(true);
});

/** One entry of Claude Code's registry of running sessions, as the Claude desktop app's process writes it. */
function register(configDir: string, pid: number, entry: Record<string, unknown>): void {
  fs.mkdirSync(path.join(configDir, "sessions"), { recursive: true });
  fs.writeFileSync(path.join(configDir, "sessions", `${pid}.json`), JSON.stringify({ pid, kind: "interactive", startedAt: Date.now(), updatedAt: Date.now(), ...entry }));
}

it("finds the Claude desktop app's own running process for a chat, and nobody else's", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-desktop-holder-"));
  scratch.push(root);
  const id = "11111111-2222-3333-4444-555555555555";
  const running = new Set([101, 102, 103, 104]);
  const alive = (pid: number) => running.has(pid);
  expect(claudeDesktopHolder(root, id, alive)).toBeUndefined();
  register(root, 101, { sessionId: "another-chat", entrypoint: "claude-desktop-3p", status: "busy" });
  register(root, 102, { sessionId: id, entrypoint: "sdk-ts", status: "busy" }); // codeaw's own Claude Code
  register(root, 103, { sessionId: id, entrypoint: "claude-desktop", status: "busy", updatedAt: Date.now() - 2 * 86_400_000 });
  register(root, 105, { sessionId: id, entrypoint: "claude-desktop-3p", status: "busy" }); // exited; its id may be reused
  fs.writeFileSync(path.join(root, "sessions", "106.json"), "{not json");
  expect(claudeDesktopHolder(root, id, alive)).toBeUndefined();
  register(root, 104, { sessionId: id, entrypoint: "claude-desktop-3p", hostSessionId: "local_x", status: "idle" });
  expect(claudeDesktopHolder(root, id, alive)).toEqual({ pid: 104, busy: false });
  register(root, 104, { sessionId: id, entrypoint: "claude-desktop-3p", hostSessionId: "local_x", status: "busy" });
  expect(claudeDesktopHolder(root, id, alive)).toEqual({ pid: 104, busy: true });
  const native = new NativeActivity();
  expect(native.claudeDesktopHolder("claude", { command: "claude-agent-acp", env: { CLAUDE_CONFIG_DIR: root } }, id, alive)).toEqual({ pid: 104, busy: true });
  expect(native.claudeDesktopHolder("codex", { command: "codex-acp", env: { CLAUDE_CONFIG_DIR: root } }, id, alive)).toBeUndefined();
  expect(native.claudeDesktopHolder("claude", { command: "claude-agent-acp", env: { CLAUDE_CONFIG_DIR: root } }, "../x", alive)).toBeUndefined();
});

it("leaves a chat to the Claude desktop app while the app has it open", async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-desktop-handover-"));
  scratch.push(home);
  const claudeDir = path.join(home, "claude");
  const running = new Set<number>();
  tb = await startTestBridge({
    home, agentId: "claude-fake", claudeProcessAlive: (pid) => running.has(pid),
    agent: { env: { FAKE_AGENT_STATE: path.join(home, "fake-state.json"), FAKE_AGENT_MCP: "stdio", CLAUDE_CONFIG_DIR: claudeDir } },
  });
  const c = await TestClient.connect(tb.url, tb.tokenFor("phone"));
  clients.push(c);
  const { sessionId } = await c.request("session/new", { cwd: home, mcpServers: [], _meta: { codeaw: { agentId: "claude-fake" } } });
  const backendId = sessionId.slice("claude-fake:".length);
  const held = () => (tb!.bridge.manager as any).sessions.get(sessionId).backendGen > 0;
  await c.request("session/prompt", promptText(sessionId, "from the phone"));
  expect(held()).toBe(true);

  // The app opens the chat and starts a turn there.
  running.add(4242);
  register(claudeDir, 4242, { sessionId: backendId, entrypoint: "claude-desktop-3p", hostSessionId: "local_y", status: "busy" });
  await expect(c.request("session/prompt", promptText(sessionId, "while the app works"))).rejects.toThrow(/Claude Desktop is working on this chat/);
  // codeaw lets go of its own Claude Code process once its turn is over.
  await tb.bridge.manager.sweep();
  expect(held()).toBe(false);

  // Idle in the app: the phone may continue, and codeaw lets go again afterwards.
  register(claudeDir, 4242, { sessionId: backendId, entrypoint: "claude-desktop-3p", hostSessionId: "local_y", status: "idle" });
  expect((await c.request("session/prompt", promptText(sessionId, "after the app's turn"))).stopReason).toBe("end_turn");
  await tb.bridge.manager.sweep();
  expect(held()).toBe(false);

  // Closed in the app: codeaw keeps its process between turns again.
  running.clear();
  await c.request("session/prompt", promptText(sessionId, "app closed"));
  await tb.bridge.manager.sweep();
  expect(held()).toBe(true);
});
