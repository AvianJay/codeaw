param([int]$MinimumAgeHours = 24)
$ErrorActionPreference = 'Stop'
if ($MinimumAgeHours -lt 1) { throw 'MinimumAgeHours must be at least 1' }
$tempRoot = (Resolve-Path -LiteralPath ([System.IO.Path]::GetTempPath())).Path.TrimEnd([System.IO.Path]::DirectorySeparatorChar)
$activeDirectories = @{}
foreach ($agentProcess in @(Get-Process -Name agy_acp_server -ErrorAction SilentlyContinue)) {
    $modules = @($agentProcess.Modules)
    if ($modules.Count -eq 0) { throw 'Cannot verify active Antigravity extraction directories' }
    foreach ($module in $modules) {
        $directory = [System.IO.Path]::GetDirectoryName($module.FileName)
        while ($directory -and $directory.StartsWith($tempRoot + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            if ([System.IO.Path]::GetDirectoryName($directory) -eq $tempRoot -and [System.IO.Path]::GetFileName($directory) -match '^_MEI[0-9a-fA-F]+$') {
                $activeDirectories[$directory.ToLowerInvariant()] = $true
                break
            }
            $directory = [System.IO.Path]::GetDirectoryName($directory)
        }
    }
}
$removed = 0
$skipped = 0
$failed = 0
foreach ($entry in @(Get-ChildItem -LiteralPath $tempRoot -Directory -Filter '_MEI*')) {
    if ($entry.Name -notmatch '^_MEI[0-9a-fA-F]+$' -or ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { $skipped++; continue }
    $target = [System.IO.Path]::GetFullPath($entry.FullName)
    # Validate the final absolute path before every recursive removal.
    if ([System.IO.Path]::GetDirectoryName($target) -ne $tempRoot) { throw 'Unsafe cleanup target' }
    $marker = Join-Path $target 'agy_acp_licenses.txt'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or $entry.LastWriteTime -ge (Get-Date).AddHours(-$MinimumAgeHours) -or $activeDirectories.ContainsKey($target.ToLowerInvariant())) { $skipped++; continue }
    try {
        Remove-Item -LiteralPath $target -Recurse -Force
        $removed++
    } catch { $failed++ }
}
[pscustomobject]@{ Removed = $removed; Preserved = $skipped; Failed = $failed; ActiveDirectories = @($activeDirectories.Keys).Count } | ConvertTo-Json
