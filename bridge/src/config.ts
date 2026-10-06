import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import YAML from "yaml";
import { z } from "zod";
import { codeawHome, expandHome } from "./util/paths.js";
import { resolveCommand } from "./util/environment.js";

const AgentConfigSchema = z.object({
  name: z.string(),
  command: z.string(),
  args: z.array(z.string()).default([]),
  env: z.record(z.string(), z.string()).default({}),
  /** Working directory of the agent process itself (sessions carry their own cwd). */
  cwd: z.string().optional(),
  enabled: z.boolean().default(true),
  /** Windows Codex: attach to a desktop owner before resuming through ACP. */
  desktopSync: z.union([z.boolean(), z.object({
    pipe: z.string().optional(),
    archivePath: z.string().optional(),
    modelCatalogPath: z.string().optional(),
    timeoutMs: z.number().int().min(100).max(60000).optional(),
  })]).optional(),
});
export type AgentConfig = z.infer<typeof AgentConfigSchema>;

const NtfySchema = z.object({
  server: z.string().default("https://ntfy.sh"),
  topic: z.string().min(1),
  token: z.string().optional(),
  /** Include session titles / tool names in pushes. Off by default: ntfy.sh is a public relay. */
  includeDetails: z.boolean().default(false),
  /** Wait this long (and confirm nobody connected) before pushing. */
  delaySeconds: z.number().min(0).default(20),
  onPermission: z.boolean().default(true),
  onTurnEnd: z.boolean().default(true),
  onError: z.boolean().default(true),
});
export type NtfyConfig = z.infer<typeof NtfySchema>;

const LiveActivitySchema = z.object({
  teamId: z.string().regex(/^[A-Z0-9]{10}$/),
  keyId: z.string().regex(/^[A-Z0-9]{10}$/),
  privateKeyPath: z.string().min(1),
  bundleId: z.string().regex(/^[A-Za-z0-9.-]+$/).default("tw.avianjay.codeaw"),
  environment: z.enum(["production", "sandbox"]).default("production"),
  /** Allow project names / command and summary excerpts to pass through Apple APNs. */
  includeDetails: z.boolean().default(false),
});
export type LiveActivityConfig = z.infer<typeof LiveActivitySchema>;

export const ConfigSchema = z.object({
  listen: z
    .object({
      /** `auto` = this machine's Tailscale IPv4 (if any) + 127.0.0.1. Or a list of addresses. */
      hosts: z.union([z.literal("auto"), z.array(z.string())]).default("auto"),
      port: z.number().int().min(0).max(65535).default(7860),
    })
    .default({ hosts: "auto", port: 7860 }),
  /** Directories the app may browse; session cwds are always allowed as well. */
  workspaces: z.array(z.string()).default([]),
  /** Opt in on the PC: paired devices can access any path this account can access. */
  filesystem: z.object({ allowAllPaths: z.boolean().default(false) }).default({ allowAllPaths: false }),
  agents: z.record(z.string().regex(/^[a-z0-9][a-z0-9_-]*$/), AgentConfigSchema),
  notifications: z.object({ ntfy: NtfySchema.optional(), liveActivity: LiveActivitySchema.optional() }).default({}),
  /** Release an idle agent-side session (frees e.g. claude.exe) after this many minutes. */
  idleSessionCloseMinutes: z.number().min(1).default(30),
  /** Stop an agent process with no live sessions after this many minutes. */
  idleAgentStopMinutes: z.number().min(1).default(60),
  dataDir: z.string().optional(),
});
export type Config = z.infer<typeof ConfigSchema>;

export interface LoadedConfig {
  config: Config;
  file: string;
  home: string;
  dataDir: string;
}

export function defaultConfigFile(): string {
  return path.join(codeawHome(), "config.yaml");
}

export function loadConfig(file = defaultConfigFile()): LoadedConfig {
  const raw = YAML.parse(fs.readFileSync(file, "utf8")) ?? {};
  const parsed = ConfigSchema.safeParse(raw);
  if (!parsed.success) {
    const issues = parsed.error.issues.map((i) => `  ${i.path.join(".") || "(root)"}: ${i.message}`).join("\n");
    throw new Error(`Invalid config ${file}:\n${issues}`);
  }
  const config = parsed.data;
  const home = path.dirname(file);
  const dataDir = path.resolve(home, expandHome(config.dataDir ?? "data"));
  return { config, file, home, dataDir };
}

/** Known ACP agents and how to launch them. Only the installed ones end up in a fresh config. */
export const KNOWN_AGENTS: Array<{ id: string; probe: string; agent: AgentConfig }> = [
  { id: "claude", probe: "claude-agent-acp", agent: { name: "Claude Code", command: "claude-agent-acp", args: [], env: {}, enabled: true } },
  { id: "codex", probe: "codex-acp", agent: { name: "Codex", command: "codex-acp", args: [], env: {}, enabled: true } },
  { id: "kimi", probe: "kimi", agent: { name: "Kimi Code", command: "kimi", args: ["acp"], env: {}, enabled: true } },
  { id: "hermes", probe: "hermes", agent: { name: "Hermes Agent", command: "hermes", args: ["acp"], env: {}, enabled: true } },
  { id: "gemini", probe: "gemini", agent: { name: "Gemini CLI", command: "gemini", args: ["--experimental-acp"], env: {}, enabled: true } },
  { id: "deepseek", probe: "dsh", agent: { name: "DeepSeek Harness", command: "dsh", args: ["--profile", "acp"], env: {}, enabled: true } },
  {
    id: "antigravity",
    probe: process.platform === "win32" ? "agy_acp_server.exe" : "agy_acp_server.par",
    agent: {
      name: "Google Antigravity",
      command: process.platform === "win32" ? "agy_acp_server.exe" : "agy_acp_server.par",
      args: process.platform === "linux" ? ["--uid="] : [],
      env: {},
      enabled: true,
    },
  },
];

export function detectAgents(): Record<string, AgentConfig> {
  const found: Record<string, AgentConfig> = {};
  for (const entry of KNOWN_AGENTS) {
    const command = resolveCommand(entry.probe);
    if (command) found[entry.id] = { ...entry.agent, command };
  }
  return found;
}

/** Writes a commented starter config. Returns false when one already exists. */
export function writeDefaultConfig(file = defaultConfigFile()): boolean {
  if (fs.existsSync(file)) return false;
  const agents = detectAgents();
  const topic = "codeaw-" + crypto.randomBytes(12).toString("hex");
  const doc = {
    listen: { hosts: "auto", port: 7860 },
    workspaces: [] as string[],
    agents,
    notifications: { ntfy: { server: "https://ntfy.sh", topic, includeDetails: false, delaySeconds: 20 } },
    idleSessionCloseMinutes: 30,
    idleAgentStopMinutes: 60,
  };
  const header = [
    "# codeaw-bridge config",
    "# listen.hosts: 'auto' binds this PC's Tailscale IP + 127.0.0.1. Never use 0.0.0.0 unless you know why.",
    "# workspaces: folders the phone may browse and start sessions in (session folders are always allowed).",
    "# agents.<id>.env: extra environment for that agent, e.g. ANTHROPIC_BASE_URL. By default each agent",
    "#   inherits your normal setup (~/.claude/settings.json, ~/.codex/config.toml, ...).",
    "# notifications.ntfy: install the ntfy app and subscribe to the topic below to get pushes when no",
    "#   device is connected. Delete this block to disable pushes.",
    "",
  ].join("\n");
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, header + YAML.stringify(doc));
  return true;
}
