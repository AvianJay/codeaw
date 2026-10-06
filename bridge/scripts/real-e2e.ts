/** Real, billable Codex smoke against an already running installed bridge.
 * No fake agent or test bridge is launched. Credentials come from a private
 * file containing {token}; the report never includes the token.
 *
 * npx tsx scripts/real-e2e.ts --auth <file> --cwd <existing-workspace>
 *   --phase acp|desktop|filesystem --session codex:<dedicated-test-id>
 */
import fs from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { parseArgs } from "node:util";
import * as acp from "@agentclientprotocol/sdk";
import { createWebSocketStream } from "@agentclientprotocol/sdk/experimental/ws-client";
import WebSocket from "ws";
import { CodexDesktopIpc } from "../src/backend/codex-desktop-ipc.js";
import { applyDesktopPatches, projectDesktopConversation } from "../src/backend/codex-desktop-state.js";

const { values } = parseArgs({ options: {
  auth: { type: "string" }, cwd: { type: "string" }, session: { type: "string" },
  phase: { type: "string", default: "acp" },
  url: { type: "string", default: "ws://127.0.0.1:7860/acp" },
  report: { type: "string" },
} });
if (!values.auth || !values.cwd) throw new Error("--auth and --cwd are required");
const { token } = JSON.parse(fs.readFileSync(values.auth, "utf8"));
if (typeof token !== "string") throw new Error("Token file has no token");
const received: { method: string; params: any }[] = [];
const checks: Record<string, unknown>[] = [];
let conn: acp.ClientConnection;
const record = (method: string) => (ctx: { params: any }) => {
  received.push({ method, params: ctx.params });
  if (method === "_codeaw/terminal/event" && ctx.params.data?.includes("\x1b[6n")) {
    void request("_codeaw/terminal/write", { terminalId: ctx.params.terminalId, data: "\x1b[1;1R" });
  }
};
const any = (p: unknown) => p as any;
const client = acp.client({ name: "codeaw-real-e2e" })
  .onNotification("session/update", record("session/update"))
  .onNotification("_codeaw/event", any, record("_codeaw/event"))
  .onNotification("_codeaw/replay", any, record("_codeaw/replay"))
  .onNotification("_codeaw/terminal/event", any, record("_codeaw/terminal/event"))
  .onRequest("session/request_permission", async (ctx) => {
    const once = ctx.params.options.find((option) => option.kind === "allow_once");
    return once ? { outcome: { outcome: "selected" as const, optionId: once.optionId } } : { outcome: { outcome: "cancelled" as const } };
  });
conn = client.connect(createWebSocketStream(values.url!, { WebSocket: WebSocket as any, headers: { Authorization: `Bearer ${token}` } }));
function request<T = any>(method: string, params: unknown): Promise<T> {
  return conn.agent.request(method, params as never) as Promise<T>;
}
async function waitFor(pred: () => boolean, timeout = 90000) {
  const start = Date.now();
  while (!pred()) {
    if (Date.now() - start > timeout) throw new Error("Real E2E timed out waiting for a notification");
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
}
function updates(id: string, after = 0) {
  return received.slice(after).filter((r) => r.method === "session/update" && r.params.sessionId === id).map((r) => r.params.update);
}
function text(id: string, after = 0) {
  return updates(id, after).filter((u) => u.sessionUpdate === "agent_message_chunk" && u.content.type === "text").map((u) => u.content.text).join("");
}
function passed(name: string, detail: unknown) { checks.push({ name, status: "passed", detail }); console.log(JSON.stringify(checks.at(-1))); }
function settingsSummary(snapshot: any) {
  const s = snapshot.latestThreadSettings;
  return { model: s.model, effort: s.effort, mode: s.sandboxPolicy?.type, collaborationMode: s.collaborationMode?.mode };
}
async function setting(id: string, configId: string, value: string) {
  const r = await request("session/set_config_option", { sessionId: id, configId, value });
  assert.equal(r.configOptions.find((o: any) => o.id === configId)?.currentValue, value);
  return r;
}
const http = new URL(values.url!); http.protocol = http.protocol === "wss:" ? "https:" : "http:";
const uploadBlock = (u: { name: string; uri: string; size: number; mimeType?: string }) => ({ type: "resource_link", name: u.name, uri: u.uri, size: u.size, ...(u.mimeType ? { mimeType: u.mimeType } : {}) });
const prompt = (id: string, message: string, blocks: any[] = []) => request("session/prompt", { sessionId: id, prompt: [{ type: "text", text: message }, ...blocks] });
let id = values.session;
const ipc = new CodexDesktopIpc({ timeoutMs: 15000 });
try {
  await request("initialize", { protocolVersion: acp.PROTOCOL_VERSION, clientCapabilities: {} });
  // Populate native session roots, as the app's session list does on connect.
  await request("session/list", {});
  if (values.phase === "acp") {
    const s = await request("session/new", { cwd: values.cwd, mcpServers: [], _meta: { codeaw: { agentId: "codex" } } });
    id = s.sessionId;
    await setting(id!, "model", "gpt-6-luna");
    await setting(id!, "reasoning_effort", "low");
    const marker = `CODEAW_UPLOAD_${randomUUID()}`;
    const bytes = Buffer.from(marker, "utf8");
    const url = new URL("/api/uploads", http); url.searchParams.set("name", "真實上傳.txt");
    const response = await fetch(url, { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: bytes });
    assert.equal(response.status, 200);
    const upload = await response.json() as any;
    assert.deepEqual(fs.readFileSync(upload.path), bytes);
    const offset = received.length;
    await prompt(id!, "This is a Codeaw integration test. Read the attached file from its local path and reply with only its entire contents. Do not modify any files.", [uploadBlock(upload)]);
    assert.ok(text(id!, offset).includes(marker), "Real Codex did not read the uploaded file");
    passed("real-acp-file-upload", { sessionId: id, model: "gpt-6-luna", effort: "low", path: upload.path, answer: text(id!, offset) });
    const roots = await request("_codeaw/workspaces/list", {});
    assert.equal(roots.allowAllPaths, false, "Run the default-deny test before enabling the PC opt-in");
    await assert.rejects(request("_codeaw/fs/list", { path: process.platform === "win32" ? "C:\\" : "/" }), /outside/);
    await assert.rejects(request("session/new", { cwd: path.join(values.cwd!, `missing-${randomUUID()}`), mcpServers: [], _meta: { codeaw: { agentId: "codex" } } }), /does not exist/);
    passed("filesystem-default-deny-and-missing-cwd", { allowAllPaths: roots.allowAllPaths });
    const terminal = await request("_codeaw/terminal/open", { cwd: values.cwd, cols: 100, rows: 30 });
    try {
      await new Promise((resolve) => setTimeout(resolve, 800));
      const start = received.length;
      await request("_codeaw/terminal/write", { terminalId: terminal.terminalId, data: "Write-Output ('CODEAW_'+'PS_LF_OK'); (Get-Location).Path\n" });
      await waitFor(() => received.slice(start).some((r) => r.method === "_codeaw/terminal/event" && r.params.data?.includes("CODEAW_PS_LF_OK")));
      const output = received.slice(start).filter((r) => r.method === "_codeaw/terminal/event").map((r) => r.params.data ?? "").join("");
      assert.ok(output.replaceAll("\\", "/").toLowerCase().includes(values.cwd!.replaceAll("\\", "/").toLowerCase()));
      passed("installed-powershell-lf", { shell: terminal.shell, cwd: terminal.cwd, output });
    } finally { await request("_codeaw/terminal/close", { terminalId: terminal.terminalId }); }
    await request("session/close", { sessionId: id });
  } else if (values.phase === "desktop") {
    if (!id) throw new Error("Use the dedicated sessionId from the ACP phase");
    const native = id.replace(/^codex:/, "");
    const owner = await ipc.request("thread-owner-discovery", { hostId: "local", conversationId: native });
    let snapshot: any;
    ipc.on("message", (message) => {
      if (message.method !== "thread-stream-state-changed" || message.params?.conversationId !== native) return;
      const change = message.params.change;
      if (change.type === "snapshot") snapshot = change.conversationState;
      else if (snapshot && change.type === "patches") snapshot = applyDesktopPatches(snapshot, change.patches);
    });
    await ipc.broadcast("thread-stream-following-changed", { hostId: "local", conversationId: native, following: true }, [owner.handledByClientId!]);
    await waitFor(() => snapshot !== undefined, 15000);
    const loaded = await request("session/load", { sessionId: id, cwd: values.cwd, mcpServers: [] });
    assert.equal(loaded._meta?.codeaw?.connection, "desktop");
    const changes = [["model", "gpt-6-sol"], ["model", "gpt-6-luna"], ["reasoning_effort", "medium"], ["mode", "read-only"], ["mode", "agent-full-access"], ["mode", "agent"], ["collaboration_mode", "plan"], ["collaboration_mode", "default"], ["reasoning_effort", "low"]];
    for (const [key, value] of changes) await setting(id, key, value);
    passed("real-desktop-settings", { sessionId: id, owner: owner.handledByClientId, changes, settings: settingsSummary(snapshot) });
    const marker = `DESKTOP_UPLOAD_${randomUUID()}`;
    const url = new URL("/api/uploads", http); url.searchParams.set("name", "desktop-upload.txt");
    const uploadResponse = await fetch(url, { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: marker });
    assert.equal(uploadResponse.status, 200);
    const upload = await uploadResponse.json() as any;
    await prompt(id, "Read the attached file from its local path and reply only with its entire contents. Do not modify files.", [uploadBlock(upload)]);
    let last = projectDesktopConversation(snapshot).turns.at(-1);
    assert.equal(last.items.filter((i: any) => i.type === "agentMessage").at(-1)?.text?.trim(), marker);
    passed("real-desktop-file-upload", { path: upload.path, answer: marker });
    const turns = () => projectDesktopConversation(snapshot).turns;
    const before = turns().length;
    const offset = received.length;
    const initial = prompt(id, "Codeaw mid-turn test: run a read-only PowerShell command Start-Sleep -Seconds 15; then reply only ORIGINAL_MARKER. Do not modify files. A follow-up may arrive while the command is running; honor the latest instruction.");
    initial.catch(() => {});
    await waitFor(() => turns().at(-1)?.status === "inProgress" && turns().at(-1).items.some((i: any) => i.type === "commandExecution" && i.status === "inProgress"));
    const turnId = turns().at(-1).turnId;
    // Update next-turn settings while the owner is actively generating.
    await setting(id, "model", "gpt-6-sol");
    await setting(id, "model", "gpt-6-luna");
    await setting(id, "reasoning_effort", "medium");
    await setting(id, "reasoning_effort", "low");
    const steering = prompt(id, "Follow-up for the CURRENT running turn: replace ORIGINAL_MARKER with CODEAW_STEER_ACCEPTED. Reply only CODEAW_STEER_ACCEPTED after the sleep finishes; do not start another task.");
    await Promise.all([initial, steering]);
    assert.equal(turns().length, before + 1, "Steering created an extra turn");
    assert.equal(turns().at(-1).turnId, turnId);
    assert.ok(text(id, offset).includes("CODEAW_STEER_ACCEPTED"));
    last = turns().at(-1);
    const answer = last.items.filter((i: any) => i.type === "agentMessage").at(-1)?.text?.trim();
    assert.equal(answer, "CODEAW_STEER_ACCEPTED");
    assert.ok(turns().at(-1).items.some((i: any) => i.type === "steeringUserMessage" || (i.type === "userMessage" && i.content?.some((b: any) => b.text?.includes("CODEAW_STEER_ACCEPTED")))));
    assert.ok(!received.slice(offset).some((r) => r.method === "_codeaw/event" && r.params.event?.queued > 0));
    passed("real-desktop-same-turn-steering", { turnId, before, after: turns().length, answer, queued: 0, settings: settingsSummary(snapshot) });
  } else if (values.phase === "filesystem") {
    const roots = await request("_codeaw/workspaces/list", {});
    assert.equal(roots.allowAllPaths, true);
    assert.ok(roots.roots.some((r: any) => r.source === "filesystem" && /^C:/i.test(r.path)));
    assert.ok(roots.roots.some((r: any) => r.source === "filesystem" && /^E:/i.test(r.path)));
    await request("_codeaw/fs/list", { path: "C:\\" });
    await request("_codeaw/fs/list", { path: "E:\\" });
    const s = await request("session/new", { cwd: values.cwd, mcpServers: [], _meta: { codeaw: { agentId: "codex" } } });
    id = s.sessionId;
    await setting(id!, "model", "gpt-6-luna"); await setting(id!, "reasoning_effort", "low");
    const offset = received.length;
    await prompt(id!, "Integration test: run the read-only command (Get-Location).Path and report the actual working directory. Do not modify files.");
    const answer = text(id!, offset).replaceAll("\\", "/");
    assert.ok(answer.toLowerCase().includes(values.cwd!.replaceAll("\\", "/").toLowerCase()));
    passed("real-c-drive-session", { sessionId: id, cwd: values.cwd, roots: roots.roots.filter((r: any) => r.source === "filesystem"), answer });
    await request("session/close", { sessionId: id });
  } else throw new Error("Unknown --phase");
} catch (error) {
  checks.push({ name: values.phase, status: "failed", error: error instanceof Error ? error.message : String(error), sessionId: id });
  throw error;
} finally {
  if (values.report) fs.writeFileSync(values.report, JSON.stringify({ phase: values.phase, sessionId: id, at: new Date().toISOString(), checks }, null, 2));
  ipc.close(); conn.close();
}
