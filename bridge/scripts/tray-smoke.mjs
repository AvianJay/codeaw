// Exercise the packaged Windows CLI, including the tray's lifetime after the CLI exits.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

if (process.platform !== "win32") throw new Error("Tray smoke requires Windows");
const executable = path.resolve(process.argv[2] ?? "dist/bin/codeaw-bridge.exe");
const launchScript = process.argv[3] ? path.resolve(process.argv[3]) : undefined;
const home = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-tray-smoke-"));
const state = path.join(home, "state with space's");
fs.mkdirSync(state);
const file = path.join(state, "config.yaml");
fs.writeFileSync(file, "listen:\n  hosts: [127.0.0.1]\n  port: 0\nagents: {}\n");
// A synthetic device prevents this lifecycle test from opening a pairing window.
fs.writeFileSync(path.join(state, "devices.json"), JSON.stringify([{ id: "d_smoke", name: "Smoke phone", tokenHash: "0".repeat(64), createdAt: new Date().toISOString() }]));
const exec = promisify(execFile);
const env = { ...process.env, CODEAW_HOME: state };
const cli = async (...args) => (await exec(executable, [...args, "--config", file], { env, windowsHide: true, timeout: 20_000 })).stdout;
const showTray = async () => launchScript
  ? exec("powershell.exe", ["-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", launchScript, "-Page", "tray"], { env, windowsHide: true, timeout: 20_000 })
  : cli("tray");
const ps = async (script) => (await exec("powershell.exe", ["-NoProfile", "-NonInteractive", "-EncodedCommand", Buffer.from(script, "utf16le").toString("base64")],
  { windowsHide: true, env, timeout: 10_000 })).stdout.trim();
const quote = (value) => "'" + value.replace(/'/g, "''") + "'";
async function trays() {
  const script = `$pattern = [Regex]::Escape(${quote(path.join(state, "runtime", "tray.ps1"))})
$items = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -match $pattern } | ForEach-Object { [int]$_.ProcessId })
ConvertTo-Json -InputObject $items -Compress`;
  return JSON.parse(await ps(script));
}
const pause = () => new Promise((resolve) => setTimeout(resolve, 3000));
let started = false;
try {
  started = true;
  await showTray();
  await pause();
  const first = await trays();
  if (first.length !== 1) throw new Error("Packaged CLI exited without a surviving tray process");
  await showTray();
  await pause();
  const second = await trays();
  if (second.length !== 1 || first[0] !== second[0]) throw new Error("Repeated tray launch did not preserve the existing desktop process");
  if (!(await cli("status")).includes("running")) throw new Error("Tray launch interrupted the bridge");
  process.stdout.write("Packaged tray stays alive after CLI exit; repeat launch keeps one tray.\n");
} finally {
  if (started) await cli("stop");
  // The tray notices the closed bridge pipe after three timer ticks.
  for (let attempt = 0; attempt < 10; attempt++) {
    if (!(await trays()).length) break;
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  if ((await trays()).length) throw new Error("Tray did not close after its bridge stopped");
  const absoluteHome = path.resolve(home);
  if (!absoluteHome.startsWith(path.resolve(os.tmpdir()) + path.sep) || !path.basename(absoluteHome).startsWith("codeaw-tray-smoke-")) throw new Error("Unsafe tray smoke cleanup path");
  fs.rmSync(absoluteHome, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}
