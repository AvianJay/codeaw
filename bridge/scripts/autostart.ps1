# Compatibility wrapper for the CLI's per-user login startup (no administrator rights required).
# Use -BridgePath for a standalone codeaw-bridge.exe; otherwise build bridge/dist first.
param([switch]$Remove, [string]$Config, [string]$BridgePath)
$ErrorActionPreference = 'Stop'
if ($BridgePath) {
    $executable = (Resolve-Path -LiteralPath $BridgePath).Path
    $bridgeArgs = @()
} else {
    $executable = (Get-Command node -ErrorAction Stop).Source
    $bridgeArgs = @((Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\dist\index.js')).Path)
}
$action = if ($Remove) { 'uninstall' } else { 'install' }
$bridgeArgs += @('autostart', $action)
if ($Config) { $bridgeArgs += @('--config', $Config) }
& $executable @bridgeArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
# Remove the old global task when migrating to login startup, preventing two launchers.
Unregister-ScheduledTask -TaskName 'codeaw-bridge' -Confirm:$false -ErrorAction SilentlyContinue
