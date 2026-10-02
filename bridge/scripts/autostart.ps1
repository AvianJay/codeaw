# Registers (or removes) a Windows scheduled task that starts codeaw-bridge hidden at logon.
#   powershell -ExecutionPolicy Bypass -File scripts\autostart.ps1            # install
#   powershell -ExecutionPolicy Bypass -File scripts\autostart.ps1 -Remove    # uninstall
# Output goes to %USERPROFILE%\.codeaw\bridge.log.
param([switch]$Remove)

$TaskName = 'codeaw-bridge'
if ($Remove) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Output "Removed scheduled task $TaskName"
    return
}

$entry = Join-Path $PSScriptRoot '..\dist\index.js' | Resolve-Path -ErrorAction Stop
$node = (Get-Command node -ErrorAction Stop).Source
$logDir = Join-Path $env:USERPROFILE '.codeaw'
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir 'bridge.log'

# PowerShell hides the console; the bridge keeps running after logon.
$command = "& '$node' '$entry' start *>> '$log'"
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"$command`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description 'codeaw bridge (remote Claude Code / Codex over Tailscale)' -Force | Out-Null
Write-Output "Registered scheduled task $TaskName (runs at logon). Start it now with: Start-ScheduledTask $TaskName"
Write-Output "Log: $log"
