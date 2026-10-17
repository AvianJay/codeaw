import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { parse } from "smol-toml";
import type * as acp from "@agentclientprotocol/sdk";
import type { AgentBackend } from "../src/backend/backend.js";
import type { AgentRegistry } from "../src/backend/registry.js";
import { patchCodexDefaults } from "../src/backend/codex-defaults.js";
import { SessionManager, type ClientHandle } from "../src/session/manager.js";
import { SessionStore } from "../src/session/store.js";

const homes: string[] = [];
const managers: SessionManager[] = [];
afterEach(async () => {
  for (const manager of managers.splice(0)) await manager.shutdown();
  for (const home of homes.splice(0)) fs.rmSync(home, { recursive: true, force: true });
});

function fixture(id = "codex") {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-settings-test-")); homes.push(home);
  const codexHome = path.join(home, "codex"); fs.mkdirSync(codexHome);
  const file = path.join(codexHome, "config.toml");
  const calls: { method: string; params: any }[] = [];
  const state = new Map<string, { model: string; reasoning_effort: string; mode: string }>();
  let next = 0;
  let rejectModel = false, ignoreModel = false;
  const defaults = () => ({ model: "expensive", reasoning_effort: "ultra", mode: "agent" });
  const options = (s: ReturnType<typeof defaults>): any[] => [
    // Deliberately put effort before model; cheap only supports low.
    { id: "reasoning_effort", category: "thought_level", name: "Effort", type: "select", currentValue: s.reasoning_effort,
      options: (s.model === "cheap" ? ["low"] : ["low", "ultra"]).map((value) => ({ value, name: value })) },
    { id: "mode", category: "mode", name: "Mode", type: "select", currentValue: s.mode,
      options: ["agent", "workspace-write", "read-only", "agent-full-access"].map((value) => ({ value, name: value })) },
    { id: "model", category: "model", name: "Model", type: "select", currentValue: s.model,
      options: ["cheap", "expensive"].map((value) => ({ value, name: value })) },
  ];
  const backend = {
    id, config: { name: "Codex", command: "fixture", args: [], env: { CODEX_HOME: codexHome }, enabled: true },
    generation: 1, running: true, capabilities: { sessionCapabilities: { resume: {}, close: {} } },
    supportsSteering: false, supportsForkAtMessage: false, inflight: 0, lastUsed: Date.now(),
    ensureStarted: async () => {}, notify: async () => {}, stop: async () => {}, describe: () => ({ id, name: "Fixture", status: "ready", steering: false }),
    request: async (method: string, params: any) => {
      calls.push({ method, params });
      if (method === "session/new") {
        const sessionId = `s${++next}`; state.set(sessionId, defaults());
        return { sessionId, configOptions: options(state.get(sessionId)!) };
      }
      if (method === "session/resume") {
        state.set(params.sessionId, defaults());
        return { configOptions: options(state.get(params.sessionId)!) };
      }
      if (method === "session/set_config_option") {
        const s = state.get(params.sessionId)!;
        if (params.configId === "model") {
          if (rejectModel) throw new Error("Model unavailable");
          if (!ignoreModel) { s.model = params.value; s.reasoning_effort = s.model === "cheap" ? "low" : "ultra"; }
        } else {
          if (params.configId === "reasoning_effort" && s.model === "cheap" && params.value !== "low") throw new Error("Unsupported effort");
          (s as any)[params.configId] = params.value;
        }
        return { configOptions: options(s) };
      }
      if (method === "session/prompt") return { stopReason: "end_turn" };
      return {};
    },
  } as AgentBackend;
  const client: ClientHandle = { id: "phone", deviceName: "phone", foreground: true,
    notify: vi.fn(async () => {}), request: vi.fn(), flush: async () => {} };
  const store = new SessionStore(path.join(home, "data"));
  function manager() {
    const registry = { get: () => backend, has: () => true, ids: () => [id] } as unknown as AgentRegistry;
    const manager = new SessionManager(registry, store, { idleAgentStopMs: 60000, idleSessionCloseMs: 60000, hostName: "test" });
    manager.addClient(client); managers.push(manager); return manager;
  }
  const newChat = (m: SessionManager) => m.newSession(client, { cwd: home, mcpServers: [] });
  const select = (m: SessionManager, sessionId: string, configId: string, value: string) => m.setConfigOption(client, { sessionId, configId, value } as acp.SetSessionConfigOptionRequest);
  const send = (m: SessionManager, sessionId: string) => m.prompt(client, { sessionId, prompt: [{ type: "text", text: "hello" }] });
  return { home, file, calls, state, backend, client, store, manager, newChat, select, send,
    reject: (value: boolean) => { rejectModel = value; }, ignore: (value: boolean) => { ignoreModel = value; } };
}

const value = (response: any, id: string) => response.configOptions.find((o: any) => o.id === id).currentValue;

describe("Codex defaults and session restoration", () => {
  it("persists the selected model, normalized effort and permission mode for new chats, including after restart", async () => {
    const f = fixture(), m = f.manager(), first = await f.newChat(m);
    await f.select(m, first.sessionId, "reasoning_effort", "low");
    expect(parse(fs.readFileSync(f.file, "utf8"))).toMatchObject({ model: "expensive", model_reasoning_effort: "low" });
    await f.select(m, first.sessionId, "model", "cheap");
    await f.select(m, first.sessionId, "mode", "agent-full-access");
    expect(parse(fs.readFileSync(f.file, "utf8"))).toMatchObject({ model: "cheap", model_reasoning_effort: "low",
      sandbox_mode: "danger-full-access", approval_policy: "never", approvals_reviewer: "user" });
    const next = await f.newChat(m);
    expect([value(next, "model"), value(next, "reasoning_effort"), value(next, "mode")]).toEqual(["cheap", "low", "agent-full-access"]);
    await m.shutdown();
    const afterRestart = await f.newChat(f.manager());
    expect(value(afterRestart, "model")).toBe("cheap");
    expect(value(afterRestart, "mode")).toBe("agent-full-access");
    expect(f.calls.some((c) => c.method === "session/prompt")).toBe(false);
  });

  it("restores a cached chat's own settings before its first send, without changing newer defaults", async () => {
    const f = fixture(), m = f.manager(), chat = await f.newChat(m);
    await f.select(m, chat.sessionId, "model", "cheap");
    await f.select(m, chat.sessionId, "mode", "read-only");
    // Other chats / CLI have since selected an expensive global default.
    fs.writeFileSync(f.file, 'model = "expensive"\nmodel_reasoning_effort = "ultra"\n');
    await m.shutdown();
    const reopened = f.manager();
    const cached = await reopened.loadSession(f.client, { sessionId: chat.sessionId, cwd: f.home, mcpServers: [] });
    expect(value(cached, "model")).toBe("cheap");
    const at = f.calls.length;
    await f.send(reopened, chat.sessionId);
    expect(f.state.get("s1")).toEqual({ model: "cheap", reasoning_effort: "low", mode: "read-only" });
    expect(f.calls.slice(at).map((c) => c.method)).toEqual(["session/resume", "session/set_config_option", "session/set_config_option", "session/prompt"]);
    expect(parse(fs.readFileSync(f.file, "utf8"))).toEqual({ model: "expensive", model_reasoning_effort: "ultra" });
  });

  it("blocks repeated sends when a restore is rejected or unconfirmed, preserving the saved model for retries", async () => {
    const f = fixture("other"), m = f.manager(), chat = await f.newChat(m);
    await f.select(m, chat.sessionId, "model", "cheap");
    await m.closeSession(f.client, { sessionId: chat.sessionId });
    f.reject(true);
    await expect(f.send(m, chat.sessionId)).rejects.toThrow();
    await expect(f.send(m, chat.sessionId)).rejects.toThrow();
    expect(value(f.store.readMeta(chat.sessionId), "model")).toBe("cheap");
    f.reject(false); f.ignore(true);
    await expect(f.send(m, chat.sessionId)).rejects.toThrow();
    expect(f.calls.some((c) => c.method === "session/prompt")).toBe(false);
    f.ignore(false);
    await f.send(m, chat.sessionId);
    expect(f.state.get("s1")?.model).toBe("cheap");
  });

  it("lets a user choose a replacement model after restoration fails", async () => {
    const f = fixture("other"), m = f.manager(), chat = await f.newChat(m);
    await f.select(m, chat.sessionId, "model", "cheap");
    await m.closeSession(f.client, { sessionId: chat.sessionId });
    f.reject(true);
    await expect(f.send(m, chat.sessionId)).rejects.toThrow();
    f.reject(false);
    const response = await f.select(m, chat.sessionId, "model", "expensive");
    expect(value(response, "model")).toBe("expensive");
    await f.send(m, chat.sessionId);
    expect(f.state.get("s1")?.model).toBe("expensive");
  });

  it("keeps settings for each idle session when the agent process restarts", async () => {
    const f = fixture("other"), m = f.manager(), a = await f.newChat(m), b = await f.newChat(m);
    await f.select(m, a.sessionId, "model", "cheap");
    await f.select(m, b.sessionId, "reasoning_effort", "low");
    (f.backend as { generation: number }).generation++;
    await f.send(m, a.sessionId); await f.send(m, b.sessionId);
    expect(f.state.get("s1")).toMatchObject({ model: "cheap", reasoning_effort: "low" });
    expect(f.state.get("s2")).toMatchObject({ model: "expensive", reasoning_effort: "low" });
  });

  it("round trips every permission preset through the official configuration fields", async () => {
    const f = fixture(), m = f.manager(), chat = await f.newChat(m);
    for (const mode of ["read-only", "workspace-write", "agent", "agent-full-access"]) {
      await f.select(m, chat.sessionId, "mode", mode);
      expect(value(await f.newChat(m), "mode")).toBe(mode);
    }
  });

  it("preserves modern permission profiles without mixing in legacy sandbox_mode", async () => {
    const f = fixture(); fs.writeFileSync(f.file, 'default_permissions = ":read-only"\n# keep custom profiles\n[permissions.custom]\nnetwork = false\n');
    const m = f.manager(), chat = await f.newChat(m);
    expect(value(chat, "mode")).toBe("read-only");
    await f.select(m, chat.sessionId, "mode", "agent-full-access");
    const config = parse(fs.readFileSync(f.file, "utf8"));
    expect(config).toMatchObject({ default_permissions: ":danger-full-access", approval_policy: "never", permissions: { custom: { network: false } } });
    expect(config).not.toHaveProperty("sandbox_mode");
    expect(value(await f.newChat(m), "mode")).toBe("agent-full-access");
  });

  it("does not expose a newly created chat when its saved model cannot be confirmed", async () => {
    const f = fixture(); fs.writeFileSync(f.file, 'model = "cheap"\nmodel_reasoning_effort = "low"\n');
    f.ignore(true);
    const m = f.manager();
    await expect(f.newChat(m)).rejects.toThrow();
    expect(f.calls.some((c) => c.method === "session/prompt")).toBe(false);
    expect(f.store.listMetas()).toEqual([]);
  });

  it("sanitizes TOML errors and never starts a turn or overwrites a malformed configuration", async () => {
    const f = fixture(), m = f.manager(), chat = await f.newChat(m);
    const bad = 'private_key = "fixture-sensitive-value"\nbad = [\n'; fs.writeFileSync(f.file, bad);
    await expect(f.select(m, chat.sessionId, "model", "cheap")).rejects.toThrow(/^This chat's setting changed, but its Codex default could not be saved to config.toml$/);
    expect(fs.readFileSync(f.file, "utf8")).toBe(bad);
    await expect(f.newChat(m)).rejects.toThrow(/^Could not read Codex defaults from config.toml$/);
    expect(f.calls.some((c) => c.method === "session/prompt")).toBe(false);
  });
});

describe("preserving config.toml", () => {
  it.each(["\n", "\r\n"])("preserves unrelated nested keys, multiline content and comments with %j newlines", (nl) => {
    const original = ["# personal settings", '"model" = "old"', "instructions = '''", '[not_a_table]', 'model = "inside literal text"', "'''",
      'model_reasoning_effort = "high"', '[profiles.work]', 'model = "profile-model"', '# keep this comment', '[mcp_servers.test]', 'command = "fixture"', 'args = ["--one", "--two"]', ''].join(nl);
    const result = patchCodexDefaults(original, { model: "cheap", model_reasoning_effort: "low", approvals_reviewer: "auto_review" });
    expect(parse(result)).toEqual({ ...parse(original), model: "cheap", model_reasoning_effort: "low", approvals_reviewer: "auto_review" });
    expect(result).toContain(original.slice(original.indexOf('[profiles.work]')));
    expect(result).toContain(['instructions = \'\'\'', '[not_a_table]', 'model = "inside literal text"', "'''"].join(nl));
    expect(result.startsWith(`# personal settings${nl}`)).toBe(true);
  });

  it("handles arrays, inline tables, escaped multiline strings, missing root defaults and an empty file", () => {
    for (const original of ['', '[profile]\nmodel = "keep"\n', 'array = [\n"[profile]",\n"model = keep"\n]\ninline = { model = "keep" }\n', 'text = """first\\\n   second \\"quoted\\""""\n']) {
      const result = patchCodexDefaults(original, { model: "cheap" });
      expect(parse(result)).toEqual({ ...parse(original), model: "cheap" });
    }
  });
});
