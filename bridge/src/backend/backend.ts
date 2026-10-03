import type * as acp from "@agentclientprotocol/sdk";
import type { AgentConfig } from "../config.js";
import type { AgentInfo } from "./agent-process.js";

/** A session transport; an ACP subprocess and a desktop follower share this contract. */
export interface AgentBackend {
  readonly id: string;
  readonly config: AgentConfig;
  readonly generation: number;
  readonly running: boolean;
  readonly capabilities: acp.AgentCapabilities | undefined;
  readonly supportsSteering: boolean;
  readonly inflight: number;
  readonly lastUsed: number;
  describe(): AgentInfo;
  ensureStarted(): Promise<void>;
  request<T = unknown>(method: string, params: unknown, options?: acp.SendRequestOptions): Promise<T>;
  notify(method: string, params: unknown): Promise<void>;
  stop(reason?: string): Promise<void>;
  sessionConnection?(sessionId: string): "desktop" | "acp";
  sessionConnected?(sessionId: string): boolean;
}
