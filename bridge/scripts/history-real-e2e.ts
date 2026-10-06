/** Real Codex history transport and concurrent activity regression.
 * Existing chats are only loaded/expanded/detached. Prompts run in new test chats.
 * Reports include counts, hashes and timings, never transcript or pairing secrets.
 */
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { gunzipSync } from "node:zlib";
import { parseArgs } from "node:util";
import * as acp from "@agentclientprotocol/sdk";
import { createWebSocketStream } from "@agentclientprotocol/sdk/experimental/ws-client";
import WebSocket from "ws";
import { loadConfig } from "../src/config.js";
import { startBridge, type Bridge } from "../src/bridge.js";
import { requestControl } from "../src/desktop/control.js";
import { SessionStore } from "../src/session/store.js";
import { compactLog } from "../src/session/compact.js";
import { lazyToolEntry } from "../src/session/history.js";
import { safeName } from "../src/util/paths.js";

const { values } = parseArgs({ options: {
  config: { type: "string" }, cwd: { type: "string" }, session: { type: "string" },
  report: { type: "string" }, fixture: { type: "string" }, installed: { type: "boolean", default: false },
  "history-only": { type: "boolean", default: false },
  "expect-compression": { type: "boolean", default: false },
} });
assert.ok(values.cwd && values.session, "--cwd and --session are required");
const original = loadConfig(values.config);
const source = new SessionStore(original.dataDir);
const originalEntries = source.readEntries(values.session);
const compact = compactLog(originalEntries);
const projected = compact.map((entry) => lazyToolEntry(entry));
const bytes = (v: unknown) => Buffer.byteLength(JSON.stringify(v));
const checks: any[] = [{ phase: "durable-history", entries: originalEntries.length,
  fullBytes: bytes(compact), lazyBytes: bytes(projected),
  reductionPercent: 100 * (1 - bytes(projected) / bytes(compact)),
  deferredTools: projected.filter((e) => e.kind === "update" && (e.update as any)._meta?.codeaw?.deferredTool).length }];
if (values.fixture) fs.writeFileSync(values.fixture, JSON.stringify(projected)); // PC-local only; never commit.

let bridge: Bridge | undefined, port: number, token: string, deviceId: string, installedBuild: number | undefined;
if (values.installed) {
  const status = await requestControl(original.file, { command: "status" });
  assert.equal(status.state, "running"); port = status.port; installedBuild = status.buildNumber;
  const pair = await requestControl(original.file, { command: "pair" });
  const response = await fetch(`http://127.0.0.1:${port}/api/pair`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ code: pair.code, deviceName: "History real regression" }),
  });
  assert.equal(response.status, 200);
  ({ token, deviceId } = await response.json() as any);
} else {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-real-history-"));
  const dataDir = path.join(home, "data");
  fs.cpSync(path.join(original.dataDir, "sessions", safeName(values.session)),
    path.join(dataDir, "sessions", safeName(values.session)), { recursive: true });
  bridge = await startBridge({ ...original, home, dataDir, file: path.join(home, "config.yaml"),
    config: { ...original.config, agents: { codex: original.config.agents.codex }, notifications: {}, workspaces: [values.cwd] } },
    { hosts: ["127.0.0.1"], port: 0 });
  token = randomUUID() + randomUUID(); deviceId = bridge.devices.addDeviceWithToken("History real regression", token).id;
  port = bridge.port();
}
const connections: acp.ClientConnection[] = [];
const newSessions = new Set<string>();
const activeRuns: Promise<unknown>[] = [];
let cleanupClient: Awaited<ReturnType<typeof connect>> | undefined;
async function connect(compress = true) {
  const received: { method: string; params: any }[] = [];
  const record = (method: string) => (ctx: { params: any }) => { received.push({ method, params: ctx.params }); };
  const any = (v: unknown) => v as any;
  const app = acp.client({ name: "codeaw-history-real" })
    .onNotification("session/update", record("session/update"))
    .onNotification("_codeaw/event", any, record("_codeaw/event"))
    .onNotification("_codeaw/replay", any, record("_codeaw/replay"))
    .onNotification("_codeaw/history/page", any, record("_codeaw/history/page"))
    .onNotification("_codeaw/activity", any, record("_codeaw/activity"))
    .onRequest("session/request_permission", (ctx) => {
      const once = ctx.params.options.find((o) => o.kind === "allow_once");
      return { outcome: once ? { outcome: "selected" as const, optionId: once.optionId } : { outcome: "cancelled" as const } };
    });
  let socket: WebSocket;
  let gzipFrames = 0;
  class MeasuredSocket extends WebSocket {
    constructor(url: string, protocols: string | string[] | undefined, options: WebSocket.ClientOptions) {
      super(url, protocols, { ...options, perMessageDeflate: compress });
      socket = this;
    }
    override emit(event: string | symbol, ...args: any[]): boolean {
      if (event === 'message' && args[1] === true && args[0]?.[0] === 0x1f && args[0]?.[1] === 0x8b) {
        gzipFrames++;
        args = [gunzipSync(args[0]).toString('utf8'), false];
      }
      return super.emit(event, ...args);
    }
  }
  const conn = app.connect(createWebSocketStream(`ws://127.0.0.1:${port}/acp${compress ? '?codeawCompression=gzip' : ''}`, {
    WebSocket: MeasuredSocket as any, headers: { Authorization: `Bearer ${token}` },
  }));
  connections.push(conn);
  const request = (method: string, params: unknown = {}) => conn.agent.request<any>(method, params as never);
  await request("initialize", { protocolVersion: acp.PROTOCOL_VERSION, clientCapabilities: {} });
  const wireBytes = () => (socket as any)._socket.bytesRead as number;
  return { conn, received, request, wireBytes, compressed: socket!.extensions.includes("permessage-deflate"), gzipFrames: () => gzipFrames };
}
async function waitFor(pred: () => boolean, timeout = 120000) {
  const start = Date.now();
  while (!pred()) {
    if (Date.now() - start > timeout) throw new Error("Real history/activity test timed out");
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
}
try {
  const full = await connect(false), lazy = await connect(); cleanupClient = lazy;
  const load = async (client: typeof full, deferred: boolean, pageBytes?: number) => {
    client.received.length = 0;
    const wireStart = client.wireBytes();
    const start = performance.now();
    const result = await client.request("session/load", { sessionId: values.session, cwd: values.cwd, mcpServers: [],
      _meta: { codeaw: { lazyHistory: deferred, ...(pageBytes ? { pageBytes, lazyHistoryBytes: 2048 } : {}) } } });
    await waitFor(() => client.received.some((r) => r.method === "_codeaw/replay" && r.params.sessionId === values.session), 15000);
    const entries = client.received.filter((r) => r.params.sessionId === values.session && ["session/update", "_codeaw/event"].includes(r.method));
    return { result, entries, milliseconds: performance.now() - start, bytes: bytes(entries), wireBytes: client.wireBytes() - wireStart };
  };
  const fullReplay = await load(full, false), lazyReplay = await load(lazy, true);
  if (values["expect-compression"]) assert.ok(lazy.compressed || lazy.gzipFrames() > 0, "Real socket must receive compressed frames");
  assert.equal(lazyReplay.result._meta.codeaw.connection, "desktop");
  const desktopActivity = (await lazy.request("_codeaw/activity/list")).activities.find((a: any) => a.sessionId === values.session);
  const knownTitle = source.readMeta(values.session)?.title;
  if (knownTitle) assert.equal(desktopActivity.title, knownTitle);
  const candidates = lazyReplay.entries.filter((r) => r.params.update?._meta?.codeaw?.deferredTool && r.params.update.status === "completed")
    .sort((a, b) => b.params.update._meta.codeaw.deferredTool.bytes - a.params.update._meta.codeaw.deferredTool.bytes);
  assert.ok(candidates.length, "Real long history must exercise deferred tools");
  const selected = candidates[0].params.update;
  const detail = await lazy.request("_codeaw/history/tool", { sessionId: values.session,
    epoch: lazyReplay.result._meta.codeaw.epoch, toolCallId: selected.toolCallId });
  const originalTool = fullReplay.entries.find((r) => r.params.update?.toolCallId === selected.toolCallId)?.params.update;
  assert.ok(originalTool, "Tool must be present in the full replay");
  const contents = (u: any) => ({ title: u.title, rawInput: u.rawInput, content: u.content, rawOutput: u.rawOutput,
    terminal: u._meta?.terminal_output, claudeResponse: u._meta?.claudeCode?.toolResponse });
  assert.deepEqual(contents(detail.update), contents(originalTool));
  checks.push({ phase: "real-desktop-transport", status: "passed", sessionId: values.session,
    connection: "desktop", fullBytes: fullReplay.bytes, lazyBytes: lazyReplay.bytes,
    fullWireBytes: fullReplay.wireBytes, lazyWireBytes: lazyReplay.wireBytes, compressionNegotiated: lazy.compressed,
    gzipFrames: lazy.gzipFrames(),
    fullLoadMs: fullReplay.milliseconds, lazyLoadMs: lazyReplay.milliseconds,
    hydrationExact: true, knownChatTitleMatches: !!knownTitle, hydrationBytes: bytes(contents(detail.update)),
    hydrationSha256: createHash("sha256").update(JSON.stringify(contents(detail.update))).digest("hex") });
  const paged = await connect();
  const firstPage = await load(paged, true, 48 * 1024);
  const boundary = paged.received.find((r) => r.method === "_codeaw/replay" && r.params.sessionId === values.session)?.params;
  assert.ok(Number.isInteger(boundary.before), "Real long history must have an older page");
  assert.ok(firstPage.wireBytes < lazyReplay.wireBytes / 2, "First page must reduce the initial transfer");
  const pageWireStart = paged.wireBytes();
  await paged.request("_codeaw/history/page", { sessionId: values.session, epoch: firstPage.result._meta.codeaw.epoch,
    before: boundary.before, pageBytes: 48 * 1024 });
  await waitFor(() => paged.received.some((r) => r.method === "_codeaw/history/page" && r.params.requested === boundary.before), 15000);
  const older = paged.received.find((r) => r.method === "_codeaw/history/page" && r.params.requested === boundary.before)!.params;
  assert.ok(older.entries.length);
  assert.ok(older.before === undefined || older.before < boundary.before, "Older-page cursor must progress");
  checks.push({ phase: "real-paged-history", status: "passed", dataSaver: true, pageBudget: 48 * 1024,
    firstPageWireBytes: firstPage.wireBytes, firstPageEntries: firstPage.entries.length,
    olderPageWireBytes: paged.wireBytes() - pageWireStart, olderPageEntries: older.entries.length,
    cursorProgressed: true, firstPageLoadMs: firstPage.milliseconds });
  await paged.conn.agent.notify("_codeaw/session/detach", { sessionId: values.session } as never).catch(() => {});
  paged.conn.close();
  const cursor = { ...lazyReplay.result._meta.codeaw };
  for (const r of lazy.received) {
    if (r.params.sessionId !== values.session) continue;
    if (r.method === "_codeaw/replay" && r.params.mode === "complete") {
      cursor.epoch = r.params.epoch; cursor.lastSeq = r.params.lastSeq;
    } else if (r.params._meta?.codeaw?.seq) cursor.lastSeq = Math.max(cursor.lastSeq, r.params._meta.codeaw.seq);
  }
  lazy.conn.close();
  const reconnect = await connect(); cleanupClient = reconnect;
  const wireStart = reconnect.wireBytes();
  const start = performance.now();
  const reloaded = await reconnect.request("session/load", { sessionId: values.session, cwd: values.cwd, mcpServers: [],
    _meta: { codeaw: { lazyHistory: true, epoch: cursor.epoch, afterSeq: cursor.lastSeq } } });
  await waitFor(() => reconnect.received.some((r) => r.method === "_codeaw/replay" && r.params.sessionId === values.session), 15000);
  const mode = reconnect.received.find((r) => r.method === "_codeaw/replay")?.params.mode;
  assert.ok(mode === "delta" || (mode === "full" && reloaded._meta.codeaw.epoch !== cursor.epoch),
    "Full reconnect must be explained by an authoritative epoch change");
  checks.push({ phase: "history-reconnect", status: "passed", mode, epochChanged: reloaded._meta.codeaw.epoch !== cursor.epoch, milliseconds: performance.now() - start,
    bytes: bytes(reconnect.received.filter((r) => r.params.sessionId === values.session)) });
  checks.at(-1).wireBytes = reconnect.wireBytes() - wireStart;
  await full.conn.agent.notify("_codeaw/session/detach", { sessionId: values.session } as never).catch(() => {});
  await reconnect.conn.agent.notify("_codeaw/session/detach", { sessionId: values.session } as never).catch(() => {});

  if (!values["history-only"]) {
    const watcher = await connect();
    const ids: string[] = [];
    for (let i = 0; i < 2; i++) {
      const r = await reconnect.request("session/new", { cwd: values.cwd, mcpServers: [], _meta: { codeaw: { agentId: "codex" } } });
      ids.push(r.sessionId); newSessions.add(r.sessionId);
      for (const [configId, value] of [["model", "gpt-6-luna"], ["reasoning_effort", "low"]]) {
        const configured = await reconnect.request("session/set_config_option", { sessionId: r.sessionId, configId, value });
        assert.equal(configured.configOptions.find((o: any) => o.id === configId)?.currentValue, value);
      }
    }
    const runs = ids.map((sessionId, i) => reconnect.request("session/prompt", { sessionId, prompt: [{ type: "text", text:
      `Codeaw concurrent Live Activity test ${i + 1}. Briefly state what you are testing, then run exactly one read-only PowerShell command: Start-Sleep -Seconds 18; Write-Output 'CODEAW_CONCURRENT_${i + 1}_OK'. Then reply only CODEAW_CONCURRENT_${i + 1}_OK. Do not edit files or delegate.` }] }));
    runs.forEach((r) => r.catch(() => {}));
    activeRuns.push(...runs);
    const active = new Map<string, any>();
    await waitFor(() => {
      for (const r of watcher.received) if (r.method === "_codeaw/activity" && ids.includes(r.params.sessionId)) active.set(r.params.sessionId, r.params);
      return ids.every((id) => active.get(id)?.state === "running" && active.get(id)?.work?.phase === "command");
    });
    await watcher.request("session/list"); // Real ACP publishes generated titles through its native list.
    const snapshot = await watcher.request("_codeaw/activity/list");
    for (const id of ids) {
      const activity = snapshot.activities.find((a: any) => a.sessionId === id);
      assert.equal(activity.state, "running");
      assert.ok(activity.title, "Generated chat title must reach the activity snapshot");
      assert.ok(activity.turnPromptId && activity.turnStartedAt);
    }
    await Promise.all(runs);
    await waitFor(() => ids.every((id) => watcher.received.some((r) => r.method === "_codeaw/activity" && r.params.sessionId === id && r.params.state === "idle" && r.params.completedTurn)));
    assert.ok(!watcher.received.some((r) => r.method === "session/update"));
    checks.push({ phase: "real-concurrent-work", status: "passed", model: "gpt-6-luna", effort: "low",
      sessions: ids, overlappingCommands: true, titlesPresent: true, watcherNeverAttached: true, completionObserved: true });
    for (const id of ids) {
      await reconnect.request("session/delete", { sessionId: id }); newSessions.delete(id);
      await assert.rejects(reconnect.request("session/load", { sessionId: id, cwd: values.cwd, mcpServers: [] }), /deleted/);
    }
    const listed = await reconnect.request("session/list", {});
    assert.ok(ids.every(id => !listed.sessions.some((s: any) => s.sessionId === id)));
    checks.push({ phase: "real-chat-deletion", status: "passed", onlyDedicatedTestChats: true, refreshKeepsDeleted: true, reopeningRejected: true });
  }
  console.log(JSON.stringify({ checks }));
} catch (error) {
  checks.push({ phase: "failure", status: "failed", error: error instanceof Error ? error.message : String(error) });
  throw error;
} finally {
  if (values.report) fs.writeFileSync(values.report, JSON.stringify({ at: new Date().toISOString(), checks,
    realCodex: true, installed: values.installed, installedBuild, primaryChatPrompted: false, bridgeRestartedByTest: false }, null, 2));
  await cleanupClient?.conn.agent.notify("_codeaw/session/detach", { sessionId: values.session } as never).catch(() => {});
  // A failed assertion must not interrupt an otherwise healthy test turn.
  await Promise.allSettled(activeRuns);
  for (const id of newSessions) await cleanupClient?.request("session/close", { sessionId: id }).catch(() => {});
  connections.forEach((c) => c.close());
  if (bridge) { bridge.devices.revoke(deviceId); await bridge.stop(); }
  else await requestControl(original.file, { command: "revoke", id: deviceId });
}
