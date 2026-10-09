import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";
import { spawn, execFile } from "node:child_process";
import { promisify } from "node:util";
import { loadConfig } from "../config.js";
import { controlAddress } from "../desktop/control.js";
import { quoteWindowsArgument } from "../desktop/service.js";
import { setLoginStartup } from "../desktop/autostart.js";
import { desktopHelper } from "./native.js";
import { gatewayName, gatewayManifestPath, gatewayRegistration, type GatewayManifest } from "./gateway-config.js";

const execute = promisify(execFile);
export async function manageDesktopService(file: string, action: string): Promise<void> {
  if (process.platform !== "win32") throw new Error("進階桌面服務只支援 Windows");
  if (!["install", "uninstall", "enable", "disable", "status"].includes(action)) throw new Error("Usage: remote-desktop <install|uninstall|enable|disable|status>");
  const registered = gatewayRegistration(file);
  if (action === "status") { process.stdout.write(registered ? "Advanced desktop service registered\n" : "Advanced desktop service not installed\n"); return; }
  const loaded = loadConfig(file);
  if (action === "install" && loaded.config.listen.port === 0) throw new Error("進階服務需要固定連接埠，請先在電腦設定連接埠");
  const helper = desktopHelper() ?? registered?.helper;
  const gateway = [path.join(path.dirname(process.execPath), "codeaw-desktop-gateway.exe"), fileURLToPath(new URL("../../dist/bin/codeaw-desktop-gateway.exe", import.meta.url)), registered?.gateway].filter((p): p is string => !!p).find((p) => fs.existsSync(p));
  if (!helper || !gateway) throw new Error("請安裝含原生桌面元件的 Windows bridge release，或先執行 build:bin");
  const sid = (await execute("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", "[Security.Principal.WindowsIdentity]::GetCurrent().User.Value"], { windowsHide: true })).stdout.trim();
  if (!/^S-1-\d+(?:-\d+)+$/.test(sid)) throw new Error("Cannot determine the Windows owner");
  const name = gatewayName(file);
  const root = path.join(process.env.ProgramW6432 ?? process.env.ProgramFiles ?? "C:\\Program Files", "codeaw-desktop", name);
  if (registered && registered.ownerSid !== sid) throw new Error("請以安裝進階桌面服務的 Windows 帳號管理此設定");
  const manifest: GatewayManifest = (action === "enable" || action === "disable") && registered ? { ...registered, enabled: action === "enable" } : { name, configFile: path.resolve(file), home: loaded.home, ownerSid: sid,
    backendPipe: registered?.backendPipe ?? `\\\\.\\pipe\\codeaw-backend-${crypto.randomBytes(16).toString("hex")}`,
    port: loaded.config.listen.port, hosts: loaded.config.listen.hosts, gateway: path.join(root, "codeaw-desktop-gateway.exe"),
    helper: path.join(root, "codeaw-desktop.exe"), webRoot: path.join(root, "web"), enabled: true };
  const runtime = path.join(loaded.home, "runtime"); fs.mkdirSync(runtime, { recursive: true });
  const nonce = crypto.randomBytes(8).toString("hex");
  const request = path.join(runtime, `desktop-install-${nonce}.json`), script = path.join(runtime, `desktop-install-${nonce}.ps1`);
  const webSource = [path.join(path.dirname(gateway), "web"), fileURLToPath(new URL("../../dist/web", import.meta.url))].find((p) => fs.existsSync(path.join(p, "index.html")));
  if (action === "install" && !webSource) throw new Error("進階桌面服務需要 Web 資產，請使用完整 Windows release");
  fs.writeFileSync(request, JSON.stringify({ action, manifest, manifestFile: gatewayManifestPath(file), sourceHelper: helper, sourceGateway: gateway, webSource,
    helperHash: crypto.createHash("sha256").update(fs.readFileSync(helper)).digest("hex"),
    gatewayHash: crypto.createHash("sha256").update(fs.readFileSync(gateway)).digest("hex"), controlPipe: controlAddress(file) }));
  fs.writeFileSync(script, "\ufeff" + DESKTOP_INSTALL_SCRIPT);
  // Windows owns the elevation prompt; no Windows login password is handled here.
  const argumentsText = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-RequestFile", request].map(quoteWindowsArgument).join(" ");
  const bootstrap = `param([string]$Arguments)\n$ErrorActionPreference='Stop'\n$p=Start-Process -FilePath powershell.exe -ArgumentList $Arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru\nexit $p.ExitCode`;
  const launch = path.join(runtime, `desktop-elevate-${nonce}.ps1`); fs.writeFileSync(launch, bootstrap);
  try {
    await new Promise<void>((resolve, reject) => {
      const child = spawn("powershell.exe", ["-NoProfile", "-NonInteractive", "-File", launch, "-Arguments", argumentsText], { windowsHide: true, stdio: "ignore" });
      child.once("error", reject); child.once("exit", (code) => code === 0 ? resolve() : reject(new Error("進階桌面服務安裝未完成，原設定已保留")));
    });
    if (action === "install") await setLoginStartup(file, true);
  } finally { for (const p of [request, script, launch]) fs.rmSync(p, { force: true }); }
}

export const DESKTOP_INSTALL_SCRIPT = String.raw`
param([string]$RequestFile)
$ErrorActionPreference = 'Stop'
$r = Get-Content -LiteralPath $RequestFile -Raw -Encoding UTF8 | ConvertFrom-Json
$m = $r.manifest
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator access required' }
if ($m.name -notmatch '^CodeawDesktop-[0-9a-f]{16}$' -or $m.ownerSid -notmatch '^S-1-\d+(-\d+)+$') { throw 'Invalid desktop manifest' }
$root = Split-Path -Parent $m.helper
$programRoot = Join-Path $env:ProgramFiles 'codeaw-desktop'
$dataRoot = Join-Path $env:ProgramData 'codeaw-desktop'
function Assert-Within([string]$Target,[string]$Parent) {
    $targetPath = [IO.Path]::GetFullPath($Target)
    $parentPath = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    if (-not $targetPath.StartsWith($parentPath,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe desktop installation path' }
}
Assert-Within $root $programRoot
Assert-Within $r.manifestFile $dataRoot
if ((Split-Path -Leaf $root) -ne $m.name -or [IO.Path]::GetFullPath($m.helper) -ne (Join-Path $root 'codeaw-desktop.exe') -or [IO.Path]::GetFullPath($m.gateway) -ne (Join-Path $root 'codeaw-desktop-gateway.exe') -or [IO.Path]::GetFullPath($m.webRoot) -ne (Join-Path $root 'web')) { throw 'Desktop executables must use protected paths' }
if ([IO.Path]::GetFullPath($r.manifestFile) -ne (Join-Path (Join-Path $dataRoot $m.name) 'service.json')) { throw 'Invalid service configuration path' }
$stage = $root + '.next'; $backup = $root + '.previous'
Assert-Within $stage $programRoot
Assert-Within $backup $programRoot
$oldManifest = if (Test-Path -LiteralPath $r.manifestFile) { [IO.File]::ReadAllText($r.manifestFile) } else { $null }
function Activate-Backend {
    $pipeName = $r.controlPipe -replace '^\\\\\.\\pipe\\',''
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [IO.Pipes.PipeDirection]::InOut)
    try {
        try { $pipe.Connect(1500) } catch [TimeoutException] { return }
        $writer = [IO.StreamWriter]::new($pipe,[Text.UTF8Encoding]::new($false),1024,$true)
        $reader = [IO.StreamReader]::new($pipe,[Text.Encoding]::UTF8,$false,1024,$true)
        $writer.WriteLine('{"command":"activateDesktopGateway"}'); $writer.Flush()
        $read = $reader.ReadLineAsync(); if (-not $read.Wait(30000)) { throw 'Bridge migration timed out' }
        $response = $read.Result | ConvertFrom-Json
        if (-not $response.ok) { throw 'Bridge migration failed' }
    } finally { $pipe.Dispose() }
}
function Stop-Desktop {
    $service = Get-Service -Name $m.name -ErrorAction SilentlyContinue
    if ($service) {
        $serviceInfo = Get-CimInstance Win32_Service -Filter ("Name='" + $m.name + "'")
        $serviceProcess = if ($serviceInfo.ProcessId) { try { [Diagnostics.Process]::GetProcessById($serviceInfo.ProcessId) } catch { $null } } else { $null }
        try { Stop-Service -Name $m.name; $service.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(20)); if ($serviceProcess) { if (-not $serviceProcess.WaitForExit(10000)) { throw 'Desktop service process did not exit' } } }
        finally { if ($serviceProcess) { $serviceProcess.Dispose() } }
    }
}
function Secure-Directory([string]$Directory) {
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
    }
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($m.ownerSid),'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'))
    Set-Acl -LiteralPath $Directory -AclObject $acl
}
try {
    if ($r.action -eq 'enable' -or $r.action -eq 'disable') {
        if (-not $oldManifest) { throw 'Desktop service not installed' }
        Stop-Desktop
        [IO.File]::WriteAllText($r.manifestFile,($m | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        Start-Service -Name $m.name
        exit 0
    }
    if ($r.action -eq 'uninstall') {
        Stop-Desktop
        if (Get-Service -Name $m.name -ErrorAction SilentlyContinue) { & sc.exe delete $m.name | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'Service removal failed' } }
        if (Test-Path -LiteralPath $r.manifestFile) { Remove-Item -LiteralPath $r.manifestFile }
        Activate-Backend
        if (Test-Path -LiteralPath $root) { Assert-Within $root $programRoot; Remove-Item -LiteralPath $root -Recurse -Force }
        exit 0
    }
    if ($r.action -ne 'install') { throw 'Unknown desktop action' }
    if ((Get-FileHash -LiteralPath $r.sourceHelper -Algorithm SHA256).Hash.ToLower() -ne $r.helperHash -or (Get-FileHash -LiteralPath $r.sourceGateway -Algorithm SHA256).Hash.ToLower() -ne $r.gatewayHash) { throw 'Desktop payload changed' }
    New-Item -ItemType Directory -Force -Path $programRoot | Out-Null
    if (Test-Path -LiteralPath $stage) { Assert-Within $stage $programRoot; Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage | Out-Null
    Secure-Directory $stage
    Copy-Item -LiteralPath $r.sourceHelper -Destination (Join-Path $stage 'codeaw-desktop.exe')
    Copy-Item -LiteralPath $r.sourceGateway -Destination (Join-Path $stage 'codeaw-desktop-gateway.exe')
    if ((Get-FileHash -LiteralPath (Join-Path $stage 'codeaw-desktop.exe') -Algorithm SHA256).Hash.ToLower() -ne $r.helperHash -or (Get-FileHash -LiteralPath (Join-Path $stage 'codeaw-desktop-gateway.exe') -Algorithm SHA256).Hash.ToLower() -ne $r.gatewayHash) { throw 'Desktop payload changed during staging' }
    Copy-Item -LiteralPath $r.webSource -Destination (Join-Path $stage 'web') -Recurse
    Stop-Desktop
    if (Test-Path -LiteralPath $backup) { Assert-Within $backup $programRoot; Remove-Item -LiteralPath $backup -Recurse -Force }
    if (Test-Path -LiteralPath $root) { Move-Item -LiteralPath $root -Destination $backup }
    Move-Item -LiteralPath $stage -Destination $root
    $directory = Split-Path -Parent $r.manifestFile
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    Secure-Directory $directory
    [IO.File]::WriteAllText($r.manifestFile,($m | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $binary = '"' + $m.helper + '" --service "' + $r.manifestFile + '"'
    if (Get-Service -Name $m.name -ErrorAction SilentlyContinue) { & sc.exe config $m.name binPath= $binary start= auto | Out-Null }
    else { & sc.exe create $m.name binPath= $binary start= auto obj= LocalSystem DisplayName= 'codeaw remote desktop' | Out-Null }
    if ($LASTEXITCODE -ne 0) { throw 'Service registration failed' }
    & sc.exe failure $m.name reset= 86400 actions= restart/5000/restart/15000/restart/30000 | Out-Null
    & sc.exe failureflag $m.name 1 | Out-Null
    Activate-Backend
    Start-Service -Name $m.name
    $service = Get-Service -Name $m.name; $service.WaitForStatus('Running',[TimeSpan]::FromSeconds(20))
    # Do not override a domain policy or enable software SAS globally.
    if (Test-Path -LiteralPath $backup) { Assert-Within $backup $programRoot; Remove-Item -LiteralPath $backup -Recurse -Force }
} catch {
    try { Stop-Desktop } catch {}
    if (Test-Path -LiteralPath $backup) {
        if (Test-Path -LiteralPath $root) { Assert-Within $root $programRoot; Remove-Item -LiteralPath $root -Recurse -Force }
        Move-Item -LiteralPath $backup -Destination $root
    }
    if ($oldManifest) { [IO.File]::WriteAllText($r.manifestFile,$oldManifest,[Text.UTF8Encoding]::new($false)); try { Activate-Backend; Start-Service -Name $m.name } catch {} }
    else { if (Test-Path -LiteralPath $r.manifestFile) { Remove-Item -LiteralPath $r.manifestFile }; try { & sc.exe delete $m.name | Out-Null; Activate-Backend } catch {} }
    exit 1
}
`;
