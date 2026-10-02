// Install/update/uninstall in a temporary directory with an isolated CODEAW_HOME.
// Refuse to overwrite an existing user installation or its shortcuts.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

if (process.platform !== "win32") throw new Error("Installer smoke requires Windows");
const installer = path.resolve(process.argv[2] ?? `dist/installer/codeaw-bridge-windows-${process.arch}-setup.exe`);
const exec = promisify(execFile);
const powershell = async (script) => (await exec("powershell.exe", ["-NoProfile", "-Command", script], { windowsHide: true })).stdout.trim();
const appKey = "HKCU:\\Software\\codeaw\\bridge";
const uninstallKey = "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\codeaw-bridge";
const registryPresent = async () => (await powershell(`if ((Test-Path '${appKey}') -or (Test-Path '${uninstallKey}')) { 'present' }`)) === "present";
if (await registryPresent()) throw new Error("Existing bridge installation detected; use an isolated Windows account for installer smoke");
const menu = await powershell("Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\\codeaw bridge'");
const desktop = await powershell("Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'codeaw bridge.lnk'");
if (fs.existsSync(menu) || fs.existsSync(desktop)) throw new Error("Existing bridge shortcuts detected; installer smoke will not overwrite them");

const home = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-installer-smoke-"));
const destination = path.join(home, "install with spaces");
const state = path.join(home, "state");
fs.mkdirSync(state);
const config = "# preserve this config\nlisten:\n  hosts: [127.0.0.1]\n  port: 0\nagents: {}\n";
fs.writeFileSync(path.join(state, "config.yaml"), config);
fs.writeFileSync(path.join(state, "devices.json"), "[]");
const env = { ...process.env, CODEAW_HOME: state };
const cli = async (...args) => (await exec(path.join(destination, "codeaw-bridge.exe"), args, { env, windowsHide: true, timeout: 20_000 })).stdout;
const setup = async () => { await exec(installer, ["/S", `/D=${destination}`], { env, windowsHide: true, windowsVerbatimArguments: true, timeout: 60_000 }); };
let installed = false;

async function uninstall() {
  const executable = path.join(destination, "uninstall.exe");
  if (!fs.existsSync(executable)) return;
  await exec(executable, ["/S"], { env, windowsHide: true, timeout: 30_000 });
  // NSIS copies the uninstaller to TEMP; wait for that child to finish its cleanup.
  for (let attempt = 0; attempt < 30; attempt++) {
    if (!await registryPresent() && !fs.existsSync(path.join(destination, "codeaw-bridge.exe"))) return;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error("Installer smoke uninstall did not finish");
}

try {
  installed = true;
  await setup();
  for (const file of ["codeaw-bridge.exe", "launch.ps1", "uninstall.exe", "LICENSE", "README.md"]) {
    if (!fs.existsSync(path.join(destination, file))) throw new Error(`Installer did not copy ${file}`);
  }
  for (const file of ["codeaw bridge.lnk", "Pair phone.lnk", "Settings.lnk", "Uninstall.lnk"]) {
    if (!fs.existsSync(path.join(menu, file))) throw new Error(`Installer did not create ${file}`);
  }
  if (!await registryPresent()) throw new Error("Installer did not register the app");
  if (!(await cli("status")).includes("stopped")) throw new Error("Silent install unexpectedly launched the bridge");
  await cli("start", "--background");
  if (!(await cli("status")).includes("running")) throw new Error("Installed bridge did not start");
  await setup();
  if (!(await cli("status")).includes("stopped")) throw new Error("Update did not stop the running bridge");
  if (fs.readFileSync(path.join(state, "config.yaml"), "utf8") !== config) throw new Error("Update changed user config");
  fs.writeFileSync(path.join(destination, "keep-me.txt"), "user file");
  await cli("autostart", "install");
  if (!(await cli("autostart", "status")).includes("enabled")) throw new Error("Installed login startup did not work");
  await cli("start", "--background");
  await uninstall();
  installed = false;
  if (!fs.existsSync(path.join(destination, "keep-me.txt"))) throw new Error("Uninstall removed a user file");
  if (fs.existsSync(menu)) throw new Error("Uninstall left Start Menu shortcuts");
  if (fs.readFileSync(path.join(state, "config.yaml"), "utf8") !== config || !fs.existsSync(path.join(state, "devices.json"))) throw new Error("Uninstall changed user state");
  // Use the known packaged binary outside the deleted install to check this isolated Run entry.
  const original = path.resolve("dist/bin/codeaw-bridge.exe");
  if ((await exec(original, ["autostart", "status"], { env, windowsHide: true })).stdout.includes("enabled")) throw new Error("Uninstall left login startup");
  process.stdout.write("NSIS silent install, running upgrade, shortcuts, startup cleanup and user-state preservation passed.\n");
} finally {
  if (installed) await uninstall();
  const absoluteHome = path.resolve(home);
  if (!absoluteHome.startsWith(path.resolve(os.tmpdir()) + path.sep) || !path.basename(absoluteHome).startsWith("codeaw-installer-smoke-")) throw new Error("Unsafe smoke cleanup path");
  fs.rmSync(absoluteHome, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}
