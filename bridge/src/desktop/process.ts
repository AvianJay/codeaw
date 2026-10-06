import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { execFile, spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { controlAddress, runningStatus } from "./control.js";
import { TRAY_SCRIPT } from "./windows-tray.js";
import { desktopEnvironment } from "../util/environment.js";

const execFileAsync = promisify(execFile);

const quotePowerShell = (value: string) => "'" + value.replace(/'/g, "''") + "'";

/** WMI's local broker does not inherit the launcher's job (e.g. a desktop update). */
async function startWindowsBackground(executable: string, args: string[], directory: string, logFile: string): Promise<number> {
  const wrapper = `$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'
Set-Location -LiteralPath ${quotePowerShell(directory)}
# Windows PowerShell treats native stderr as ErrorRecords. A warning must not
# terminate the wrapper and its agent process tree.
$ErrorActionPreference = 'Continue'
& ${quotePowerShell(executable)} ${args.map(quotePowerShell).join(' ')} *>> ${quotePowerShell(logFile)}
exit $LASTEXITCODE`;
  const encoded = Buffer.from(wrapper, 'utf16le').toString('base64');
  const bootstrap = `$ErrorActionPreference = 'Stop'
$startup = ([wmiclass]'Win32_ProcessStartup').CreateInstance()
$startup.ShowWindow = 0
$startup.CreateFlags = 16777216
$startup.WinstationDesktop = 'winsta0\\default'
$startup.EnvironmentVariables = @([Environment]::GetEnvironmentVariables('Process').GetEnumerator() | ForEach-Object { $_.Key + '=' + $_.Value })
$command = '"' + (Join-Path $PSHOME 'powershell.exe') + '" -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand ${encoded}'
$result = ([wmiclass]'Win32_Process').Create($command, ${quotePowerShell(directory)}, $startup)
if ($result.ReturnValue -ne 0) { throw ('Cannot start background bridge (WMI ' + $result.ReturnValue + ')') }
[Console]::Write($result.ProcessId)`;
  const result = await execFileAsync('powershell.exe', ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-EncodedCommand',
    Buffer.from(bootstrap, 'utf16le').toString('base64')], { windowsHide: true, timeout: 15_000 });
  const pid = Number(result.stdout.trim());
  if (!Number.isSafeInteger(pid) || pid <= 0) throw new Error(`Cannot start background bridge. See ${logFile}`);
  return pid;
}

function desktopBootstrap(script: string, pipeName: string, readyFile: string, logFile: string, iconPath: string): string {
  const quote = (value: string) => "'" + value.replace(/'/g, "''") + "'";
  const args = ['-NoProfile', '-NonInteractive', '-STA', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
    '-File', `"${script}"`, '-PipeName', pipeName, '-ReadyFile', `"${readyFile}"`, '-LogFile', `"${logFile}"`,
    '-IconPath', `"${iconPath}"`].join(' ');
  return `$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$mutex = [Threading.Mutex]::new($false, ${quote(`Local\\${pipeName}-tray`)})
try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { $mutex.Dispose(); exit 0 }
$mutex.ReleaseMutex(); $mutex.Dispose()
$startup = ([wmiclass]'Win32_ProcessStartup').CreateInstance()
$startup.ShowWindow = 0
$startup.CreateFlags = 16777216
$startup.WinstationDesktop = 'winsta0\\default'
$startup.EnvironmentVariables = @([Environment]::GetEnvironmentVariables('Process').GetEnumerator() | ForEach-Object { $_.Key + '=' + $_.Value })
$command = '"' + (Join-Path $PSHOME 'powershell.exe') + '" ' + ${quote(args)}
$created = ([wmiclass]'Win32_Process').Create($command, ${quote(path.dirname(script))}, $startup)
if ($created.ReturnValue -ne 0) { throw ('Cannot start system tray (WMI ' + $created.ReturnValue + ')') }
$deadline = [DateTime]::UtcNow.AddSeconds(10)
while ([DateTime]::UtcNow -lt $deadline) {
    if ([IO.File]::Exists(${quote(readyFile)})) { exit 0 }
    if (-not (Get-Process -Id $created.ProcessId -ErrorAction SilentlyContinue)) {
        # A concurrent launcher may already have acquired the tray mutex.
        $mutex = [Threading.Mutex]::new($false, ${quote(`Local\\${pipeName}-tray`)})
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { $mutex.Dispose(); exit 0 }
        $mutex.ReleaseMutex(); $mutex.Dispose()
        throw 'System tray exited before it was ready'
    }
    Start-Sleep -Milliseconds 100
}
throw 'System tray startup timed out'
`;
}

/** Launch in the caller's interactive session, including when the bridge runs in SCM Session 0. */
export async function launchDesktop(file: string): Promise<void> {
  if (process.platform === "darwin") { await launchMacDesktop(file); return; }
  if (process.platform !== "win32") throw new Error("Native tray and windows are currently available on Windows");
  const directory = path.join(path.dirname(file), "runtime");
  fs.mkdirSync(directory, { recursive: true });
  const script = path.join(directory, "tray.ps1");
  fs.writeFileSync(script, "\ufeff" + TRAY_SCRIPT, "utf8");
  const logFile = path.join(path.dirname(file), "desktop.log");
  const readyFile = path.join(directory, `tray-ready-${crypto.randomUUID()}.json`);
  // Standalone builds carry the icon in their PE resources; Node builds ship the ICO asset.
  const invocation = bridgeInvocation();
  const iconPath = invocation.args.length ? fileURLToPath(new URL("../assets/codeaw.ico", import.meta.url)) : invocation.executable;
  const bootstrap = desktopBootstrap(script, controlAddress(file).replace(/^\\\\\.\\pipe\\/, ""), readyFile, logFile, iconPath);
  try {
    // The local broker detaches the tray from Bun and enclosing desktop jobs.
    await execFileAsync("powershell.exe", ["-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-EncodedCommand",
      Buffer.from(bootstrap, "utf16le").toString("base64")], { windowsHide: true, timeout: 15_000 });
  } catch {
    throw new Error(`Cannot start the Windows system tray. See ${logFile}`);
  } finally { fs.rmSync(readyFile, { force: true }); }
}

async function launchMacDesktop(file: string): Promise<void> {
  const candidates = [path.join(path.dirname(process.execPath), "codeaw-menu"),
    fileURLToPath(new URL("../assets/codeaw-menu", import.meta.url)),
    fileURLToPath(new URL("../../dist/assets/codeaw-menu", import.meta.url))];
  const executable = candidates.find((candidate) => fs.existsSync(candidate));
  if (!executable) throw new Error("macOS menu bar helper not found. Install a macOS release or run npm run build:macos in bridge.");
  const directory = path.join(path.dirname(file), "runtime");
  fs.mkdirSync(directory, { recursive: true });
  const readyFile = path.join(directory, `tray-ready-${crypto.randomUUID()}.json`);
  const logFile = path.join(path.dirname(file), "desktop.log");
  const log = fs.openSync(logFile, "a", 0o600);
  let exited = false;
  try {
    const child = spawn(executable, ["--socket", controlAddress(file), "--ready", readyFile], {
      detached: true, stdio: ["ignore", log, log], env: desktopEnvironment(),
    });
    child.once("error", () => { exited = true; });
    child.once("exit", () => { exited = true; });
    child.unref();
    for (let attempt = 0; attempt < 100; attempt++) {
      if (fs.existsSync(readyFile)) return;
      if (exited) break;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error(`Cannot start the macOS menu bar. See ${logFile}`);
  } finally { fs.closeSync(log); fs.rmSync(readyFile, { force: true }); }
}

/** Works for Node source/builds and Bun's standalone executable. */
export function bridgeInvocation(): { executable: string; args: string[] } {
  const bundled = !!(globalThis as typeof globalThis & { Bun?: { isStandaloneExecutable?: boolean } }).Bun?.isStandaloneExecutable;
  if (bundled) return { executable: process.execPath, args: [] };
  const entry = fileURLToPath(new URL("../index.js", import.meta.url));
  const source = !fs.existsSync(entry);
  return { executable: process.execPath, args: [...(source && !process.versions.bun ? ["--import", import.meta.resolve("tsx")] : []),
    source ? entry.replace(/\.js$/, ".ts") : entry] };
}

export async function startBackground(file: string, options: { port?: number; tray?: boolean; debug?: boolean } = {}) {
  for (let attempt = 0; attempt < 100; attempt++) {
    const existing = await runningStatus(file);
    if (!existing) break;
    if (existing.state === "running") return existing;
    if (existing.state === "error") throw new Error("Bridge is in an error state. Fix the config and run codeaw-bridge restart.");
    if (attempt === 99) throw new Error("Existing bridge did not finish starting or stopping");
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  const home = path.dirname(file);
  fs.mkdirSync(home, { recursive: true });
  const logFile = path.join(home, "bridge.log");
  // Rotate before opening the inherited descriptor; no log contents enter the CLI response.
  if (fs.existsSync(logFile) && fs.statSync(logFile).size > 5 * 1024 * 1024) {
    fs.rmSync(logFile + ".1", { force: true });
    fs.renameSync(logFile, logFile + ".1");
  }
  const invocation = bridgeInvocation();
  const args = [...invocation.args, "start", "--headless", "--config", file];
  if (options.port !== undefined) args.push("--port", String(options.port));
  if (options.tray) args.push("--tray");
  if (options.debug) args.push("--debug");
  let error: Error | undefined;
  let exited = false;
  let brokerPid: number | undefined;
  if (process.platform === "win32") {
    brokerPid = await startWindowsBackground(invocation.executable, args, home, logFile);
  } else {
    const fd = fs.openSync(logFile, "a", 0o600);
    try {
      const child = spawn(invocation.executable, args, { cwd: home, detached: true, stdio: ["ignore", fd, fd] });
      child.once("error", (err) => { error = err; });
      child.once("exit", () => { exited = true; });
      child.unref();
    } finally { fs.closeSync(fd); }
  }
  for (let attempt = 0; attempt < 100; attempt++) {
    if (error) throw error;
    const status = await runningStatus(file);
    if (status?.state === "running") return status;
    if (brokerPid) { try { process.kill(brokerPid, 0); } catch { exited = true; } }
    if (exited) throw new Error(`Background bridge could not start. See ${logFile}`);
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`Background bridge startup timed out. See ${logFile}`);
}
