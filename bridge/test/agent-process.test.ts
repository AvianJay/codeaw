import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { AgentProcess, type AgentHandlers } from "../src/backend/agent-process.js";
import { codexInstructionsEnvironment } from "../src/backend/codex-defaults.js";
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
const launches = (root: string): Array<{ pid: number; codexConfig?: string }> => fs.readFileSync(path.join(root, "launches.jsonl"), "utf8").trim().split("\n").map((line) => JSON.parse(line));
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

describe("Codex instructions", () => {
  const told = "You are running through codeaw.";
  function codexHome(config?: string): { root: string; home: string } {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-lifecycle-")); roots.push(root);
    const home = path.join(root, "codex-home");
    fs.mkdirSync(home);
    if (config !== undefined) fs.writeFileSync(path.join(home, "config.toml"), config);
    return { root, home };
  }
  const backend = (home: string) => ({ id: "codex", config: { command: "codex-acp", env: { CODEX_HOME: home } } }) as any;
  const overrides = (env: NodeJS.ProcessEnv) => JSON.parse(env.CODEX_CONFIG!);

  it("launches Codex with the bridge's instructions after the user's own", async () => {
    const { root, home } = codexHome('model = "gpt-test"\ndeveloper_instructions = """\nReply in Traditional Chinese.\n"""\n\n[features]\nx = true\n');
    const config = ConfigSchema.parse({ agents: { codex: { name: "Codex", command: process.execPath, args: [fixture],
      env: { ACP_FIXTURE_ROOT: root, CODEX_HOME: home, CODEX_CONFIG: JSON.stringify({ model_provider: "proxy" }) } } } }).agents.codex;
    const asked: string[] = [];
    const agent = new AgentProcess("codex", config, { ...handlers, agentInstructions: (id) => { asked.push(id); return told; } }, path.join(root, "logs"), 3000);
    agents.push(agent);
    await agent.ensureStarted();
    expect(asked).toEqual(["codex"]);
    expect(JSON.parse(launches(root)[0].codexConfig!)).toEqual({ model_provider: "proxy", developer_instructions: `Reply in Traditional Chinese.\n\n${told}` });
    // The user's file is only read.
    expect(fs.readFileSync(path.join(home, "config.toml"), "utf8")).toContain('model = "gpt-test"');
  });

  it("leaves other agents, and Codex without the bridge's tools, as they are", async () => {
    const { agent, root } = setup();
    (agent as any).handlers = { ...handlers, agentInstructions: () => told };
    await agent.ensureStarted();
    expect(launches(root)[0].codexConfig).toBeUndefined();

    const { root: other, home } = codexHome();
    const config = ConfigSchema.parse({ agents: { codex: { name: "Codex", command: process.execPath, args: [fixture], env: { ACP_FIXTURE_ROOT: other, CODEX_HOME: home } } } }).agents.codex;
    const codex = new AgentProcess("codex", config, { ...handlers, agentInstructions: () => undefined }, path.join(other, "logs"), 3000);
    agents.push(codex);
    await codex.ensureStarted();
    expect(launches(other)[0].codexConfig).toBeUndefined();
  });

  it("adds to the settings it can read and changes nothing otherwise", () => {
    // No config file, or one without developer instructions.
    expect(overrides(codexInstructionsEnvironment(backend(codexHome().home), { PATH: "x" }, told))).toEqual({ developer_instructions: told });
    expect(overrides(codexInstructionsEnvironment(backend(codexHome('model = "m"\n').home), {}, told))).toEqual({ developer_instructions: told });
    // An override the user already launches Codex with wins over their file.
    const both = codexHome('developer_instructions = "from the file"\n').home;
    expect(overrides(codexInstructionsEnvironment(backend(both), { CODEX_CONFIG: '{"developer_instructions":" from the launch ","model":"m"}' }, told)))
      .toEqual({ model: "m", developer_instructions: `from the launch\n\n${told}` });
    expect(overrides(codexInstructionsEnvironment(backend(both), { CODEX_CONFIG: '{"developer_instructions":""}' }, told))).toEqual({ developer_instructions: told });

    // Replacing instructions that cannot be read would drop them.
    for (const [config, env] of [
      ['developer_instructions = "unterminated\n', {}],
      ["developer_instructions = 5\n", {}],
      ['model = "m"\n', { CODEX_CONFIG: "{not json" }],
      ['model = "m"\n', { CODEX_CONFIG: "[]" }],
      ['model = "m"\n', { CODEX_CONFIG: '{"developer_instructions":null}' }],
    ] as [string, NodeJS.ProcessEnv][]) {
      expect(codexInstructionsEnvironment(backend(codexHome(config).home), env, told)).toBe(env);
    }
    // One environment variable has a size limit on Windows.
    const large = {};
    expect(codexInstructionsEnvironment(backend(codexHome().home), large, "x".repeat(40_000))).toBe(large);
  });
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
