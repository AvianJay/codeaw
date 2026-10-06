import path from "node:path";
import * as acp from "@agentclientprotocol/sdk";
import type { AgentConfig } from "../config.js";
import { AgentProcess, type AgentHandlers, type AgentInfo } from "./agent-process.js";
import type { AgentBackend } from "./backend.js";
import { CodexDesktopBackend } from "./codex-desktop.js";
import { AgyBackend } from "./agy.js";

export class AgentRegistry {
  private readonly agents = new Map<string, AgentBackend>();

  constructor(configs: Record<string, AgentConfig>, handlers: AgentHandlers, dataDir: string, startTimeoutMs?: number) {
    for (const [id, cfg] of Object.entries(configs)) {
      if (!cfg.enabled) continue;
      const desktop = cfg.desktopSync !== false && ((id === "codex" && process.platform === "win32") || cfg.desktopSync === true || typeof cfg.desktopSync === "object");
      const Backend = cfg.transport === "agy" ? AgyBackend : desktop ? CodexDesktopBackend : AgentProcess;
      this.agents.set(id, new Backend(id, cfg, handlers, path.join(dataDir, "logs"), startTimeoutMs));
    }
  }

  ids(): string[] {
    return [...this.agents.keys()];
  }

  all(): AgentBackend[] {
    return [...this.agents.values()];
  }

  has(id: string): boolean {
    return this.agents.has(id);
  }

  get(id: string): AgentBackend {
    const agent = this.agents.get(id);
    if (!agent) throw acp.RequestError.invalidParams(undefined, `Unknown or disabled agent "${id}"`);
    return agent;
  }

  describe(): AgentInfo[] {
    return this.all().map((a) => a.describe());
  }

  async stopAll(): Promise<void> {
    await Promise.all(this.all().map((a) => a.stop("bridge shutting down")));
  }
}
