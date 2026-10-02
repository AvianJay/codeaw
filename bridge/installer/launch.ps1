param([ValidateSet('tray', 'settings', 'pair')][string]$Page = 'tray')
$ErrorActionPreference = 'Stop'
$bridge = Join-Path $PSScriptRoot 'codeaw-bridge.exe'
$stateDirectory = if ($env:CODEAW_HOME) { $env:CODEAW_HOME } else { Join-Path $env:USERPROFILE '.codeaw' }
New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
$log = Join-Path $stateDirectory 'desktop-launch.log'
$bridgeArgs = @($Page)
if ($Page -eq 'pair') { $bridgeArgs += '--window' }
& $bridge @bridgeArgs *>> $log
$bridgeExitCode = $LASTEXITCODE
if ($bridgeExitCode -ne 0) { exit $bridgeExitCode }

# Older standalone builds can lose the tray child when their CLI exits. Keep the
# installed shortcut usable by launching the generated desktop script from Windows.
$configFile = [IO.Path]::GetFullPath((Join-Path $stateDirectory 'config.yaml')).ToLowerInvariant()
$sha = [Security.Cryptography.SHA256]::Create()
try { $key = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($configFile))).Replace('-','').ToLowerInvariant()).Substring(0,24) }
finally { $sha.Dispose() }
$pipeName = 'codeaw-' + $key
$mutex = [Threading.Mutex]::new($false, ('Local\' + $pipeName + '-tray'))
try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
if ($owned) { $mutex.ReleaseMutex() }
$mutex.Dispose()
if ($owned) {
    $trayScript = Join-Path $stateDirectory 'runtime/tray.ps1'
    if (-not [IO.File]::Exists($trayScript)) { throw 'System tray script was not created' }
    $trayArgs = '-NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $trayScript + '" -PipeName ' + $pipeName
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -WindowStyle Hidden -ArgumentList $trayArgs | Out-Null
}
exit 0
