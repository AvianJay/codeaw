import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { AgentProcess, type AgentHandlers } from "../src/backend/agent-process.js";
import { AgentRegistry } from "../src/backend/registry.js";
import { SessionManager } from "../src/session/manager.js";
import { SessionStore } from "../src/session/store.js";
import { ConfigSchema } from "../src/config.js";
import { setLogSilent } from "../src/util/log.js";

setLogSilent(true);
const fixture = fileURLToPath(new URL("./fixtures/acp-lifecycle.mjs", import.meta.url));
const roots: string[] = [];
const agents: AgentProcess[] = [];
const handlers: AgentHandlers = { onUpdate: () => {}, onExit: () => {},
  onPermission: async () => ({ outcome: { outcome: "cancelled" } }), onElicitation: async () => ({ action: "cancel" }) };
function setup(env: Record<string, string> = {}, timeoutMs = 3000) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-lifecycle-")); roots.push(root);
  const config = ConfigSchema.parse({ agents: { fixture: { name: "Fixture", command: process.execPath, args: [fixture], env: { ACP_FIXTURE_ROOT: root, ...env } } } }).agents.fixture;
  const agent = new AgentProcess("fixture", config, handlers, path.join(root, "logs"), timeoutMs); agents.push(agent);
  return { agent, root, config };
}
const launches = (root: string): Array<{ pid: number }> => fs.readFileSync(path.join(root, "launches.jsonl"), "utf8").trim().split("\n").map((line) => JSON.parse(line));
async function waitFor(predicate: () => boolean) {
  const deadline = Date.now() + 5000;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("waitFor timed out");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}
afterEach(async () => {
  await Promise.all(agents.splice(0).map((agent) => agent.stop()));
  for (const root of roots.splice(0)) {
    if (path.dirname(root) !== path.resolve(os.tmpdir()) || !path.basename(root).startsWith("codeaw-lifecycle-")) throw new Error("Unsafe test cleanup");
    fs.rmSync(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  }
});

describe("ACP process lifecycle", () => {
  it("does not stop a reconnect that is still initializing during the idle sweep", async () => {
    const { root, config } = setup({ ACP_FIXTURE_INIT_DELAY: "300" });
    const registry = new AgentRegistry({ fixture: config }, handlers, root, 3000);
    const agent = registry.get("fixture") as AgentProcess; agents.push(agent);
    const manager = new SessionManager(registry, new SessionStore(root), { idleSessionCloseMs: 60_000, idleAgentStopMs: 60_000, hostName: "fixture" });
    agent.lastUsed = 0;
    const started = agent.ensureStarted();
    expect(agent.lastUsed).toBeGreaterThan(0);
    await waitFor(() => fs.existsSync(path.join(root, "launches.jsonl")));
    // Simulate a sweep with a stale idle timestamp while initialize is pending.
    agent.lastUsed = 0;
    await manager.sweep();
    await started;
    expect(agent.status).toBe("ready");
    expect(launches(root)).toHaveLength(1);
    await manager.sweep();
    expect(agent.status).toBe("ready");
    agent.lastUsed = 0;
    await manager.sweep();
    expect(agent.status).toBe("stopped");
    await agent.ensureStarted();
    expect(agent.status).toBe("ready");
    expect(launches(root)).toHaveLength(2);
    await manager.shutdown();
  });

  it("lets the old process finish cleanup after stdout EOF before restarting", async () => {
    const { agent, root } = setup();
    await agent.ensureStarted();
    const oldPid = launches(root)[0].pid;
    await agent.request("_fixture/close", {});
    await waitFor(() => agent.status === "error");
    await agent.ensureStarted();
    expect(fs.existsSync(path.join(root, "cleaned-" + oldPid))).toBe(true);
    expect(launches(root)).toHaveLength(2);
    expect(agent.status).toBe("ready");
  });

  it("serializes a restart with an explicit stop", async () => {
    const { agent, root } = setup();
    await agent.ensureStarted();
    const oldPid = launches(root)[0].pid;
    await Promise.all([agent.stop("idle"), agent.ensureStarted()]);
    expect(fs.existsSync(path.join(root, "cleaned-" + oldPid))).toBe(true);
    expect(agent.status).toBe("ready");
    expect(launches(root)).toHaveLength(2);
  });

  it("waits for process cleanup on initialization timeout and can retry", async () => {
    const { agent, root, config } = setup({ ACP_FIXTURE_NO_INIT: "1" }, 3000);
    await expect(agent.ensureStarted()).rejects.toThrow(/initialize timed out/);
    const oldPid = launches(root)[0].pid;
    expect(fs.existsSync(path.join(root, "cleaned-" + oldPid))).toBe(true);
    expect(agent.status).toBe("error");
    delete config.env.ACP_FIXTURE_NO_INIT;
    await agent.ensureStarted();
    expect(agent.status).toBe("ready");
  });

  it("does not become ready after being stopped during initialization", async () => {
    const { agent, root } = setup({ ACP_FIXTURE_INIT_DELAY: "600" });
    const started = agent.ensureStarted();
    const rejected = expect(started).rejects.toThrow();
    await waitFor(() => fs.existsSync(path.join(root, "launches.jsonl")));
    await agent.stop();
    await rejected;
    expect(agent.status).toBe("stopped");
  });

  it("kills a process that ignores stdin EOF before allowing another launch", async () => {
    const { agent, root, config } = setup({ ACP_FIXTURE_NO_EXIT: "1" });
    await agent.ensureStarted();
    const oldPid = launches(root)[0].pid;
    await agent.stop("idle");
    expect(() => process.kill(oldPid, 0)).toThrow();
    delete config.env.ACP_FIXTURE_NO_EXIT;
    await agent.ensureStarted();
    expect(agent.status).toBe("ready");
    expect(launches(root)).toHaveLength(2);
  });
});
