param([ValidateSet('tray', 'settings', 'pair')][string]$Page = 'tray')
$ErrorActionPreference = 'Stop'
$bridge = Join-Path $PSScriptRoot 'codeaw-bridge.exe'
$stateDirectory = if ($env:CODEAW_HOME) { $env:CODEAW_HOME } else { Join-Path $env:USERPROFILE '.codeaw' }
New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
$log = Join-Path $stateDirectory 'desktop-launch.log'
$bridgeArgs = @($Page)
if ($Page -eq 'pair') { $bridgeArgs += '--window' }
& $bridge @bridgeArgs *>> $log
exit $LASTEXITCODE
