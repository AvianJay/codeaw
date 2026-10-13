import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import assert from "node:assert/strict";
import { AgentProcess, type AgentHandlers } from "../src/backend/agent-process.js";
import { resolveCommand } from "../src/util/environment.js";
import { setLogSilent } from "../src/util/log.js";

if (process.platform !== "win32") throw new Error("This smoke checks the Windows PyInstaller executable");
const command = resolveCommand(process.argv[2] ?? "agy_acp_server.exe");
if (!command) throw new Error("Install Antigravity ACP or pass its executable path");
setLogSilent(true);
const root = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-agy-acp-smoke-"));
const tempRoot = path.join(root, "tmp", "agy-acp");
const handlers: AgentHandlers = { onUpdate: () => {}, onExit: () => {},
  onPermission: async () => ({ outcome: { outcome: "cancelled" } }), onElicitation: async () => ({ action: "cancel" }) };
const agent = new AgentProcess("antigravity", { name: "Antigravity ACP", command, args: [], env: {}, enabled: true }, handlers, path.join(root, "logs"));
const timedOutAgent = new AgentProcess("antigravity", agent.config, handlers, path.join(root, "logs"), 1000);
try {
  for (let cycle = 1; cycle <= 2; cycle++) {
    const started = Date.now();
    await agent.ensureStarted();
    assert.equal(agent.status, "ready");
    const runs = fs.readdirSync(tempRoot);
    assert.equal(runs.length, 1);
    assert.ok(fs.readdirSync(path.join(tempRoot, runs[0])).some((name) => name.startsWith("_MEI")), "PyInstaller must extract inside the bridge-owned run");
    process.stdout.write("cycle " + cycle + ": initialized in " + (Date.now() - started) + " ms; extraction isolated\n");
    await agent.stop("smoke idle restart");
    assert.equal(agent.status, "stopped");
    assert.deepEqual(fs.readdirSync(tempRoot), []);
    process.stdout.write("cycle " + cycle + ": stopped; extraction removed\n");
  }
  await assert.rejects(timedOutAgent.ensureStarted(), /initialize timed out/);
  assert.equal(timedOutAgent.status, "error");
  assert.deepEqual(fs.readdirSync(tempRoot), []);
  process.stdout.write("initialization timeout: process terminated; extraction removed\n");
} catch {
  // Agent error details can contain upstream stderr; keep this smoke's output private.
  process.stderr.write("Antigravity ACP lifecycle smoke failed\n");
  process.exitCode = 1;
} finally {
  await agent.stop();
  await timedOutAgent.stop();
  if (path.dirname(root) !== path.resolve(os.tmpdir()) || !path.basename(root).startsWith("codeaw-agy-acp-smoke-")) throw new Error("Unsafe smoke cleanup");
  fs.rmSync(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 150 });
}
