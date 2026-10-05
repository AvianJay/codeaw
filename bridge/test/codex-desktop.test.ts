import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { afterEach, describe, expect, it } from "vitest";
import { CodexDesktopIpc, encodeDesktopIpc, readDesktopIpcVersions } from "../src/backend/codex-desktop-ipc.js";
import { applyDesktopPatches, desktopRecordChanges, projectDesktopConversation } from "../src/backend/codex-desktop-state.js";
import { startTestBridge, TestClient, type TestBridge } from "./helpers.js";

const VERSIONS = { "thread-owner-discovery": 1, "thread-stream-state-changed": 11, "thread-stream-following-changed": 1, "thread-follower-start-turn": 2, "thread-follower-steer-turn": 1, "thread-follower-interrupt-turn": 4 };

function appArchive(file: string): void {
  const source = Buffer.from(`const versions=${JSON.stringify(VERSIONS)};`);
  const header = Buffer.from(JSON.stringify({ files: { ".vite": { files: { build: { files: { "src-versions.js": { size: source.length, offset: "0" } } } } } } }));
  const prefix = Buffer.alloc(16);
  prefix.writeUInt32LE(4, 0); prefix.writeUInt32LE(header.length + 8, 4); prefix.writeUInt32LE(header.length + 4, 8); prefix.writeUInt32LE(header.length, 12);
  fs.writeFileSync(file, Buffer.concat([prefix, header, source]));
}

/** A desktop owner using the installed app's wire format, independent of fake-agent's history. */
class DesktopPeer {
  readonly id = "desktop-thread";
  readonly owner = "desktop-owner";
  readonly home = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-desktop-test-"));
  readonly pipe = process.platform === "win32" ? `\\\\.\\pipe\\codeaw-desktop-test-${randomUUID()}` : path.join(this.home, "ipc.sock");
  readonly archivePath = path.join(this.home, "app.asar");
  readonly sockets = new Set<net.Socket>();
  readonly followed = new Set<net.Socket>();
  readonly requests: any[] = [];
  readonly server = net.createServer((socket) => this.accept(socket));
  available = true;
  fragment = false;
  dropSteeringReply = false;
  revision = 0;
  conversation: any = {
    id: this.id, cwd: this.home, title: "Desktop fixture",
    turnsPagination: { hasLoadedOldest: true }, requests: [],
    turns: [{ turnId: "old-turn", status: "completed", params: { input: [{ type: "text", text: "earlier desktop prompt" }] }, items: [{ type: "agentMessage", id: "old-reply", text: "earlier desktop reply" }] }],
  };

  async start(): Promise<void> {
    appArchive(this.archivePath);
    await new Promise<void>((resolve, reject) => { this.server.once("error", reject); this.server.listen(this.pipe, resolve); });
  }

  private send(socket: net.Socket, message: any): void {
    const frame = encodeDesktopIpc(message);
    if (this.fragment) { socket.write(frame.subarray(0, 3)); socket.write(frame.subarray(3, 9)); socket.write(frame.subarray(9)); }
    else socket.write(frame);
  }

  private accept(socket: net.Socket): void {
    this.sockets.add(socket);
    let buffer = Buffer.alloc(0);
    socket.on("error", () => {});
    socket.on("close", () => { this.sockets.delete(socket); this.followed.delete(socket); });
    socket.on("data", (chunk) => {
      buffer = Buffer.concat([buffer, typeof chunk === "string" ? Buffer.from(chunk) : chunk]);
      while (buffer.length >= 4) {
        const size = buffer.readUInt32LE(0);
        if (buffer.length < size + 4) return;
        const message = JSON.parse(buffer.subarray(4, size + 4).toString());
        buffer = buffer.subarray(size + 4);
        this.receive(socket, message);
      }
    });
  }

  private receive(socket: net.Socket, message: any): void {
    this.requests.push(message);
    const params = message.params ?? {};
    const reply = (result: any) => this.send(socket, { type: "response", requestId: message.requestId, method: message.method, resultType: "success", handledByClientId: this.owner, result });
    if (message.method === "initialize") { reply({ clientId: randomUUID() }); return; }
    if (message.type === "broadcast" && message.method === "thread-stream-following-changed") {
      if (params.following) { this.followed.add(socket); this.snapshot(socket); }
      else this.followed.delete(socket);
      return;
    }
    if (message.method === "thread-owner-discovery") {
      if (this.available && params.conversationId === this.id) reply({ supportsUntrustedAppInput: true });
      else this.send(socket, { type: "response", requestId: message.requestId, method: message.method, resultType: "error", error: "no-client-found" });
    } else if (message.method === "thread-follower-start-turn") {
      const request = params.turnStart.request;
      const turnId = this.begin(request.input, request.clientUserMessageId);
      reply({ result: { turnId } });
    } else if (message.method === "thread-follower-steer-turn") {
      const index = this.conversation.turns.length - 1;
      const items = this.conversation.turns[index].items;
      this.patch([{ op: "add", path: ["turns", index, "items", items.length], value: { type: "steeringUserMessage", id: randomUUID(), input: params.input } }]);
      if (!this.dropSteeringReply) reply({ result: true });
    } else if (message.method === "thread-follower-interrupt-turn") {
      const turn = this.conversation.turns.at(-1);
      if (params.expectedTurnId && params.expectedTurnId !== turn.turnId) throw new Error("Interrupt targeted the wrong turn");
      this.finish("interrupted"); reply({ interruptedTurnId: turn.turnId });
    } else if (message.method === "thread-follower-load-complete-history") {
      this.conversation.turnsPagination.hasLoadedOldest = true;
      this.revision++;
      for (const peer of this.followed) this.snapshot(peer);
      reply({ revision: this.revision });
    } else if (["thread-follower-command-approval-decision", "thread-follower-file-approval-decision", "thread-follower-permissions-request-approval-response", "thread-follower-submit-user-input", "thread-follower-submit-mcp-server-elicitation-response"].includes(message.method)) {
      this.patch([{ op: "replace", path: ["requests"], value: this.conversation.requests.filter((request: any) => request.id !== params.requestId) }]);
      reply({ ok: true });
    } else if (message.method === "echo") reply({ value: params.value });
  }

  private snapshot(socket: net.Socket): void {
    this.send(socket, { type: "broadcast", method: "thread-stream-state-changed", version: 11, sourceClientId: this.owner, params: { conversationId: this.id, hostId: "local", change: { type: "snapshot", revision: this.revision, conversationState: this.conversation } } });
  }

  patch(patches: any[], base = this.revision): void {
    this.conversation = applyDesktopPatches(this.conversation, patches);
    const revision = ++this.revision;
    for (const socket of this.followed) this.send(socket, { type: "broadcast", method: "thread-stream-state-changed", version: 11, sourceClientId: this.owner, params: { conversationId: this.id, hostId: "local", change: { type: "patches", baseRevision: base, revision, patches } } });
  }

  begin(input: any[] = [{ type: "text", text: "started on desktop" }], clientUserMessageId = randomUUID()): string {
    const turnId = randomUUID();
    this.patch([{ op: "add", path: ["turns", this.conversation.turns.length], value: { turnId, turnStartedAtMs: Date.now(), status: "inProgress", params: { input, clientUserMessageId }, items: [{ type: "agentMessage", id: "reply", text: "" }] } }]);
    return turnId;
  }

  text(text: string): void { this.patch([{ op: "replace", path: ["turns", this.conversation.turns.length - 1, "items", 0, "text"], value: text }]); }
  finish(status = "completed"): void { this.patch([{ op: "replace", path: ["turns", this.conversation.turns.length - 1, "status"], value: status }]); }
  async stop(): Promise<void> {
    for (const socket of this.sockets) socket.destroy();
    await new Promise<void>((resolve) => this.server.close(() => resolve()));
    // The directory is generated above, never a user-supplied cleanup target.
    if (path.dirname(this.home) !== path.resolve(os.tmpdir()) || !path.basename(this.home).startsWith("codeaw-desktop-test-")) throw new Error("Invalid test cleanup directory");
    fs.rmSync(this.home, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  }
}

let desktop: DesktopPeer | undefined;
let bridge: TestBridge | undefined;
const clients: TestClient[] = [];
afterEach(async () => {
  for (const client of clients.splice(0)) client.close();
  await bridge?.stop(); bridge = undefined;
  await desktop?.stop(); desktop = undefined;
});

async function setup(timeoutMs = 1000): Promise<{ a: TestClient; desktop: DesktopPeer; bridge: TestBridge }> {
  desktop = new DesktopPeer(); await desktop.start();
  bridge = await startTestBridge({ desktopSync: { pipe: desktop.pipe, archivePath: desktop.archivePath, timeoutMs } });
  const a = await TestClient.connect(bridge.url, bridge.tokenFor("phone")); clients.push(a);
  return { a, desktop, bridge };
}
async function load(client: TestClient): Promise<any> { return client.request("session/load", { sessionId: `fake:${desktop!.id}`, cwd: bridge!.home, mcpServers: [] }); }
const nativeId = "fake:desktop-thread";
function send(client: TestClient, text: string, queue = false): Promise<any> { return client.request("session/prompt", { sessionId: nativeId, prompt: [{ type: "text", text }], ...(queue ? { _meta: { codeaw: { delivery: "queue" } } } : {}) }); }

describe("Codex desktop synchronization", () => {
  it("loads an owned thread without resuming it in the ACP process, and fans out both desktop and phone messages", async () => {
    const { a, desktop, bridge } = await setup();
    const response = await load(a);
    expect(response._meta.codeaw.connection).toBe("desktop");
    expect(fs.existsSync(path.join(bridge.home, "fake-state.json"))).toBe(false);
    expect(a.text(nativeId)).toBe("earlier desktop reply");
    const b = await TestClient.connect(bridge.url, bridge.tokenFor("tablet")); clients.push(b); await load(b);
    desktop.begin(); desktop.text("hello"); desktop.text("hello desktop"); desktop.finish();
    await a.waitFor(() => a.text(nativeId).includes("hello desktop"));
    await b.waitFor(() => b.text(nativeId).includes("hello desktop"));
    const prompt = send(a, "from phone");
    await a.waitFor(() => desktop.requests.some((message) => message.method === "thread-follower-start-turn"));
    desktop.text("phone reply"); desktop.finish();
    expect((await prompt).stopReason).toBe("end_turn");
    expect(a.text(nativeId, "user_message_chunk").match(/from phone/g)).toHaveLength(1);
    expect(b.text(nativeId, "user_message_chunk").match(/from phone/g)).toHaveLength(1);
    expect(a.text(nativeId)).toBe("earlier desktop replyhello desktopphone reply");
  });

  it("steers desktop-started turns and honors explicit queueing after they finish", async () => {
    const { a, desktop } = await setup(); await load(a);
    desktop.begin(); await a.waitFor(() => a.events(nativeId, "state").at(-1)?.event.state === "running");
    await send(a, "look here");
    expect(desktop.requests.filter((message) => message.method === "thread-follower-steer-turn")).toHaveLength(1);
    const queued = send(a, "after desktop", true);
    await a.waitFor(() => a.events(nativeId, "state").at(-1)?.event.queued === 1);
    expect(desktop.requests.filter((message) => message.method === "thread-follower-start-turn")).toHaveLength(0);
    desktop.finish();
    await a.waitFor(() => desktop.requests.some((message) => message.method === "thread-follower-start-turn"));
    desktop.text("queued reply"); desktop.finish(); await queued;
    expect(a.text(nativeId, "user_message_chunk").match(/look here/g)).toHaveLength(1);
  });

  it("interrupts a desktop-started turn, while closing the mobile view only unfollows", async () => {
    const { a, desktop } = await setup(); await load(a);
    desktop.begin(); await a.waitFor(() => a.events(nativeId, "state").at(-1)?.event.state === "running");
    await a.notify("session/cancel", { sessionId: nativeId });
    await a.waitFor(() => desktop.conversation.turns.at(-1).status === "interrupted");
    expect(desktop.requests.find((message) => message.method === "thread-follower-interrupt-turn").version).toBe(4);
    desktop.begin(); await a.waitFor(() => a.events(nativeId, "state").at(-1)?.event.state === "running");
    await a.request("session/close", { sessionId: nativeId });
    expect(desktop.conversation.turns.at(-1).status).toBe("inProgress");
    expect(desktop.requests.filter((message) => message.method === "thread-follower-interrupt-turn")).toHaveLength(1);
    await load(a); expect(a.events(nativeId, "state").at(-1)?.event.desktopConnected).toBe(true);
  });

  it("recovers a lost IPC connection without starting another runtime or duplicating transcript text", async () => {
    const { a, desktop } = await setup(); await load(a);
    desktop.begin(); desktop.text("before");
    await a.waitFor(() => a.text(nativeId).includes("before"));
    for (const socket of desktop.sockets) socket.destroy();
    await a.waitFor(() => a.events(nativeId, "state").at(-1)?.event.desktopConnected === false);
    desktop.text("before and after"); desktop.finish();
    await a.waitFor(() => a.events(nativeId, "state").at(-1)?.event.desktopConnected === true, 7000);
    expect(a.text(nativeId)).toBe("earlier desktop replybefore and after");
    expect(desktop.requests.filter((message) => message.method === "thread-follower-start-turn")).toHaveLength(0);
  });

  it("resynchronizes missed revisions and replaces edited history with a complete replay boundary", async () => {
    const { a, desktop } = await setup(); await load(a);
    const epoch = (await load(a))._meta.codeaw.epoch;
    desktop.patch([{ op: "replace", path: ["turns", 0, "items", 0, "text"], value: "edited desktop reply" }], -99);
    await a.waitFor(() => a.received.filter((message) => message.method === "_codeaw/replay" && message.params.mode === "complete").length > 0);
    await a.waitFor(() => a.text(nativeId).includes("edited desktop reply"));
    const fresh = await load(a);
    expect(fresh._meta.codeaw.epoch).not.toBe(epoch);
    expect(a.received.some((message) => message.method === "_codeaw/replay" && message.params.mode === "complete")).toBe(true);
  });

  it("does not retry an ambiguously delivered steering request as a new prompt", async () => {
    const { a, desktop } = await setup(150); await load(a);
    desktop.begin(); await a.waitFor(() => a.events(nativeId, "state").at(-1)?.event.state === "running");
    desktop.dropSteeringReply = true;
    await expect(send(a, "only once")).rejects.toThrow(/outcome may be unknown/);
    expect(desktop.requests.filter((message) => message.method === "thread-follower-steer-turn")).toHaveLength(1);
    expect(desktop.requests.filter((message) => message.method === "thread-follower-start-turn")).toHaveLength(0);
    expect(a.events(nativeId, "state").at(-1)?.event.queued).toBe(0);
  });

  it("uses the existing ACP transport for unowned sessions", async () => {
    const { a, bridge } = await setup();
    const session = await a.request("session/new", { cwd: bridge.home, mcpServers: [] });
    const reply = await a.request("session/prompt", { sessionId: session.sessionId, prompt: [{ type: "text", text: "echo ordinary ACP" }] });
    expect(reply.stopReason).toBe("end_turn");
    expect(a.text(session.sessionId)).toBe("ordinary ACP");
  });

  it("forwards phone approvals to the desktop owner and cancels sheets answered on desktop", async () => {
    const { a, desktop } = await setup(); await load(a); desktop.begin();
    a.permissionAnswer = () => ({ outcome: { outcome: "selected", optionId: "allow" } });
    desktop.patch([{ op: "add", path: ["requests", 0], value: { id: "approve-1", method: "item/commandExecution/requestApproval", params: { turnId: desktop.conversation.turns.at(-1).turnId, itemId: "command", command: "echo fixture", cwd: desktop.home } } }]);
    await a.waitFor(() => desktop.requests.some((message) => message.method === "thread-follower-command-approval-decision"));
    const reply = desktop.requests.find((message) => message.method === "thread-follower-command-approval-decision");
    expect(reply.params).toMatchObject({ requestId: "approve-1", decision: "accept" });
    a.permissionAnswer = undefined;
    desktop.patch([{ op: "add", path: ["requests", 0], value: { id: "approve-2", method: "item/fileChange/requestApproval", params: { turnId: desktop.conversation.turns.at(-1).turnId, itemId: "edit", reason: "fixture edit" } } }]);
    await a.waitFor(() => a.permissionSignals.length >= 2);
    desktop.patch([{ op: "replace", path: ["requests"], value: [] }]);
    await a.waitFor(() => a.permissionSignals.at(-1)?.aborted === true);
    expect(a.events(nativeId, "permission_resolved").at(-1)?.event.optionName).toBe("已在桌面處理");
    expect(desktop.requests.filter((message) => message.method === "thread-follower-file-approval-decision")).toHaveLength(0);
  });

  it("forwards user questions without duplicating or persisting their answers in history", async () => {
    const { a, desktop } = await setup(); await load(a); desktop.begin();
    a.elicitationAnswer = () => ({ action: "accept", content: { choice: "A" } });
    desktop.patch([{ op: "add", path: ["requests", 0], value: { id: "question-1", method: "item/tool/requestUserInput", params: { questions: [{ id: "choice", header: "Choose", question: "Which option?", options: [{ label: "A" }, { label: "B" }] }] } } }]);
    await a.waitFor(() => desktop.requests.some((message) => message.method === "thread-follower-submit-user-input"));
    expect(desktop.requests.find((message) => message.method === "thread-follower-submit-user-input").params.response).toEqual({ answers: { choice: { answers: ["A"] } } });
    expect(a.events(nativeId, "elicitation_resolved").at(-1)?.event).not.toHaveProperty("content");
  });

  it("persists desktop affinity across bridge restarts and refuses to resume an unavailable owner through ACP", async () => {
    const { a, desktop, bridge: first } = await setup(); await load(a);
    const home = first.home;
    // Keep the generated test directory across this one restart.
    const config = first.loaded;
    a.close(); clients.splice(clients.indexOf(a), 1);
    // startBridge does not own its data directory; bypass the helper's temporary cleanup.
    await first.bridge.stop(); bridge = undefined;
    desktop.available = false;
    const { startBridge } = await import("../src/bridge.js");
    const restarted = await startBridge(config, { hosts: ["127.0.0.1"], port: 0 });
    try {
      const b = await TestClient.connect(`ws://127.0.0.1:${restarted.port()}/acp`, first.tokenFor("phone")); clients.push(b);
      await expect(b.request("session/load", { sessionId: nativeId, cwd: home, mcpServers: [] })).rejects.toThrow(/desktop/i);
      b.close(); clients.splice(clients.indexOf(b), 1);
    } finally {
      await restarted.stop();
      if (path.dirname(home) !== path.resolve(os.tmpdir()) || !path.basename(home).startsWith("codeaw-test-")) throw new Error("Invalid test cleanup directory");
      fs.rmSync(home, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
    }
  });
});

describe("desktop IPC wire and state", () => {
  it("reads method versions from an app archive and handles fragmented UTF-8 frames and concurrent requests", async () => {
    desktop = new DesktopPeer(); desktop.fragment = true; await desktop.start();
    expect(await readDesktopIpcVersions(desktop.archivePath)).toEqual(VERSIONS);
    const ipc = new CodexDesktopIpc({ pipe: desktop.pipe, archivePath: desktop.archivePath });
    try {
      const responses = await Promise.all([ipc.request("echo", { value: "中文 🦉" }), ipc.request("echo", { value: "second" })]);
      expect(responses.map((response) => response.result.value)).toEqual(["中文 🦉", "second"]);
      expect(desktop.requests.filter((message) => message.method === "initialize")).toHaveLength(1);
    } finally { ipc.close(); }
  });

  it("projects canonical and live history and emits only newly appended text", () => {
    const turn = { turnId: "one", status: "completed", params: { input: [{ type: "text", text: "prompt" }] }, items: [{ type: "agentMessage", id: "answer", text: "hello" }] };
    const state = { turns: [], turnHistory: { kind: "canonical", history: { entitiesByKey: { one: turn }, islands: [{ entries: [{ value: "one" }] }] } } };
    const previous = projectDesktopConversation(state).records;
    const changed = applyDesktopPatches(state, [{ op: "replace", path: ["turnHistory", "history", "entitiesByKey", "one", "items", 0, "text"], value: "hello world" }]);
    const delta = desktopRecordChanges(previous, projectDesktopConversation(changed).records);
    expect(delta.reset).toBe(false);
    expect((delta.updates[0] as any).content.text).toBe(" world");
    expect(state.turnHistory.history.entitiesByKey.one.items[0].text).toBe("hello");
  });

  it("rejects unsafe or unsupported patches atomically", () => {
    const state = { turns: [{ text: "original" }] };
    expect(() => applyDesktopPatches(state, [{ op: "replace", path: ["turns", 0, "text"], value: "changed" }, { op: "add", path: ["__proto__", "polluted"], value: true }])).toThrow(/Unsafe/);
    expect(() => applyDesktopPatches(state, [{ op: "replace", path: ["turns", 9], value: {} }])).toThrow();
    expect(state.turns[0].text).toBe("original");
    expect(({} as any).polluted).toBeUndefined();
  });

  it("rebuilds when older history is prepended and converts tool progress without losing its identity", () => {
    const state = { cwd: "fixture", turns: [{ turnId: "one", status: "inProgress", params: { input: [] }, items: [{ type: "commandExecution", id: "command", command: "echo fixture", status: "inProgress", aggregatedOutput: "first" }] }] };
    const previous = projectDesktopConversation(state).records;
    const changed = applyDesktopPatches(state, [{ op: "replace", path: ["turns", 0, "items", 0, "aggregatedOutput"], value: "first second" }, { op: "replace", path: ["turns", 0, "items", 0, "status"], value: "completed" }]);
    const delta = desktopRecordChanges(previous, projectDesktopConversation(changed).records);
    expect(delta.reset).toBe(false);
    expect(delta.updates[0]).toMatchObject({ sessionUpdate: "tool_call_update", toolCallId: "one:command", status: "completed" });
    const earlier = structuredClone(changed);
    earlier.turns.unshift({ turnId: "older", status: "completed", params: { input: [] }, items: [{ type: "commandExecution", id: "older-command", command: "echo older", status: "completed", aggregatedOutput: "old" }] });
    expect(desktopRecordChanges(projectDesktopConversation(changed).records, projectDesktopConversation(earlier).records).reset).toBe(true);
  });

  it("names MCP calls by server and tool like codex-acp", () => {
    const item = { type: "mcpToolCall", id: "docs", server: "context7", tool: "query-docs", arguments: { query: "MenuAnchor" }, status: "completed" };
    const { records } = projectDesktopConversation({ turns: [{ turnId: "one", status: "completed", params: { input: [] }, items: [item] }] });
    expect(records[0].update).toMatchObject({ title: "mcp.context7.query-docs", rawInput: { server: "context7", tool: "query-docs", arguments: { query: "MenuAnchor" } } });
  });
});
