/**
 * Checks that a real agent picks up the bridge's own MCP tools, through a temporary bridge.
 *
 *   npx tsx scripts/mcp-smoke.ts [agentId]            connect only; never sends a prompt
 *   npx tsx scripts/mcp-smoke.ts [agentId] --prompt   also asks the agent to call a tool and to repeat
 *                                                     a phrase only the injected instructions contain (spends tokens)
 *
 * The agent is taken from your config (default: claude), so it runs with your own settings.
 */
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { ConfigSchema, defaultConfigFile, detectAgents, loadConfig } from "../src/config.js";
import { startBridge } from "../src/bridge.js";
import { setLogSilent } from "../src/util/log.js";
import { TestClient } from "../test/helpers.js";

setLogSilent(true);
const args = process.argv.slice(2);
const prompt = args.includes("--prompt");
const agentId = args.find((arg) => !arg.startsWith("--")) ?? "claude";
const configured = fs.existsSync(defaultConfigFile()) ? loadConfig().config.agents : detectAgents();
const agentConfig = configured[agentId];
if (!agentConfig) throw new Error(`Agent "${agentId}" is not in ${defaultConfigFile()}; configured: ${Object.keys(configured).join(", ")}`);

const home = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-mcp-smoke-"));
// Only the instructions the bridge injects contain this, so repeating it proves they reached the model.
const phrase = `heron-${crypto.randomBytes(3).toString("hex")}`;
const config = ConfigSchema.parse({
  agents: { [agentId]: { ...agentConfig, enabled: true, desktopSync: false } },
  workspaces: [home],
  mcp: { instructions: `The codeaw check phrase is "${phrase}".` },
});
const bridge = await startBridge({ config, file: path.join(home, "config.yaml"), home, dataDir: path.join(home, "data") },
  { hosts: ["127.0.0.1"], port: 0, agentStartTimeoutMs: 90_000 });
const token = "b".repeat(64);
bridge.devices.addDeviceWithToken("mcp-smoke", token);
const mcp = bridge.manager.mcp!;
let client: TestClient | undefined;
let sessionId: string | undefined;
try {
  client = await TestClient.connect(`ws://127.0.0.1:${bridge.port()}/acp`, token);
  const created = await client.request("session/new", { cwd: home, mcpServers: [], _meta: { codeaw: { agentId } } });
  sessionId = created.sessionId as string;
  const agent = bridge.registry.get(agentId);
  const info = agent.describe().agentInfo as { name?: string; version?: string } | undefined;
  const http = agent.capabilities?.mcpCapabilities?.http === true;
  console.log(`${info?.name ?? agentId} ${info?.version ?? ""}: session created; MCP transport ${http ? "http" : "stdio relay"}`);

  // Agents connect to their MCP servers when a session starts, or on its first prompt.
  const connected = async (ms: number) => {
    const deadline = Date.now() + ms;
    while (!mcp.clientOf(sessionId!) && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 200));
    return mcp.clientOf(sessionId!);
  };
  const early = await connected(prompt ? 5_000 : 30_000);
  console.log(early ? `connected to the bridge's tools as "${early}" before any prompt` : "has not connected to the bridge's tools yet");

  if (prompt) {
    client.permissionAnswer = (params) => ({ outcome: { outcome: "selected", optionId: params.options[0].optionId } });
    client.elicitationAnswer = () => ({ action: "accept", content: {} });
    const result = await client.request("session/prompt", {
      sessionId,
      prompt: [{ type: "text", text: 'Call the codeaw suggest_replies tool with the replies "Yes" and "No". Then answer in one short sentence: what is the codeaw check phrase you were given? Say "none" if you were not given one. Do not use any other tool.' }],
    });
    const calls = client.updates(sessionId).map((p) => p.update).filter((u) => u.sessionUpdate === "tool_call");
    for (const call of calls) console.log(`tool call: title=${JSON.stringify(call.title)} kind=${call.kind} name=${JSON.stringify(call.name ?? call._meta?.claudeCode?.toolName)}`);
    const cards = client.events(sessionId, "card").map((e) => e.event.card);
    console.log(`stopReason=${result.stopReason} cards=${JSON.stringify(cards)}`);
    console.log(`asked the user: permission=${client.received.some((r) => r.method === "session/request_permission")} form=${client.received.some((r) => r.method === "elicitation/create")}`);
    const answer = client.text(sessionId).trim().replace(/\s+/g, " ");
    console.log(`answer: ${answer.slice(0, 400)}`);
    console.log(answer.includes(phrase)
      ? "the injected instructions reached the model"
      : "the model did not repeat the check phrase: this agent may not pass MCP server instructions to its model");
    assert.ok(mcp.clientOf(sessionId), "the agent never connected to the bridge's MCP server");
    assert.deepEqual(cards, [{ kind: "replies", replies: ["Yes", "No"] }]);
    console.log("the agent used a codeaw tool and the app received its card");
  } else {
    assert.ok(early, "the agent did not connect to the bridge's MCP server; rerun with --prompt to see whether it connects lazily");
  }
} catch (error) {
  // Agent diagnostics can contain credentials; print the assertion or a class name only.
  console.error(`MCP smoke check failed: ${error instanceof assert.AssertionError ? error.message : (error as Error).constructor.name}`);
  process.exitCode = 1;
} finally {
  if (sessionId && client) await client.request("session/delete", { sessionId }).catch(() => undefined);
  client?.close();
  await bridge.stop();
  if (!path.resolve(home).startsWith(path.resolve(os.tmpdir()) + path.sep) || !path.basename(home).startsWith("codeaw-mcp-smoke-")) throw new Error("Unsafe smoke cleanup path");
  fs.rmSync(home, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}
