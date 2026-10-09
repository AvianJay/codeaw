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
const INSTALL_STAGES = { elevation: "取得 Windows 權限", preflight: "檢查安裝環境", payload: "複製程式", configuration: "寫入服務設定",
  registration: "註冊 Windows 服務", recovery: "設定服務復原", migration: "切換 Bridge 連線", startup: "啟動服務", cleanup: "完成安裝" };
export function desktopServiceFailure(result: unknown): string {
  const value = result as { stage?: unknown; code?: unknown } | undefined;
  const stage = typeof value?.stage === "string" && Object.hasOwn(INSTALL_STAGES, value.stage)
    ? INSTALL_STAGES[value.stage as keyof typeof INSTALL_STAGES] : undefined;
  const code = Number.isSafeInteger(value?.code) ? `，錯誤碼 ${value!.code}` : "";
  return `進階桌面服務安裝未完成${stage ? `（${stage}${code}）` : ""}，原設定已保留`;
}

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
  const resultFile = path.join(runtime, `desktop-result-${nonce}.json`);
  const webSource = [path.join(path.dirname(gateway), "web"), fileURLToPath(new URL("../../dist/web", import.meta.url))].find((p) => fs.existsSync(path.join(p, "index.html")));
  if (action === "install" && !webSource) throw new Error("進階桌面服務需要 Web 資產，請使用完整 Windows release");
  fs.writeFileSync(request, JSON.stringify({ action, manifest, manifestFile: gatewayManifestPath(file), sourceHelper: helper, sourceGateway: gateway, webSource,
    helperHash: crypto.createHash("sha256").update(fs.readFileSync(helper)).digest("hex"),
    gatewayHash: crypto.createHash("sha256").update(fs.readFileSync(gateway)).digest("hex"), controlPipe: controlAddress(file) }));
  fs.writeFileSync(script, "\ufeff" + DESKTOP_INSTALL_SCRIPT);
  // Windows owns the elevation prompt; no Windows login password is handled here.
  const argumentsText = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-RequestFile", request, "-ResultFile", resultFile].map(quoteWindowsArgument).join(" ");
  const bootstrap = `param([string]$Arguments,[string]$ResultFile)\n$ErrorActionPreference='Stop'\ntry {\n$p=Start-Process -FilePath powershell.exe -ArgumentList $Arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru\nexit $p.ExitCode\n} catch {\n$code=$_.Exception.HResult; if ($_.Exception.InnerException -is [ComponentModel.Win32Exception]) { $code=$_.Exception.InnerException.NativeErrorCode }\n[IO.File]::WriteAllText($ResultFile,(@{ok=$false;stage='elevation';code=$code} | ConvertTo-Json),[Text.UTF8Encoding]::new($false))\nexit 1\n}`;
  const launch = path.join(runtime, `desktop-elevate-${nonce}.ps1`); fs.writeFileSync(launch, bootstrap);
  try {
    await new Promise<void>((resolve, reject) => {
      const child = spawn("powershell.exe", ["-NoProfile", "-NonInteractive", "-File", launch, "-Arguments", argumentsText, "-ResultFile", resultFile], { windowsHide: true, stdio: "ignore" });
      child.once("error", reject); child.once("exit", (code) => {
        let result: unknown;
        try { if (fs.statSync(resultFile).size < 4096) result = JSON.parse(fs.readFileSync(resultFile, "utf8")); } catch { /* Elevation may be cancelled before a receipt is written. */ }
        const value = result as { stage?: unknown; code?: unknown } | undefined;
        const stage = typeof value?.stage === "string" && Object.hasOwn(INSTALL_STAGES, value.stage) ? value.stage : "elevation";
        // Keep a sanitized receipt for support after temporary elevation files are removed.
        try { fs.writeFileSync(path.join(runtime, "desktop-service-result.json"), JSON.stringify({ action, ok: code === 0, stage,
          code: Number.isSafeInteger(value?.code) ? value!.code : code, time: new Date().toISOString() })); } catch { /* A receipt must not change the operation's outcome. */ }
        if (code === 0) return resolve();
        reject(new Error(desktopServiceFailure(result)));
      });
    });
    if (action === "install") await setLoginStartup(file, true);
  } finally { for (const p of [request, script, launch, resultFile]) fs.rmSync(p, { force: true }); }
}

export const DESKTOP_INSTALL_SCRIPT = String.raw`
param([string]$RequestFile,[string]$ResultFile)
$ErrorActionPreference = 'Stop'
$operationStage = 'preflight'
$operationCode = $null
$resultWritten = $false
$backendActivated = $false
function Write-OperationResult([bool]$Success,[object]$Failure = $null) {
    if (-not $ResultFile -or $script:resultWritten) { return }
    $code = $script:operationCode
    if ($null -eq $code -and $Failure) { $code = $Failure.Exception.HResult }
    # Only fixed stage identifiers and numeric OS codes cross the elevation boundary.
    [IO.File]::WriteAllText($ResultFile,(@{ok=$Success;stage=$script:operationStage;code=$code} | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $script:resultWritten = $true
}
trap { Write-OperationResult $false $_; exit 1 }
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
        $operationStage = 'configuration'
        Stop-Desktop
        [IO.File]::WriteAllText($r.manifestFile,($m | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        Start-Service -Name $m.name
        Write-OperationResult $true
        exit 0
    }
    if ($r.action -eq 'uninstall') {
        $operationStage = 'cleanup'
        Stop-Desktop
        if (Get-Service -Name $m.name -ErrorAction SilentlyContinue) { & sc.exe delete $m.name | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'Service removal failed' } }
        if (Test-Path -LiteralPath $r.manifestFile) { Remove-Item -LiteralPath $r.manifestFile }
        $backendActivated = $true; Activate-Backend
        if (Test-Path -LiteralPath $root) { Assert-Within $root $programRoot; Remove-Item -LiteralPath $root -Recurse -Force }
        Write-OperationResult $true; exit 0
    }
    if ($r.action -ne 'install') { throw 'Unknown desktop action' }
    $operationStage = 'payload'
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
    $operationStage = 'configuration'
    $directory = Split-Path -Parent $r.manifestFile
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    Secure-Directory $directory
    [IO.File]::WriteAllText($r.manifestFile,($m | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $binary = '"' + $m.helper + '" --service "' + $r.manifestFile + '"'
    $operationStage = 'registration'
    # PowerShell 5.1 strips embedded quotes when passing binPath to sc.exe.
    # Cmdlet/CIM parameters preserve the executable and manifest paths verbatim.
    if (Get-Service -Name $m.name -ErrorAction SilentlyContinue) {
        $existing = Get-CimInstance Win32_Service -Filter ("Name='" + $m.name + "'")
        $changed = Invoke-CimMethod -InputObject $existing -MethodName Change -Arguments @{PathName=$binary;StartMode='Automatic';StartName='LocalSystem'}
        if ($changed.ReturnValue -ne 0) { $operationCode = [int]$changed.ReturnValue; throw 'Service registration failed' }
    } else { New-Service -Name $m.name -BinaryPathName $binary -StartupType Automatic -DisplayName 'codeaw remote desktop' | Out-Null }
    $operationStage = 'recovery'
    & sc.exe failure $m.name reset= 86400 actions= restart/5000/restart/15000/restart/30000 | Out-Null
    if ($LASTEXITCODE -ne 0) { $operationCode = $LASTEXITCODE; throw 'Service recovery configuration failed' }
    & sc.exe failureflag $m.name 1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $operationCode = $LASTEXITCODE; throw 'Service recovery configuration failed' }
    $operationStage = 'migration'
    $backendActivated = $true; Activate-Backend
    $operationStage = 'startup'
    Start-Service -Name $m.name
    $service = Get-Service -Name $m.name; $service.WaitForStatus('Running',[TimeSpan]::FromSeconds(20))
    # Do not override a domain policy or enable software SAS globally.
    $operationStage = 'cleanup'
    if (Test-Path -LiteralPath $backup) { Assert-Within $backup $programRoot; Remove-Item -LiteralPath $backup -Recurse -Force }
    Write-OperationResult $true
} catch {
    Write-OperationResult $false $_
    try { Stop-Desktop } catch {}
    if (Test-Path -LiteralPath $backup) {
        if (Test-Path -LiteralPath $root) { Assert-Within $root $programRoot; Remove-Item -LiteralPath $root -Recurse -Force }
        Move-Item -LiteralPath $backup -Destination $root
    }
    if ($oldManifest) { [IO.File]::WriteAllText($r.manifestFile,$oldManifest,[Text.UTF8Encoding]::new($false)); try { if ($backendActivated) { Activate-Backend }; Start-Service -Name $m.name } catch {} }
    else { if (Test-Path -LiteralPath $r.manifestFile) { Remove-Item -LiteralPath $r.manifestFile }; try { & sc.exe delete $m.name | Out-Null; if ($backendActivated) { Activate-Backend } } catch {} }
    exit 1
}
`;
