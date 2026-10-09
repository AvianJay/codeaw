/** Use a cooked template so bundler Unicode escapes become characters, not PowerShell text. */
export const TRAY_SCRIPT = `
param([Parameter(Mandatory=$true)][string]$PipeName, [string]$ReadyFile, [string]$IconPath, [string]$LogFile)
$ErrorActionPreference = 'Stop'
try {
$script:mutex = [System.Threading.Mutex]::new($false, ('Local\\' + $PipeName + '-tray'))
try { $owned = $script:mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { $script:mutex.Dispose(); exit 0 }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$script:appIcon = if ([System.IO.Path]::GetExtension($IconPath) -eq '.ico') {
    [System.Drawing.Icon]::new($IconPath)
} else {
    [System.Drawing.Icon]::ExtractAssociatedIcon($IconPath)
}
$script:trayIcon = [System.Drawing.Icon]::new($script:appIcon, [System.Windows.Forms.SystemInformation]::SmallIconSize)

function Invoke-Control([string]$Command, [hashtable]$Fields = @{}) {
    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
    try {
        $pipe.Connect(1500)
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $writer = [System.IO.StreamWriter]::new($pipe, $utf8, 1024, $true)
        $reader = [System.IO.StreamReader]::new($pipe, $utf8, $false, 1024, $true)
        try {
            $Fields.command = $Command
            $writer.WriteLine(($Fields | ConvertTo-Json -Depth 8 -Compress))
            $writer.Flush()
            $read = $reader.ReadLineAsync()
            $timeout = if ($Command -eq 'installDesktopService' -or $Command -eq 'uninstallDesktopService') { 300000 } else { 15000 }
            if (-not $read.Wait($timeout)) { throw 'Bridge 回應逾時' }
            $response = $read.Result | ConvertFrom-Json
            if (-not $response.ok) { throw $response.error }
            return $response.result
        } finally { $writer.Dispose(); $reader.Dispose() }
    } finally { $pipe.Dispose() }
}

function Show-Error($ErrorRecord) {
    [System.Windows.Forms.MessageBox]::Show([string]$ErrorRecord, 'codeaw bridge', 'OK', 'Error') | Out-Null
}

function Show-App {
    try { $app = Invoke-Control 'app' } catch { Show-Error $_; return }
    $edge = Get-Command msedge.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if (-not $edge) {
        foreach ($folder in @('ProgramFilesX86', 'ProgramFiles', 'LocalApplicationData')) {
            $candidate = Join-Path ([Environment]::GetFolderPath($folder)) 'Microsoft\\Edge\\Application\\msedge.exe'
            if ([System.IO.File]::Exists($candidate)) { $edge = $candidate; break }
        }
    }
    try {
        if ($edge) { Start-Process -FilePath $edge -ArgumentList ('--app="' + $app.url + '"') }
        else { Start-Process -FilePath $app.url }
    } catch { Show-Error '無法開啟 App，請確認已安裝 Microsoft Edge 或預設瀏覽器。' }
}

function New-Window([string]$Title, [int]$Width, [int]$Height) {
    if ($script:window -and -not $script:window.IsDisposed) { $script:window.Close() }
    $script:page = $Title
    $script:window = [System.Windows.Forms.Form]::new()
    $script:window.Text = 'codeaw bridge · ' + $Title
    $script:window.ClientSize = [System.Drawing.Size]::new($Width, $Height)
    $script:window.StartPosition = 'CenterScreen'
    $script:window.AutoScaleDimensions = [System.Drawing.SizeF]::new(96, 96)
    $script:window.AutoScaleMode = 'Dpi'
    $script:window.FormBorderStyle = 'FixedDialog'
    $script:window.MaximizeBox = $false
    $script:window.Font = [System.Drawing.Font]::new('Microsoft JhengHei UI', 10)
    $script:window.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
    $script:window.Icon = $script:appIcon
    return $script:window
}

function Add-Label($Form, [string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height) {
    $label = [System.Windows.Forms.Label]::new()
    $label.Text = $Text
    $label.Location = [System.Drawing.Point]::new($X, $Y)
    $label.Size = [System.Drawing.Size]::new($Width, $Height)
    $Form.Controls.Add($label)
    return $label
}

function Add-Button($Form, [string]$Text, [int]$X, [int]$Y, [int]$Width, $Click) {
    $button = [System.Windows.Forms.Button]::new()
    $button.Text = $Text
    $button.Location = [System.Drawing.Point]::new($X, $Y)
    $button.Size = [System.Drawing.Size]::new($Width, 34)
    $button.Add_Click($Click)
    $Form.Controls.Add($button)
    return $button
}

function Refresh-Pair {
    try {
        $script:pair = Invoke-Control 'pair'
        $script:pairCompleted = $false
        $bytes = [Convert]::FromBase64String(($script:pair.qr -split ',', 2)[1])
        $stream = [System.IO.MemoryStream]::new($bytes, 0, $bytes.Length)
        try {
            $source = [System.Drawing.Image]::FromStream($stream)
            try { $image = [System.Drawing.Bitmap]::new($source) } finally { $source.Dispose() }
        } finally { $stream.Dispose() }
        if ($script:qr.Image) { $script:qr.Image.Dispose() }
        $script:qr.Image = $image
        $script:qr.Visible = $true
        $script:pairCode.Text = $script:pair.code
        $script:pairUrl.Text = $script:pair.urls[0]
        $script:pairMessage.Text = '使用手機 codeaw App 掃描 QR code'
    } catch { Show-Error $_ }
}

function Show-Pair {
    $form = New-Window '配對手機' 440 568
    (Add-Label $form '連接這台電腦' 24 18 390 30).Font = [System.Drawing.Font]::new('Microsoft JhengHei UI', 16, [System.Drawing.FontStyle]::Bold)
    $script:pairMessage = Add-Label $form '使用手機 codeaw App 掃描 QR code' 24 58 390 28
    $script:qr = [System.Windows.Forms.PictureBox]::new()
    $script:qr.Location = [System.Drawing.Point]::new(60, 90)
    $script:qr.Size = [System.Drawing.Size]::new(320, 320)
    $script:qr.SizeMode = 'Zoom'
    $form.Controls.Add($script:qr)
    $script:pairCode = [System.Windows.Forms.TextBox]::new()
    $script:pairCode.Location = [System.Drawing.Point]::new(110, 422)
    $script:pairCode.Size = [System.Drawing.Size]::new(220, 40)
    $script:pairCode.Font = [System.Drawing.Font]::new('Consolas', 20, [System.Drawing.FontStyle]::Bold)
    $script:pairCode.TextAlign = 'Center'
    $script:pairCode.ReadOnly = $true
    $form.Controls.Add($script:pairCode)
    $script:pairUrl = [System.Windows.Forms.TextBox]::new()
    $script:pairUrl.Location = [System.Drawing.Point]::new(24, 472)
    $script:pairUrl.Size = [System.Drawing.Size]::new(392, 28)
    $script:pairUrl.ReadOnly = $true
    $form.Controls.Add($script:pairUrl)
    Add-Button $form '產生新配對碼' 24 516 150 { Refresh-Pair } | Out-Null
    Add-Button $form '複製網址與配對碼' 190 516 226 {
        if ($script:pair -and -not $script:pairCompleted -and [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -lt $script:pair.expiresAt) {
            [System.Windows.Forms.Clipboard]::SetText($script:pair.urls[0] + [Environment]::NewLine + $script:pair.code)
        }
    } | Out-Null
    $form.Add_FormClosed({ if ($script:qr.Image) { $script:qr.Image.Dispose(); $script:qr.Image = $null } })
    Refresh-Pair
    $form.Show()
    $form.Activate()
}

function Add-Number($Form, [string]$Text, [int]$Y, [int]$Maximum, [int]$Value, [int]$Minimum = 1) {
    Add-Label $Form $Text 24 $Y 290 28 | Out-Null
    $number = [System.Windows.Forms.NumericUpDown]::new()
    $number.Location = [System.Drawing.Point]::new(344, $Y - 2)
    $number.Size = [System.Drawing.Size]::new(140, 28)
    $number.Minimum = $Minimum
    $number.Maximum = $Maximum
    $number.Value = [Math]::Max($Minimum, [Math]::Min($Maximum, $Value))
    $Form.Controls.Add($number)
    return $number
}

function Show-Settings {
    try { $script:settings = Invoke-Control 'settings' } catch { Show-Error $_; return }
    $settingsHeight = [Math]::Min(806, [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height - 80)
    $form = New-Window '設定' 508 $settingsHeight
    $form.AutoScroll = $true
    $form.AutoScrollMinSize = [System.Drawing.Size]::new(490, 806)
    (Add-Label $form 'Bridge 設定' 24 18 460 30).Font = [System.Drawing.Font]::new('Microsoft JhengHei UI', 16, [System.Drawing.FontStyle]::Bold)
    $script:port = Add-Number $form '連接埠（0 = 自動分配）' 70 65535 $script:settings.port 0
    $script:sessionIdle = Add-Number $form '閒置對話釋放時間（分鐘）' 110 10080 $script:settings.idleSessionCloseMinutes
    $script:agentIdle = Add-Number $form '閒置 agent 停止時間（分鐘）' 150 10080 $script:settings.idleAgentStopMinutes
    Add-Label $form '工作目錄（每行一個完整路徑）' 24 196 460 28 | Out-Null
    $script:folders = [System.Windows.Forms.TextBox]::new()
    $script:folders.Location = [System.Drawing.Point]::new(24, 228)
    $script:folders.Size = [System.Drawing.Size]::new(460, 126)
    $script:folders.Multiline = $true
    $script:folders.ScrollBars = 'Vertical'
    $script:folders.Text = $script:settings.workspaces -join [Environment]::NewLine
    $form.Controls.Add($script:folders)
    $script:allPaths = [System.Windows.Forms.CheckBox]::new()
    $script:allPaths.Text = '允許已配對裝置瀏覽所有磁碟與資料夾'
    $script:allPaths.Location = [System.Drawing.Point]::new(24, 366)
    $script:allPaths.Size = [System.Drawing.Size]::new(460, 28)
    $script:allPaths.Checked = [bool]$script:settings.allowAllPaths
    $form.Controls.Add($script:allPaths)
    Add-Label $form '啟用後所有已配對裝置可存取此 Windows 帳號可讀取的檔案。這不是沙箱；只配對你信任的裝置。' 24 396 460 48 | Out-Null
    Add-Label $form '啟用的 agents' 24 448 460 28 | Out-Null
    $script:agents = [System.Windows.Forms.CheckedListBox]::new()
    $script:agents.Location = [System.Drawing.Point]::new(24, 478)
    $script:agents.Size = [System.Drawing.Size]::new(460, 94)
    $script:agents.CheckOnClick = $true
    foreach ($agent in $script:settings.agents) { $script:agents.Items.Add($agent.name + ' (' + $agent.id + ')', [bool]$agent.enabled) | Out-Null }
    $form.Controls.Add($script:agents)
    $script:remoteDesktop = [System.Windows.Forms.CheckBox]::new()
    $script:remoteDesktop.Text = '允許已配對裝置操作遠端桌面'
    $script:remoteDesktop.Location = [System.Drawing.Point]::new(24, 626)
    $script:remoteDesktop.Size = [System.Drawing.Size]::new(460, 28)
    $script:remoteDesktop.Checked = [bool]$script:settings.remoteDesktopEnabled -or [bool]$script:settings.advancedDesktopInstalled
    $script:remoteDesktop.Enabled = -not [bool]$script:settings.advancedDesktopInstalled
    $form.Controls.Add($script:remoteDesktop)
    $advancedLabel = if ($script:settings.advancedDesktopInstalled) { '解除進階桌面服務…' } else { '安裝進階桌面服務…' }
    Add-Button $form $advancedLabel 24 666 220 {
        try {
            $command = if ($script:settings.advancedDesktopInstalled) { 'uninstallDesktopService' } else { 'installDesktopService' }
            Invoke-Control $command | Out-Null
            $script:window.Close()
            Show-Settings
        } catch { Show-Error $_ }
    } | Out-Null
    Add-Label $form '進階服務可在登入前連線，並操作解鎖與 UAC；需 Windows 管理員授權。' 24 706 460 32 | Out-Null
    Add-Button $form '安裝 ACP agent…' 24 750 160 { Show-AgentInstaller } | Out-Null
    Add-Label $form '儲存會重新啟動 bridge，正在執行的回合將中止。' 24 592 460 28 | Out-Null
    Add-Button $form '取消' 194 750 100 { $script:window.Close() } | Out-Null
    Add-Button $form '儲存並重新啟動' 304 750 180 {
        if ([System.Windows.Forms.MessageBox]::Show('套用設定並重新啟動 bridge？正在執行的回合將中止。', '套用設定', 'OKCancel', 'Question') -ne 'OK') { return }
        $enabled = @{}
        for ($i = 0; $i -lt @($script:settings.agents).Count; $i++) { $enabled[$script:settings.agents[$i].id] = $script:agents.GetItemChecked($i) }
        $folders = @($script:folders.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $settings = @{ port = [int]$script:port.Value; workspaces = $folders; allowAllPaths = [bool]$script:allPaths.Checked; agents = $enabled; remoteDesktopEnabled = [bool]$script:remoteDesktop.Checked;
            idleSessionCloseMinutes = [int]$script:sessionIdle.Value; idleAgentStopMinutes = [int]$script:agentIdle.Value }
        try { Invoke-Control 'saveSettings' @{ settings = $settings } | Out-Null; $script:window.Close() }
        catch { Show-Error $_ }
    } | Out-Null
    $form.Show()
    $form.Activate()
}

function Update-AgentSelection {
    $agent = $script:catalogList.SelectedItem
    if (-not $agent) { $script:installButton.Enabled = $false; return }
    $availability = if ($agent.supported) {
        switch ($agent.kind) { 'npx' { '需要 Node.js 與 npm' }; 'uvx' { '需要 uv' }; 'binary' { '直接下載執行檔' } }
    } else { '不支援這台電腦：' + $agent.target }
    $configured = if ($agent.configured) { ' · 已加入設定' } else { '' }
    $script:agentDescription.Text = $agent.name + ' · ' + $agent.version + $configured + [Environment]::NewLine + $availability + [Environment]::NewLine + $agent.description
    $script:installButton.Text = if ($agent.configured) { '重新安裝 / 更新' } else { '安裝' }
    $script:installButton.Enabled = $agent.supported -and -not $script:installBusy
}

function Refresh-AgentCatalog([bool]$Refresh = $false) {
    $selectedId = if ($script:catalogList.SelectedItem) { $script:catalogList.SelectedItem.id } else { $null }
    $script:catalogList.Items.Clear()
    foreach ($agent in @(Invoke-Control 'agentCatalog' @{ refresh = $Refresh })) { $script:catalogList.Items.Add($agent) | Out-Null }
    if ($script:catalogList.Items.Count) { $script:catalogList.SelectedIndex = 0 }
    for ($i = 0; $i -lt $script:catalogList.Items.Count; $i++) {
        if ($script:catalogList.Items[$i].id -eq $selectedId) { $script:catalogList.SelectedIndex = $i; break }
    }
}

function Show-AgentInstaller {
    $form = New-Window '安裝 ACP agents' 640 564
    (Add-Label $form '安裝 ACP agents' 24 18 592 30).Font = [System.Drawing.Font]::new('Microsoft JhengHei UI', 16, [System.Drawing.FontStyle]::Bold)
    Add-Label $form '從 ACP registry 選擇 agent，安裝後重新啟動 bridge 即可使用。' 24 58 592 28 | Out-Null
    $script:catalogList = [System.Windows.Forms.ListBox]::new()
    $script:catalogList.Location = [System.Drawing.Point]::new(24, 94)
    $script:catalogList.Size = [System.Drawing.Size]::new(592, 220)
    $script:catalogList.DisplayMember = 'name'
    $script:catalogList.Add_SelectedIndexChanged({ Update-AgentSelection })
    $form.Controls.Add($script:catalogList)
    $script:agentDescription = Add-Label $form '' 24 328 592 104
    $script:installMessage = Add-Label $form '正在載入 ACP registry…' 24 444 592 44
    $script:installBusy = $false
    $script:lastInstallState = 'idle'
    $script:installButton = Add-Button $form '安裝' 466 506 150 {
        $agent = $script:catalogList.SelectedItem
        if (-not $agent) { return }
        try {
            $result = Invoke-Control 'installAgent' @{ id = $agent.id }
            $script:installBusy = $result.state -eq 'installing'
            $script:installMessage.Text = $result.message
            Update-AgentSelection
        } catch { $script:installMessage.Text = [string]$_ }
    }
    $script:installButton.Enabled = $false
    Add-Button $form '重新整理' 24 506 120 {
        try { Refresh-AgentCatalog $true; $script:installMessage.Text = '' } catch { $script:installMessage.Text = [string]$_ }
    } | Out-Null
    Add-Button $form '返回設定' 158 506 120 { Show-Settings } | Out-Null
    $script:installRestart = Add-Button $form '重新啟動 bridge' 292 506 160 {
        if ([System.Windows.Forms.MessageBox]::Show('重新啟動 bridge 以套用 agent？正在執行的回合將中止。', '套用 agent', 'OKCancel', 'Question') -ne 'OK') { return }
        try { Invoke-Control 'restart' | Out-Null; Show-Settings } catch { Show-Error $_ }
    }
    $script:installRestart.Enabled = $false
    $form.Show()
    $form.Activate()
    try { Refresh-AgentCatalog; $script:installMessage.Text = '' } catch { $script:installMessage.Text = [string]$_ }
}

function Refresh-Devices {
    $script:devices.Items.Clear()
    foreach ($device in @(Invoke-Control 'devices')) {
        $item = [System.Windows.Forms.ListViewItem]::new([string]$device.name)
        $item.Tag = $device.id
        $item.SubItems.Add([string]$device.createdAt) | Out-Null
        $item.SubItems.Add([string]$device.lastSeenAt) | Out-Null
        $script:devices.Items.Add($item) | Out-Null
    }
}

function Show-Devices {
    $form = New-Window '已配對裝置' 620 356
    Add-Label $form '已配對裝置' 24 18 570 30 | Out-Null
    $script:devices = [System.Windows.Forms.ListView]::new()
    $script:devices.Location = [System.Drawing.Point]::new(24, 58)
    $script:devices.Size = [System.Drawing.Size]::new(572, 226)
    $script:devices.View = 'Details'
    $script:devices.FullRowSelect = $true
    $script:devices.MultiSelect = $false
    $script:devices.Columns.Add('名稱', 160) | Out-Null
    $script:devices.Columns.Add('配對時間', 198) | Out-Null
    $script:devices.Columns.Add('最後連線', 198) | Out-Null
    $form.Controls.Add($script:devices)
    Add-Button $form '重新整理' 24 304 120 { try { Refresh-Devices } catch { Show-Error $_ } } | Out-Null
    Add-Button $form '撤銷選取裝置' 426 304 170 {
        if (-not $script:devices.SelectedItems.Count) { return }
        $selected = $script:devices.SelectedItems[0]
        if ([System.Windows.Forms.MessageBox]::Show('撤銷 ' + $selected.Text + '？下次連線需要重新配對。', '撤銷裝置', 'OKCancel', 'Question') -ne 'OK') { return }
        try { Invoke-Control 'revoke' @{ id = $selected.Tag } | Out-Null; Refresh-Devices } catch { Show-Error $_ }
    } | Out-Null
    try { Refresh-Devices } catch { Show-Error $_ }
    $form.Show()
    $form.Activate()
}

function Refresh-Updater {
    $script:update = Invoke-Control 'updaterStatus'
    $busy = $script:update.state -in @('checking', 'downloading')
    $script:updateChannel.Enabled = -not $busy
    $script:updateCheck.Enabled = -not $busy
    $script:updateDownload.Enabled = (-not $busy) -and $script:update.updateAvailable
    $script:updateInstall.Enabled = (-not $busy) -and $script:update.canInstall -and $script:update.updateAvailable
    $script:updateInstalled.Text = '目前版本：' + $script:update.installedVersion + ' · ' + $script:update.buildChannel + ' · ' + $script:update.target
    $script:updateMessage.Text = $script:update.message
    $script:updateProgress.Visible = $script:update.state -eq 'downloading'
    if ($script:update.progress) { $script:updateProgress.Value = [Math]::Min(100, [int]($script:update.progress * 100)) }
    $script:updateInstall.Text = if ($script:update.state -eq 'ready' -and $script:update.kind -eq 'installer') { '執行安裝程式' } else { '下載更新並驗證' }
}

function Show-Updater {
    $form = New-Window 'Bridge 更新' 660 388
    $script:updateInstalled = Add-Label $form '' 24 24 612 28
    Add-Label $form '更新頻道' 24 67 92 28 | Out-Null
    $script:updateChannel = [System.Windows.Forms.ComboBox]::new()
    $script:updateChannel.Location = [System.Drawing.Point]::new(120, 64)
    $script:updateChannel.Size = [System.Drawing.Size]::new(184, 28)
    $script:updateChannel.DropDownStyle = 'DropDownList'
    $script:updateChannel.Items.AddRange(@('release', 'nightly'))
    $form.Controls.Add($script:updateChannel)
    $script:updateMessage = Add-Label $form '' 24 112 612 100
    $script:updateMessage.AutoEllipsis = $true
    $script:updateProgress = [System.Windows.Forms.ProgressBar]::new()
    $script:updateProgress.Location = [System.Drawing.Point]::new(24, 218)
    $script:updateProgress.Size = [System.Drawing.Size]::new(612, 20)
    $form.Controls.Add($script:updateProgress)
    Add-Label $form '更新會中止執行中的回合。設定與配對裝置會保留。' 24 254 612 28 | Out-Null
    $script:updateCheck = Add-Button $form '檢查更新' 24 304 120 {
        try { Invoke-Control 'checkUpdate' | Out-Null; Refresh-Updater } catch { Show-Error $_ }
    }
    $script:updateDownload = Add-Button $form '下載可攜版' 160 304 136 {
        try { Invoke-Control 'prepareBridgeUpdate' @{ kind = 'portable' } | Out-Null; Refresh-Updater } catch { Show-Error $_ }
    }
    $script:updateInstall = Add-Button $form '下載更新並驗證' 312 304 160 {
        try {
            if ($script:update.state -eq 'ready' -and $script:update.kind -eq 'installer') {
                if ([System.Windows.Forms.MessageBox]::Show('安裝 bridge 更新？安裝時執行中的回合將中止。', 'Bridge 更新', 'OKCancel', 'Question') -ne 'OK') { return }
                $installer = Invoke-Control 'bridgeUpdateInstaller'
                Start-Process -FilePath $installer.file -ArgumentList ('/D=' + $installer.directory)
                if ($installer.stopCustomProfile) { Invoke-Control 'stop' | Out-Null }
                $script:window.Close()
            } else { Invoke-Control 'prepareBridgeUpdate' @{ kind = 'installer' } | Out-Null; Refresh-Updater }
        } catch { Show-Error $_ }
    }
    Add-Button $form '版本說明' 488 304 148 {
        try { Start-Process -FilePath $script:update.releaseUrl } catch { Show-Error $_ }
    } | Out-Null
    try {
        $initial = Invoke-Control 'updaterStatus'
        $script:updateChannel.SelectedItem = $initial.channel
        $script:updateChannel.Add_SelectedIndexChanged({
            try {
                Invoke-Control 'setUpdateChannel' @{ channel = [string]$script:updateChannel.SelectedItem } | Out-Null
                Invoke-Control 'checkUpdate' | Out-Null
                Refresh-Updater
            } catch { Show-Error $_ }
        })
        if ($initial.state -eq 'idle') { Invoke-Control 'checkUpdate' | Out-Null }
        Refresh-Updater
    } catch { Show-Error $_ }
    $form.Show()
    $form.Activate()
}

$script:tray = [System.Windows.Forms.NotifyIcon]::new()
$script:tray.Icon = $script:trayIcon
$script:tray.Text = 'codeaw bridge'
$menu = [System.Windows.Forms.ContextMenuStrip]::new()
$script:statusItem = $menu.Items.Add('Bridge 啟動中…')
$script:statusItem.Enabled = $false
$menu.Items.Add('-') | Out-Null
$menu.Items.Add('開啟 App').Add_Click({ Show-App })
$menu.Items.Add('配對手機…').Add_Click({ Show-Pair })
$menu.Items.Add('設定…').Add_Click({ Show-Settings })
$menu.Items.Add('已配對裝置…').Add_Click({ Show-Devices })
$menu.Items.Add('安裝 ACP agents…').Add_Click({ Show-AgentInstaller })
$menu.Items.Add('Bridge 更新…').Add_Click({ Show-Updater })
$script:startupItem = $menu.Items.Add('登入後自動啟動系統匣')
$script:startupItem.Add_Click({
    try {
        $result = Invoke-Control 'setAutostart' @{ enabled = (-not $script:startupItem.Checked) }
        $script:startupItem.Checked = $result.enabled
    } catch { Show-Error $_ }
})
$menu.Add_Opening({
    try { $script:startupItem.Checked = (Invoke-Control 'autostart').enabled } catch { $script:startupItem.Checked = $false }
})
$menu.Items.Add('開啟日誌').Add_Click({
    try {
        $status = Invoke-Control 'status'
        if (-not [System.IO.File]::Exists($status.logFile)) { [System.IO.File]::WriteAllText($status.logFile, '') }
        Start-Process notepad.exe -ArgumentList ('"' + $status.logFile + '"')
    } catch { Show-Error $_ }
})
$menu.Items.Add('重新啟動 bridge').Add_Click({
    if ([System.Windows.Forms.MessageBox]::Show('重新啟動 bridge？正在執行的回合將中止。', '重新啟動', 'OKCancel', 'Question') -eq 'OK') {
        try { Invoke-Control 'restart' | Out-Null } catch { Show-Error $_ }
    }
})
$menu.Items.Add('-') | Out-Null
$menu.Items.Add('關閉系統匣（繼續背景運行）').Add_Click({ [System.Windows.Forms.Application]::Exit() })
$menu.Items.Add('停止 bridge 並退出').Add_Click({
    if ([System.Windows.Forms.MessageBox]::Show('停止 bridge？正在執行的回合將中止。', '停止 bridge', 'OKCancel', 'Question') -eq 'OK') {
        try { Invoke-Control 'stop' | Out-Null; [System.Windows.Forms.Application]::Exit() } catch { Show-Error $_ }
    }
})
$script:tray.ContextMenuStrip = $menu
$script:tray.Add_DoubleClick({ Show-App })
$script:tray.Visible = $true
$script:failures = 0
$script:timer = [System.Windows.Forms.Timer]::new()
$script:timer.Interval = 2000
$script:timer.Add_Tick({
    try {
        $status = Invoke-Control 'poll'
        $script:failures = 0
        $script:statusItem.Text = 'Bridge ' + $status.state + ' · ' + $status.clients + ' 台連線 · :' + $status.port
        $script:tray.Text = 'codeaw bridge · ' + $status.state + ' · ' + $status.clients + ' connected'
        switch ($status.page) { 'pair' { Show-Pair }; 'settings' { Show-Settings }; 'devices' { Show-Devices }; 'agents' { Show-AgentInstaller }; 'updates' { Show-Updater } }
        if ($script:page -eq 'Bridge 更新' -and $script:window -and -not $script:window.IsDisposed) { Refresh-Updater }
        if ($script:page -eq '安裝 ACP agents' -and $script:window -and -not $script:window.IsDisposed) {
            $install = Invoke-Control 'installerStatus'
            $script:installBusy = $install.state -eq 'installing'
            if ($install.state -eq 'succeeded' -and $script:lastInstallState -ne 'succeeded') { Refresh-AgentCatalog }
            $script:lastInstallState = $install.state
            if ($install.state -ne 'idle') { $script:installMessage.Text = $install.message }
            $script:installRestart.Enabled = $install.state -eq 'succeeded'
            Update-AgentSelection
        }
        if ($script:page -eq '配對手機' -and $script:window -and -not $script:window.IsDisposed -and $script:pair) {
            if ($script:pair.port -ne $status.port -and $status.state -eq 'running') { Refresh-Pair }
            $remaining = [Math]::Ceiling(($script:pair.expiresAt - [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) / 1000)
            if ($script:pairCompleted) {
                $script:pairMessage.Text = '配對成功！可關閉此視窗並開始使用手機 App'
            } elseif ($remaining -le 0) {
                $script:pairMessage.Text = '配對碼已過期，請產生新配對碼'
                $script:qr.Visible = $false
                $script:pairCode.Text = '已過期'
            } elseif (-not (Invoke-Control 'pairingStatus' @{ code = $script:pair.code }).pending) {
                $script:pairCompleted = $true
                $script:pairMessage.Text = '配對成功！可關閉此視窗並開始使用手機 App'
                $script:qr.Visible = $false
                $script:pairCode.Text = '已配對'
            } else { $script:pairMessage.Text = '配對碼有效時間：' + $remaining + ' 秒（只能使用一次）' }
        }
    } catch {
        $script:failures++
        $script:statusItem.Text = 'Bridge 已離線'
        if ($script:failures -ge 3) { [System.Windows.Forms.Application]::Exit() }
    }
})
try {
    $script:timer.Start()
    if ($ReadyFile) { [IO.File]::WriteAllText($ReadyFile, ('{"pid":' + $PID + '}')) }
    [System.Windows.Forms.Application]::Run()
} finally {
    $script:timer.Stop()
    $script:timer.Dispose()
    if ($script:window -and -not $script:window.IsDisposed) { $script:window.Dispose() }
    $script:tray.Visible = $false
    $script:tray.Dispose()
    $menu.Dispose()
    $script:trayIcon.Dispose()
    $script:appIcon.Dispose()
    $script:mutex.ReleaseMutex()
    $script:mutex.Dispose()
    if ($ReadyFile -and [IO.File]::Exists($ReadyFile)) { [IO.File]::Delete($ReadyFile) }
}
} catch {
    if ($LogFile) { [IO.File]::AppendAllText($LogFile, ([DateTime]::UtcNow.ToString('o') + ' Tray failed: ' + $_.Exception.Message + [Environment]::NewLine)) }
    else { [Console]::Error.WriteLine($_.Exception.Message) }
    exit 1
}
`;
