import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import * as acp from "@agentclientprotocol/sdk";

interface Model { id: string; name: string; efforts: string[] }

/** Catalog metadata only; never read Codex credentials or start another thread. */
export function desktopModels(catalogPath?: string): Model[] {
  const home = process.env.CODEX_HOME ?? path.join(os.homedir(), ".codex");
  for (const file of catalogPath ? [catalogPath] : [path.join(home, "model_catalog.json"), path.join(home, "models_cache.json")]) {
    try {
      if (fs.statSync(file).size > 4 * 1024 * 1024) continue;
      const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
      const models = (Array.isArray(parsed.models) ? parsed.models : []).flatMap((model: any) => {
        const id = model.slug ?? model.id ?? model.model;
        if (typeof id !== "string" || (typeof model.visibility === "string" && model.visibility !== "list")) return [];
        const levels = model.supported_reasoning_levels ?? model.supportedReasoningEfforts ?? [];
        return [{ id, name: model.display_name ?? model.displayName ?? id,
          efforts: levels.map((level: any) => level.effort ?? level.reasoningEffort).filter((level: unknown) => typeof level === "string") }];
      });
      if (models.length) return models;
    } catch { /* The current model and custom model entry remain available. */ }
  }
  return [];
}

export function desktopConfigOptions(conversation: any, models: Model[]): acp.SessionConfigOption[] {
  const settings = conversation?.latestThreadSettings ?? {};
  const model = settings.model ?? conversation?.latestModel ?? "";
  const effort = settings.effort ?? conversation?.latestReasoningEffort ?? "low";
  const collaboration = settings.collaborationMode ?? conversation?.latestCollaborationMode;
  const sandbox = settings.sandboxPolicy?.type;
  const permission = settings.activePermissionProfile?.id;
  const mode = sandbox === "dangerFullAccess" || permission === ":danger-full-access" ? "agent-full-access"
    : sandbox === "readOnly" || permission === ":read-only" ? "read-only" : "agent";
  const catalog = models.some((entry) => entry.id === model) ? models : [{ id: model, name: model || "目前模型", efforts: [] }, ...models];
  const efforts = models.find((entry) => entry.id === model)?.efforts ?? [];
  const values = [...new Set([effort, ...(efforts.length ? efforts : ["low", "medium", "high", "xhigh", "max"])])];
  return [
    { id: "model", name: "模型", category: "model", type: "select", currentValue: model, options: catalog.map(({ id, name }) => ({ value: id, name })) },
    { id: "reasoning_effort", name: "推理強度", category: "thought_level", type: "select", currentValue: effort, options: values.map((value) => ({ value, name: value })) },
    { id: "mode", name: "權限模式", category: "mode", type: "select", currentValue: mode, options: [
      { value: "read-only", name: "唯讀" }, { value: "agent", name: "Agent" }, { value: "agent-full-access", name: "完整存取", description: "允許 agent 存取工作區外檔案與網路" },
    ] },
    { id: "collaboration_mode", name: "協作模式", category: "mode", type: "select", currentValue: collaboration?.mode ?? "default", options: [
      { value: "default", name: "Default" }, { value: "plan", name: "Plan" },
    ], description: "模型、推理與協作設定套用於下一個回合；進行中的回合繼續使用原設定。" },
  ];
}

export function desktopSettingsPatch(conversation: any, configId: string, value: unknown): Record<string, unknown> {
  if (typeof value !== "string" || !value.trim()) throw acp.RequestError.invalidParams(undefined, "A setting value is required");
  const current = conversation.latestThreadSettings ?? {};
  const model = current.model ?? conversation.latestModel;
  const effort = current.effort ?? conversation.latestReasoningEffort ?? null;
  const collaboration = current.collaborationMode ?? conversation.latestCollaborationMode ?? { mode: "default", settings: { model, reasoning_effort: effort, developer_instructions: null } };
  if (configId === "model") return { model: value, collaborationMode: { ...collaboration, settings: { ...collaboration.settings, model: value } } };
  if (configId === "reasoning_effort" && ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].includes(value))
    return { effort: value, collaborationMode: { ...collaboration, settings: { ...collaboration.settings, reasoning_effort: value } } };
  if (configId === "collaboration_mode" && ["default", "plan"].includes(value))
    return { collaborationMode: { mode: value, settings: { model, reasoning_effort: effort, developer_instructions: null } } };
  if (configId === "mode") {
    const sandboxPolicy = value === "read-only" ? { type: "readOnly" } : value === "agent-full-access" ? { type: "dangerFullAccess" }
      : value === "agent" ? { type: "workspaceWrite", writableRoots: [conversation.cwd], networkAccess: false, excludeTmpdirEnvVar: false, excludeSlashTmp: false } : undefined;
    if (sandboxPolicy) return { sandboxPolicy, permissions: null, approvalPolicy: value === "agent-full-access" ? "never" : "on-request" };
  }
  throw acp.RequestError.invalidParams(undefined, "Unknown desktop setting or unsupported value");
}

/** The desktop uses this to restore a failed/optimistic steer and derive its context. */
export function desktopRestoreMessage(conversation: any, input: any[], id: string): Record<string, unknown> {
  const text = input.filter((item) => item.type === "text").map((item) => item.text).join("\n");
  return { id, text, input, createdAt: Date.now(),
    cwd: conversation.cwd, context: { prompt: text, addedFiles: [], fileAttachments: [], ideContext: null,
      imageAttachments: [], commentAttachments: [], workspaceRoots: conversation.cwd ? [conversation.cwd] : [],
      collaborationMode: conversation.latestThreadSettings?.collaborationMode ?? conversation.latestCollaborationMode ?? null } };
}
