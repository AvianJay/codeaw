/**
 * Records a session exercising every event type through a real bridge + the fake agent and
 * writes app/test/fixtures/replay.json = { raw, compacted }: the full log and the compacted
 * replay a fresh client receives. The Dart timeline test checks both reduce to the same state.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { newFakeSession, promptText, rawLog, startTestBridge, TestClient } from "../test/helpers.js";

const out = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../app/test/fixtures/replay.json");
const tb = await startTestBridge();
try {
  const a = await TestClient.connect(tb.url, tb.tokenFor("A"));
  a.permissionAnswer = async () => ({ outcome: { outcome: "selected", optionId: "allow" } });
  a.elicitationAnswer = async () => ({ action: "accept", content: { question_0: "Vue" } });
  const s = await newFakeSession(a, tb.home);
  for (const p of ["echo hello streaming world", "tool", "edit", "perm", "elicit", "title Fixture Session", "slow 6"]) {
    await a.request("session/prompt", promptText(s.sessionId, p));
  }
  const queuedFirst = a.request("session/prompt", promptText(s.sessionId, "slow 10"));
  await a.waitFor(() => a.text(s.sessionId).endsWith("0 "));
  const queued = a.request("session/prompt", promptText(s.sessionId, "echo queued one"));
  await Promise.all([queuedFirst, queued]);
  const cancelled = a.request("session/prompt", promptText(s.sessionId, "slow 300"));
  await a.waitFor(() => a.events(s.sessionId, "state").at(-1)?.event.state === "running");
  await a.notify("session/cancel", { sessionId: s.sessionId });
  await cancelled;
  a.close();

  const b = await TestClient.connect(tb.url, tb.tokenFor("B"));
  await b.request("session/load", { sessionId: s.sessionId, cwd: tb.home, mcpServers: [] });
  const raw = rawLog(tb, s.sessionId);
  const compacted = b.log(s.sessionId);
  b.close();
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, JSON.stringify({ raw, compacted }, null, 1));
  console.log(`wrote ${out}: ${raw.length} raw, ${compacted.length} compacted`);
} finally {
  await tb.stop();
}
