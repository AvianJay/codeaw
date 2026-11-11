import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import zlib from "node:zlib";
import { afterEach, describe, expect, it, onTestFinished } from "vitest";
import { compactLog } from "../src/session/compact.js";
import { claudeProjectSlug, lastTranscriptActivity, NativeActivity, transcriptKind } from "../src/session/native-activity.js";
import type { LogEntry } from "../src/session/types.js";
import { newFakeSession, promptText, rawLog, startTestBridge, TestClient, type TestBridge } from "./helpers.js";

let tb: TestBridge | undefined;
const clients: TestClient[] = [];

async function client(name = "phone"): Promise<TestClient> {
  const c = await TestClient.connect(tb!.url, tb!.tokenFor(name));
  clients.push(c);
  return c;
}

afterEach(async () => {
  for (const c of clients.splice(0)) c.close();
  await tb?.stop();
  tb = undefined;
});

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function listed(c: TestClient, sessionId: string): Promise<string> {
  const list = await c.request("session/list", {});
  return list.sessions.find((x: any) => x.sessionId === sessionId).updatedAt;
}

function notices(tb: TestBridge, sessionId: string): any[] {
  return rawLog(tb, sessionId).filter((r) => r.method === "session/update" && r.params.update.sessionUpdate === "notice");
}

describe("last activity time", () => {
  it("keeps a chat's time when it is reopened, reconfigured or replayed after a restart", async () => {
    const first = await startTestBridge({ keepHome: true, touchOnOpen: true });
    const keptHome = first.home;
    onTestFinished(() => fs.rmSync(keptHome, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }));
    const c1 = await TestClient.connect(first.url, first.tokenFor("A"));
    const s = await newFakeSession(c1, first.home);
    await c1.request("session/prompt", promptText(s.sessionId, "echo hello"));
    const asked = await listed(c1, s.sessionId);
    c1.close();
    await first.stop();
    await sleep(60);

    tb = await startTestBridge({ home: first.home, touchOnOpen: true });
    const c = await client();
    expect(await listed(c, s.sessionId)).toBe(asked);

    // Opening resumes the agent session, which rewrites its file and logs settings.
    await c.request("session/load", { sessionId: s.sessionId, cwd: first.home, mcpServers: [] });
    await c.request("session/set_config_option", { sessionId: s.sessionId, configId: "mode", value: "code" });
    await c.waitFor(() => notices(tb!, s.sessionId).length > 0);
    expect(await listed(c, s.sessionId)).toBe(asked);
    const pushed = c.received.filter((r) => r.method === "_codeaw/activity" && r.params.sessionId === s.sessionId);
    for (const activity of pushed) expect(activity.params.updatedAt).toBe(asked);

    await sleep(20);
    await c.request("session/prompt", promptText(s.sessionId, "echo again"));
    expect(Date.parse(await listed(c, s.sessionId))).toBeGreaterThan(Date.parse(asked));
  });

  it("keeps the agent's own time when importing a chat the bridge has never seen", async () => {
    const first = await startTestBridge({ keepHome: true, touchOnOpen: true });
    const keptHome = first.home;
    onTestFinished(() => fs.rmSync(keptHome, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }));
    const c1 = await TestClient.connect(first.url, first.tokenFor("A"));
    const s = await newFakeSession(c1, first.home);
    await c1.request("session/prompt", promptText(s.sessionId, "echo from the terminal"));
    c1.close();
    await first.stop();
    await sleep(60);

    tb = await startTestBridge({ home: first.home, freshData: true, touchOnOpen: true });
    const c = await client();
    const before = await listed(c, s.sessionId);
    await c.request("session/load", { sessionId: s.sessionId, cwd: first.home, mcpServers: [] });
    expect(c.text(s.sessionId)).toBe("from the terminal");
    expect(await listed(c, s.sessionId)).toBe(before);
  });

  it("orders chats by when they were last asked, not by when they were last opened", async () => {
    tb = await startTestBridge({ touchOnOpen: true });
    const c = await client();
    const older = await newFakeSession(c, tb.home);
    await c.request("session/prompt", promptText(older.sessionId, "echo one"));
    await sleep(30);
    const newer = await newFakeSession(c, tb.home);
    await c.request("session/prompt", promptText(newer.sessionId, "echo two"));
    await sleep(30);
    await c.request("session/set_config_option", { sessionId: older.sessionId, configId: "mode", value: "code" });
    const list = await c.request("session/list", {});
    expect(list.sessions.map((x: any) => x.sessionId)).toEqual([newer.sessionId, older.sessionId]);
  });
});

describe("repeated notices", () => {
  it("records a warning the agent repeats on every resume only once", async () => {
    const first = await startTestBridge({ keepHome: true, touchOnOpen: true });
    const keptHome = first.home;
    onTestFinished(() => fs.rmSync(keptHome, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }));
    const c1 = await TestClient.connect(first.url, first.tokenFor("A"));
    const s = await newFakeSession(c1, first.home);
    await c1.request("session/prompt", promptText(s.sessionId, "echo hello"));
    c1.close();
    await first.stop();

    for (let round = 0; round < 3; round++) {
      tb = await startTestBridge({ home: first.home, touchOnOpen: true });
      const c = await client();
      await c.request("session/load", { sessionId: s.sessionId, cwd: first.home, mcpServers: [] });
      await c.request("session/prompt", promptText(s.sessionId, `echo round ${round}`));
      await c.waitFor(() => notices(tb!, s.sessionId).length > 0);
      await sleep(50);
      expect(notices(tb, s.sessionId)).toHaveLength(1);
      for (const open of clients.splice(0)) open.close();
      await tb.stop();
      tb = undefined;
    }
  });

  it("hides duplicates already saved by older bridges when replaying", () => {
    const notice = (seq: number, title: string): LogEntry => ({ seq, t: seq, kind: "update", update: { sessionUpdate: "notice", severity: "warning", title } as any });
    const message = (seq: number, text: string): LogEntry => ({ seq, t: seq, kind: "update", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text }, _meta: { codeaw: { mid: `m${seq}` } } } as any });
    const out = compactLog([notice(1, "deprecated"), notice(2, "ignored"), message(3, "hi"), notice(4, "deprecated"), notice(5, "ignored"), notice(6, "new")]);
    expect(out.filter((e) => e.kind === "update" && (e.update.sessionUpdate as string) === "notice").map((e: any) => e.update.title)).toEqual(["deprecated", "ignored", "new"]);
    expect(out).toHaveLength(4);
  });
});

describe("agent transcripts", () => {
  const dir = () => {
    const d = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-transcript-"));
    onTestFinished(() => fs.rmSync(d, { recursive: true, force: true }));
    return d;
  };
  const line = (o: unknown) => JSON.stringify(o) + "\n";

  it("recognises the agents whose transcripts it can read", () => {
    expect(transcriptKind("claude", { command: "C:\\agents\\claude-agent-acp.exe" })).toBe("claude");
    expect(transcriptKind("work", { command: "/usr/bin/codex-acp" })).toBe("codex");
    expect(transcriptKind("opencode", { command: "opencode" })).toBeUndefined();
    expect(claudeProjectSlug("E:\\Front TV Custom Thing")).toBe("E--Front-TV-Custom-Thing");
    expect(claudeProjectSlug("C:\\Users\\me\\.codeaw\\data")).toBe("C--Users-me--codeaw-data");
  });

  it("reads Claude's last message and ignores what a resume appends", () => {
    const home = dir();
    const project = path.join(home, "projects", claudeProjectSlug("E:\\work"));
    fs.mkdirSync(project, { recursive: true });
    const file = path.join(project, "abc-123.jsonl");
    fs.writeFileSync(file,
      line({ type: "user", timestamp: "2026-01-02T03:04:05.000Z", message: { role: "user", content: "hi" } }) +
      line({ type: "assistant", timestamp: "2026-01-02T03:04:09.500Z", message: { role: "assistant", content: [] } }) +
      line({ type: "user", isMeta: true, timestamp: "2026-05-05T00:00:00.000Z", message: { role: "user", content: "meta" } }) +
      line({ type: "assistant", isSidechain: true, timestamp: "2026-05-06T00:00:00.000Z" }) +
      line({ type: "cost-state", sessionId: "abc-123", blob: "x".repeat(200_000) }) +
      line({ type: "ai-title", timestamp: "2026-06-01T00:00:00.000Z" }) +
      '{"type":"assistant","timestamp":"2026-07-01T00:00');
    expect(lastTranscriptActivity(file, "claude")).toBe("2026-01-02T03:04:09.500Z");

    const native = new NativeActivity();
    const config = { command: "claude-agent-acp", env: { CLAUDE_CONFIG_DIR: home } };
    expect(native.lastMessageAt("claude", config, "abc-123", "E:\\work")).toBe("2026-01-02T03:04:09.500Z");
    // Found by id even when the cwd is unknown or maps to another directory name.
    expect(native.lastMessageAt("claude", config, "abc-123")).toBe("2026-01-02T03:04:09.500Z");
    expect(native.lastMessageAt("claude", config, "..\\..\\secret", "E:\\work")).toBeUndefined();
    expect(native.lastMessageAt("claude", config, "missing", "E:\\work")).toBeUndefined();

    fs.appendFileSync(file, "\n" + line({ type: "assistant", timestamp: "2026-08-01T00:00:00.000Z", message: {} }));
    expect(native.lastMessageAt("claude", config, "abc-123", "E:\\work")).toBe("2026-08-01T00:00:00.000Z");
  });

  it("reads Codex's last turn and ignores reapplied settings", () => {
    const home = dir();
    const day = path.join(home, "sessions", "2026", "11", "09");
    fs.mkdirSync(day, { recursive: true });
    const id = "01a1bfcc-b13c-79f3-953c-6883c662e952";
    fs.writeFileSync(path.join(day, `rollout-2026-11-09T18-13-45-${id}.jsonl`),
      line({ timestamp: "2026-11-09T10:13:45.000Z", type: "session_meta", payload: { id } }) +
      line({ timestamp: "2026-11-09T10:20:00.000Z", type: "response_item", payload: { type: "message", role: "assistant" } }) +
      line({ timestamp: "2026-11-09T10:20:01.000Z", type: "event_msg", payload: { type: "task_complete" } }) +
      line({ timestamp: "2026-11-10T14:00:24.000Z", type: "event_msg", payload: { type: "thread_settings_applied" } }) +
      line({ timestamp: "2026-11-11T09:00:35.000Z", type: "event_msg", payload: { type: "thread_settings_applied" } }));
    const native = new NativeActivity();
    const config = { command: "codex-acp.cmd", env: { CODEX_HOME: home } };
    expect(native.lastMessageAt("codex", config, id)).toBe("2026-11-09T10:20:01.000Z");

    // Older transcripts are compressed whole.
    const old = "019e2aa7-2596-7e23-b4e7-82393dec3e29";
    const packed = zlib.zstdCompressSync(Buffer.from(
      line({ timestamp: "2026-05-15T08:00:57.000Z", type: "response_item", payload: { type: "message", role: "user" } }) +
      line({ timestamp: "2026-05-15T08:03:00.000Z", type: "event_msg", payload: { type: "token_count" } })));
    fs.mkdirSync(path.join(home, "archived_sessions"));
    fs.writeFileSync(path.join(home, "archived_sessions", `rollout-2026-05-15T16-00-57-${old}.jsonl.zst`), packed);
    expect(new NativeActivity().lastMessageAt("codex", config, old)).toBe("2026-05-15T08:00:57.000Z");
  });
});
