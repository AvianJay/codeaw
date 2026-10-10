/** Real Oh My Pi ACP check through a temporary bridge. Never sends a prompt. */
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { ConfigSchema, detectAgents } from "../src/config.js";
import { startBridge } from "../src/bridge.js";
import { setLogSilent } from "../src/util/log.js";
import { TestClient } from "../test/helpers.js";

setLogSilent(true);
const detected = detectAgents().omp;
if (!detected) throw new Error("Oh My Pi was not found on PATH or in the default Windows installation directory");
const home = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-omp-smoke-"));
const config = ConfigSchema.parse({ agents: { omp: detected }, workspaces: [home] });
const bridge = await startBridge({ config, file: path.join(home, "config.yaml"), home, dataDir: path.join(home, "data") },
  { hosts: ["127.0.0.1"], port: 0, agentStartTimeoutMs: 30_000 });
const token = "a".repeat(64);
bridge.devices.addDeviceWithToken("omp-smoke", token);
let client: TestClient | undefined;
let sessionId: string | undefined;
try {
  client = await TestClient.connect(`ws://127.0.0.1:${bridge.port()}/acp`, token);
  const agent = bridge.registry.get("omp");
  await agent.ensureStarted();
  const info = agent.describe();
  assert.equal(info.status, "ready");
  assert.equal((info.agentInfo as { name: string }).name, "omp");
  console.log(`Oh My Pi ACP initialized (${(info.agentInfo as { version: string }).version})`);
  console.log(`load=${!!agent.capabilities?.loadSession} image=${!!agent.capabilities?.promptCapabilities?.image} steering=${agent.supportsSteering}`);
  const created = await client.request("session/new", { cwd: home, mcpServers: [], _meta: { codeaw: { agentId: "omp" } } });
  sessionId = created.sessionId;
  assert.ok(sessionId?.startsWith("omp:"));
  assert.ok(created.configOptions?.length);
  console.log(`session/new succeeded; settings: ${created.configOptions.map((option: any) => option.id).join(", ")}`);
  for (const option of created.configOptions) {
    if (option.type === "select" && typeof option.currentValue === "string") {
      await client.request("session/set_config_option", { sessionId, configId: option.id, value: option.currentValue });
    }
  }
  console.log("session settings accepted");
  const list = await client.request("session/list", { cwd: home });
  assert.ok(list.sessions.some((session: any) => session.sessionId === sessionId));
  await client.request("session/close", { sessionId });
  await client.request("_codeaw/agents/restart", { agentId: "omp" });
  await client.request("session/resume", { sessionId, cwd: home, mcpServers: [] });
  await client.request("session/load", { sessionId, cwd: home, mcpServers: [] });
  console.log("session list, close, process restart, resume and load succeeded");
} catch {
  // Provider/extension diagnostics can contain credentials; report no payloads.
  console.error("Oh My Pi ACP smoke check failed");
  process.exitCode = 1;
} finally {
  if (sessionId && client) await client.request("session/close", { sessionId }).catch(() => undefined);
  client?.close();
  await bridge.stop();
  if (!path.resolve(home).startsWith(path.resolve(os.tmpdir()) + path.sep) || !path.basename(home).startsWith("codeaw-omp-smoke-")) throw new Error("Unsafe smoke cleanup path");
  fs.rmSync(home, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}
