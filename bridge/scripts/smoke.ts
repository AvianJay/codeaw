/**
 * Smoke test against the real agents installed on this machine, through a throwaway bridge.
 * Never sends a prompt (no tokens are spent).
 *
 *   npm run smoke                       # every detected agent
 *   npm run smoke -- claude codex       # only these
 *   npm run smoke -- --load claude:<id> # additionally import one existing session and summarize it
 */
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { ConfigSchema, detectAgents, type LoadedConfig } from "../src/config.js";
import { startBridge } from "../src/bridge.js";
import { setLogSilent } from "../src/util/log.js";
import { TestClient } from "../test/helpers.js";

setLogSilent(process.env.CODEAW_TEST_LOG !== "1");

const args = process.argv.slice(2);
const loadIdx = args.indexOf("--load");
const loadId = loadIdx >= 0 ? args[loadIdx + 1] : undefined;
const wanted = args.filter((a, i) => !a.startsWith("--") && i !== loadIdx + 1);

const home = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-smoke-"));
const work = path.join(home, "work");
fs.mkdirSync(work);
const detected = detectAgents();
const agents = Object.fromEntries(Object.entries(detected).filter(([id]) => wanted.length === 0 || wanted.includes(id)));
const config = ConfigSchema.parse({ agents, workspaces: [work] });
const loaded: LoadedConfig = { config, file: path.join(home, "config.yaml"), home, dataDir: path.join(home, "data") };

const bridge = await startBridge(loaded, { hosts: ["127.0.0.1"], port: 0 });
const token = "a".repeat(64);
bridge.devices.addDeviceWithToken("smoke", token);
const c = await TestClient.connect(`ws://127.0.0.1:${bridge.port()}/acp`, token);
const t0 = Date.now();
const ms = () => `${Date.now() - t0} ms`;

try {
  console.log(`agents: ${Object.keys(agents).join(", ")}`);
  const list = await c.request("session/list", {});
  console.log(`session/list: ${list.sessions.length} sessions (${ms()})`);
  for (const e of list._meta.codeaw.errors) console.log(`  ! ${e.agentId}: ${e.message}`);
  const byAgent = new Map<string, number>();
  for (const s of list.sessions) byAgent.set(s._meta.codeaw.agentId, (byAgent.get(s._meta.codeaw.agentId) ?? 0) + 1);
  for (const [a, n] of byAgent) console.log(`  ${a}: ${n} on first page`);

  const info = (await c.request("_codeaw/agents/list", {})).agents;
  for (const a of info) {
    console.log(`\n[${a.id}] ${a.status} ${a.agentInfo ? `${a.agentInfo.name} ${a.agentInfo.version}` : ""} steering=${a.steering}`);
    if (a.status !== "ready") {
      console.log(`  error: ${a.error}`);
      continue;
    }
    const caps = a.capabilities ?? {};
    console.log(`  load=${!!caps.loadSession} session=${Object.keys(caps.sessionCapabilities ?? {}).join(",")} prompt=${JSON.stringify(caps.promptCapabilities ?? {})}`);
    try {
      const s = await c.request("session/new", { cwd: work, mcpServers: [], _meta: { codeaw: { agentId: a.id } } });
      const opts = (s.configOptions ?? []).map((o: any) => `${o.id}=${o.currentValue}`);
      console.log(`  session/new ${s.sessionId} (${ms()}) config: ${opts.join(" ")} modes: ${s.modes?.availableModes?.map((m: any) => m.id).join("/") ?? "-"}`);
      await c.waitFor(() => c.updates(s.sessionId).some((u) => u.update.sessionUpdate === "available_commands_update"), 5000).catch(() => undefined);
      const cmds = c.updates(s.sessionId).find((u) => u.update.sessionUpdate === "available_commands_update");
      console.log(`  commands: ${cmds ? cmds.update.availableCommands.length : "none yet"}`);
      await c.request("session/close", { sessionId: s.sessionId }).catch((e: Error) => console.log(`  close: ${e.message}`));
      await c.request("session/delete", { sessionId: s.sessionId }).catch((e: Error) => console.log(`  delete: ${e.message}`));
    } catch (err) {
      console.log(`  session/new failed: ${(err as Error).message}`);
    }
  }

  if (loadId) {
    const native = list.sessions.find((s: any) => s.sessionId === loadId);
    console.log(`\nimporting ${loadId} (${native?.title ?? "?"})`);
    const resp = await c.request("session/load", { sessionId: loadId, cwd: native?.cwd ?? work, mcpServers: [] });
    const counts = new Map<string, number>();
    for (const m of c.log(loadId)) {
      const k = m.method === "session/update" ? m.params.update.sessionUpdate : `event:${m.params.event.type}`;
      counts.set(k, (counts.get(k) ?? 0) + 1);
    }
    console.log(`  replayed ${c.log(loadId).length} entries, lastSeq=${resp._meta.codeaw.lastSeq} (${ms()})`);
    for (const [k, n] of counts) console.log(`    ${k}: ${n}`);
    const firstUser = c.updates(loadId).find((u) => u.update.sessionUpdate === "user_message_chunk");
    if (firstUser) console.log(`  first user message: ${JSON.stringify(firstUser.update.content).slice(0, 120)}`);
  }
} finally {
  c.close();
  await bridge.stop();
  fs.rmSync(home, { recursive: true, force: true });
}
