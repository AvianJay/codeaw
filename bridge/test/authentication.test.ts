import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, expect, it } from "vitest";
import { startBridge, type Bridge } from "../src/bridge.js";
import { ConfigSchema } from "../src/config.js";
import { TestClient } from "./helpers.js";

const roots: string[] = [];
const bridges: Bridge[] = [];
const clients: TestClient[] = [];
const methods = [{ id: "oauth-personal", name: "Log in with Google", description: "Use your Google account" },
  { id: "gemini-api-key", name: "Gemini API key" }];

async function setup(env: Record<string, string> = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-auth-test-")); roots.push(root);
  const agent = { name: "Antigravity", command: process.execPath, args: [fileURLToPath(new URL("./fixtures/acp-auth.mjs", import.meta.url))], env };
  const config = ConfigSchema.parse({ agents: { antigravity: agent, other: { ...agent, name: "Other" } }, workspaces: [root] });
  const bridge = await startBridge({ config, home: root, file: path.join(root, "config.yaml"), dataDir: path.join(root, "data") }, { hosts: ["127.0.0.1"], port: 0 });
  bridges.push(bridge);
  const token = "a".repeat(64); bridge.devices.addDeviceWithToken("auth-fixture", token);
  const client = await TestClient.connect(`ws://127.0.0.1:${bridge.port()}/acp`, token); clients.push(client);
  const newSession = (agentId = "antigravity") => client.request("session/new", { cwd: root, mcpServers: [], _meta: { codeaw: { agentId } } });
  const authCalls = (agentId = "antigravity") => bridge.registry.get(agentId).request("_fixture/authCalls", {});
  return { client, newSession, authCalls, root };
}

afterEach(async () => {
  for (const client of clients.splice(0)) client.close();
  await Promise.all(bridges.splice(0).map((bridge) => bridge.stop()));
  for (const root of roots.splice(0)) {
    if (path.dirname(root) !== path.resolve(os.tmpdir()) || !path.basename(root).startsWith("codeaw-auth-test-")) throw new Error("Unsafe test cleanup");
    fs.rmSync(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  }
});

it("returns actionable authentication methods without local diagnostics, launch env or metadata", async () => {
  const { client, newSession } = await setup();
  await expect(newSession()).rejects.toMatchObject({ code: -32000, message: "Authentication required",
    data: { codeaw: { agentId: "antigravity", authMethods: methods } } });
  const { agents } = await client.request("_codeaw/agents/list", {});
  expect(agents.find((agent: any) => agent.id === "antigravity").authMethods).toEqual(methods);
  expect(JSON.stringify(agents)).not.toContain("fixture-private");
});

it("authenticates the selected agent and retries session creation using only its method ID", async () => {
  const { client, newSession, authCalls } = await setup();
  await expect(newSession()).rejects.toMatchObject({ code: -32000 });
  await client.request("_codeaw/agents/authenticate", { agentId: "antigravity", methodId: "gemini-api-key", env: { UNTRUSTED: "ignored" }, _meta: { ignored: true } });
  expect(await authCalls()).toEqual({ calls: [{ methodId: "gemini-api-key" }] });
  expect((await newSession()).sessionId).toBe("antigravity:session-1");
  await expect(newSession("other")).rejects.toMatchObject({ code: -32000 });
  expect(await authCalls("other")).toEqual({ calls: [] });
});

it("rejects malformed, unadvertised and terminal methods before forwarding authentication", async () => {
  const { client, authCalls } = await setup();
  for (const params of [{}, { agentId: "antigravity", methodId: 1 },
    { agentId: "antigravity", methodId: "unknown" }, { agentId: "antigravity", methodId: "terminal-login" },
    { agentId: "missing", methodId: "oauth-personal" }]) {
    await expect(client.request("_codeaw/agents/authenticate", params)).rejects.toMatchObject({ code: -32602 });
  }
  expect(await authCalls()).toEqual({ calls: [] });
});

it("keeps failed sign-in retryable without exposing provider diagnostics", async () => {
  const { client, newSession, authCalls, root } = await setup({ ACP_AUTH_FAIL_METHOD: "gemini-api-key" });
  await expect(client.request("_codeaw/agents/authenticate", { agentId: "antigravity", methodId: "gemini-api-key" })).rejects.toMatchObject({
    code: -32000, message: "Authentication required", data: { codeaw: { agentId: "antigravity", authMethods: methods, authFailed: true } },
  });
  await client.request("_codeaw/agents/authenticate", { agentId: "antigravity", methodId: "oauth-personal" });
  expect((await newSession()).sessionId).toBe("antigravity:session-1");
  expect(await authCalls()).toEqual({ calls: [{ methodId: "gemini-api-key" }, { methodId: "oauth-personal" }] });
  expect(fs.existsSync(path.join(root, "data", "logs", "antigravity.log"))).toBe(false);
});

it("creates an already-authenticated session without starting another sign-in", async () => {
  const { newSession, authCalls } = await setup({ ACP_AUTH_PREAUTH: "1" });
  expect((await newSession()).sessionId).toBe("antigravity:session-1");
  expect(await authCalls()).toEqual({ calls: [] });
});
