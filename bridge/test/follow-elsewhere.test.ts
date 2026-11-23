import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, expect, it } from "vitest";
import { claudeProjectSlug, lastTranscriptTurn } from "../src/session/native-activity.js";
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
