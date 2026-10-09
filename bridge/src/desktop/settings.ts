import fs from "node:fs";
import YAML from "yaml";
import { z } from "zod";
import { ConfigSchema, loadConfig, type LoadedConfig } from "../config.js";
import { writeFileAtomic } from "../util/paths.js";
import { gatewayRegistration } from "../remote-desktop/gateway-config.js";

const SettingsSchema = z.object({
  port: z.number().int().min(0).max(65535),
  workspaces: z.array(z.string().trim().min(1)).max(100),
  allowAllPaths: z.boolean().optional(),
  remoteDesktopEnabled: z.boolean().optional(),
  idleSessionCloseMinutes: z.number().int().min(1).max(10080),
  idleAgentStopMinutes: z.number().int().min(1).max(10080),
  agents: z.record(z.string(), z.boolean()),
}).strict();

/** Return only editable, non-secret fields. Agent env and notification tokens stay in the config. */
export function desktopSettings(loaded: LoadedConfig) {
  return { file: loaded.file, port: loaded.config.listen.port, workspaces: loaded.config.workspaces,
    allowAllPaths: loaded.config.filesystem.allowAllPaths,
    remoteDesktopEnabled: gatewayRegistration(loaded.file)?.enabled ?? loaded.config.remoteDesktop.enabled,
    advancedDesktopInstalled: !!gatewayRegistration(loaded.file),
    idleSessionCloseMinutes: loaded.config.idleSessionCloseMinutes,
    idleAgentStopMinutes: loaded.config.idleAgentStopMinutes,
    agents: Object.entries(loaded.config.agents).map(([id, agent]) => ({ id, name: agent.name, enabled: agent.enabled })) };
}

/** Preserve YAML comments and advanced fields rather than replacing the config with the UI model. */
export function saveDesktopSettings(file: string, input: unknown): { loaded: LoadedConfig; restore(): void } {
  const parsed = SettingsSchema.safeParse(input);
  if (!parsed.success) throw new Error("Invalid settings: check port, folders and idle timeouts");
  const settings = parsed.data;
  const original = fs.readFileSync(file, "utf8");
  const doc = YAML.parseDocument(original);
  if (doc.errors.length) throw new Error("Config contains invalid YAML");
  const current = loadConfig(file);
  if (gatewayRegistration(file) && settings.port !== current.config.listen.port) throw new Error("請先解除進階桌面服務再變更連接埠");
  for (const id of Object.keys(settings.agents)) {
    if (!current.config.agents[id]) throw new Error("Unknown agent in settings");
  }
  doc.setIn(["listen", "port"], settings.port);
  doc.set("workspaces", [...new Set(settings.workspaces)]);
  if (settings.allowAllPaths !== undefined) doc.setIn(["filesystem", "allowAllPaths"], settings.allowAllPaths);
  if (settings.remoteDesktopEnabled !== undefined) doc.setIn(["remoteDesktop", "enabled"], settings.remoteDesktopEnabled);
  doc.set("idleSessionCloseMinutes", settings.idleSessionCloseMinutes);
  doc.set("idleAgentStopMinutes", settings.idleAgentStopMinutes);
  for (const [id, enabled] of Object.entries(settings.agents)) doc.setIn(["agents", id, "enabled"], enabled);
  if (!ConfigSchema.safeParse(doc.toJSON()).success) throw new Error("Settings would create an invalid config");
  writeFileAtomic(file, doc.toString());
  return { loaded: loadConfig(file), restore: () => writeFileAtomic(file, original) };
}
