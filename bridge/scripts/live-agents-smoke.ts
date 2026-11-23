/**
 * Real, billable smoke of two integrations through a bridge built from source (no installed bridge
 * is touched, and nothing is written to the user's Claude or AGY history):
 *
 * - Claude desktop chats: clones a transcript the Claude desktop app wrote into a private
 *   CLAUDE_CONFIG_DIR, resumes it through claude-agent-acp on the chosen model and checks that the
 *   model's `mcp__ccd_turn__*` calls land as a task list and quick replies instead of failing.
 * - Antigravity CLI (`transport: agy`): one tool-using turn on the chosen model, checking tool rows,
 *   the chat title and the file it wrote.
 *
 *   npx tsx scripts/live-agents-smoke.ts --claude-command <claude-agent-acp> --desktop-transcript <file.jsonl>
 *     --claude-model haiku --agy-command <agy> --agy-model "Gemini 3.8 Flash Low (CPA)" [--only claude|agy] [--report out.json]
 *
 * Provider credentials come from the environment (ANTHROPIC_*, GEMINI_API_KEY, GOOGLE_GEMINI_BASE_URL)
 * and are never printed. Exit code 1 when a check fails.
 */
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { parseArgs } from "node:util";
import { ConfigSchema, type LoadedConfig } from "../src/config.js";
import { startBridge } from "../src/bridge.js";
import { claudeProjectSlug } from "../src/session/native-activity.js";
import { TestClient } from "../test/helpers.js";

const { values } = parseArgs({ options: {
  "claude-command": { type: "string" }, "desktop-transcript": { type: "string" }, "claude-model": { type: "string", default: "haiku" },
  "agy-command": { type: "string" }, "agy-model": { type: "string" },
  only: { type: "string" }, report: { type: "string" },
} });
const runClaude = values.only !== "agy";
const runAgy = values.only !== "claude";
if (runClaude && (!values["claude-command"] || !values["desktop-transcript"])) throw new Error("--claude-command and --desktop-transcript are required");
if (runAgy && (!values["agy-command"] || !values["agy-model"])) throw new Error("--agy-command and --agy-model are required");

// A Claude Code session that runs this script must not look like the parent of the agents it starts.
for (const name of Object.keys(process.env)) {
  if (/^(CLAUDECODE|CLAUDE_CODE_|CLAUDE_AGENT_SDK|CLAUDE_EFFORT|CLAUDE_PID|CODEAW_MCP_)/.test(name)) delete process.env[name];
}

const secrets = [process.env.ANTHROPIC_AUTH_TOKEN, process.env.ANTHROPIC_API_KEY, process.env.GEMINI_API_KEY].filter((v): v is string => !!v && v.length > 5);
const redact = (text: string) => secrets.reduce((t, s) => t.split(s).join("[REDACTED]"), text);
const checks: { name: string; ok: boolean; detail?: string }[] = [];
const check = (name: string, ok: boolean, detail?: unknown) => {
  const entry = { name, ok, ...(detail === undefined ? {} : { detail: redact(typeof detail === "string" ? detail : JSON.stringify(detail)).slice(0, 600) }) };
  checks.push(entry);
  process.stdout.write(`${ok ? "PASS" : "FAIL"} ${name}${entry.detail ? ` — ${entry.detail}` : ""}\n`);
};

const root = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-live-smoke-"));
const work = path.join(root, "work");
fs.mkdirSync(work);
const claudeHome = path.join(root, "claude");
const desktopId = randomUUID();
if (runClaude) {
  // The clone gets its own id and folder; Claude Code finds it by cwd and id.
  const dir = path.join(claudeHome, "projects", claudeProjectSlug(work));
  fs.mkdirSync(dir, { recursive: true });
  const original = fs.readFileSync(values["desktop-transcript"]!, "utf8");
  const sourceId = path.basename(values["desktop-transcript"]!, ".jsonl");
  const lines = original.split("\n").filter(Boolean).map((line) => {
    const entry = JSON.parse(line);
    if (entry.sessionId === sourceId) entry.sessionId = desktopId;
    if (typeof entry.cwd === "string") entry.cwd = work;
    return JSON.stringify(entry);
  });
  fs.writeFileSync(path.join(dir, `${desktopId}.jsonl`), lines.join("\n") + "\n");
  check("cloned transcript was written by the Claude desktop app", original.includes('"entrypoint":"claude-desktop'));
}

const config = ConfigSchema.parse({
  workspaces: [work],
  agents: {
    ...(runClaude ? { claude: { name: "Claude Code", command: values["claude-command"], args: [], env: { CLAUDE_CONFIG_DIR: claudeHome } } } : {}),
    ...(runAgy ? { antigravity: { name: "Antigravity CLI", command: values["agy-command"], transport: "agy", args: ["--model", values["agy-model"]], env: {} } } : {}),
  },
});
const loaded: LoadedConfig = { config, file: path.join(root, "config.yaml"), home: root, dataDir: path.join(root, "data") };
const bridge = await startBridge(loaded, { hosts: ["127.0.0.1"], port: 0 });
const token = randomUUID().replace(/-/g, "") + randomUUID().replace(/-/g, "");
bridge.devices.addDeviceWithToken("live-smoke", token);
const c = await TestClient.connect(`ws://127.0.0.1:${bridge.port()}/acp`, token);
c.permissionAnswer = (params) => {
  const once = params.options.find((o: any) => o.kind === "allow_once");
  return once ? { outcome: { outcome: "selected", optionId: once.optionId } } : { outcome: { outcome: "cancelled" } };
};
const withTimeout = <T>(promise: Promise<T>, ms: number, what: string) =>
  Promise.race([promise, new Promise<never>((_, reject) => setTimeout(() => reject(new Error(`${what} timed out after ${ms / 1000}s`)), ms))]);
const prompt = (sessionId: string, text: string) =>
  withTimeout(c.request("session/prompt", { sessionId, prompt: [{ type: "text", text }] }), 240_000, "prompt");
const toolCalls = (sessionId: string) => {
  const calls = new Map<string, any>();
  for (const u of c.updates(sessionId).map((p) => p.update)) {
    if (u.sessionUpdate === "tool_call") calls.set(u.toolCallId, { ...u });
    else if (u.sessionUpdate === "tool_call_update" && calls.has(u.toolCallId)) Object.assign(calls.get(u.toolCallId), Object.fromEntries(Object.entries(u).filter(([, v]) => v !== undefined && v !== null)));
  }
  return [...calls.values()];
};
const toolName = (call: any) => call._meta?.claudeCode?.toolName ?? call.title;

try {
  if (runClaude) {
    const sessionId = `claude:${desktopId}`;
    const opened: any = await withTimeout(c.request("session/load", { sessionId, cwd: work, mcpServers: [] }), 120_000, "open desktop chat");
    const model = opened.configOptions?.find((o: any) => o.category === "model" || o.id === "model");
    const wanted = values["claude-model"]!.toLowerCase();
    const choice = model?.options?.find((o: any) => String(o.value).toLowerCase() === wanted) ??
      model?.options?.find((o: any) => `${o.value} ${o.name} ${o.description ?? ""}`.toLowerCase().includes(wanted));
    check("chosen Claude model is offered", !!choice, model?.options?.map((o: any) => `${o.value}=${o.name}`));
    if (choice) await c.request("session/set_config_option", { sessionId, configId: model.id, value: choice.value });
    const result: any = await prompt(sessionId, [
      "Automated check of how this chat works from the codeaw phone app. Use no other tools and do exactly this, in order:",
      "1) call mcp__ccd_turn__update_plan with items [{\"content\": \"Say ALPHA\", \"status\": \"in_progress\"}, {\"content\": \"Say BETA\", \"status\": \"pending\"}];",
      "2) call mcp__ccd_turn__update_plan with {\"advance\": true};",
      "3) call mcp__ccd_turn__wrap_up with recap \"Smoke check finished.\", question \"Run again?\" and buttons [\"Yes\", \"No\"];",
      "4) reply with the single word DONE.",
    ].join("\n"));
    check("Claude turn ended normally", result.stopReason === "end_turn", result.stopReason);
    const calls = toolCalls(sessionId);
    const turnCalls = calls.filter((call) => /ccd_turn/.test(String(toolName(call))));
    check("model called the desktop turn tools", turnCalls.length >= 3, calls.map((call) => `${toolName(call)}:${call.status}`));
    check("every desktop turn tool call succeeded", turnCalls.length > 0 && turnCalls.every((call) => call.status === "completed"), turnCalls.map((call) => `${toolName(call)}:${call.status}`));
    const plans = c.updates(sessionId).filter((p) => p.update.sessionUpdate === "plan").map((p) => p.update.entries.map((e: any) => `${e.status}:${e.content}`).join(","));
    check("task list reached the chat and advanced", plans.length >= 2 && plans.some((p) => p.startsWith("completed:Say ALPHA,in_progress:Say BETA")), plans);
    const cards = c.events(sessionId, "card").map((e) => e.event.card);
    check("wrap-up buttons became quick replies", cards.some((card) => card.kind === "replies" && card.replies.join("|") === "Yes|No"), cards);
    check("no permission prompt for the stand-in tools", !c.received.some((r) => r.method === "session/request_permission" && /ccd_turn/.test(JSON.stringify(r.params.toolCall))));
    check("final reply says DONE", /\bDONE\b/.test(c.text(sessionId)), c.text(sessionId).slice(-200));
  }

  if (runAgy) {
    const created: any = await withTimeout(c.request("session/new", { cwd: work, mcpServers: [], _meta: { codeaw: { agentId: "antigravity" } } }), 60_000, "new AGY chat");
    const sessionId = created.sessionId;
    const model = created.configOptions?.find((o: any) => o.id === "model");
    check("AGY chat uses the configured model", model?.currentValue === values["agy-model"], model?.currentValue);
    const result: any = await prompt(sessionId, "Create a file named smoke.txt in the current folder containing exactly the text codeaw-ok, then read it back with a tool and reply with exactly its content.");
    check("AGY turn ended normally", result.stopReason === "end_turn", result.stopReason);
    const calls = toolCalls(sessionId);
    check("AGY tool rows name what they touch", calls.some((call) => /^(Write|Edit) smoke\.txt$/.test(call.title)) && calls.some((call) => call.title === "Read smoke.txt" || /smoke\.txt/.test(call.title)),
      calls.map((call) => `${call.kind}:${call.title}:${call.status}`));
    check("AGY file rows carry their path", calls.filter((call) => call.kind !== "execute").every((call) => call.locations?.[0]?.path), calls.map((call) => call.locations));
    const written = path.join(work, "smoke.txt");
    check("AGY wrote the file", fs.existsSync(written) && fs.readFileSync(written, "utf8").trim() === "codeaw-ok");
    check("AGY reply has the content", c.text(sessionId).includes("codeaw-ok"), c.text(sessionId).slice(-200));
    const titles = c.updates(sessionId).filter((p) => p.update.sessionUpdate === "session_info_update").map((p) => p.update.title);
    check("AGY chat got a title", titles.length === 1 && titles[0].startsWith("Create a file named smoke.txt"), titles);
  }
} catch (error) {
  check("smoke ran to completion", false, error instanceof Error ? error.message : String(error));
} finally {
  c.close();
  await bridge.stop().catch(() => undefined);
  if (values.report) fs.writeFileSync(values.report, JSON.stringify({ at: new Date().toISOString(), checks }, null, 2));
  if (path.dirname(root) === path.resolve(os.tmpdir()) && path.basename(root).startsWith("codeaw-live-smoke-")) {
    fs.rmSync(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}
const failed = checks.filter((entry) => !entry.ok);
process.stdout.write(`${checks.length - failed.length}/${checks.length} checks passed\n`);
process.exit(failed.length ? 1 : 0);
