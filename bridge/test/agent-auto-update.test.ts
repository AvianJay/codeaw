import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import YAML from "yaml";
import { afterEach, describe, expect, it, vi } from "vitest";
import { AgentAutoUpdater, managedInstall, probeAgent, updateCandidates } from "../src/agents/auto-update.js";
import { registerInstalledAgent, type InstalledAgent } from "../src/agents/install.js";
import { parseRegistry, type RegistryAgent } from "../src/agents/registry.js";
import { AgentProcess } from "../src/backend/agent-process.js";
import { ConfigSchema, loadConfig, type AgentConfig } from "../src/config.js";
import { setLogSilent } from "../src/util/log.js";

setLogSilent(true);
const fixture = fileURLToPath(new URL("./fixtures/acp-lifecycle.mjs", import.meta.url));
const roots: string[] = [];
const agents: AgentProcess[] = [];

function home() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-autoupdate-")); roots.push(root);
  return root;
}
/** A finished Codeaw installation, as prepareAgent leaves it. */
function install(root: string, registryId: string, version: string, name = "install-" + version.replace(/\./g, "")) {
  const directory = path.join(root, "agents", registryId, name);
  fs.mkdirSync(directory, { recursive: true });
  fs.writeFileSync(path.join(directory, "installed.json"), JSON.stringify({ id: registryId, version }));
  fs.writeFileSync(path.join(directory, "agent.exe"), "");
  return directory;
}
function catalog(entries: Record<string, string>): RegistryAgent[] {
  return parseRegistry({ agents: Object.entries(entries).map(([id, version]) =>
    ({ id, name: id, version, distribution: { npx: { package: `${id}@${version}` } } })) });
}
function writeConfig(root: string, agents: Record<string, unknown>, extra: Record<string, unknown> = {}) {
  const file = path.join(root, "config.yaml");
  fs.writeFileSync(file, YAML.stringify({ agents, ...extra }));
  return file;
}
const day = (iso: string) => () => new Date(iso);

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all(agents.splice(0).map((agent) => agent.stop()));
  for (const root of roots.splice(0)) {
    if (path.dirname(root) !== path.resolve(os.tmpdir()) || !path.basename(root).startsWith("codeaw-autoupdate-")) throw new Error("Unsafe test cleanup");
    fs.rmSync(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  }
});

describe("ACP adapter auto-update selection", () => {
  it("updates only Codeaw installations, including disabled ones, and never native transports or user adapters", () => {
    const root = home();
    const claude = install(root, "claude-acp", "1.0.0");
    const amp = install(root, "amp-acp", "2.0.0");
    const current = install(root, "opencode", "3.0.0");
    const { agents } = ConfigSchema.parse({ agents: {
      claude: { name: "Claude", command: path.join(claude, "agent.exe") },
      "amp-acp": { name: "Amp", command: path.join(amp, "agent.exe"), enabled: false },
      opencode: { name: "OpenCode", command: path.join(current, "agent.exe"), args: ["acp"] },
      antigravity: { name: "AGY", command: path.join(claude, "agent.exe"), transport: "agy" },
      codex: { name: "My own Codex", command: "codex-acp" },
      renamed: { name: "Moved key", command: path.join(claude, "agent.exe") },
    } });
    const found = updateCandidates(root, agents, catalog({ "claude-acp": "1.1.0", "amp-acp": "2.1.0", opencode: "3.0.0", "codex-acp": "9.0.0", "antigravity-acp": "9.0.0" }));
    expect(found.map(({ id, from, entry }) => [id, from, entry.version])).toEqual([["claude", "1.0.0", "1.1.0"], ["amp-acp", "2.0.0", "2.1.0"]]);
    expect(managedInstall(root, path.join(root, "agents", "claude-acp", "agent.exe"))).toBeUndefined();
    expect(managedInstall(root, path.join(os.tmpdir(), "agent.exe"))).toBeUndefined();
  });

  it("moves a cwd that belonged to the old installation and keeps a custom cwd", () => {
    const root = home();
    const old = install(root, "claude-acp", "1.0.0");
    const next = install(root, "claude-acp", "1.1.0");
    const file = writeConfig(root, {
      claude: { name: "Claude", command: path.join(old, "agent.exe"), cwd: old },
      other: { name: "Other", command: path.join(old, "agent.exe"), cwd: root },
    });
    const entry = (id: string): InstalledAgent => ({ id, name: id, version: "1.1.0", directory: next,
      config: { name: id, command: path.join(next, "agent.exe"), args: [], env: {}, enabled: true, cwd: next } });
    registerInstalledAgent(file, entry("claude"));
    registerInstalledAgent(file, entry("other"));
    const agents = loadConfig(file).config.agents;
    expect(agents.claude.cwd).toBe(next);
    expect(agents.other.cwd).toBe(root);
  });
});

describe("daily ACP adapter updates", () => {
  function updater(root: string, file: string, registry: () => Promise<RegistryAgent[]>, live?: () => any) {
    const prepare = vi.fn(async (_home: string, entry: RegistryAgent): Promise<InstalledAgent> => {
      const directory = install(root, entry.id, entry.version, "install-new" + entry.version.replace(/\./g, ""));
      return { id: entry.id === "claude-acp" ? "claude" : entry.id, name: entry.name, version: entry.version, directory,
        config: { name: entry.name, command: path.join(directory, "agent.exe"), args: [], env: { DEFAULT: "1" }, enabled: true } };
    });
    const probe = vi.fn(async () => undefined);
    const commit = vi.fn(async (agent: InstalledAgent) => registerInstalledAgent(file, agent));
    return { prepare, probe, commit, now: day("2026-11-12T10:00:00"),
      create(now = day("2026-11-12T10:00:00")) {
        return new AgentAutoUpdater(file, { live: live ?? (() => undefined), commit }, { registry, prepare, probe, now });
      } };
  }

  it("installs a newer adapter once per day, keeping credentials, and retries a failure after an hour", async () => {
    const root = home();
    const old = install(root, "claude-acp", "1.0.0");
    const file = writeConfig(root, { claude: { name: "Claude", command: path.join(old, "agent.exe"), env: { ANTHROPIC_API_KEY: "kept" } } });
    let versions: Record<string, string> = { "claude-acp": "1.1.0" };
    const registry = vi.fn(async () => catalog(versions));
    const setup = updater(root, file, registry);
    await setup.create().run();
    let agent = loadConfig(file).config.agents.claude;
    expect(agent.command).toBe(path.join(root, "agents", "claude-acp", "install-new110", "agent.exe"));
    expect(agent.env).toEqual({ ANTHROPIC_API_KEY: "kept", DEFAULT: "1" });
    expect(setup.probe).toHaveBeenCalledOnce();
    expect((setup.probe.mock.calls[0] as any[])[1].env.ANTHROPIC_API_KEY).toBe("kept");
    const state = setup.create().status();
    expect(state).toMatchObject({ checkedDay: "2026-11-12", checking: false, enabled: true, results: { claude: { version: "1.1.0" } } });

    // Same day: no second registry request, even from a new runtime.
    await setup.create().run();
    expect(registry).toHaveBeenCalledOnce();

    // Next day: a failed probe keeps the working installation and removes the staged one.
    versions = { "claude-acp": "1.2.0" };
    setup.probe.mockRejectedValueOnce(new Error("initialize failed"));
    await setup.create(day("2026-11-13T10:00:00")).run();
    agent = loadConfig(file).config.agents.claude;
    expect(agent.command).toContain("install-new110");
    expect(fs.existsSync(path.join(root, "agents", "claude-acp", "install-new120"))).toBe(false);
    expect(setup.create().status().checkedDay).toBe("2026-11-12");
    expect(setup.create().status().results.claude.message).toMatch(/1\.2\.0 failed: initialize failed/);

    await setup.create(day("2026-11-13T10:30:00")).run();
    expect(registry).toHaveBeenCalledTimes(2);
    await setup.create(day("2026-11-13T11:05:00")).run();
    expect(registry).toHaveBeenCalledTimes(3);
    expect(loadConfig(file).config.agents.claude.command).toContain("install-new120");
  });

  it("respects autoUpdateAgents: false unless an update is requested explicitly", async () => {
    const root = home();
    const old = install(root, "claude-acp", "1.0.0");
    const file = writeConfig(root, { claude: { name: "Claude", command: path.join(old, "agent.exe") } }, { autoUpdateAgents: false });
    const registry = vi.fn(async () => catalog({ "claude-acp": "1.1.0" }));
    const setup = updater(root, file, registry);
    await setup.create().run();
    expect(registry).not.toHaveBeenCalled();
    await setup.create().run(true);
    expect(loadConfig(file).config.agents.claude.command).toContain("install-new110");
  });

  it("moves a running agent to the new installation only once its chats are idle", async () => {
    const root = home();
    const old = install(root, "claude-acp", "1.0.0");
    const stale = install(root, "claude-acp", "0.9.0");
    const past = new Date(Date.now() - 2 * 24 * 60 * 60_000);
    fs.utimesSync(stale, past, past);
    const file = writeConfig(root, { claude: { name: "Claude", command: path.join(old, "agent.exe") } });
    const backend = { id: "claude", config: loadConfig(file).config.agents.claude as AgentConfig,
      retarget: vi.fn(async (config: AgentConfig) => { backend.config = config; return true; }) };
    let idle = false;
    const manager = { agentIdle: vi.fn(() => idle), reopenViewed: vi.fn(async () => undefined) };
    const setup = updater(root, file, async () => catalog({ "claude-acp": "1.1.0" }), () => ({ registry: { all: () => [backend] }, manager }));
    const runner = setup.create();
    await runner.run();
    expect(backend.retarget).not.toHaveBeenCalled();
    idle = true;
    await runner.run();
    expect(backend.retarget).toHaveBeenCalledOnce();
    expect(backend.config.command).toContain("install-new110");
    expect(manager.reopenViewed).toHaveBeenCalledWith("claude");
    // The previous installation is kept for processes still exiting; older finished ones go.
    expect(fs.existsSync(old)).toBe(true);
    expect(fs.existsSync(stale)).toBe(false);
    await runner.run();
    expect(backend.retarget).toHaveBeenCalledOnce();
  });
});

describe("ACP process retargeting", () => {
  const handlers = { onUpdate: () => {}, onExit: () => {},
    onPermission: async () => ({ outcome: { outcome: "cancelled" as const } }), onElicitation: async () => ({ action: "cancel" as const }) };
  const fixtureConfig = (root: string) => ConfigSchema.parse({ agents: { fixture: { name: "Fixture", command: process.execPath, args: [fixture], env: { ACP_FIXTURE_ROOT: root } } } }).agents.fixture;

  it("stops the idle process and launches the new installation next time", async () => {
    const first = home();
    const second = home();
    const agent = new AgentProcess("fixture", fixtureConfig(first), handlers, path.join(first, "logs"), 5000); agents.push(agent);
    await agent.ensureStarted();
    const generation = agent.generation;
    expect(await agent.retarget(fixtureConfig(second))).toBe(true);
    expect(agent.running).toBe(false);
    await agent.ensureStarted();
    expect(agent.generation).toBeGreaterThan(generation);
    expect(fs.existsSync(path.join(second, "launches.jsonl"))).toBe(true);
  });

  it("probes a new adapter with a real ACP handshake", async () => {
    const root = home();
    await expect(probeAgent("fixture", fixtureConfig(root), path.join(root, "logs"))).resolves.toBeUndefined();
    const broken = { ...fixtureConfig(root), command: path.join(root, "missing.exe") };
    await expect(probeAgent("fixture", broken, path.join(root, "logs"))).rejects.toThrow();
  });
});
