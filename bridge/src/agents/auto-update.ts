import fs from "node:fs";
import path from "node:path";
import { loadConfig, type AgentConfig } from "../config.js";
import { prepareAgent, type InstalledAgent } from "./install.js";
import { configAgentId, distributionFor, fetchRegistry, type RegistryAgent } from "./registry.js";
import { AgentProcess } from "../backend/agent-process.js";
import type { AgentRegistry } from "../backend/registry.js";
import type { SessionManager } from "../session/manager.js";
import { isInside, readJson, writeFileAtomic } from "../util/paths.js";
import { logger } from "../util/log.js";

const log = logger("agent-updates");
const FIRST_TICK_MS = 2 * 60_000;
const TICK_MS = 10 * 60_000;
const RETRY_MS = 60 * 60_000;
const PRUNE_AGE_MS = 24 * 60 * 60_000;

export interface ManagedInstall { registryId: string; version: string; directory: string }

/** Only installations Codeaw made from the ACP registry are updated; a user's own adapter is left alone. */
export function managedInstall(home: string, command: string): ManagedInstall | undefined {
  const root = path.resolve(home, "agents");
  const resolved = path.resolve(command);
  if (!isInside(root, resolved)) return undefined;
  const [registryId, install] = path.relative(root, resolved).split(path.sep);
  if (!registryId || !install?.startsWith("install-")) return undefined;
  const directory = path.join(root, registryId, install);
  const marker = readJson<{ id?: unknown; version?: unknown }>(path.join(directory, "installed.json"), {});
  if (marker.id !== registryId || typeof marker.version !== "string") return undefined;
  return { registryId, version: marker.version, directory };
}

export interface UpdateCandidate { id: string; entry: RegistryAgent; from: string }

/** Disabled adapters are included so they are current when enabled; native transports never are. */
export function updateCandidates(home: string, agents: Record<string, AgentConfig>, catalog: RegistryAgent[]): UpdateCandidate[] {
  const found: UpdateCandidate[] = [];
  for (const [id, config] of Object.entries(agents)) {
    if (config.transport && config.transport !== "acp") continue;
    const installed = managedInstall(home, config.command);
    if (!installed || configAgentId(installed.registryId) !== id) continue;
    const entry = catalog.find((agent) => agent.id === installed.registryId);
    if (!entry || !distributionFor(entry) || entry.version === installed.version) continue;
    found.push({ id, entry, from: installed.version });
  }
  return found;
}

/** Start the new adapter once and complete the ACP handshake before any chat is moved to it. */
export async function probeAgent(id: string, config: AgentConfig, logDir: string): Promise<void> {
  fs.mkdirSync(logDir, { recursive: true });
  const probe = new AgentProcess(id, config, {
    onUpdate() {}, onExit() {},
    onPermission: async () => ({ outcome: { outcome: "cancelled" } }),
    onElicitation: async () => ({ action: "cancel" }),
  }, logDir, 60_000);
  try { await probe.ensureStarted(); }
  finally { await probe.stop("update check"); }
}

export interface AgentUpdateResult { version: string; message: string; at: string }
export interface AgentUpdateState { checkedDay?: string; attemptedAt?: number; results: Record<string, AgentUpdateResult> }
export interface AgentUpdateStatus extends AgentUpdateState { enabled: boolean; checking: boolean }

export interface AgentUpdaterHost {
  /** The bridge currently serving chats; replaced on restart. */
  live(): { registry: AgentRegistry; manager: SessionManager } | undefined;
  commit(installed: InstalledAgent): Promise<void>;
}

export interface AgentUpdaterDependencies {
  registry?: typeof fetchRegistry;
  prepare?: typeof prepareAgent;
  probe?: typeof probeAgent;
  now?: () => Date;
}

const localDay = (date: Date) => date.toLocaleDateString("sv-SE");

/**
 * Checks the ACP registry once per local day and installs newer adapters into
 * fresh directories. Each running agent moves to its new installation the
 * next time none of its chats has work, so new models appear without a bridge
 * restart and without interrupting a turn.
 */
export class AgentAutoUpdater {
  private timer?: NodeJS.Timeout;
  private running?: Promise<void>;
  private controller = new AbortController();
  private closed = false;
  private readonly stateFile: string;
  private readonly home: string;

  constructor(private readonly file: string, private readonly host: AgentUpdaterHost, private readonly deps: AgentUpdaterDependencies = {}) {
    this.home = path.dirname(file);
    this.stateFile = path.join(this.home, "agent-updates.json");
  }

  start(): void {
    if (this.closed || this.timer) return;
    this.schedule(FIRST_TICK_MS);
  }

  private schedule(delay: number): void {
    if (this.closed) return;
    this.timer = setTimeout(() => {
      this.timer = undefined;
      void this.run().finally(() => this.schedule(TICK_MS));
    }, delay);
    this.timer.unref?.();
  }

  private state(): AgentUpdateState {
    const state = readJson<AgentUpdateState>(this.stateFile, { results: {} });
    return { ...state, results: state.results ?? {} };
  }

  private enabled(): boolean {
    try { return loadConfig(this.file).config.autoUpdateAgents; } catch { return false; }
  }

  status(): AgentUpdateStatus {
    return { ...this.state(), enabled: this.enabled(), checking: this.running !== undefined };
  }

  /** `force` checks the registry now, even if today's check already ran or automatic updates are off. */
  run(force = false): Promise<void> {
    if (this.closed) return Promise.resolve();
    return this.running ??= (async () => {
      try {
        if (!force && !this.enabled()) return;
        const state = this.state();
        const now = this.deps.now?.() ?? new Date();
        if (force || (state.checkedDay !== localDay(now) && now.getTime() - (state.attemptedAt ?? 0) >= RETRY_MS)) {
          await this.check(state, now);
        }
        await this.apply();
      } catch (error) {
        log.warn(`agent update check failed: ${(error as Error).message}`);
      } finally { this.running = undefined; }
    })();
  }

  private save(state: AgentUpdateState): void { writeFileAtomic(this.stateFile, JSON.stringify(state, null, 2)); }

  private async check(state: AgentUpdateState, now: Date): Promise<void> {
    state.attemptedAt = now.getTime();
    this.save(state);
    const signal = this.controller.signal;
    const catalog = await (this.deps.registry ?? fetchRegistry)();
    const loaded = loadConfig(this.file);
    let failed = false;
    const candidates = updateCandidates(loaded.home, loaded.config.agents, catalog);
    for (const [id, config] of Object.entries(loaded.config.agents)) {
      const installed = !candidates.some((candidate) => candidate.id === id) && (!config.transport || config.transport === "acp")
        ? managedInstall(loaded.home, config.command) : undefined;
      if (installed && catalog.some((agent) => agent.id === installed.registryId)) {
        state.results[id] = { version: installed.version, message: "up to date", at: now.toISOString() };
      }
    }
    for (const candidate of candidates) {
      signal.throwIfAborted();
      const { id, entry } = candidate;
      const at = new Date().toISOString();
      try {
        log.info(`${id}: updating ACP adapter ${candidate.from} → ${entry.version}`);
        const installed = await (this.deps.prepare ?? prepareAgent)(loaded.home, entry, (message) => log.debug(`${id}: ${message}`), signal);
        try {
          const current = loadConfig(this.file).config.agents[id];
          await (this.deps.probe ?? probeAgent)(id, { ...current, command: installed.config.command, args: installed.config.args,
            env: { ...installed.config.env, ...current.env }, cwd: installed.config.cwd ?? current.cwd, enabled: true },
          path.join(this.home, "logs", "agent-updates"));
          signal.throwIfAborted();
          await this.host.commit(installed);
        } catch (error) {
          fs.rmSync(installed.directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
          throw error;
        }
        state.results[id] = { version: entry.version, message: "installed; applies when the agent is idle", at };
      } catch (error) {
        if (signal.aborted) throw error;
        failed = true;
        // The previous installation is untouched; the next hourly tick retries.
        state.results[id] = { version: candidate.from, message: `update to ${entry.version} failed: ${(error as Error).message}`, at };
        log.warn(`${id}: ${state.results[id].message}`);
      }
    }
    if (!failed) state.checkedDay = localDay(now);
    this.save(state);
  }

  /** Move idle running agents to an installation already written to the config. */
  private async apply(): Promise<void> {
    const live = this.host.live();
    if (!live) return;
    const loaded = loadConfig(this.file);
    for (const backend of live.registry.all()) {
      const next = loaded.config.agents[backend.id];
      if (!next || !backend.retarget || backend.config.command === next.command) continue;
      if (next.transport && next.transport !== "acp") continue;
      const installed = managedInstall(loaded.home, next.command);
      if (!installed) continue;
      if (!live.manager.agentIdle(backend.id)) { log.info(`${backend.id}: ACP adapter ${installed.version} waits until its chats are idle`); continue; }
      const previous = managedInstall(loaded.home, backend.config.command)?.directory;
      if (!await backend.retarget(next)) continue;
      log.info(`${backend.id}: now using ACP adapter ${installed.version}`);
      await live.manager.reopenViewed(backend.id);
      this.prune(installed, previous);
    }
  }

  /** Keep the current and previous installations; remove older finished ones nothing refers to. */
  private prune(current: ManagedInstall, previous: string | undefined): void {
    const root = path.join(this.home, "agents", current.registryId);
    let referenced: string[];
    try {
      referenced = Object.values(loadConfig(this.file).config.agents).flatMap((agent) => [agent.command, agent.cwd ?? ""])
        .filter(Boolean).map((value) => path.resolve(value));
    } catch { return; }
    for (const name of fs.readdirSync(root)) {
      const directory = path.join(root, name);
      if (!name.startsWith("install-") || directory === current.directory || directory === previous) continue;
      if (referenced.some((value) => isInside(directory, value))) continue;
      try {
        // Unfinished installs have no marker yet; recent ones may belong to a running installer.
        if (!fs.existsSync(path.join(directory, "installed.json")) || Date.now() - fs.statSync(directory).mtimeMs < PRUNE_AGE_MS) continue;
        fs.rmSync(directory, { recursive: true, force: true, maxRetries: 3, retryDelay: 200 });
      } catch { /* A file still in use is removed after a later update. */ }
    }
  }

  async stop(): Promise<void> {
    this.closed = true;
    if (this.timer) clearTimeout(this.timer);
    this.timer = undefined;
    this.controller.abort();
    await this.running;
  }
}
