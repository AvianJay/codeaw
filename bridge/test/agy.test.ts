import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { ConfigSchema } from "../src/config.js";
import { AgyBackend, agyErrorMessage, agyTitle, agyToolCall, agyToolOutput, geminiProviderEnvironment } from "../src/backend/agy.js";
import { AgentRegistry } from "../src/backend/registry.js";
import type { AgentHandlers } from "../src/backend/agent-process.js";
import { startBridge } from "../src/bridge.js";
import { TestClient } from "./helpers.js";

const fixture = fileURLToPath(new URL("./fixtures/agy.mjs", import.meta.url));
const homes: string[] = [];
const backends: AgyBackend[] = [];
const home = () => { const root = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-agy-test-")); homes.push(root); return root; };
const handlers = (updates: any[] = []): AgentHandlers => ({ onUpdate: (_id, p) => updates.push(p), onExit: () => {},
  onPermission: async () => { throw new Error("Headless must not request interactive approval"); },
  onElicitation: async () => { throw new Error("Headless must not request interactive input"); } });

function backend(root = home(), updates: any[] = [], extra: Record<string, unknown> = {}) {
  const config = ConfigSchema.parse({ agents: { agy: { name: "AGY", command: process.execPath, args: [fixture], transport: "agy",
    env: { AGY_FIXTURE_HOME: root, GEMINI_API_KEY: "synthetic-private-key" }, ...extra } } }).agents.agy;
  // AGY's own settings file is per user; tests must not read this computer's.
  const agent = new AgyBackend("agy", config, handlers(updates), path.join(root, "logs"), 1000, path.join(root, "agy-settings.json"));
  backends.push(agent);
  return agent;
}
const prompt = (a: AgyBackend, sessionId: string, text: string) => a.request<any>("session/prompt", { sessionId, prompt: [{ type: "text", text }] });
const launches = (root: string) => fs.readFileSync(path.join(root, "launches.jsonl"), "utf8").trim().split("\n").map((l) => JSON.parse(l));
const waitFor = async (predicate: () => boolean) => {
  const deadline = Date.now() + 5000;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error("AGY fixture timed out");
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
};

afterEach(async () => {
  await Promise.all(backends.splice(0).map((b) => b.stop()));
  for (const root of homes.splice(0)) {
    if (!path.resolve(root).startsWith(path.resolve(os.tmpdir()) + path.sep) || !path.basename(root).startsWith("codeaw-agy-test-")) throw new Error("Unsafe cleanup path");
    fs.rmSync(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  }
});

describe("AGY NDJSON backend", () => {
  it("keeps two conversations isolated, streams Unicode/tools and resumes native context after bridge restart", async () => {
    const root = home(); const updates: any[] = []; let a = backend(root, updates);
    const first = await a.request<any>("session/new", { cwd: root });
    const second = await a.request<any>("session/new", { cwd: root });
    await Promise.all([prompt(a, first.sessionId, "remember 蘋果"), prompt(a, second.sessionId, "remember banana")]);
    const result = await prompt(a, first.sessionId, "tools");
    expect(result.usage).toMatchObject({ inputTokens: 200, outputTokens: 14, thoughtTokens: 6 });
    expect(updates.filter((u) => u.sessionId === first.sessionId && u.update.sessionUpdate === "agent_message_chunk").map((u) => u.update.content.text).join("")).toBe("remember 蘋果\n工具完成🙂\n");
    expect(updates.find((u) => u.update.sessionUpdate === "tool_call").update).toMatchObject({ title: "echo hello_headless_demo", kind: "execute", status: "in_progress", rawInput: { CommandLine: "echo hello_headless_demo" } });
    expect(updates.find((u) => u.update.sessionUpdate === "tool_call_update").update).toMatchObject({ status: "completed", rawOutput: "hello_headless_demo\r\n" });
    await a.stop(); a = backend(root, updates);
    await a.request("session/resume", { sessionId: first.sessionId, cwd: root });
    await prompt(a, first.sessionId, "recall");
    expect(updates.at(-2).update.content.text).toBe("蘋果");
    expect(launches(root).at(-1).args).toContain("--conversation");
    await prompt(a, second.sessionId, "recall");
    expect(updates.at(-2).update.content.text).toBe("banana");
    expect(launches(root).some((l) => l.args.includes("--dangerously-skip-permissions"))).toBe(false);
  });

  it("applies model, effort and mode on the next turn and saves settings across restarts", async () => {
    const root = home(); const updates: any[] = []; let a = backend(root, updates);
    const s = await a.request<any>("session/new", { cwd: root });
    const active = prompt(a, s.sessionId, "before");
    await waitFor(() => updates.some((u) => u.update.content?.text === "before"));
    await a.request("session/set_config_option", { sessionId: s.sessionId, configId: "model", value: "gemini-3.8-flash" });
    await a.request("session/set_config_option", { sessionId: s.sessionId, configId: "effort", value: "low" });
    await a.request("session/set_mode", { sessionId: s.sessionId, modeId: "plan" });
    expect((await active).stopReason).toBe("end_turn");
    await prompt(a, s.sessionId, "settings");
    expect(updates.at(-2).update.content.text).toBe("gemini-3.8-flash|low|plan");
    expect(launches(root)).toHaveLength(2);
    await a.stop(); a = backend(root, updates);
    const resumed = await a.request<any>("session/resume", { sessionId: s.sessionId });
    expect(resumed.configOptions.find((o: any) => o.id === "effort").currentValue).toBe("low");
    await prompt(a, s.sessionId, "settings");
    expect(updates.at(-2).update.content.text).toBe("gemini-3.8-flash|low|plan");
  });

  it("cancels only the requested conversation and preserves its native context for another turn", async () => {
    const root = home(); const updates: any[] = []; const a = backend(root, updates);
    const s = await a.request<any>("session/new", { cwd: root });
    await prompt(a, s.sessionId, "remember saved");
    const pending = prompt(a, s.sessionId, "hang");
    await waitFor(() => a.inflight === 1);
    // The existing process is ready before this second prompt.
    await new Promise((resolve) => setTimeout(resolve, 30));
    await a.notify("session/cancel", { sessionId: s.sessionId });
    expect((await pending).stopReason).toBe("cancelled");
    await prompt(a, s.sessionId, "recall");
    expect(updates.at(-2).update.content.text).toBe("saved");
  });

  it("rejects startup/result/protocol failures and does not reveal provider keys", async () => {
    const root = home(); const a = backend(root);
    const s = await a.request<any>("session/new", { cwd: root });
    await expect(prompt(a, s.sessionId, "error")).rejects.toThrow("Invalid API key [REDACTED]");
    await expect(prompt(a, s.sessionId, "bad-json")).rejects.toThrow("Invalid AGY stream");
    await expect(prompt(a, s.sessionId, "crash")).rejects.toThrow(/AGY exited/);
    await a.request("session/set_config_option", { sessionId: s.sessionId, configId: "model", value: "invalid-model" });
    await expect(prompt(a, s.sessionId, "hello")).rejects.toThrow("Unknown model invalid-model");
    expect(a.inflight).toBe(0);
    const state = fs.readFileSync(path.join(root, "agy", "agy", s.sessionId + ".json"), "utf8");
    expect(state).not.toContain("synthetic-private-key");
  });

  it("cancels while AGY is initializing without leaving a new process or starting the prompt", async () => {
    const root = home(); const updates: any[] = [];
    const a = backend(root, updates, { env: { AGY_FIXTURE_HOME: root, AGY_FIXTURE_SLOW_INIT: "1" } });
    const s = await a.request<any>("session/new", { cwd: root });
    const starting = prompt(a, s.sessionId, "should not run");
    await waitFor(() => fs.existsSync(path.join(root, "launches.jsonl")));
    await a.notify("session/cancel", { sessionId: s.sessionId });
    expect((await starting).stopReason).toBe("cancelled");
    // Only the title taken from the message; nothing from a turn.
    expect(updates.map((u) => u.update.sessionUpdate)).toEqual(["session_info_update"]);
    expect(a.inflight).toBe(0);
    await prompt(a, s.sessionId, "after cancel");
    expect(updates.at(-2).update.content.text).toBe("after cancel");
    expect(launches(root)).toHaveLength(2);
  });

  it("rejects inline images before starting AGY and preserves explicit uploaded file references", async () => {
    const root = home(); const updates: any[] = []; const a = backend(root, updates);
    const s = await a.request<any>("session/new", { cwd: root });
    await expect(a.request("session/prompt", { sessionId: s.sessionId, prompt: [{ type: "image", mimeType: "image/png", data: "x" }] })).rejects.toThrow("Upload images as files");
    expect(fs.existsSync(path.join(root, "launches.jsonl"))).toBe(false);
    await a.request("session/prompt", { sessionId: s.sessionId, prompt: [{ type: "resource_link", name: "attachment", uri: "file:///C:/upload.txt" }] });
    expect(updates.at(-2).update.content.text).toBe("attachment: file:///C:/upload.txt");
  });

  it("rereads CC Switch provider changes between turns and only imports permitted Gemini variables", async () => {
    const root = home(); const file = path.join(root, "gemini.env");
    fs.writeFileSync(file, "GEMINI_API_KEY='test-one'\nGOOGLE_GEMINI_BASE_URL=https://first.example\nGEMINI_MODEL=gemini-3.8-flash-low\nPATH=hostile\nNODE_OPTIONS=hostile\n");
    expect(geminiProviderEnvironment(file)).toEqual({ GEMINI_API_KEY: "test-one", GOOGLE_GEMINI_BASE_URL: "https://first.example", GEMINI_MODEL: "gemini-3.8-flash-low" });
    const a = backend(root, [], { geminiEnvFile: file });
    const s = await a.request<any>("session/new", { cwd: root }); await prompt(a, s.sessionId, "first");
    fs.writeFileSync(file, "export GEMINI_API_KEY=\"test-two\"\nGOOGLE_GEMINI_BASE_URL=https://second.example # switched\n");
    await prompt(a, s.sessionId, "second");
    expect(launches(root).map((l) => l.endpoint)).toEqual(["https://first.example", "https://second.example"]);
  });

  it("explains a Gemini API provider without a key before launching AGY", async () => {
    const root = home(); const updates: any[] = [];
    const file = path.join(root, "gemini.env");
    fs.writeFileSync(file, "");
    fs.writeFileSync(path.join(root, "agy-settings.json"), JSON.stringify({ modelProvider: "gemini" }));
    const a = backend(root, updates, { env: { AGY_FIXTURE_HOME: root }, geminiEnvFile: file });
    const s = await a.request<any>("session/new", { cwd: root });
    await expect(prompt(a, s.sessionId, "hello")).rejects.toThrow(/"modelProvider": "gemini".*gemini\.env has no GEMINI_API_KEY.*CC Switch.*agents\.agy\.env/s);
    expect(fs.existsSync(path.join(root, "launches.jsonl"))).toBe(false);
    // Selecting the provider in CC Switch fills the file; the next message works.
    fs.writeFileSync(file, "GEMINI_API_KEY=switched-key\nGOOGLE_GEMINI_BASE_URL=https://proxy.example\n");
    await prompt(a, s.sessionId, "hello");
    expect(launches(root).map((l) => l.endpoint)).toEqual(["https://proxy.example"]);
    // Google sign-in needs no key, and a missing file is not an error by itself.
    fs.writeFileSync(path.join(root, "agy-settings.json"), JSON.stringify({}));
    const b = backend(root, [], { env: { AGY_FIXTURE_HOME: root }, geminiEnvFile: path.join(root, "absent.env") });
    const t = await b.request<any>("session/new", { cwd: root });
    await prompt(b, t.sessionId, "signed in");
    expect(geminiProviderEnvironment(path.join(root, "absent.env"))).toEqual({});
  });

  it("titles a conversation once, from its first message", async () => {
    const root = home(); const updates: any[] = []; let a = backend(root, updates);
    const s = await a.request<any>("session/new", { cwd: root });
    await prompt(a, s.sessionId, "\n  Fix   the login page\nand more details");
    await prompt(a, s.sessionId, "second message");
    await a.stop(); a = backend(root, updates);
    await prompt(a, s.sessionId, "after restart");
    expect(updates.filter((u) => u.update.sessionUpdate === "session_info_update").map((u) => u.update.title)).toEqual(["Fix the login page"]);
    expect(agyTitle("x".repeat(80))).toHaveLength(60);
    expect(agyTitle(" \n ")).toBeUndefined();
  });

  it("names tool calls by what they touch and keeps only what a command printed", () => {
    expect(agyToolCall("read_file", { Path: "C:\\work\\notes.txt" })).toEqual({ title: "Read notes.txt", kind: "read", locations: [{ path: "C:\\work\\notes.txt" }] });
    expect(agyToolCall("view_file", { AbsolutePath: "/tmp/a.ts" })).toMatchObject({ title: "Read a.ts", kind: "read" });
    expect(agyToolCall("edit_file", { Path: "C:\\work\\notes.txt" })).toMatchObject({ title: "Edit notes.txt", kind: "edit" });
    expect(agyToolCall("write_to_file", { TargetFile: "/w/hello.txt" })).toMatchObject({ title: "Write hello.txt", kind: "edit", locations: [{ path: "/w/hello.txt" }] });
    expect(agyToolCall("run_command", { CommandLine: "echo done", Cwd: "C:\\work" })).toEqual({ title: "echo done", kind: "execute", locations: [{ path: "C:\\work" }] });
    expect(agyToolCall("grep_search", { Query: "beta", SearchPath: "/w" })).toMatchObject({ title: "Search beta", kind: "search" });
    expect(agyToolCall("list_dir", { DirectoryPath: "/w" })).toMatchObject({ title: "List /w", kind: "read" });
    expect(agyToolCall("search_web", { query: "acp" })).toMatchObject({ title: "Search the web: acp", kind: "fetch" });
    expect(agyToolCall("browser_click_element", {})).toEqual({ title: "Browser click element", kind: "other" });
    // As AGY 1.5 reports a finished command.
    const ran = "Created At: 2026-11-23T09:08:05+08:00\nCompleted At: 2026-11-23T09:08:06+08:00\nCommand exited with code 0.\n\nCommand output:\ndone\r\n";
    expect(agyToolOutput("run_command", ran)).toBe("done");
    expect(agyToolOutput("run_command", ran.replace("code 0", "code 2"))).toBe("Exit code 2\ndone");
    expect(agyToolOutput("run_command", "no preamble")).toBe("no preamble");
    expect(agyToolOutput("read_file", "2 lines, 11 bytes")).toBe("2 lines, 11 bytes");
  });

  it("turns provider failures into the provider's own words with a hint", () => {
    const raw = 'agent executor error: generating and executing: Error 400, Message: {"error":{"message":"unknown provider for model gemini-3.8-flash","type":"invalid_request_error","code":"model_not_found","param":"model"}}, Status: 400 Bad Request, Details: []';
    expect(agyErrorMessage(raw)).toBe("The model provider answered HTTP 400: unknown provider for model gemini-3.8-flash. This provider does not serve that model: pick another one in the model menu. Custom models from AGY's customModelsConfig are listed there too.");
    expect(agyErrorMessage(raw.replace("400", "429").replace("unknown provider for model gemini-3.8-flash", "quota exceeded").replace("model_not_found", "rate_limited"))).toContain("HTTP 429: quota exceeded. The provider is rate limiting");
    expect(agyErrorMessage("agent executor error: generating and executing: connection reset")).toBe("connection reset");
    expect(agyErrorMessage("Invalid API key [REDACTED]")).toBe("Invalid API key [REDACTED]");
  });

  it("uses the explicit transport selector and allows ACP registry installs to remain ACP", () => {
    const root = home(); const a = backend(root);
    const registry = new AgentRegistry({ agy: a.config, acp: { ...a.config, transport: "acp" } }, handlers(), root);
    expect(registry.get("agy")).toBeInstanceOf(AgyBackend);
    expect(registry.get("acp")).not.toBeInstanceOf(AgyBackend);
  });

  it("queues mid-turn messages through the actual bridge and replays both completed turns", async () => {
    const root = home(); const a = backend(root);
    const config = ConfigSchema.parse({ agents: { agy: a.config }, workspaces: [root] });
    const bridge = await startBridge({ config, home: root, file: path.join(root, "config.yaml"), dataDir: path.join(root, "data") }, { hosts: ["127.0.0.1"], port: 0 });
    const token = "a".repeat(64); bridge.devices.addDeviceWithToken("agy-fixture", token);
    const c = await TestClient.connect(`ws://127.0.0.1:${bridge.port()}/acp`, token);
    try {
      const s = await c.request("session/new", { cwd: root, mcpServers: [], _meta: { codeaw: { agentId: "agy" } } });
      const first = c.request("session/prompt", { sessionId: s.sessionId, prompt: [{ type: "text", text: "remember bridge" }] });
      await waitFor(() => c.updates(s.sessionId).some((u) => u.update.content?.text === "remember bridge"));
      const second = c.request("session/prompt", { sessionId: s.sessionId, prompt: [{ type: "text", text: "recall" }] });
      await waitFor(() => c.events(s.sessionId, "state").some((e) => e.event.queued === 1));
      expect((await first).stopReason).toBe("end_turn"); expect((await second).stopReason).toBe("end_turn");
      await c.request("session/load", { sessionId: s.sessionId, cwd: root, mcpServers: [] });
      expect(c.updates(s.sessionId).filter((u) => u.update.sessionUpdate === "agent_message_chunk").map((u) => u.update.content.text).join("")).toContain("bridge\n");
      expect(launches(root)).toHaveLength(1);
    } finally { c.close(); await bridge.stop(); }
  });
});
