import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { afterEach, expect, it } from "vitest";
import { SessionStore } from "../src/session/store.js";
import { startTestBridge, TestClient, newFakeSession, promptText, type TestBridge } from "./helpers.js";

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
const remove = (client: TestClient, sessionId: string, promptId: string) => client.request("_codeaw/session/remove_prompt", { sessionId, promptId });

it("removes only one queued prompt, preserves the active turn and other queue entries, and broadcasts to every device", async () => {
  bridge = await startTestBridge();
  const a = await connect(), s = await newFakeSession(a, bridge.home), id = s.sessionId;
  let answer!: (value: any) => void;
  a.permissionAnswer = () => new Promise((resolve) => { answer = resolve; });
  const first = a.request("session/prompt", promptText(id, "perm"));
  await a.waitFor(() => a.events(id, "permission_request").length === 1);
  const b = await connect("tablet");
  await b.request("session/load", { sessionId: id, cwd: bridge.home, mcpServers: [] });
  const before = a.events(id, "state").at(-1)!.event;
  const drop = randomUUID(), keep = randomUUID();
  const dropped = a.request("session/prompt", promptText(id, "echo MUST_NOT_RUN", { clientPromptId: drop, delivery: "queue" }));
  const kept = a.request("session/prompt", promptText(id, "echo OTHER_QUEUE_RUNS", { clientPromptId: keep, delivery: "queue" }));
  await a.waitFor(() => a.events(id, "state").at(-1)?.event.queued === 2);
  expect(await remove(a, id, drop)).toEqual({ removed: true });
  expect((await dropped).stopReason).toBe("cancelled");
  await b.waitFor(() => b.events(id, "dequeued").some((e) => e.event.promptId === drop && e.event.removed));
  const state = a.events(id, "state").at(-1)!.event;
  expect(state).toMatchObject({ state: "requires_action", queued: 1, turnPromptId: before.turnPromptId, turnStartedAt: before.turnStartedAt });
  expect(a.events(id, "permission_resolved")).toHaveLength(0);
  expect(await remove(a, id, drop)).toEqual({ removed: true });
  answer({ outcome: { outcome: "selected", optionId: "reject" } });
  expect((await first).stopReason).toBe("end_turn");
  expect((await kept).stopReason).toBe("end_turn");
  expect(a.text(id)).not.toContain("MUST_NOT_RUN");
  expect(a.text(id)).toContain("OTHER_QUEUE_RUNS");
  const replay = await connect("reopened");
  await replay.request("session/load", { sessionId: id, cwd: bridge.home, mcpServers: [] });
  expect(replay.events(id, "dequeued").findLast((e) => e.event.promptId === drop)?.event).toMatchObject({ cancelled: true, removed: true });
});

it("rejects removal once a prompt is running or has been read", async () => {
  bridge = await startTestBridge();
  const a = await connect(), s = await newFakeSession(a, bridge.home), active = randomUUID();
  const first = a.request("session/prompt", promptText(s.sessionId, "perm", { clientPromptId: active }));
  await a.waitFor(() => a.events(s.sessionId, "permission_request").length === 1);
  expect(await remove(a, s.sessionId, active)).toEqual({ removed: false, reason: "processing" });
  expect(a.events(s.sessionId, "dequeued")).toHaveLength(0);
  await a.notify("session/cancel", { sessionId: s.sessionId }); await first;
  const read = randomUUID();
  await a.request("session/prompt", promptText(s.sessionId, "echo READ", { clientPromptId: read }));
  expect(await remove(a, s.sessionId, read)).toEqual({ removed: false, reason: "processing" });
});

it("cancels a not-yet-accepted prompt while its agent connection is pending", async () => {
  bridge = await startTestBridge();
  const a = await connect(), s = await newFakeSession(a, bridge.home), id = randomUUID();
  const agent = bridge.bridge.registry.get("fake"), start = agent.ensureStarted.bind(agent);
  let release!: () => void, entered!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const connecting = new Promise<void>((resolve) => { entered = resolve; });
  agent.ensureStarted = async () => { entered(); await gate; await start(); };
  const pending = a.request("session/prompt", promptText(s.sessionId, "echo RACING_SEND", { clientPromptId: id }));
  await connecting;
  expect(await remove(a, s.sessionId, id)).toEqual({ removed: true });
  release();
  expect((await pending).stopReason).toBe("cancelled");
  expect(a.text(s.sessionId)).not.toContain("RACING_SEND");
});

it("protects in-flight steering and starts its queued fallback if the previous turn finishes first", async () => {
  bridge = await startTestBridge({ steering: true });
  const a = await connect(), s = await newFakeSession(a, bridge.home), id = randomUUID();
  let answer!: (value: any) => void;
  a.permissionAnswer = () => new Promise((resolve) => { answer = resolve; });
  const first = a.request("session/prompt", promptText(s.sessionId, "perm"));
  await a.waitFor(() => a.events(s.sessionId, "permission_request").length === 1);
  const agent = bridge.bridge.registry.get("fake"), request = agent.request.bind(agent);
  let release!: () => void, entered!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const steering = new Promise<void>((resolve) => { entered = resolve; });
  agent.request = async (method, params) => {
    if (method === "_session/steering") { entered(); await gate; return { outcome: "promptRequired" } as any; }
    return request(method, params);
  };
  const pending = a.request("session/prompt", promptText(s.sessionId, "echo FALLBACK_AFTER_FINISH", { clientPromptId: id }));
  await steering;
  expect(await remove(a, s.sessionId, id)).toEqual({ removed: false, reason: "processing" });
  answer({ outcome: { outcome: "selected", optionId: "reject" } }); await first;
  release();
  expect((await pending).stopReason).toBe("end_turn");
  expect(a.text(s.sessionId)).toContain("FALLBACK_AFTER_FINISH");
});

it("persists an unknown prompt tombstone and prevents a late or replayed request from dispatching it", async () => {
  bridge = await startTestBridge();
  const a = await connect(), s = await newFakeSession(a, bridge.home), pending = randomUUID();
  expect(await remove(a, s.sessionId, pending)).toEqual({ removed: true });
  const before = a.text(s.sessionId);
  const late = await a.request("session/prompt", promptText(s.sessionId, "echo LATE_MUST_NOT_RUN", { clientPromptId: pending }));
  expect(late).toMatchObject({ stopReason: "cancelled", _meta: { codeaw: { duplicate: true } } });
  expect(a.text(s.sessionId)).toBe(before);
  await expect(remove(a, s.sessionId, "invalid")).rejects.toThrow(/Invalid promptId/);
});

it("settles legacy orphaned queues after restart and keeps removal durable", async () => {
  bridge = await startTestBridge({ keepHome: true });
  const home = bridge.home, a = await connect(), s = await newFakeSession(a, home), pending = randomUUID();
  a.close(); await bridge.stop(); bridge = undefined;
  const store = new SessionStore(`${home}/data`);
  const meta = store.readMeta(s.sessionId)!;
  store.append(s.sessionId, { seq: ++meta.lastSeq, t: Date.now(), kind: "update", update: {
    sessionUpdate: "user_message_chunk", content: { type: "text", text: "legacy stuck queue" },
    _meta: { codeaw: { mid: `u-${pending}`, promptId: pending, queued: true } },
  } });
  store.append(s.sessionId, { seq: ++meta.lastSeq, t: Date.now(), kind: "event", event: { type: "prompt_receipt", promptId: pending, status: "received" } });
  store.writeMeta(meta); store.closeAll();
  try {
    bridge = await startTestBridge({ home });
    const b = await connect();
    await b.request("session/load", { sessionId: s.sessionId, cwd: home, mcpServers: [] });
    expect(b.events(s.sessionId, "dequeued").findLast((e) => e.event.promptId === pending)?.event.cancelled).toBe(true);
    expect(await remove(b, s.sessionId, pending)).toEqual({ removed: true });
    b.close(); await bridge.stop();
    bridge = await startTestBridge({ home });
    const c = await connect();
    await c.request("session/load", { sessionId: s.sessionId, cwd: home, mcpServers: [] });
    expect(c.events(s.sessionId, "dequeued").findLast((e) => e.event.promptId === pending)?.event.removed).toBe(true);
    expect((await c.request("session/prompt", promptText(s.sessionId, "echo NO_RESEND", { clientPromptId: pending }))).stopReason).toBe("cancelled");
  } finally {
    for (const c of clients) c.close();
    await bridge?.stop(); bridge = undefined;
    if (path.dirname(home) !== path.resolve(os.tmpdir()) || !path.basename(home).startsWith("codeaw-test-")) throw new Error("Invalid test cleanup directory");
    fs.rmSync(home, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
});
