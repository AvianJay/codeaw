import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { afterEach, describe, expect, it } from "vitest";
import { CodexDesktopIpc, encodeDesktopIpc, readDesktopIpcVersions } from "../src/backend/codex-desktop-ipc.js";
import { applyDesktopPatches, desktopRecordChanges, projectDesktopConversation } from "../src/backend/codex-desktop-state.js";
import { desktopAsyncReply, desktopAsyncRequests, desktopQuestionReplies } from "../src/backend/codex-desktop-questions.js";
import { startTestBridge, TestClient, type TestBridge } from "./helpers.js";

const VERSIONS = { "thread-owner-discovery": 1, "thread-stream-state-changed": 11, "thread-stream-following-changed": 1, "thread-follower-start-turn": 2, "thread-follower-steer-turn": 1, "thread-follower-interrupt-turn": 4, "thread-follower-update-thread-settings": 2 };

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
  delayedSettings = false;
  completeHistoryGate?: () => void;
  delayCompleteHistory = false;
  revision = 0;
  conversation: any = {
    id: this.id, cwd: this.home, title: "Desktop fixture",
    turnsPagination: { hasLoadedOldest: true }, requests: [],
    latestThreadSettings: { model: "gpt-6-luna", effort: "low", sandboxPolicy: { type: "workspaceWrite" }, collaborationMode: { mode: "default", settings: { model: "gpt-6-luna", reasoning_effort: "low", developer_instructions: null } } },
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
      reply({ method: message.method, result: { result: { turnId } } });
    } else if (message.method === "thread-follower-steer-turn") {
      if (!params.restoreMessage?.context?.workspaceRoots || params.restoreMessage.cwd !== this.home || params.restoreMessage.id !== params.clientUserMessageId) {
        this.send(socket, { type: "response", requestId: message.requestId, resultType: "error", error: "missing restoreMessage context" }); return;
      }
      const index = this.conversation.turns.length - 1;
      const items = this.conversation.turns[index].items;
      this.patch([{ op: "add", path: ["turns", index, "items", items.length], value: { type: "steeringUserMessage", id: randomUUID(), input: params.input } }]);
      if (!this.dropSteeringReply) reply({ method: message.method, result: { result: { turnId: this.conversation.turns[index].turnId } } });
    } else if (message.method === "thread-follower-update-thread-settings") {
      const apply = () => {
        const settings = { ...this.conversation.latestThreadSettings, ...params.threadSettings };
        if (settings.sandboxPolicy?.type === "workspaceWrite") settings.sandboxPolicy = { ...settings.sandboxPolicy, writableRoots: [this.home, path.join(this.home, "artifacts")] };
        this.patch([{ op: "replace", path: ["latestThreadSettings"], value: settings }]);
      };
      if (this.delayedSettings) {
        this.patch([{ op: "replace", path: ["title"], value: "Unrelated owner update" }]);
        setTimeout(apply, 30);
      } else apply();
      reply({ method: message.method, result: { applied: true } });
    } else if (message.method === "thread-follower-interrupt-turn") {
      const turn = this.conversation.turns.at(-1);
      if (params.expectedTurnId && params.expectedTurnId !== turn.turnId) throw new Error("Interrupt targeted the wrong turn");
      this.finish("interrupted"); reply({ interruptedTurnId: turn.turnId });
    } else if (message.method === "thread-follower-load-complete-history") {
      const complete = () => {
        this.conversation.turns.unshift({ turnId: "oldest", status: "completed", params: { input: [{ type: "text", text: "oldest prompt" }] }, items: [{ type: "agentMessage", id: "oldest-reply", text: "oldest reply" }] });
        this.conversation.turnsPagination.hasLoadedOldest = true;
        this.revision++;
        for (const peer of this.followed) this.snapshot(peer);
        reply({ method: message.method, result: { revision: this.revision } });
      };
      if (this.delayCompleteHistory) this.completeHistoryGate = complete; else complete();
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
  it("returns the current snapshot before delayed older history and then replaces it completely", async () => {
    const { a, desktop } = await setup();
    desktop.conversation.turnsPagination.hasLoadedOldest = false;
    desktop.delayCompleteHistory = true;
    const loaded = await load(a);
    expect(loaded._meta.codeaw.connection).toBe("desktop");
    expect(a.text(nativeId)).toBe("earlier desktop reply");
    await a.waitFor(() => desktop.completeHistoryGate !== undefined);
    desktop.completeHistoryGate!();
    await a.waitFor(() => a.received.some((r) => r.method === "_codeaw/replay" && r.params.mode === "complete"));
    const final = await load(a);
    expect(final._meta.codeaw.epoch).not.toBe(loaded._meta.codeaw.epoch);
    expect(a.text(nativeId)).toContain("oldest reply");
  });
  it("waits through unrelated owner revisions and accepts normalized artifact roots", async () => {
    const { a, desktop } = await setup(); await load(a);
    desktop.delayedSettings = true;
    const result = await a.request("session/set_config_option", { sessionId: nativeId, configId: "mode", value: "agent" });
    expect(result.configOptions.find((option: any) => option.id === "mode").currentValue).toBe("agent");
    expect(desktop.conversation.latestThreadSettings.sandboxPolicy.writableRoots).toContain(path.join(desktop.home, "artifacts"));
  });
  it("changes settings on the same owner and streams desktop changes back", async () => {
    const { a, desktop, bridge } = await setup();
    const response = await load(a);
    expect(response.configOptions.find((option: any) => option.id === "model").currentValue).toBe("gpt-6-luna");
    for (const [configId, value] of [["model", "gpt-6-sol"], ["reasoning_effort", "medium"], ["mode", "read-only"], ["collaboration_mode", "plan"]]) {
      const r = await a.request("session/set_config_option", { sessionId: nativeId, configId, value });
      expect(r.configOptions.find((option: any) => option.id === configId).currentValue).toBe(value);
    }
    expect(desktop.requests.filter((message) => message.method === "thread-follower-update-thread-settings")).toHaveLength(4);
    expect(fs.existsSync(path.join(bridge.home, "fake-state.json"))).toBe(false);
    desktop.patch([{ op: "replace", path: ["latestThreadSettings", "effort"], value: "low" }]);
    await a.waitFor(() => a.updates(nativeId).at(-1)?.update.configOptions?.some((option: any) => option.id === "reasoning_effort" && option.currentValue === "low"));
  });
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

  it("keeps queued receipts through native history rebuilds and marks read only after desktop accepts", async () => {
    const { a, desktop } = await setup(); await load(a);
    desktop.begin(); await a.waitFor(() => a.events(nativeId, "state").at(-1)?.event.state === "running");
    const id = "42e82e99-6479-437f-b1a1-e84303284f19";
    const queued = a.request("session/prompt", { sessionId: nativeId, prompt: [{ type: "text", text: "receipt after desktop" }], _meta: { codeaw: { delivery: "queue", clientPromptId: id } } });
    await a.waitFor(() => a.events(nativeId, "state").at(-1)?.event.queued === 1);
    expect(a.events(nativeId, "prompt_receipt").filter((e) => e.event.promptId === id).map((e) => e.event.status)).toEqual(["received"]);
    const b = await TestClient.connect(bridge!.url, bridge!.tokenFor("receipt tablet")); clients.push(b); await load(b);
    expect(b.text(nativeId, "user_message_chunk")).toContain("receipt after desktop");
    desktop.patch([{ op: "replace", path: ["turns", 0, "items", 0, "text"], value: "edited older reply" }]);
    await b.waitFor(() => b.received.some((r) => r.method === "_codeaw/replay" && r.params.mode === "complete"));
    expect(b.events(nativeId, "prompt_receipt").at(-1)?.event.status).toBe("received");
    desktop.finish();
    await a.waitFor(() => a.events(nativeId, "prompt_receipt").some((e) => e.event.promptId === id && e.event.status === "read"));
    desktop.text("receipt reply"); desktop.finish(); await queued;
    const fresh = await TestClient.connect(bridge!.url, bridge!.tokenFor("receipt fresh")); clients.push(fresh); await load(fresh);
    expect(fresh.text(nativeId, "user_message_chunk").match(/receipt after desktop/g)).toHaveLength(1);
    expect(fresh.events(nativeId, "prompt_receipt").some((e) => e.event.promptId === id && e.event.status === "read")).toBe(true);
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

  it("removes an idle desktop-linked chat from Codeaw without deleting or interrupting its desktop owner", async () => {
    const { a, desktop } = await setup(); await load(a);
    desktop.begin(); await a.waitFor(() => a.events(nativeId, "state").at(-1)?.event.state === "running");
    await expect(a.request("session/delete", { sessionId: nativeId })).rejects.toThrow(/busy/);
    expect(desktop.requests.filter(r => r.method === "thread-follower-interrupt-turn")).toHaveLength(0);
    desktop.finish(); await a.waitFor(() => a.events(nativeId, "state").at(-1)?.event.state === "idle");
    const history = structuredClone(desktop.conversation.turns);
    await a.request("session/delete", { sessionId: nativeId });
    expect(desktop.conversation.turns).toEqual(history);
    expect(desktop.requests.filter(r => r.method === "thread-follower-interrupt-turn")).toHaveLength(0);
    expect((await a.request("session/list", {})).sessions.some((s: any) => s.sessionId === nativeId)).toBe(false);
    await expect(load(a)).rejects.toThrow(/deleted/);
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

  it("preserves blocking question choices, descriptions and custom input", async () => {
    const { a, desktop } = await setup(); await load(a); desktop.begin();
    a.elicitationAnswer = () => ({ action: "accept", content: { choice: "自訂內容" } });
    desktop.patch([{ op: "add", path: ["requests", 0], value: { id: "blocking-custom", method: "item/tool/requestUserInput",
      params: { questions: [{ id: "choice", question: "選擇或輸入", isOther: true, options: [{ label: "A", description: "第一個" }, { label: "B" }] }] } } }]);
    await a.waitFor(() => desktop.requests.some((message) => message.method === "thread-follower-submit-user-input"));
    const schema = a.received.find((message) => message.method === "elicitation/create")!.params.requestedSchema.properties.choice;
    expect(schema).toMatchObject({ _meta: { codeaw: { allowCustom: true } }, oneOf: [{ const: "A", description: "第一個" }, { const: "B" }] });
    expect(desktop.requests.find((message) => message.method === "thread-follower-submit-user-input").params.response.answers.choice.answers).toEqual(["自訂內容"]);
  });

  it("replays async choices after phone reconnect and steers both choice and free text into the same turn", async () => {
    const { a, desktop, bridge } = await setup(); await load(a); const turnId = desktop.begin();
    desktop.patch([{ op: "add", path: ["turns", 1, "items", 1], value: { type: "agentMessage", id: "async-call", delivery: "async", text: "選擇或自訂",
      questions: [{ title: "選擇或自訂", options: ["A", "B"] }, { title: "自由文字", options: null }] } }]);
    await a.waitFor(() => a.received.some((message) => message.method === "elicitation/create"));
    expect(a.events(nativeId, "state").at(-1)?.event.state).toBe("running");
    a.close(); clients.splice(clients.indexOf(a), 1);
    const b = await TestClient.connect(bridge.url, bridge.tokenFor("phone")); clients.push(b);
    b.elicitationAnswer = (params) => {
      const [choice, text] = params.requestedSchema.required;
      expect(params._meta.codeaw.async).toBe(true);
      expect(params.requestedSchema.properties[choice]).toMatchObject({ enum: ["A", "B"], _meta: { codeaw: { allowCustom: true } } });
      return { action: "accept", content: { [choice]: "B", [text]: "自訂 中文 🐦" } };
    };
    await load(b);
    await b.waitFor(() => desktop.requests.some((message) => message.method === "thread-follower-steer-turn"));
    const steering = desktop.requests.find((message) => message.method === "thread-follower-steer-turn");
    expect(desktopQuestionReplies(steering.params.input)).toEqual([
      { questionItemId: JSON.stringify(["request_user_input_async", "async-call", 0]), question: "選擇或自訂", answer: "B" },
      { questionItemId: JSON.stringify(["request_user_input_async", "async-call", 1]), question: "自由文字", answer: "自訂 中文 🐦" },
    ]);
    expect(steering.params.restoreMessage.context.turnTrigger).toBe("send_user_message_async_question");
    expect(desktop.conversation.turns.at(-1).turnId).toBe(turnId);
    expect(desktop.requests.filter((message) => message.method === "thread-follower-start-turn")).toHaveLength(0);
    const fresh = await TestClient.connect(bridge.url, bridge.tokenFor("fresh")); clients.push(fresh); await load(fresh);
    expect(fresh.received.filter((message) => message.method === "elicitation/create")).toHaveLength(0);
    expect(fresh.text(nativeId, "user_message_chunk")).toContain("自訂 中文 🐦");
    expect(fresh.text(nativeId, "user_message_chunk")).not.toContain("send_user_message_question_reply");
  });

  it("starts an async reply on the same idle conversation and never retries ambiguous steering", async () => {
    const { a, desktop } = await setup(120); await load(a);
    a.elicitationAnswer = (params) => ({ action: "accept", content: { [params.requestedSchema.required[0]]: "custom" } });
    desktop.patch([{ op: "add", path: ["turns", 0, "items", 1], value: { type: "agentMessage", id: "idle-call", delivery: "async", text: "question", questions: [{ title: "question", options: ["suggestion"] }] } }]);
    await a.waitFor(() => desktop.requests.some((message) => message.method === "thread-follower-start-turn"));
    expect(desktopQuestionReplies(desktop.requests.find((message) => message.method === "thread-follower-start-turn").params.turnStart.request.input)[0].answer).toBe("custom");
    desktop.finish();
    desktop.begin(); desktop.dropSteeringReply = true;
    desktop.patch([{ op: "add", path: ["turns", 2, "items", 1], value: { type: "agentMessage", id: "ambiguous-call", delivery: "async", text: "question", questions: [{ title: "question" }] } }]);
    await a.waitFor(() => desktop.requests.some((message) => message.method === "thread-follower-steer-turn"));
    await new Promise((resolve) => setTimeout(resolve, 200));
    expect(desktop.requests.filter((message) => message.method === "thread-follower-start-turn")).toHaveLength(1);
    expect(desktop.requests.filter((message) => message.method === "thread-follower-steer-turn")).toHaveLength(1);
  });

  it("withdraws partially answered forms and reopens only the remaining question", async () => {
    const { a, desktop } = await setup(); await load(a); desktop.begin();
    desktop.patch([{ op: "add", path: ["turns", 1, "items", 1], value: { type: "agentMessage", id: "partial-call", delivery: "async", text: "two questions", questions: [{ title: "first", options: ["A"] }, { title: "second" }] } }]);
    await a.waitFor(() => a.received.some((message) => message.method === "elicitation/create"));
    const reply = desktopAsyncReply(desktopAsyncRequests(desktop.conversation)[0].params.questions.slice(0, 1), { action: "accept", content: { [JSON.stringify(["request_user_input_async", "partial-call", 0])]: "A" } });
    desktop.patch([{ op: "add", path: ["turns", 1, "items", 2], value: { type: "steeringUserMessage", status: "accepted", id: "desktop-answer", input: [{ type: "text", text: reply.text }] } }]);
    await a.waitFor(() => a.received.filter((message) => message.method === "elicitation/create").length === 2);
    expect(a.received.filter((message) => message.method === "elicitation/create").at(-1)!.params.requestedSchema.required).toEqual([JSON.stringify(["request_user_input_async", "partial-call", 1])]);
    expect(a.events(nativeId, "elicitation_resolved").at(-1)?.event.action).toBe("cancel");
  });

  it("does not restore superseded questions from canonical history", () => {
    const question = { type: "agentMessage", id: "historical-question", delivery: "async", questions: [{ title: "Old question" }] };
    const old = { turnId: "historical-turn", status: "completed", items: [question] };
    const conversation = { turnHistory: { kind: "canonical", history: {
      islands: [{ entries: [{ value: "old" }] }], entitiesByKey: { old },
    } }, turns: [{ turnId: "current-turn", status: "inProgress", items: [] }] };
    expect(desktopAsyncRequests(conversation)).toEqual([]);
    // A newer idle turn still supersedes the question after history is loaded.
    conversation.turns[0].status = "completed";
    expect(desktopAsyncRequests(conversation)).toEqual([]);
    conversation.turns = [];
    expect(desktopAsyncRequests(conversation).map((request) => request.id)).toEqual(["historical-question"]);
  });

  it.each(["interrupted", "failed", "error", "cancelled", "canceled"])("does not restore questions from a %s turn", (status) => {
    expect(desktopAsyncRequests({ turns: [{ turnId: "latest-turn", status, items: [
      { type: "agentMessage", id: "obsolete-question", delivery: "async", questions: [{ title: "Obsolete question" }] },
    ] }] })).toEqual([]);
  });

  it("withdraws a superseded form and reconnects only the latest unanswered question", async () => {
    const { a, desktop, bridge } = await setup(); await load(a);
    const question = (id: string) => ({ type: "agentMessage", id, delivery: "async", questions: [{ title: id, options: ["A", "B"] }] });
    desktop.patch([{ op: "add", path: ["turns", 0, "items", 1], value: question("obsolete-question") }]);
    await a.waitFor(() => a.received.some((message) => message.method === "elicitation/create"));
    desktop.begin();
    await a.waitFor(() => a.events(nativeId, "elicitation_resolved").some((message) => message.event.action === "cancel"));
    expect(desktop.requests.some((message) => ["thread-follower-start-turn", "thread-follower-steer-turn"].includes(message.method))).toBe(false);
    desktop.patch([{ op: "add", path: ["turns", 1, "items", 1], value: question("latest-question") }]);
    await a.waitFor(() => a.received.filter((message) => message.method === "elicitation/create").length === 2);
    desktop.finish();
    const b = await TestClient.connect(bridge.url, bridge.tokenFor("fresh")); clients.push(b); await load(b);
    await b.waitFor(() => b.received.some((message) => message.method === "elicitation/create"));
    const forms = b.received.filter((message) => message.method === "elicitation/create");
    expect(forms).toHaveLength(1);
    expect(forms[0].params.requestedSchema.required).toEqual([JSON.stringify(["request_user_input_async", "latest-question", 0])]);
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
  it("retains steering client prompt ids directly from the native snapshot after reconnect", () => {
    const id = randomUUID();
    const conversation = { turns: [{ turnId: "t", status: "completed", items: [{
      type: "steeringUserMessage", id: "steer", clientUserMessageId: id,
      input: [{ type: "text", text: "steered" }],
    }] }] };
    const user = projectDesktopConversation(conversation).records.find((r) => r.key === "t:steer:0")!.update as any;
    expect(user._meta.codeaw).toMatchObject({ promptId: id, receipt: "read", steered: true });
  });
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
