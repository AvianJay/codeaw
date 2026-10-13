import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { afterEach, describe, expect, it } from "vitest";
import { AgentTempDirectory } from "../src/backend/agent-temp.js";

const roots: string[] = [];
function root() { const directory = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-agent-temp-test-")); roots.push(directory); return directory; }
async function deadPid(): Promise<number> {
  const child = spawn(process.execPath, ["-e", "process.exit(0)"], { windowsHide: true });
  await new Promise<void>((resolve, reject) => { child.once("close", () => resolve()); child.once("error", reject); });
  return child.pid!;
}
afterEach(() => {
  for (const directory of roots.splice(0)) {
    if (path.dirname(directory) !== path.resolve(os.tmpdir()) || !path.basename(directory).startsWith("codeaw-agent-temp-test-")) throw new Error("Unsafe test cleanup");
    fs.rmSync(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  }
});
describe("Antigravity extraction directories", () => {
  it("isolates TMP/TEMP with case insensitive overrides and removes only its own run", async () => {
    const directory = root();
    const unrelated = path.join(directory, "_MEI-other-app"); fs.mkdirSync(unrelated);
    const run = await AgentTempDirectory.create(directory);
    const inherited = { Temp: "custom", TMP: "custom", Path: "preserved" };
    expect(run.environment(inherited)).toEqual({ TMP: run.directory, TEMP: run.directory, Path: "preserved" });
    expect(inherited.Temp).toBe("custom");
    fs.mkdirSync(path.join(run.directory, "_MEI-fixture"));
    await run.recordProcess(process.pid);
    await run.dispose();
    expect(fs.existsSync(run.directory)).toBe(false);
    expect(fs.existsSync(unrelated)).toBe(true);
  });

  it("reclaims a dead bridge's run while preserving live owners and unknown directories", async () => {
    const directory = root(), pid = await deadPid();
    const makeRun = (name: string, childPid?: number) => {
      const run = path.join(directory, name); fs.mkdirSync(run);
      if (childPid) fs.writeFileSync(path.join(run, "owner.json"), JSON.stringify({ pid: childPid }));
      return run;
    };
    const stale = makeRun("run-" + pid + "-stale", pid);
    const liveBridge = makeRun("run-" + process.pid + "-live", pid);
    const liveAgent = makeRun("run-" + pid + "-liveagent", process.pid);
    const unknown = makeRun("run-" + pid + "-unknown");
    const unrelated = makeRun("_MEI-other-app", pid);
    const run = await AgentTempDirectory.create(directory);
    expect(fs.existsSync(stale)).toBe(false);
    for (const kept of [liveBridge, liveAgent, unknown, unrelated]) expect(fs.existsSync(kept)).toBe(true);
    await run.dispose();
  });
});
