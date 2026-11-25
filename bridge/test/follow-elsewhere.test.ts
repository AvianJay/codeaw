import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, expect, it } from "vitest";
import { claudeProjectSlug, forgetClaudeProcess, lastChainWrite, lastTranscriptTurn, type DesktopHolder, type ProcessEnd } from "../src/session/native-activity.js";
import { promptText, startTestBridge, TestClient, type TestBridge } from "./helpers.js";

let tb: TestBridge | undefined;
const clients: TestClient[] = [];
const scratch: string[] = [];
afterEach(async () => {
  for (const client of clients.splice(0)) client.close();
  await tb?.stop(); tb = undefined;
  for (const dir of scratch.splice(0)) fs.rmSync(dir, { recursive: true, force: true });
});

function tempDir(prefix: string): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  scratch.push(dir);
  return dir;
}

/** A Claude Code transcript line. */
function said(type: "user" | "assistant", at: number, content: unknown, extra: Record<string, unknown> = {}): string {
  const message = type === "user" ? { role: "user", content } : { role: "assistant", content, stop_reason: extra.stop };
  return JSON.stringify({ type, timestamp: new Date(at).toISOString(), message, ...extra }) + "\n";
}

/** A line of a Claude chat's own message chain, as the named program's process writes it. */
function chained(entrypoint: string, type: "user" | "assistant", at: number, content: unknown, extra: Record<string, unknown> = {}): string {
  return said(type, at, content, { uuid: `${type}-${at}`, entrypoint, ...extra });
}

it("tells whether a transcript's last turn had ended", () => {
  const dir = tempDir("codeaw-turn-");
  const file = path.join(dir, "chat.jsonl");
  const t = Date.parse("2026-11-23T10:00:00Z");
  const turn = () => lastTranscriptTurn(file, "claude");
  fs.writeFileSync(file, said("user", t, "Fix it"));
  expect(turn()).toEqual({ at: new Date(t).toISOString(), settled: false });
  fs.appendFileSync(file, said("assistant", t + 1, [{ type: "tool_use", name: "Bash" }], { stop: "tool_use" }));
  expect(turn()?.settled).toBe(false);
  fs.appendFileSync(file, said("user", t + 2, [{ type: "tool_result", content: "ok" }]));
  expect(turn()?.settled).toBe(false);
  fs.appendFileSync(file, said("assistant", t + 3, [{ type: "text", text: "Fixed." }], { stop: "end_turn" }));
  expect(turn()).toEqual({ at: new Date(t + 3).toISOString(), settled: true });
  // A subagent's own lines do not end or continue the chat's turn.
  fs.appendFileSync(file, said("assistant", t + 4, [{ type: "tool_use" }], { stop: "tool_use", isSidechain: true }));
  expect(turn()?.at).toBe(new Date(t + 3).toISOString());
  fs.appendFileSync(file, said("user", t + 5, "Next"));
  expect(turn()?.settled).toBe(false);
  fs.appendFileSync(file, said("user", t + 6, [{ type: "text", text: "[Request interrupted by user]" }]));
  expect(turn()?.settled).toBe(true);

  const codex = path.join(dir, "rollout.jsonl");
  const event = (type: string, payload: Record<string, unknown>, at: number) => JSON.stringify({ timestamp: new Date(at).toISOString(), type, payload }) + "\n";
  fs.writeFileSync(codex, event("event_msg", { type: "user_message" }, t) + event("response_item", { type: "message" }, t + 1));
  expect(lastTranscriptTurn(codex, "codex")?.settled).toBe(false);
  fs.appendFileSync(codex, event("event_msg", { type: "task_complete" }, t + 2));
  expect(lastTranscriptTurn(codex, "codex")).toEqual({ at: new Date(t + 2).toISOString(), settled: true });
});

/** One entry of Claude Code's registry of running sessions, as the Claude desktop app's process writes it. */
function register(configDir: string, pid: number, entry: Record<string, unknown>): void {
  fs.mkdirSync(path.join(configDir, "sessions"), { recursive: true });
  fs.writeFileSync(path.join(configDir, "sessions", `${pid}.json`), JSON.stringify({ pid, kind: "interactive", startedAt: Date.now(), updatedAt: Date.now(), ...entry }));
}

it("brings an open chat up to date once a turn taken in the Claude desktop app is over", async () => {
  const home = tempDir("codeaw-follow-");
  const claudeDir = path.join(home, "claude");
  const stateFile = path.join(home, "fake-state.json");
  const running = new Set([4242]);
  tb = await startTestBridge({
    home, agentId: "claude-fake", claudeProcessAlive: (pid) => running.has(pid),
    agent: { env: { FAKE_AGENT_STATE: stateFile, FAKE_AGENT_MCP: "stdio", FAKE_AGENT_RELOAD: "1", CLAUDE_CONFIG_DIR: claudeDir } },
  });
  const manager = tb.bridge.manager as any;
  const c = await TestClient.connect(tb.url, tb.tokenFor("phone"));
  clients.push(c);
  const { sessionId } = await c.request("session/new", { cwd: home, mcpServers: [], _meta: { codeaw: { agentId: "claude-fake" } } });
  const backendId = sessionId.slice("claude-fake:".length);
  const held = () => manager.sessions.get(sessionId).backendGen > 0;
  await c.request("session/prompt", promptText(sessionId, "echo from the phone"));

  // The desktop app opens the chat; codeaw closes its own process for it.
  const desktop = (status: string) => register(claudeDir, 4242, { sessionId: backendId, entrypoint: "claude-desktop-3p", hostSessionId: "local_y", status });
  desktop("idle");
  await manager.sweep();
  expect(held()).toBe(false);

  // A turn there: the agent's saved history and its transcript move on.
  const transcript = path.join(claudeDir, "projects", claudeProjectSlug(home), `${backendId}.jsonl`);
  fs.mkdirSync(path.dirname(transcript), { recursive: true });
  const elsewhere = (question: string, answer: string) => {
    const state = JSON.parse(fs.readFileSync(stateFile, "utf8"));
    state[backendId].history.push(
      { sessionUpdate: "user_message_chunk", content: { type: "text", text: question } },
      { sessionUpdate: "agent_message_chunk", messageId: `m-${answer}`, content: { type: "text", text: answer } },
    );
    fs.writeFileSync(stateFile, JSON.stringify(state));
  };
  // Later than codeaw's own contact with the chat.
  let at = Date.now() + 5000;
  elsewhere("from the desktop", "Desktop answer");
  fs.writeFileSync(transcript, said("user", at, "from the desktop") + said("assistant", at + 1, [{ type: "tool_use" }], { stop: "tool_use" }));
  desktop("busy");

  const replays = () => c.received.filter((m) => m.method === "_codeaw/replay" && m.params.sessionId === sessionId);
  const known = replays().length;
  const mark = c.received.length;
  // Mid-turn there: reading the chat now could write into that turn.
  await manager.follow();
  fs.appendFileSync(transcript, said("assistant", at + 2, [{ type: "text", text: "Desktop answer" }], { stop: "end_turn" }));
  await manager.follow(); // answered, but the app has not finished the turn yet
  expect(replays()).toHaveLength(known);
  expect(held()).toBe(false);

  desktop("idle");
  await manager.follow();
  await c.waitFor(() => replays().length === known + 2);
  expect(replays().slice(known).map((m) => m.params.mode)).toEqual(["full", "complete"]);
  // The screen gets the rebuilt history whole (one page), not also the import's replay as new
  // turns: that replay streams the phone's echo again in three chunks.
  const seqs = c.received.slice(mark).filter((m) => m.method === "session/update").map((m) => m.params._meta.codeaw.seq);
  expect(new Set(seqs).size).toBe(seqs.length);
  expect(c.received.slice(mark).filter((m) => m.method === "session/update" && m.params.update.content?.text === "echo from the phone")).toHaveLength(1);
  const texts = (from: number) => c.received.slice(from).filter((m) => m.method === "session/update" && m.params.update.sessionUpdate === "agent_message_chunk").map((m) => m.params.update.content.text).join("");
  expect(texts(mark)).toContain("Desktop answer");
  expect(held()).toBe(false); // the app stays the chat's only writer
  await manager.follow();
  expect(replays()).toHaveLength(known + 2);

  // Another turn there, and the phone sends before the next check: the turn comes in first.
  at += 10_000;
  elsewhere("again from the desktop", "Second desktop answer");
  fs.appendFileSync(transcript, said("user", at, "again from the desktop") + said("assistant", at + 1, [{ type: "text", text: "Second desktop answer" }], { stop: "end_turn" }));
  const before = c.received.length;
  expect((await c.request("session/prompt", promptText(sessionId, "echo after both"))).stopReason).toBe("end_turn");
  const sent = texts(before);
  expect(sent.indexOf("Second desktop answer")).toBeGreaterThanOrEqual(0);
  expect(sent.indexOf("Second desktop answer")).toBeLessThan(sent.indexOf("after both"));

  // A turn still running in another app, unknown to the registry: the phone waits for it.
  await manager.sweep();
  expect(held()).toBe(false);
  at += 10_000;
  fs.appendFileSync(transcript, said("user", at, "from a terminal"));
  await expect(c.request("session/prompt", promptText(sessionId, "echo too early"))).rejects.toThrow(/middle of a turn in this chat/);
});

it("ends a reload from the computer with a complete history", async () => {
  tb = await startTestBridge({ agentId: "claude-fake" });
  const c = await TestClient.connect(tb.url, tb.tokenFor("phone"));
  clients.push(c);
  const { sessionId } = await c.request("session/new", { cwd: tb.home, mcpServers: [], _meta: { codeaw: { agentId: "claude-fake" } } });
  await c.request("session/prompt", promptText(sessionId, "echo hello"));
  const mark = c.received.length;
  const { epoch } = await c.request("_codeaw/session/reimport", { sessionId });
  await c.waitFor(() => c.received.slice(mark).some((m) => m.method === "_codeaw/replay" && m.params.mode === "complete"));
  const after = c.received.slice(mark);
  expect(after.filter((m) => m.method === "_codeaw/replay").map((m) => [m.params.mode, m.params.epoch])).toEqual([["full", epoch], ["complete", epoch]]);
  expect(after.filter((m) => m.method === "session/update" && m.params.update.sessionUpdate === "agent_message_chunk").map((m) => m.params.update.content.text).join("")).toContain("hello");
});

it("tells which program wrote a chat's newest message", () => {
  const dir = tempDir("codeaw-chain-");
  const file = path.join(dir, "chat.jsonl");
  const t = Date.parse("2026-11-25T10:00:00Z");
  expect(lastChainWrite(file)).toBeUndefined();
  fs.writeFileSync(file, chained("claude-desktop-3p", "user", t, "Fix it"));
  expect(lastChainWrite(file)).toEqual({ at: t, desktop: true });
  fs.appendFileSync(file, chained("sdk-ts", "user", t + 1000, "And this"));
  expect(lastChainWrite(file)).toEqual({ at: t + 1000, desktop: false });
  // Not part of the chat's own chain: a subagent's line, a title, a line cut short.
  fs.appendFileSync(file, chained("claude-desktop-3p", "assistant", t + 2000, [{ type: "text", text: "Looking" }], { isSidechain: true }));
  fs.appendFileSync(file, JSON.stringify({ type: "ai-title", aiTitle: "Fixes", timestamp: new Date(t + 3000).toISOString() }) + "\n");
  fs.appendFileSync(file, '{"uuid":"cut","timestamp":\n');
  expect(lastChainWrite(file)).toEqual({ at: t + 1000, desktop: false });
  fs.appendFileSync(file, chained("claude-desktop", "assistant", t + 4000, [{ type: "text", text: "Fixed." }], { stop: "end_turn" }));
  expect(lastChainWrite(file)).toEqual({ at: t + 4000, desktop: true });
});

it("removes the registry entry of a process it ended, and no other", () => {
  const root = tempDir("codeaw-forget-");
  const entry = path.join(root, "sessions", "4242.json");
  const holder = { pid: 4242, procStart: "134400813473843167" };
  forgetClaudeProcess(root, "chat", holder); // nothing there
  register(root, 4242, { sessionId: "another-chat", entrypoint: "claude-desktop-3p", procStart: holder.procStart });
  forgetClaudeProcess(root, "chat", holder);
  expect(fs.existsSync(entry)).toBe(true);
  // A later process given the same id has written its own entry.
  register(root, 4242, { sessionId: "chat", entrypoint: "claude-desktop-3p", procStart: "134400899999999999" });
  forgetClaudeProcess(root, "chat", holder);
  expect(fs.existsSync(entry)).toBe(true);
  register(root, 4242, { sessionId: "chat", entrypoint: "claude-desktop-3p", procStart: holder.procStart });
  forgetClaudeProcess(root, "chat", holder);
  expect(fs.existsSync(entry)).toBe(false);
});

it("hands a chat back to the Claude desktop app after a turn taken here", async () => {
  const home = tempDir("codeaw-handback-");
  const claudeDir = path.join(home, "claude");
  const running = new Set<number>();
  const ended: DesktopHolder[] = [];
  let outcome: ProcessEnd = "ended";
  tb = await startTestBridge({
    home, agentId: "claude-fake", claudeProcessAlive: (pid) => running.has(pid),
    endClaudeProcess: async (holder) => {
      ended.push(holder);
      if (outcome === "ended") running.delete(holder.pid);
      return outcome;
    },
    agent: { env: { FAKE_AGENT_STATE: path.join(home, "fake-state.json"), FAKE_AGENT_MCP: "stdio", CLAUDE_CONFIG_DIR: claudeDir } },
  });
  const manager = tb.bridge.manager as any;
  const c = await TestClient.connect(tb.url, tb.tokenFor("phone"));
  clients.push(c);
  const { sessionId } = await c.request("session/new", { cwd: home, mcpServers: [], _meta: { codeaw: { agentId: "claude-fake" } } });
  const backendId = sessionId.slice("claude-fake:".length);
  const held = () => manager.sessions.get(sessionId).backendGen > 0;
  const send = async (text: string) => expect((await c.request("session/prompt", promptText(sessionId, text))).stopReason).toBe("end_turn");
  const transcript = path.join(claudeDir, "projects", claudeProjectSlug(home), `${backendId}.jsonl`);
  fs.mkdirSync(path.dirname(transcript), { recursive: true });
  const entry = path.join(claudeDir, "sessions", "4242.json");
  // All of it a minute old: nothing here reads as a turn another app took since codeaw's last.
  const t = Date.now() - 60_000;
  const desktop = (status: string, startedAt = t) => {
    running.add(4242);
    register(claudeDir, 4242, { sessionId: backendId, entrypoint: "claude-desktop-3p", hostSessionId: "local_y", status, startedAt, procStart: "134400813473843167" });
  };

  // The app's process wrote the newest message itself: it has the whole chat.
  fs.writeFileSync(transcript, chained("claude-desktop-3p", "user", t + 1000, "from the desktop") + chained("claude-desktop-3p", "assistant", t + 2000, [{ type: "text", text: "Desktop answer" }], { stop: "end_turn" }));
  desktop("idle");
  await send("echo one");
  expect(ended).toHaveLength(0);

  // A turn here, written after the app's process started: that process has not seen it.
  fs.appendFileSync(transcript, chained("sdk-ts", "user", t + 3000, "from the phone") + chained("sdk-ts", "assistant", t + 4000, [{ type: "text", text: "Phone answer" }], { stop: "end_turn" }));
  await send("echo two");
  await c.waitFor(() => ended.length === 1);
  expect(ended[0]).toEqual({ pid: 4242, busy: false, startedAt: t, procStart: "134400813473843167" });
  // Its registry entry goes with it, and codeaw keeps its own process for the chat.
  await c.waitFor(() => !fs.existsSync(entry));
  await manager.sweep();
  expect(held()).toBe(true);

  // A process the app started after that turn has read it.
  desktop("idle", Date.now());
  await send("echo three");
  expect(ended).toHaveLength(1);

  // In a turn there, or waiting inside one for an answer: left alone.
  for (const status of ["busy", "waiting"]) {
    desktop(status);
    await manager.handBack(manager.sessions.get(sessionId));
  }
  expect(ended).toHaveLength(1);

  // A process that cannot be ended (it runs a shell command) stays, and codeaw leaves the chat to it.
  outcome = "working";
  desktop("idle");
  await send("echo four");
  await c.waitFor(() => ended.length === 2);
  expect(fs.existsSync(entry)).toBe(true);
  await manager.sweep();
  expect(held()).toBe(false);
});

it("takes in a turn the Claude desktop app took while codeaw still had the chat open", async () => {
  const home = tempDir("codeaw-meanwhile-");
  const claudeDir = path.join(home, "claude");
  const stateFile = path.join(home, "fake-state.json");
  const running = new Set<number>();
  tb = await startTestBridge({
    home, agentId: "claude-fake", claudeProcessAlive: (pid) => running.has(pid), endClaudeProcess: async () => "unsupported",
    agent: { env: { FAKE_AGENT_STATE: stateFile, FAKE_AGENT_MCP: "stdio", FAKE_AGENT_RELOAD: "1", CLAUDE_CONFIG_DIR: claudeDir } },
  });
  const manager = tb.bridge.manager as any;
  const c = await TestClient.connect(tb.url, tb.tokenFor("phone"));
  clients.push(c);
  const { sessionId } = await c.request("session/new", { cwd: home, mcpServers: [], _meta: { codeaw: { agentId: "claude-fake" } } });
  const backendId = sessionId.slice("claude-fake:".length);
  const session = () => manager.sessions.get(sessionId);
  const held = () => session().backendGen > 0;
  const transcript = path.join(claudeDir, "projects", claudeProjectSlug(home), `${backendId}.jsonl`);
  fs.mkdirSync(path.dirname(transcript), { recursive: true });
  const texts = (from: number) => c.received.slice(from).filter((m) => m.method === "session/update" && m.params.update.sessionUpdate === "agent_message_chunk").map((m) => m.params.update.content.text).join("");
  // A whole turn in the app, written by its own process. Codeaw's process, open on the chat
  // since before, may report something of its own afterwards; that is no reading of this turn.
  const elsewhere = (question: string, answer: string) => {
    const state = JSON.parse(fs.readFileSync(stateFile, "utf8"));
    state[backendId].history.push(
      { sessionUpdate: "user_message_chunk", content: { type: "text", text: question } },
      { sessionUpdate: "agent_message_chunk", messageId: `m-${answer}`, content: { type: "text", text: answer } },
    );
    // An agent opens a chat with its own default settings.
    state[backendId].mode = "ask";
    fs.writeFileSync(stateFile, JSON.stringify(state));
    const now = Date.now();
    fs.appendFileSync(transcript, chained("claude-desktop-3p", "user", now, question) + chained("claude-desktop-3p", "assistant", now + 1, [{ type: "text", text: answer }], { stop: "end_turn" }));
    manager.onUpdate("claude-fake", { sessionId: backendId, update: { sessionUpdate: "usage_update", used: 10, size: 1000 } });
  };
  const mode = () => session().meta.configOptions.find((o: any) => o.id === "mode").currentValue;

  // No process of the app's was on the chat, so codeaw kept its own after the phone's turn.
  await c.request("session/set_config_option", { sessionId, configId: "mode", value: "code" });
  await c.request("session/prompt", promptText(sessionId, "echo from the phone"));
  await manager.sweep();
  expect(held()).toBe(true);
  // The app then starts one, which reads the chat, and takes a turn.
  running.add(4242);
  register(claudeDir, 4242, { sessionId: backendId, entrypoint: "claude-desktop-3p", hostSessionId: "local_y", status: "idle" });
  elsewhere("from the desktop", "Desktop answer");

  // The phone answers before any check has run: codeaw's process would continue from before that turn.
  let mark = c.received.length;
  expect((await c.request("session/prompt", promptText(sessionId, "echo after the desktop"))).stopReason).toBe("end_turn");
  const sent = texts(mark);
  expect(sent.indexOf("Desktop answer")).toBeGreaterThanOrEqual(0);
  expect(sent.indexOf("Desktop answer")).toBeLessThan(sent.indexOf("after the desktop"));
  // Reading the chat again does not cost it the mode (or model) chosen for it on the phone.
  expect(mode()).toBe("code");
  expect(JSON.parse(fs.readFileSync(stateFile, "utf8"))[backendId].mode).toBe("code");

  // With the chat open on a phone, the check itself lets go of codeaw's process and brings the app's next turn in.
  expect(held()).toBe(true);
  elsewhere("again from the desktop", "Second desktop answer");
  const replays = () => c.received.filter((m) => m.method === "_codeaw/replay" && m.params.sessionId === sessionId);
  const known = replays().length;
  mark = c.received.length;
  await manager.follow();
  await c.waitFor(() => replays().length === known + 2);
  expect(texts(mark)).toContain("Second desktop answer");
  expect(held()).toBe(false);
  expect(mode()).toBe("code");

  // And the minute sweep does not hide such a turn from the next check either.
  expect((await c.request("session/prompt", promptText(sessionId, "echo once more"))).stopReason).toBe("end_turn");
  expect(held()).toBe(true);
  elsewhere("a third time from the desktop", "Third desktop answer");
  await manager.sweep();
  expect(held()).toBe(false);
  mark = c.received.length;
  await manager.follow();
  await c.waitFor(() => texts(mark).includes("Third desktop answer"));
});

it("does not open or reload a chat while another app is in the middle of a turn in it", async () => {
  const home = tempDir("codeaw-midturn-");
  const claudeDir = path.join(home, "claude");
  const stateFile = path.join(home, "fake-state.json");
  const running = new Set<number>();
  // A chat begun in another app, which codeaw has not opened yet.
  fs.writeFileSync(stateFile, JSON.stringify({ native1: {
    cwd: home, updatedAt: new Date().toISOString(), mode: "ask",
    history: [{ sessionUpdate: "user_message_chunk", content: { type: "text", text: "from the desktop" } }],
  } }));
  tb = await startTestBridge({
    home, agentId: "claude-fake", claudeProcessAlive: (pid) => running.has(pid),
    agent: { env: { FAKE_AGENT_STATE: stateFile, FAKE_AGENT_MCP: "stdio", FAKE_AGENT_RELOAD: "1", CLAUDE_CONFIG_DIR: claudeDir } },
  });
  const c = await TestClient.connect(tb.url, tb.tokenFor("phone"));
  clients.push(c);
  const id = "claude-fake:native1";
  const transcript = path.join(claudeDir, "projects", claudeProjectSlug(home), "native1.jsonl");
  fs.mkdirSync(path.dirname(transcript), { recursive: true });
  const at = Date.now();
  fs.writeFileSync(transcript, said("user", at, "from the desktop") + said("assistant", at + 1, [{ type: "tool_use" }], { stop: "tool_use" }));
  const open = () => c.request("session/load", { sessionId: id, cwd: home, mcpServers: [] });
  const desktop = (status: string) => register(claudeDir, 4242, { sessionId: "native1", entrypoint: "claude-desktop-3p", hostSessionId: "local_y", status });

  // Opening it now would make the agent answer the message that turn is still working on.
  await expect(open()).rejects.toThrow(/middle of a turn in this chat/);
  // Answered, but the app is waiting inside the turn for the person there.
  fs.appendFileSync(transcript, said("assistant", at + 2, [{ type: "text", text: "Desktop answer" }], { stop: "end_turn" }));
  running.add(4242);
  desktop("waiting");
  await expect(open()).rejects.toThrow(/middle of a turn in this chat/);
  desktop("idle");
  await open();
  expect(c.text(id, "user_message_chunk")).toContain("from the desktop");

  // The same for a reload asked for from the phone.
  desktop("busy");
  await expect(c.request("_codeaw/session/reimport", { sessionId: id })).rejects.toThrow(/middle of a turn in this chat/);
  desktop("idle");
  expect((await c.request("_codeaw/session/reimport", { sessionId: id })).epoch).toBeTruthy();
});
