import fs from "node:fs";
import path from "node:path";
import { afterEach, describe, expect, it, onTestFinished } from "vitest";
import { reduce } from "./reduce.js";
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

const PNG_1PX = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

describe("auth & pairing", () => {
  it("rejects connections without a valid token and pairs with a one-time code", async () => {
    tb = await startTestBridge();
    await expect(TestClient.connect(tb.url, "nope")).rejects.toThrow();

    const health: any = await fetch(`${tb.http}/api/health`).then((r) => r.json());
    expect(health.ok).toBe(true);

    const code = tb.bridge.devices.createPairingCode();
    const paired = await fetch(`${tb.http}/api/pair`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code: code.slice(0, 4) + "-" + code.slice(4).toLowerCase(), deviceName: "Pixel" }),
    });
    expect(paired.status).toBe(200);
    const { token } = (await paired.json()) as any;
    const c = await TestClient.connect(tb.url, token);
    clients.push(c);

    const reuse = await fetch(`${tb.http}/api/pair`, { method: "POST", body: JSON.stringify({ code, deviceName: "x" }) });
    expect(reuse.status).toBe(403);
    expect((await fetch(`${tb.http}/api/blobs/${"0".repeat(64)}`)).status).toBe(401);
  });
});

describe("sessions", () => {
  it("creates a session, streams a turn with seq/mid and reports state", async () => {
    tb = await startTestBridge();
    const c = await client();
    const init = c.init;
    expect(init._meta.codeaw.agents.map((a: any) => a.id)).toEqual(["fake"]);

    const s = await newFakeSession(c, tb.home);
    expect(s.sessionId).toMatch(/^fake:s/);
    expect(s.configOptions[0].currentValue).toBe("ask");
    expect(s.models).toBeUndefined();

    const r = await c.request("session/prompt", promptText(s.sessionId, "echo hello world"));
    expect(r.stopReason).toBe("end_turn");
    await c.waitFor(() => c.events(s.sessionId, "state").some((e) => e.event.state === "idle"));

    const updates = c.updates(s.sessionId);
    const user = updates.find((u) => u.update.sessionUpdate === "user_message_chunk");
    expect(user.update.content.text).toBe("echo hello world");
    expect(user.update._meta.codeaw.promptId).toMatch(/^[0-9a-f-]{36}$/);
    const chunks = updates.filter((u) => u.update.sessionUpdate === "agent_message_chunk");
    expect(chunks.map((u) => u.update.content.text).join("")).toBe("hello world");
    expect(new Set(chunks.map((u) => u.update._meta.codeaw.mid)).size).toBe(1);

    const seqs = c.log(s.sessionId).map((m) => m.params._meta.codeaw.seq);
    expect(seqs).toEqual([...seqs].sort((a, b) => a - b));
    expect(new Set(seqs).size).toBe(seqs.length);
    expect(c.log(s.sessionId).every((m) => typeof m.params._meta.codeaw.t === "number")).toBe(true);
    const states = c.events(s.sessionId, "state").map((e) => e.event.state);
    expect(states).toEqual(["running", "idle"]);
    expect(c.events(s.sessionId, "state")[0].event.turnStartedAt).toBeTypeOf("number");
    expect(c.events(s.sessionId, "state")[1].event.turnStartedAt).toBeUndefined();
    const completed = c.events(s.sessionId, "state")[1].event.completedTurn;
    expect(completed.promptId).toBe(user.update._meta.codeaw.promptId);
    expect(completed.startedAt).toBe(c.events(s.sessionId, "state")[0].event.turnStartedAt);
    expect(completed.endedAt).toBeGreaterThanOrEqual(completed.startedAt);
  });

  it("preserves turn start time while waiting, queueing and replaying to another device", async () => {
    tb = await startTestBridge();
    const a = await client("A");
    let allow!: () => void;
    const answer = new Promise<void>((resolve) => { allow = resolve; });
    a.permissionAnswer = async () => {
      await answer;
      return { outcome: { outcome: "selected", optionId: "allow" } };
    };
    const s = await newFakeSession(a, tb.home);
    const first = a.request("session/prompt", promptText(s.sessionId, "perm"));
    await a.waitFor(() => a.events(s.sessionId, "state").some((e) => e.event.state === "requires_action"));
    const startedAt = a.events(s.sessionId, "state")[0].event.turnStartedAt;
    expect(startedAt).toBeTypeOf("number");

    const queued = a.request("session/prompt", promptText(s.sessionId, "echo queued"));
    await a.waitFor(() => a.events(s.sessionId, "state").some((e) => e.event.queued === 1));
    expect(a.events(s.sessionId, "state").every((e) => e.event.turnStartedAt === startedAt)).toBe(true);

    const b = await client("B");
    const full = await b.request("session/load", { sessionId: s.sessionId, cwd: tb.home, mcpServers: [] });
    expect(full._meta.codeaw.turnStartedAt).toBe(startedAt);
    expect(b.events(s.sessionId, "state").at(-1).event.turnStartedAt).toBe(startedAt);
    const delta = await b.request("session/load", {
      sessionId: s.sessionId, cwd: tb.home, mcpServers: [],
      _meta: { codeaw: { afterSeq: full._meta.codeaw.lastSeq, epoch: full._meta.codeaw.epoch } },
    });
    expect(delta._meta.codeaw.turnStartedAt).toBe(startedAt);
    allow();
    await Promise.all([first, queued]);
    await a.waitFor(() => a.events(s.sessionId, "state").filter((e) => e.event.state === "idle").length === 2);
    const next = a.events(s.sessionId, "state").filter((e) => e.event.state === "running").at(-1);
    expect(next.event.turnStartedAt).toBeGreaterThan(startedAt);
    const completed = a.events(s.sessionId, "state").filter((e) => e.event.completedTurn).map((e) => e.event.completedTurn);
    expect(completed).toHaveLength(2);
    expect(completed[0].promptId).not.toBe(completed[1].promptId);
    const replayAt = b.received.length;
    await b.request("session/load", { sessionId: s.sessionId, cwd: tb.home, mcpServers: [] });
    const replayed = b.received.slice(replayAt);
    const replayStart = replayed.findIndex((m) => m.method === "_codeaw/replay" && m.params.mode === "full");
    expect(replayStart).toBeGreaterThanOrEqual(0);
    const replayStates = replayed.slice(replayStart + 1).filter((m) => m.method === "_codeaw/event" && m.params.event.type === "state");
    expect(replayStates.filter((m) => m.params.event.completedTurn).map((m) => m.params.event.completedTurn)).toEqual(completed);
    expect(replayStates.filter((m) => m.params.event.state === "running")).toHaveLength(2);
  });

  it("first permission answer wins and is withdrawn from the other device", async () => {
    tb = await startTestBridge();
    const a = await client("A");
    const b = await client("B");
    const s = await newFakeSession(a, tb.home);
    await b.request("session/load", { sessionId: s.sessionId, cwd: tb.home, mcpServers: [] });

    b.permissionAnswer = async () => ({ outcome: { outcome: "selected", optionId: "allow" } });
    const r = await a.request("session/prompt", promptText(s.sessionId, "perm"));
    expect(r.stopReason).toBe("end_turn");
    expect(a.text(s.sessionId)).toBe("allowed");

    await a.waitFor(() => a.permissionSignals.length === 1 && a.permissionSignals[0].aborted);
    const resolved = a.events(s.sessionId, "permission_resolved")[0].event;
    expect(resolved.by).toBe("B");
    expect(resolved.optionName).toBe("Allow");
    expect(b.received.some((m) => m.method === "session/request_permission" && m.params._meta.codeaw.requestId === resolved.requestId)).toBe(true);
  });

  it("answers elicitation forms", async () => {
    tb = await startTestBridge();
    const c = await client();
    c.elicitationAnswer = async () => ({ action: "accept", content: { question_0: "Vue" } });
    const s = await newFakeSession(c, tb.home);
    await c.request("session/prompt", promptText(s.sessionId, "elicit"));
    expect(c.text(s.sessionId)).toBe("answer=Vue");
    expect(c.events(s.sessionId, "elicitation_resolved")[0].event.action).toBe("accept");
  });

  it("replays only the missed entries after a reconnect", async () => {
    tb = await startTestBridge();
    const a = await client("A");
    const s = await newFakeSession(a, tb.home);
    await a.request("session/prompt", promptText(s.sessionId, "echo first"));
    await a.waitFor(() => a.events(s.sessionId, "state").some((e) => e.event.state === "idle"));
    const lastSeq = Math.max(...a.log(s.sessionId).map((m) => m.params._meta.codeaw.seq));
    a.close();

    const b = await client("B");
    await b.request("session/load", { sessionId: s.sessionId, cwd: tb.home, mcpServers: [] });
    await b.request("session/prompt", promptText(s.sessionId, "echo second"));

    const a2 = await client("A");
    const resp = await a2.request("session/load", {
      sessionId: s.sessionId,
      cwd: tb.home,
      mcpServers: [],
      _meta: { codeaw: { afterSeq: lastSeq, epoch: s._meta.codeaw.epoch } },
    });
    const replay = a2.received.find((m) => m.method === "_codeaw/replay")!;
    expect(replay.params.mode).toBe("delta");
    const seqs = a2.log(s.sessionId).map((m) => m.params._meta.codeaw.seq);
    expect(Math.min(...seqs)).toBe(lastSeq + 1);
    expect(Math.max(...seqs)).toBe(resp._meta.codeaw.lastSeq);
    expect(a2.text(s.sessionId)).toBe("second");
    expect(a2.text(s.sessionId, "user_message_chunk")).toBe("echo second");
  });

  it("full replay is compacted and reduces to the same timeline as the raw log", async () => {
    tb = await startTestBridge();
    const a = await client("A");
    a.permissionAnswer = async () => ({ outcome: { outcome: "selected", optionId: "reject" } });
    const s = await newFakeSession(a, tb.home);
    for (const p of ["echo one two three", "tool", "edit", "perm", "title My Session", "slow 5"]) {
      await a.request("session/prompt", promptText(s.sessionId, p));
    }
    await a.waitFor(() => a.events(s.sessionId, "state").filter((e) => e.event.state === "idle").length === 6);

    const b = await client("B");
    await b.request("session/load", { sessionId: s.sessionId, cwd: tb.home, mcpServers: [] });
    expect(b.received.find((m) => m.method === "_codeaw/replay")!.params.mode).toBe("full");
    const raw = rawLog(tb, s.sessionId);
    const compacted = b.log(s.sessionId);
    expect(compacted.length).toBeLessThan(raw.length);
    expect(reduce(compacted)).toEqual(reduce(raw));

    const tool = reduce(compacted).items.find((i) => i.kind === "tool" && i.state.toolCallId === "t1");
    expect(tool.state.terminalOutput).toBe("line1\nline2\n");
    const edit = reduce(compacted).items.find((i) => i.kind === "tool" && i.state.toolCallId === "e1");
    expect(edit.state.content.map((c: any) => c.type)).toEqual(["diff", "content"]);
  });

  it("queues prompts while a turn runs and cancels everything on session/cancel", async () => {
    tb = await startTestBridge();
    const c = await client();
    const s = await newFakeSession(c, tb.home);
    const first = c.request("session/prompt", promptText(s.sessionId, "slow 8"));
    await c.waitFor(() => c.text(s.sessionId).length > 0);
    const second = c.request("session/prompt", promptText(s.sessionId, "echo queued"));
    expect((await first).stopReason).toBe("end_turn");
    expect((await second).stopReason).toBe("end_turn");
    expect(c.events(s.sessionId, "dequeued")).toHaveLength(1);
    expect(c.text(s.sessionId)).toContain("queued");

    const statesBeforeCancel = c.events(s.sessionId, "state").length;
    const textBeforeCancel = c.text(s.sessionId).length;
    const long = c.request("session/prompt", promptText(s.sessionId, "slow 200"));
    const dropped = c.request("session/prompt", promptText(s.sessionId, "echo never"));
    // Wait for this turn to reach the fake agent and queue its follow-up. A
    // previous turn's queued event can otherwise cancel before prompt starts.
    await c.waitFor(() => c.text(s.sessionId).length > textBeforeCancel && c.events(s.sessionId, "state").slice(statesBeforeCancel).some((e) => e.event.queued === 1));
    await c.notify("session/cancel", { sessionId: s.sessionId });
    expect((await long).stopReason).toBe("cancelled");
    expect((await dropped).stopReason).toBe("cancelled");
    expect(c.text(s.sessionId)).not.toContain("never");
  });

  it("acknowledges a queued prompt, replays receipts after disconnect and suppresses duplicate delivery", async () => {
    tb = await startTestBridge();
    const a = await client();
    const s = await newFakeSession(a, tb.home);
    const first = a.request("session/prompt", promptText(s.sessionId, "slow 15")).catch(() => undefined);
    await a.waitFor(() => a.text(s.sessionId).length > 0);
    const id = "a2fa3c1c-a01c-4d12-845d-43e1d0bf346b";
    const params = { ...promptText(s.sessionId, "echo queued receipt"), _meta: { codeaw: { delivery: "queue", clientPromptId: id } } };
    const queued = a.request("session/prompt", params).catch(() => undefined);
    await a.waitFor(() => a.events(s.sessionId, "prompt_receipt").some((e) => e.event.promptId === id && e.event.status === "received"));
    expect(a.events(s.sessionId, "prompt_receipt").filter((e) => e.event.promptId === id).map((e) => e.event.status)).toEqual(["received"]);
    await a.request("session/prompt", params);
    expect(a.events(s.sessionId, "state").at(-1)!.event.queued).toBe(1);
    a.close();
    const b = await client();
    await b.request("session/load", { sessionId: s.sessionId, cwd: tb.home, mcpServers: [] });
    await b.waitFor(() => b.events(s.sessionId, "prompt_receipt").some((e) => e.event.promptId === id && e.event.status === "read"));
    expect(b.text(s.sessionId, "user_message_chunk").match(/queued receipt/g)).toHaveLength(1);
    expect(b.text(s.sessionId)).toContain("queued receipt");
    await Promise.all([first, queued]);
  });

  it("steers into a running turn when the agent supports it", async () => {
    tb = await startTestBridge({ steering: true });
    const c = await client();
    const s = await newFakeSession(c, tb.home);
    const first = c.request("session/prompt", promptText(s.sessionId, "slow 15"));
    await c.waitFor(() => c.text(s.sessionId).length > 0);
    const steer = c.request("session/prompt", promptText(s.sessionId, "look here"));
    const [r1, r2] = await Promise.all([first, steer]);
    expect(r1.stopReason).toBe("end_turn");
    expect(r2.stopReason).toBe("end_turn");
    expect(c.text(s.sessionId)).toContain("[steer:look here]");
    const steered = c.updates(s.sessionId).find((u) => u.update._meta?.codeaw?.steered);
    expect(steered.update.content.text).toBe("look here");
  });

  it("survives an agent crash and restores the mode after resume", async () => {
    tb = await startTestBridge();
    const c = await client();
    const s = await newFakeSession(c, tb.home, { initialConfig: { mode: "code" } });
    expect(s.configOptions[0].currentValue).toBe("code");
    await expect(c.request("session/prompt", promptText(s.sessionId, "crash"))).rejects.toThrow();
    await c.waitFor(() => c.events(s.sessionId, "error").length > 0);

    const r = await c.request("session/prompt", promptText(s.sessionId, "echo back again"));
    expect(r.stopReason).toBe("end_turn");
    expect(c.text(s.sessionId)).toContain("back again");
    const cfg = c.updates(s.sessionId).filter((u) => u.update.sessionUpdate === "config_option_update").pop();
    expect(cfg.update.configOptions[0].currentValue).toBe("code");
  });

  it("lists and imports sessions that only exist in the agent's history", async () => {
    const first = await startTestBridge({ keepHome: true });
    const c1 = await TestClient.connect(first.url, first.tokenFor("A"));
    const s = await newFakeSession(c1, first.home);
    await c1.request("session/prompt", promptText(s.sessionId, "echo from the terminal"));
    c1.close();
    await first.stop();

    tb = await startTestBridge({ home: first.home, freshData: true });
    const keptHome = first.home;
    onTestFinished(() => fs.rmSync(keptHome, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }));
    const c = await client();
    const list = await c.request("session/list", {});
    const info = list.sessions.find((x: any) => x.sessionId === s.sessionId);
    expect(info._meta.codeaw.known).toBe(false);

    await c.request("session/load", { sessionId: s.sessionId, cwd: info.cwd, mcpServers: [] });
    expect(c.text(s.sessionId)).toBe("from the terminal");
    expect(c.text(s.sessionId, "user_message_chunk")).toBe("echo from the terminal");
    const again = await c.request("session/list", {});
    expect(again.sessions.find((x: any) => x.sessionId === s.sessionId)._meta.codeaw.known).toBe(true);
  });

  it("stores images as blobs and serves them over HTTP", async () => {
    tb = await startTestBridge();
    const c = await client();
    const s = await newFakeSession(c, tb.home);
    await c.request("session/prompt", {
      sessionId: s.sessionId,
      prompt: [
        { type: "text", text: "image" },
        { type: "image", mimeType: "image/png", data: PNG_1PX },
      ],
    });
    expect(c.text(s.sessionId)).toBe(`got image image/png ${PNG_1PX.length}`);
    const img = c.updates(s.sessionId).find((u) => u.update.content?.type === "image").update.content;
    expect(img.data).toBe("");
    const sha = img.uri.replace("codeaw-blob:", "");
    const res = await fetch(`${tb.http}/api/blobs/${sha}`, { headers: { Authorization: `Bearer ${tb.tokenFor("phone")}` } });
    expect(res.headers.get("content-type")).toBe("image/png");
    expect(Buffer.from(await res.arrayBuffer()).toString("base64")).toBe(PNG_1PX);
  });
});

describe("offline handling", () => {
  it("keeps a permission request open while nobody is connected, pushes, and re-sends it on attach", async () => {
    const pushes: any[] = [];
    const fetchImpl = (async (_url: string, init: any) => {
      pushes.push(JSON.parse(init.body));
      return new Response("{}", { status: 200 });
    }) as unknown as typeof fetch;
    tb = await startTestBridge({ ntfy: { topic: "t", delaySeconds: 0 }, fetchImpl });
    const a = await client("A");
    const s = await newFakeSession(a, tb.home);
    void a.request("session/prompt", promptText(s.sessionId, "perm")).catch(() => undefined);
    await a.waitFor(() => a.received.some((m) => m.method === "session/request_permission"));
    a.close();
    await a.waitFor(() => pushes.length > 0);
    expect(pushes[0].message).toContain("需要你的批准");
    expect(pushes[0].click).toBe(`codeaw://session/${encodeURIComponent(s.sessionId)}`);
    expect(pushes[0].message).not.toContain("rm -rf");

    const b = await client("B");
    b.permissionAnswer = async () => ({ outcome: { outcome: "selected", optionId: "allow" } });
    await b.request("session/load", { sessionId: s.sessionId, cwd: tb.home, mcpServers: [] });
    await b.waitFor(() => b.text(s.sessionId).includes("allowed"));
    await b.waitFor(() => b.events(s.sessionId, "state").some((e) => e.event.state === "idle"));
  });
});

describe("files", () => {
  it("only serves paths inside workspaces and session folders", async () => {
    tb = await startTestBridge();
    const c = await client();
    fs.mkdirSync(path.join(tb.home, "src"), { recursive: true });
    fs.writeFileSync(path.join(tb.home, "src", "a.txt"), "hello");
    const listing = await c.request("_codeaw/fs/list", { path: tb.home });
    expect(listing.entries.find((e: any) => e.name === "src").type).toBe("dir");
    const file = await c.request("_codeaw/fs/read", { path: path.join(tb.home, "src", "a.txt") });
    expect(file.text).toBe("hello");
    await expect(c.request("_codeaw/fs/list", { path: path.dirname(tb.home) })).rejects.toThrow(/outside/);
    await expect(c.request("_codeaw/fs/read", { path: path.join(tb.home, "..", "x") })).rejects.toThrow();
    const status = await c.request("_codeaw/git/status", { cwd: tb.home });
    expect(status.files).toEqual([]);
  });
});

describe("reconnect regression", () => {
  it("a device that dropped mid-turn and a fresh device end with the same timeline", async () => {
    tb = await startTestBridge();
    const a = await client("A");
    a.permissionAnswer = async () => ({ outcome: { outcome: "selected", optionId: "allow" } });
    const s = await newFakeSession(a, tb.home);
    await a.request("session/prompt", promptText(s.sessionId, "echo hi there"));
    await a.request("session/prompt", promptText(s.sessionId, "perm"));
    void a.request("session/prompt", promptText(s.sessionId, "slow 25")).catch(() => undefined);
    await a.waitFor(() => a.text(s.sessionId).includes("3 "));
    const lastSeq = Math.max(...a.log(s.sessionId).map((m) => m.params._meta.codeaw.seq));
    a.close();

    const a2 = await client("A");
    await a2.request("session/load", { sessionId: s.sessionId, cwd: tb.home, mcpServers: [], _meta: { codeaw: { afterSeq: lastSeq, epoch: s._meta.codeaw.epoch } } });
    await a2.waitFor(() => a2.events(s.sessionId, "state").some((e) => e.event.state === "idle"));

    const b = await client("B");
    await b.request("session/load", { sessionId: s.sessionId, cwd: tb.home, mcpServers: [] });
    const raw = rawLog(tb, s.sessionId);
    expect(reduce(b.log(s.sessionId))).toEqual(reduce(raw));
    expect(b.text(s.sessionId)).toContain("24 ");
  });
});
