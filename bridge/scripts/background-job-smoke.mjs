// A disposable Windows job simulates the desktop/terminal shutting down.
// It owns only the test CLI and its children, never the user's desktop or bridge.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

if (process.platform !== "win32") throw new Error("Windows job smoke requires Windows");
const executable = path.resolve(process.argv[2] ?? "dist/bin/codeaw-bridge.exe");
const home = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-job-smoke-"));
const state = path.join(home, "state with space's 中文");
fs.mkdirSync(state);
const file = path.join(state, "config.yaml");
fs.writeFileSync(file, "listen:\n  hosts: [127.0.0.1]\n  port: 0\nagents: {}\n");
fs.writeFileSync(path.join(state, "devices.json"), JSON.stringify([{ id: "d_job_smoke", name: "Isolated fixture", tokenHash: "0".repeat(64), createdAt: new Date().toISOString() }]));
const exec = promisify(execFile);
const env = { ...process.env, CODEAW_HOME: state };
let trayPid;
try {
  const result = await exec("powershell.exe", ["-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass",
    "-File", fileURLToPath(new URL("./background-job-smoke.ps1", import.meta.url)), "-Executable", executable, "-Config", file],
    { windowsHide: true, env, timeout: 60_000 });
  const outcome = JSON.parse(result.stdout.trim());
  trayPid = outcome.trayPid;
  assert.equal(outcome.inheritedTestJob, false);
  assert.equal(outcome.survivedJobTermination, true);
  assert.equal(outcome.trayInheritedTestJob, false);
  assert.equal(outcome.traySurvived, true);
  process.stdout.write("Packaged bridge and tray survived termination of the launcher's Windows job.\n");
} finally {
  await exec(executable, ["stop", "--config", file], { env, windowsHide: true, timeout: 20_000 });
  // Tray closes after three missed control-pipe probes, including connect timeouts.
  for (let attempt = 0; attempt < 15 && trayPid; attempt++) {
    try { process.kill(trayPid, 0); } catch { trayPid = undefined; break; }
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  if (trayPid) throw new Error("Isolated tray did not exit after its bridge stopped");
  const target = path.resolve(home);
  if (path.dirname(target) !== path.resolve(os.tmpdir()) || !path.basename(target).startsWith("codeaw-job-smoke-")) throw new Error("Invalid test cleanup path");
  fs.rmSync(target, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}
