import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { afterEach, expect, it, vi } from "vitest";
import { SessionStore } from "../src/session/store.js";
import { newFakeSession, promptText, startTestBridge, TestClient, type TestBridge } from "./helpers.js";

let bridge: TestBridge | undefined;
const clients: TestClient[] = [];
let retainedHome: string | undefined;
afterEach(async () => {
  vi.restoreAllMocks();
  for (const c of clients.splice(0)) c.close();
  await bridge?.stop();
  bridge = undefined;
  if (retainedHome) {
    if (path.dirname(retainedHome) !== os.tmpdir() || !path.basename(retainedHome).startsWith("codeaw-test-")) throw new Error("Unexpected test directory");
    fs.rmSync(retainedHome, { recursive: true, force: true });
    retainedHome = undefined;
  }
});

async function connect() {
  const c = await TestClient.connect(bridge!.url, bridge!.tokenFor("projectless-phone"));
  clients.push(c);
  return c;
}

it("creates independent no-project chats without workspaces, ignoring client paths and retaining normal guards", async () => {
  bridge = await startTestBridge();
  bridge.loaded.config.workspaces = [];
  const c = await connect();
  expect(c.init._meta.codeaw.projectless).toBe(true);
  await expect(newFakeSession(c, bridge.home)).rejects.toThrow(/outside/);
  const a = await newFakeSession(c, "", { projectless: true });
  const agent = bridge.bridge.registry.get("fake");
  agent.capabilities!.sessionCapabilities!.additionalDirectories = {};
  const requests = vi.spyOn(agent, "request");
  const b = await c.request("session/new", { cwd: os.tmpdir(), additionalDirectories: [os.tmpdir()], mcpServers: [], _meta: { codeaw: { projectless: true } } });
  expect(requests).toHaveBeenCalledWith("session/new", { cwd: b._meta.codeaw.cwd, mcpServers: [] });
  const cwd = a._meta.codeaw.cwd;
  expect(a._meta.codeaw.projectless).toBe(true);
  expect(path.dirname(cwd)).toBe(path.join(bridge.loaded.dataDir, "chats"));
  expect(fs.statSync(cwd).isDirectory()).toBe(true);
  expect(b._meta.codeaw.cwd).not.toBe(cwd);
  const native = JSON.parse(fs.readFileSync(path.join(bridge.home, "fake-state.json"), "utf8"));
  expect(native[a.sessionId.split(":")[1]].cwd).toBe(cwd);
  expect(native[b.sessionId.split(":")[1]].cwd).toBe(b._meta.codeaw.cwd);
  await expect(c.request("_codeaw/fs/list", { path: os.tmpdir() })).rejects.toThrow(/outside/);
  await expect(newFakeSession(c, os.tmpdir())).rejects.toThrow(/outside/);
  const file = path.join(cwd, "note.txt");
  fs.writeFileSync(file, "only this chat");
  expect((await c.request("_codeaw/fs/read", { path: file })).text).toBe("only this chat");
  bridge.loaded.config.workspaces = [bridge.home];
  const project = await newFakeSession(c, bridge.home);
  expect(project._meta.codeaw.projectless).toBe(false);
  expect(project._meta.codeaw.cwd).toBe(bridge.home);
});

it("keeps no-project uploads, metadata, activity and conversation history through bridge restart", async () => {
  bridge = await startTestBridge({ keepHome: true });
  retainedHome = bridge.home;
  bridge.loaded.config.workspaces = [];
  const c = await connect();
  const s = await newFakeSession(c, "", { projectless: true });
  const cwd = s._meta.codeaw.cwd;
  const response = await fetch(`${bridge.http}/api/uploads?sessionId=${encodeURIComponent(s.sessionId)}&name=note.txt`, {
    method: "POST", headers: { Authorization: `Bearer ${bridge.tokenFor("projectless-phone")}` }, body: "projectless attachment",
  });
  expect(response.status).toBe(201);
  const uploaded = await response.json() as any;
  expect(path.dirname(uploaded.path)).toBe(path.join(cwd, ".codeaw-uploads"));
  await c.request("session/prompt", { ...promptText(s.sessionId, "echo saved reply"), prompt: [{ type: "text", text: "echo saved reply" }, uploaded.block] });
  await c.waitFor(() => c.received.some((r) => r.method === "_codeaw/activity" && r.params.sessionId === s.sessionId && r.params.state === "idle"));
  const activity = c.received.filter((r) => r.method === "_codeaw/activity" && r.params.sessionId === s.sessionId).at(-1)!.params;
  expect(activity).toMatchObject({ projectless: true, work: { project: "無專案" } });
  c.close();
  await bridge.stop();
  bridge = await startTestBridge({ home: retainedHome });
  bridge.loaded.config.workspaces = [];
  const next = await connect();
  const list = await next.request("session/list", {});
  expect(list.sessions.find((item: any) => item.sessionId === s.sessionId)).toMatchObject({ cwd, _meta: { codeaw: { projectless: true } } });
  const loaded = await next.request("session/load", { sessionId: s.sessionId, cwd: "", mcpServers: [] });
  expect(loaded._meta.codeaw).toMatchObject({ cwd, projectless: true });
  expect(next.text(s.sessionId)).toBe("saved reply");
  expect((await next.request("_codeaw/fs/read", { path: uploaded.path })).text).toBe("projectless attachment");
  await next.request("session/prompt", promptText(s.sessionId, "echo continued"));
  expect(next.text(s.sessionId)).toBe("saved replycontinued");
  expect((await next.request("session/resume", { sessionId: s.sessionId, cwd: "", mcpServers: [] }))._meta.codeaw).toMatchObject({ cwd, projectless: true });
});

it("cleans empty allocations after agent creation failure but preserves any files written by the agent", async () => {
  bridge = await startTestBridge();
  const c = await connect();
  const agent = bridge.bridge.registry.get("fake");
  await agent.ensureStarted();
  const original = agent.request.bind(agent);
  let keepFile = false;
  vi.spyOn(agent, "request").mockImplementation(async (method, params: any) => {
    if (method !== "session/new") return original(method, params);
    if (keepFile) fs.writeFileSync(path.join(params.cwd, "important.txt"), "keep me");
    throw new Error("creation failed");
  });
  const root = path.join(bridge.loaded.dataDir, "chats");
  await expect(newFakeSession(c, "", { projectless: true })).rejects.toThrow();
  expect(fs.readdirSync(root)).toEqual([]);
  keepFile = true;
  await expect(newFakeSession(c, "", { projectless: true })).rejects.toThrow();
  expect(fs.readdirSync(root)).toHaveLength(1);
  expect(fs.readFileSync(path.join(root, fs.readdirSync(root)[0], "important.txt"), "utf8")).toBe("keep me");
  expect(new SessionStore(bridge.loaded.dataDir).listMetas()).toEqual([]);
});
