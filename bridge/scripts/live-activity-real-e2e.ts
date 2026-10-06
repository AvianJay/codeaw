/** Real Codex only. Defaults to an isolated localhost bridge; --installed tests
 * the already-running bridge without restarting it. --desktop-session must be
 * a dedicated, idle test chat. Pairing credentials never reach the report. */
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { parseArgs } from "node:util";
import * as acp from "@agentclientprotocol/sdk";
import { createWebSocketStream } from "@agentclientprotocol/sdk/experimental/ws-client";
import WebSocket from "ws";
import { loadConfig } from "../src/config.js";
import { startBridge, type Bridge } from "../src/bridge.js";
import { requestControl } from "../src/desktop/control.js";
import { CodexDesktopIpc } from "../src/backend/codex-desktop-ipc.js";
import { applyDesktopPatches, desktopTurns } from "../src/backend/codex-desktop-state.js";

const { values } = parseArgs({ options: { config: { type: "string" }, cwd: { type: "string" }, report: { type: "string" }, installed: { type: "boolean", default: false }, "desktop-session": { type: "string" } } });
if (!values.cwd) throw new Error("--cwd is required");
const original = loadConfig(values.config);
assert.ok(original.config.agents.codex, "Real Codex configuration required");
let bridge: Bridge | undefined;
let token: string;
let deviceId: string;
let port: number;
let installedBuild: number | undefined;
if (values.installed) {
  const status = await requestControl(original.file, { command: "status" });
  assert.equal(status.state, "running", "Installed bridge must already be running");
  port = status.port;
  installedBuild = status.buildNumber;
  const pairing = await requestControl(original.file, { command: "pair" });
  const response = await fetch(`http://127.0.0.1:${port}/api/pair`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ code: pairing.code, deviceName: "Live Activity real regression" }),
  });
  assert.equal(response.status, 200, "Temporary test-device pairing failed");
  const paired = await response.json() as { token: string; deviceId: string };
  token = paired.token; deviceId = paired.deviceId;
} else {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-real-activity-"));
  const config = { ...original.config, agents: { codex: original.config.agents.codex }, notifications: {}, workspaces: [values.cwd] };
  bridge = await startBridge({ ...original, config, home, file: path.join(home, "config.yaml"), dataDir: path.join(home, "data") }, { hosts: ["127.0.0.1"], port: 0 });
  token = randomUUID() + randomUUID();
  deviceId = bridge.devices.addDeviceWithToken("Live Activity real regression", token).id;
  port = bridge.port();
}
const url = `ws://127.0.0.1:${port}/acp`;
const connections: acp.ClientConnection[] = [];
const testSessions = new Set<string>();
let senderForCleanup: Awaited<ReturnType<typeof connect>> | undefined;
const checks: object[] = [];
const ipc = new CodexDesktopIpc();
let desktopSnapshot: any;
let owner: string | undefined;
let currentPhase: string | undefined;

async function connect() {
  const received: { method: string; params: any }[] = [];
  const record = (method: string) => (ctx: { params: any }) => { received.push({ method, params: ctx.params }); };
  const any = (p: unknown) => p as any;
  const app = acp.client({ name: "codeaw-live-activity-real" })
    .onNotification("session/update", record("session/update"))
    .onNotification("_codeaw/event", any, record("_codeaw/event"))
    .onNotification("_codeaw/replay", any, record("_codeaw/replay"))
    .onNotification("_codeaw/activity", any, record("_codeaw/activity"))
    .onRequest("session/request_permission", (ctx) => {
      const once = ctx.params.options.find((o) => o.kind === "allow_once");
      return { outcome: once ? { outcome: "selected" as const, optionId: once.optionId } : { outcome: "cancelled" as const } };
    });
  const conn = app.connect(createWebSocketStream(url, { WebSocket: WebSocket as any, headers: { Authorization: `Bearer ${token}` } }));
  connections.push(conn);
  const request = async (method: string, params: unknown = {}) => {
    try { return await conn.agent.request<any>(method, params as never); }
    catch (error) { throw new Error(`${method}: ${error instanceof Error ? error.message : String(error)}`); }
  };
  await request("initialize", { protocolVersion: acp.PROTOCOL_VERSION, clientCapabilities: {} });
  return { conn, received, request };
}
async function waitFor(pred: () => boolean, timeout = 90000) {
  const start = Date.now();
  while (!pred()) { if (Date.now() - start > timeout) throw new Error("Live Activity real test timed out"); await new Promise((resolve) => setTimeout(resolve, 50)); }
}
try {
  const sender = await connect();
  senderForCleanup = sender;
  let watcher = await connect();
  const phases = ["acp", ...(values["desktop-session"] ? ["desktop"] : [])];
  for (const phase of phases) {
    currentPhase = phase;
    let id: string;
    if (phase === "acp") {
      const session = await sender.request("session/new", { cwd: values.cwd, mcpServers: [], _meta: { codeaw: { agentId: "codex" } } });
      id = session.sessionId;
      testSessions.add(id);
    } else {
      id = values["desktop-session"]!;
      const nativeId = id.replace(/^codex:/, "");
      const discovery = await ipc.request("thread-owner-discovery", { hostId: "local", conversationId: nativeId });
      owner = discovery.handledByClientId;
      ipc.on("message", (m) => {
        if (m.method !== "thread-stream-state-changed" || m.params?.conversationId !== nativeId) return;
        const change = m.params.change;
        if (change.type === "snapshot") desktopSnapshot = change.conversationState;
        else if (desktopSnapshot && change.type === "patches") desktopSnapshot = applyDesktopPatches(desktopSnapshot, change.patches);
      });
      await ipc.broadcast("thread-stream-following-changed", { hostId: "local", conversationId: nativeId, following: true }, [owner!]);
      await waitFor(() => desktopSnapshot !== undefined, 15000);
      assert.ok(!desktopTurns(desktopSnapshot).some((t) => ["inProgress", "running", "requires_action"].includes(t.status)), "Dedicated desktop test chat is busy; refusing to interrupt it");
      const loaded = await sender.request("session/load", { sessionId: id, cwd: values.cwd, mcpServers: [] });
      assert.equal(loaded._meta.codeaw.connection, "desktop");
    }
    for (const [configId, value] of [["model", "gpt-6-luna"], ["reasoning_effort", "low"]]) {
      const response = await sender.request("session/set_config_option", { sessionId: id, configId, value });
      assert.equal(response.configOptions.find((o: any) => o.id === configId)?.currentValue, value);
    }
    watcher.received.length = 0;
    const offset = sender.received.length;
    const run = sender.request("session/prompt", { sessionId: id, prompt: [{ type: "text", text:
      "Codeaw Live Activity integration test. Explain briefly what you are checking, then run exactly one read-only PowerShell command: Start-Sleep -Seconds 12; Write-Output 'CODEAW_ACTIVITY_OK'. Then reply only CODEAW_ACTIVITY_OK. Do not edit files, do not delegate, and do not launch any extra task." }] });
    run.catch(() => {});
    const activities = () => watcher.received.filter((r) => r.method === "_codeaw/activity" && r.params.sessionId === id).map((r) => r.params);
    await waitFor(() => activities().some((s) => s.state === "running" && s.work.phase === "command" && /Start-Sleep/i.test(s.work.summary)));
    const command = activities().find((s) => s.work.phase === "command" && /Start-Sleep/i.test(s.work.summary));
    assert.equal(command.work.project.toLowerCase(), path.basename(values.cwd!).toLowerCase());
    assert.equal(typeof command.turnStartedAt, "number");
    const thoughts = activities().filter((s) => s.work.phase === "thinking");
    // The watcher never attaches to this session and still obtains a full snapshot after reconnect.
    watcher.conn.close(); watcher = await connect();
    const list = await watcher.request("_codeaw/activity/list");
    const restored = list.activities.find((s: any) => s.sessionId === id);
    assert.equal(restored.turnPromptId, command.turnPromptId);
    assert.equal(restored.turnStartedAt, command.turnStartedAt);
    assert.equal(restored.work.phase, "command");
    await run;
    await waitFor(() => activities().some((s) => s.state === "idle" && s.completedTurn));
    const end = activities().find((s) => s.state === "idle" && s.completedTurn);
    assert.equal(end.completedTurn.promptId, command.turnPromptId);
    assert.equal(end.completedTurn.startedAt, command.turnStartedAt);
    assert.equal(end.work.phase, "completed");
    assert.ok(end.completedTurn.endedAt > end.completedTurn.startedAt);
    const answer = sender.received.slice(offset).filter((r) => r.method === "session/update" && r.params.sessionId === id && r.params.update.sessionUpdate === "agent_message_chunk")
      .map((r) => r.params.update.content?.text ?? "").join("");
    assert.ok(answer.includes("CODEAW_ACTIVITY_OK"));
    assert.ok(!watcher.received.some((r) => r.method === "session/update"));
    let actualModel = "gpt-6-luna", actualEffort = "low";
    if (phase === "desktop") {
      const turn = desktopTurns(desktopSnapshot).at(-1);
      actualModel = turn.params.model; actualEffort = turn.params.effort;
      assert.equal(actualModel, "gpt-6-luna"); assert.equal(actualEffort, "low");
    }
    const check = { phase, status: "passed", sessionId: id, model: actualModel, effort: actualEffort, project: command.work.project,
      command: command.work.summary, turnId: command.turnPromptId, startedAt: command.turnStartedAt, endedAt: end.completedTurn.endedAt,
      thinkingUpdates: thoughts.length, thinkingExcerpts: thoughts.map((s) => s.work.summary), reconnectedWithoutChatAttachment: true, answer };
    checks.push(check); console.log(JSON.stringify(check));
    await sender.request("session/close", { sessionId: id });
    testSessions.delete(id);
  }
} catch (error) {
  checks.push({ phase: currentPhase, status: "failed", error: error instanceof Error ? error.message : String(error) });
  throw error;
} finally {
  if (values.report) fs.writeFileSync(values.report, JSON.stringify({ at: new Date().toISOString(), checks, realCodex: true, isolatedBridge: !values.installed, testedInstalledBridge: values.installed, installedBuild, bridgeRestartedByTest: false }, null, 2));
  if (owner) await ipc.broadcast("thread-stream-following-changed", { hostId: "local", conversationId: values["desktop-session"]!.replace(/^codex:/, ""), following: false }, [owner]).catch(() => {});
  ipc.close();
  for (const sessionId of testSessions) await senderForCleanup?.request("session/close", { sessionId }).catch(() => {});
  for (const conn of connections) conn.close();
  if (bridge) {
    bridge.devices.revoke(deviceId);
    await bridge.stop();
  } else {
    await requestControl(original.file, { command: "revoke", id: deviceId });
  }
  // Keep the unique test home for evidence; it contains no persistent pairing after revocation.
}
