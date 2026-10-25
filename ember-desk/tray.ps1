#Requires -Version 7
<#
.SYNOPSIS
  炉灵 托盘程序（WinForms NotifyIcon），守护进程 HTTP API 的轻客户端。
.PARAMETER SelfTest
  构建图标与完整菜单、查询守护进程（若可达；未加 -NoDaemon 时会尝试启动），
  输出 JSON 摘要后以 0 退出，不进入消息循环。
.PARAMETER NoDaemon
  不自动启动守护进程。
#>
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$NoDaemon
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:Dir = $PSScriptRoot
$script:StateDir = if ($env:EMBER_DESK_HOME) { $env:EMBER_DESK_HOME } else { Join-Path $env:APPDATA 'ember-desk' }
$script:RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:RunName = 'EmberDesk'
$script:BalloonKinds = @('meeting_joined', 'meeting_ended', 'meeting_failed', 'released')

$script:Status = $null          # 最近一次 /status 结果（$null = 不可达）
$script:Channels = @()
$script:Feed = @()
$script:LastSeenAt = $null      # 已展示过的最新 feed 时间（毫秒）
$script:Polling = $false
$script:Notify = $null
$script:Ctx = $null
$script:Exiting = $false

# ---------------------------------------------------------------- 基础工具

function Get-Conn {
    $statePath = Join-Path $script:StateDir 'state.json'
    $tokenPath = Join-Path $script:StateDir 'token'
    if (-not (Test-Path -LiteralPath $statePath) -or -not (Test-Path -LiteralPath $tokenPath)) { return $null }
    try {
        $st = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json
        $tok = (Get-Content -LiteralPath $tokenPath -Raw -Encoding utf8).Trim()
        if (-not $st.port -or -not $tok) { return $null }
        return [pscustomobject]@{ Port = [int]$st.port; Pid = [int]$st.pid; Token = $tok; Base = "http://127.0.0.1:$($st.port)" }
    } catch { return $null }
}

function Get-ApiErrorText {
    param($Err)
    $msg = $null
    try {
        $body = $Err.ErrorDetails.Message
        if ($body) {
            $j = $body | ConvertFrom-Json -ErrorAction Stop
            if ($j.message) { $msg = [string]$j.message }
            elseif ($j.error) { $msg = [string]$j.error }
        }
    } catch {}
    if (-not $msg) {
        $code = $null
        try { $code = [int]$Err.Exception.Response.StatusCode } catch {}
        if ($code -eq 401) { $msg = '令牌无效（401）' }
        elseif ($code -eq 409) { $msg = '已在会议中' }
        elseif ($code) { $msg = "请求失败（HTTP $code）" }
        else { $msg = '无法连接 炉灵 守护进程' }
    }
    return $msg
}

# 返回 @{ Ok; Data; Error }
function Invoke-Api {
    param(
        [string]$Method = 'GET',
        [string]$Path,
        $Body = $null,
        [int]$TimeoutSec = 2
    )
    $c = Get-Conn
    if (-not $c) { return @{ Ok = $false; Data = $null; Error = '炉灵 未运行' } }
    $p = @{
        Method      = $Method
        Uri         = $c.Base + $Path
        Headers     = @{ Authorization = "Bearer $($c.Token)" }
        TimeoutSec  = $TimeoutSec
        ErrorAction = 'Stop'
    }
    if ($Method -ne 'GET') {
        $json = if ($null -ne $Body) { $Body | ConvertTo-Json -Compress -Depth 6 } else { '{}' }
        $p.Body = [System.Text.Encoding]::UTF8.GetBytes($json)
        $p.ContentType = 'application/json; charset=utf-8'
    }
    try {
        $data = Invoke-RestMethod @p
        return @{ Ok = $true; Data = $data; Error = $null }
    } catch {
        return @{ Ok = $false; Data = $null; Error = (Get-ApiErrorText $_) }
    }
}

function Test-Daemon {
    $r = Invoke-Api -Path '/status' -TimeoutSec 2
    if ($r.Ok -and $r.Data) { return $r.Data }
    return $null
}

function Start-Daemon {
    param([int]$WaitSec = 15)
    $existing = Test-Daemon
    if ($existing) { return $existing }
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { throw '找不到 node，请先安装 Node.js' }
    $daemon = Join-Path $script:Dir 'daemon.mjs'
    if (-not (Test-Path -LiteralPath $daemon)) { throw "找不到 $daemon" }
    Start-Process -WindowStyle Hidden -FilePath $node.Source -ArgumentList ('"' + $daemon + '"') -WorkingDirectory $script:Dir | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 400
        if (-not $SelfTest) { [System.Windows.Forms.Application]::DoEvents() }
        $s = Test-Daemon
        if ($s) { return $s }
    }
    return $null
}

function Get-AtMs {
    param($At)
    if ($null -eq $At) { return 0.0 }
    if ($At -is [datetime]) { return [double]([DateTimeOffset]$At.ToUniversalTime()).ToUnixTimeMilliseconds() }
    if ($At -is [DateTimeOffset]) { return [double]$At.ToUnixTimeMilliseconds() }
    if ($At -is [ValueType]) { try { return [double]$At } catch { return 0.0 } }
    $d = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$At, [ref]$d)) { return [double]$d.ToUnixTimeMilliseconds() }
    $n = 0.0
    if ([double]::TryParse([string]$At, [ref]$n)) { return $n }
    return 0.0
}

function Format-At {
    param($At)
    $ms = Get-AtMs $At
    if ($ms -le 0) { return '' }
    try { return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$ms).ToLocalTime().ToString('HH:mm') } catch { return '' }
}

function Limit-Text {
    param([string]$Text, [int]$Max)
    if ($null -eq $Text) { return '' }
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -le $Max) { return $t }
    return $t.Substring(0, [Math]::Max(0, $Max - 1)) + '…'
}

function Get-StatusLine {
    $s = $script:Status
    if (-not $s) { return '炉灵 · 未运行' }
    $room = $null
    if ($s.session) { $room = if ($s.session.room) { [string]$s.session.room } else { [string]$s.session.link } }
    switch ([string]$s.state) {
        'idle' { return '炉灵 · 空闲' }
        'joining' { return (Limit-Text "炉灵 · 正在加入 $room" 60) }
        'in-meeting' { return (Limit-Text "炉灵 · 会议中 $room" 60) }
        'leaving' { return '炉灵 · 正在离开会议' }
        default { return (Limit-Text "炉灵 · $($s.state)" 60) }
    }
}

function Get-ClipboardLink {
    try {
        if ([System.Windows.Forms.Clipboard]::ContainsText()) {
            $t = [System.Windows.Forms.Clipboard]::GetText().Trim()
            if ($t -match '^https://\S+$' -and $t.Length -le 2048) { return $t }
        }
    } catch {}
    return $null
}

function Test-Autostart {
    try {
        $v = (Get-ItemProperty -LiteralPath $script:RunKey -Name $script:RunName -ErrorAction Stop).$($script:RunName)
        return [bool]$v
    } catch { return $false }
}

function Set-Autostart {
    param([bool]$On)
    if ($On) {
        if (-not (Test-Path -LiteralPath $script:RunKey)) { New-Item -Path $script:RunKey -Force | Out-Null }
        $cmd = 'wscript.exe "' + (Join-Path $script:Dir 'start.vbs') + '"'
        Set-ItemProperty -LiteralPath $script:RunKey -Name $script:RunName -Value $cmd -Type String
    } else {
        Remove-ItemProperty -LiteralPath $script:RunKey -Name $script:RunName -ErrorAction SilentlyContinue
    }
}

function Show-Balloon {
    param([string]$Title, [string]$Text, [System.Windows.Forms.ToolTipIcon]$Icon = [System.Windows.Forms.ToolTipIcon]::Info)
    if ($SelfTest -or -not $script:Notify) { return }
    try {
        $t = if ($Title) { Limit-Text $Title 60 } else { '炉灵' }
        $x = if ($Text) { Limit-Text $Text 250 } else { ' ' }
        $script:Notify.ShowBalloonTip(5000, $t, $x, $Icon)
    } catch {}
}

function Invoke-Safe {
    param([scriptblock]$Action)
    try { & $Action } catch {
        try { Show-Balloon '炉灵' ("出错了：" + $_.Exception.Message) ([System.Windows.Forms.ToolTipIcon]::Warning) } catch {}
    }
}

# ---------------------------------------------------------------- 状态刷新

function Update-Data {
    param([switch]$WithFeed)
    $s = Test-Daemon
    $script:Status = $s
    if ($s) {
        $ch = Invoke-Api -Path '/channels'
        if ($ch.Ok -and $null -ne $ch.Data) { $script:Channels = @($ch.Data) }
        elseif ($s.channels) { $script:Channels = @($s.channels) }
        if ($WithFeed) {
            $f = Invoke-Api -Path '/feed?n=10'
            if ($f.Ok -and $null -ne $f.Data) { $script:Feed = @($f.Data) }
        }
    } else {
        $script:Channels = @()
    }
}

function Update-Tooltip {
    if (-not $script:Notify) { return }
    try { $script:Notify.Text = Limit-Text (Get-StatusLine) 63 } catch {}
}

function Invoke-Poll {
    if ($script:Polling -or $script:Exiting) { return }
    $script:Polling = $true
    try {
        Update-Data -WithFeed
        if ($script:Status -and $script:Feed.Count -gt 0) {
            $maxAt = $script:LastSeenAt
            $items = @($script:Feed)
            if ($null -eq $script:LastSeenAt) {
                # 首次：仅建立基线，不弹历史气泡
                foreach ($it in $items) { $a = Get-AtMs $it.at; if ($null -eq $maxAt -or $a -gt $maxAt) { $maxAt = $a } }
            } else {
                foreach ($it in $items) {
                    $a = Get-AtMs $it.at
                    if ($a -gt $script:LastSeenAt) {
                        if ($script:BalloonKinds -contains [string]$it.kind) {
                            $icon = if ($it.kind -eq 'meeting_failed') { [System.Windows.Forms.ToolTipIcon]::Warning } else { [System.Windows.Forms.ToolTipIcon]::Info }
                            Show-Balloon ([string]$it.title) ([string]$it.text) $icon
                        }
                        if ($a -gt $maxAt) { $maxAt = $a }
                    }
                }
            }
            $script:LastSeenAt = $maxAt
        } elseif ($script:Status -and $null -eq $script:LastSeenAt) {
            $script:LastSeenAt = 0.0
        }
        Update-Tooltip
    } catch {
        # 轮询永不抛出
    } finally { $script:Polling = $false }
}

# ---------------------------------------------------------------- 动作

function Show-JoinDialog {
    param([string]$Prefill)
    $form = [System.Windows.Forms.Form]::new()
    $form.Text = '炉灵 · 加入会议'
    $form.FormBorderStyle = 'FixedDialog'
    $form.StartPosition = 'CenterScreen'
    $form.MinimizeBox = $false; $form.MaximizeBox = $false
    $form.TopMost = $true
    $form.ClientSize = [System.Drawing.Size]::new(460, 120)
    $form.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 9)
    try { $form.Icon = $script:IconObj } catch {}

    $lbl = [System.Windows.Forms.Label]::new()
    $lbl.Text = '会议链接（Jitsi / Zoom / Lares）：'
    $lbl.SetBounds(12, 12, 436, 20)
    $tb = [System.Windows.Forms.TextBox]::new()
    $tb.SetBounds(12, 36, 436, 24)
    if ($Prefill) { $tb.Text = $Prefill; $tb.SelectAll() }
    $ok = [System.Windows.Forms.Button]::new(); $ok.Text = '加入'; $ok.SetBounds(282, 76, 80, 28)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $cancel = [System.Windows.Forms.Button]::new(); $cancel.Text = '取消'; $cancel.SetBounds(368, 76, 80, 28)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.AddRange(@($lbl, $tb, $ok, $cancel))
    $form.AcceptButton = $ok; $form.CancelButton = $cancel
    $form.add_Shown({ $form.Activate(); $tb.Focus() })
    try {
        $res = $form.ShowDialog()
        if ($res -eq [System.Windows.Forms.DialogResult]::OK) { return $tb.Text.Trim() }
        return $null
    } finally { $form.Dispose() }
}

function Invoke-Join {
    param([string]$Link)
    if (-not $Link) { return }
    if (-not (Test-Daemon)) {
        if ($NoDaemon) { Show-Balloon '炉灵' '炉灵 未运行' ([System.Windows.Forms.ToolTipIcon]::Warning); return }
        if (-not (Start-Daemon)) { Show-Balloon '炉灵' '无法启动 炉灵 守护进程' ([System.Windows.Forms.ToolTipIcon]::Error); return }
    }
    $r = Invoke-Api -Method POST -Path '/join' -Body @{ link = $Link } -TimeoutSec 20
    if ($r.Ok) {
        $room = if ($r.Data.room) { $r.Data.room } else { $Link }
        Show-Balloon '炉灵 · 正在加入会议' ([string]$room)
    } else {
        Show-Balloon '炉灵 · 加入失败' $r.Error ([System.Windows.Forms.ToolTipIcon]::Error)
    }
    Invoke-Poll
}

function Invoke-Leave {
    $r = Invoke-Api -Method POST -Path '/leave' -TimeoutSec 20
    if ($r.Ok) { Show-Balloon '炉灵' '已请求离开会议' }
    else { Show-Balloon '炉灵 · 离开失败' $r.Error ([System.Windows.Forms.ToolTipIcon]::Warning) }
    Invoke-Poll
}

function Invoke-ChannelToggle {
    param([string]$Id, [bool]$Running)
    $verb = if ($Running) { 'stop' } else { 'start' }
    $r = Invoke-Api -Method POST -Path ("/channels/{0}/{1}" -f [uri]::EscapeDataString($Id), $verb) -TimeoutSec 10
    if (-not $r.Ok) { Show-Balloon '炉灵 · 频道' $r.Error ([System.Windows.Forms.ToolTipIcon]::Warning) }
    Invoke-Poll
}

function Invoke-Quit {
    $script:Exiting = $true
    try { $script:Timer.Stop() } catch {}
    $c = Get-Conn
    if ($c -and (Test-Daemon)) {
        $null = Invoke-Api -Method POST -Path '/quit' -TimeoutSec 5
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while ([DateTime]::UtcNow -lt $deadline) {
            if (-not (Get-Process -Id $c.Pid -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 250
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
    try { $script:Notify.Visible = $false; $script:Notify.Dispose() } catch {}
    try { $script:Ctx.ExitThread() } catch {}
}

# ---------------------------------------------------------------- 菜单

function New-Item2 {
    param([string]$Text, [scriptblock]$OnClick, [bool]$Enabled = $true)
    $mi = [System.Windows.Forms.ToolStripMenuItem]::new($Text)
    $mi.Enabled = $Enabled
    if ($OnClick) {
        $mi.Tag = $OnClick
        $mi.add_Click({ param($sender, $e) $act = $sender.Tag; Invoke-Safe $act })
    }
    return $mi
}

function Get-KindLabel {
    param([string]$Kind)
    switch ($Kind) { 'input' { '输入' } 'output' { '输出' } 'meeting' { '会议' } default { $Kind } }
}

function Build-Menu {
    param([System.Windows.Forms.ContextMenuStrip]$Menu)
    $Menu.SuspendLayout()
    try {
        $Menu.Items.Clear()
        $running = [bool]$script:Status
        $state = if ($running) { [string]$script:Status.state } else { '' }
        $inMeeting = $state -in @('joining', 'in-meeting', 'leaving')

        $statusItem = [System.Windows.Forms.ToolStripMenuItem]::new((Get-StatusLine))
        $statusItem.Enabled = $false
        [void]$Menu.Items.Add($statusItem)
        if (-not $running) {
            [void]$Menu.Items.Add((New-Item2 '启动' {
                        if (Start-Daemon) { Show-Balloon '炉灵' '炉灵 已启动' } else { Show-Balloon '炉灵' '无法启动 炉灵 守护进程' ([System.Windows.Forms.ToolTipIcon]::Error) }
                        Invoke-Poll
                    }))
        }
        [void]$Menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())

        $clip = Get-ClipboardLink
        [void]$Menu.Items.Add((New-Item2 '加入会议…' {
                    $link = Show-JoinDialog -Prefill (Get-ClipboardLink)
                    if ($link) { Invoke-Join $link }
                } (-not $inMeeting)))
        if ($clip) {
            $ci = New-Item2 '加入剪贴板中的链接' { $l = Get-ClipboardLink; if ($l) { Invoke-Join $l } } (-not $inMeeting)
            $ci.ToolTipText = Limit-Text $clip 120
            [void]$Menu.Items.Add($ci)
        }
        [void]$Menu.Items.Add((New-Item2 '离开会议' { Invoke-Leave } ($running -and $inMeeting)))
        [void]$Menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())

        # 频道
        $chMenu = [System.Windows.Forms.ToolStripMenuItem]::new('频道')
        $chMenu.DropDown.ShowItemToolTips = $true
        $chs = @($script:Channels)
        if (-not $running -or $chs.Count -eq 0) {
            $none = [System.Windows.Forms.ToolStripMenuItem]::new($(if ($running) { '（无频道）' } else { '（炉灵 未运行）' }))
            $none.Enabled = $false
            [void]$chMenu.DropDownItems.Add($none)
        } else {
            foreach ($ch in $chs) {
                $name = if ($ch.name) { [string]$ch.name } else { [string]$ch.id }
                $mi = [System.Windows.Forms.ToolStripMenuItem]::new(("{0}（{1}）" -f $name, (Get-KindLabel ([string]$ch.kind))))
                $mi.Checked = [bool]$ch.running
                $mi.Enabled = [bool]$ch.configured
                $tip = [string]$ch.detail
                if (-not $ch.configured -and -not $tip) { $tip = '未配置' }
                if ($tip) { $mi.ToolTipText = Limit-Text $tip 200 }
                $mi.Tag = [pscustomobject]@{ Id = [string]$ch.id; Running = [bool]$ch.running }
                $mi.add_Click({ param($sender, $e) $t = $sender.Tag; Invoke-Safe { Invoke-ChannelToggle -Id $t.Id -Running $t.Running } })
                [void]$chMenu.DropDownItems.Add($mi)
            }
        }
        [void]$Menu.Items.Add($chMenu)

        # 最近消息
        $feedMenu = [System.Windows.Forms.ToolStripMenuItem]::new('最近消息')
        $items = @($script:Feed)
        if (-not $running -or $items.Count -eq 0) {
            $none = [System.Windows.Forms.ToolStripMenuItem]::new('（暂无消息）')
            $none.Enabled = $false
            [void]$feedMenu.DropDownItems.Add($none)
        } else {
            for ($i = $items.Count - 1; $i -ge 0; $i--) {
                $it = $items[$i]
                $title = if ($it.title) { [string]$it.title } else { [string]$it.kind }
                $label = ('{0} {1}' -f (Format-At $it.at), (Limit-Text $title 40)).Trim()
                $mi = [System.Windows.Forms.ToolStripMenuItem]::new($label)
                $mi.Tag = [pscustomobject]@{ Title = $title; Text = [string]$it.text; At = (Format-At $it.at) }
                $mi.add_Click({
                        param($sender, $e)
                        $t = $sender.Tag
                        $body = if ($t.Text) { $t.Text } else { $t.Title }
                        [void][System.Windows.Forms.MessageBox]::Show($body, ('炉灵 · ' + $t.Title), 'OK', 'Information')
                    })
                [void]$feedMenu.DropDownItems.Add($mi)
            }
        }
        [void]$Menu.Items.Add($feedMenu)

        [void]$Menu.Items.Add((New-Item2 '打开状态页' {
                    $c = Get-Conn
                    if ($c) { Start-Process ("http://127.0.0.1:{0}/ui#{1}" -f $c.Port, $c.Token) }
                    else { Show-Balloon '炉灵' '炉灵 未运行' ([System.Windows.Forms.ToolTipIcon]::Warning) }
                } $running))
        [void]$Menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())

        $auto = New-Item2 '开机自启' { Set-Autostart (-not (Test-Autostart)) }
        $auto.Checked = Test-Autostart
        [void]$Menu.Items.Add($auto)
        [void]$Menu.Items.Add((New-Item2 '退出' { Invoke-Quit }))
    } finally { $Menu.ResumeLayout() }
}

function Get-MenuTexts {
    param($Items, [string]$Prefix = '')
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($it in $Items) {
        if ($it -is [System.Windows.Forms.ToolStripSeparator]) { continue }
        $out.Add($Prefix + $it.Text)
        if ($it -is [System.Windows.Forms.ToolStripMenuItem] -and $it.DropDownItems.Count -gt 0) {
            foreach ($s in (Get-MenuTexts $it.DropDownItems ($Prefix + $it.Text + ' > '))) { $out.Add($s) }
        }
    }
    return , $out
}

# ---------------------------------------------------------------- 图标

function Get-TrayIcon {
    $p = Join-Path $script:Dir 'ember.ico'
    if (-not (Test-Path -LiteralPath $p)) {
        try { & (Join-Path $script:Dir 'make-icon.ps1') -OutPath $p | Out-Null } catch {}
    }
    if (Test-Path -LiteralPath $p) {
        try { return @{ Icon = [System.Drawing.Icon]::new($p, 16, 16); FromFile = $true } } catch {}
    }
    return @{ Icon = [System.Drawing.SystemIcons]::Application; FromFile = $false }
}

# ---------------------------------------------------------------- 主体

[System.Windows.Forms.Application]::EnableVisualStyles()

if ($SelfTest) {
    $code = 0
    try {
        $ic = Get-TrayIcon
        $script:IconObj = $ic.Icon
        if (-not $NoDaemon) { try { $null = Start-Daemon } catch {} }
        Update-Data -WithFeed
        $menu = [System.Windows.Forms.ContextMenuStrip]::new()
        Build-Menu $menu
        $ni = [System.Windows.Forms.NotifyIcon]::new()
        $ni.Icon = $ic.Icon
        $ni.ContextMenuStrip = $menu
        $ni.Text = Limit-Text (Get-StatusLine) 63
        $summary = [ordered]@{
            ok        = $true
            menuItems = [string[]](Get-MenuTexts $menu.Items).ToArray()
            daemon    = [ordered]@{
                reachable = [bool]$script:Status
                state     = if ($script:Status) { [string]$script:Status.state } else { $null }
            }
            icon      = [bool]$ic.FromFile
            tooltip   = $ni.Text
            autostart = Test-Autostart
            stateDir  = $script:StateDir
        }
        $ni.Dispose(); $menu.Dispose()
    } catch {
        $summary = [ordered]@{ ok = $false; error = $_.Exception.Message }
        $code = 1
    }
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $summary | ConvertTo-Json -Depth 5
    exit $code
}

# 单实例
$createdNew = $false
$script:Mutex = [System.Threading.Mutex]::new($true, 'Local\EmberDeskTray', [ref]$createdNew)
if (-not $createdNew) {
    $script:Mutex.Dispose()
    exit 0
}

try {
    $ic = Get-TrayIcon
    $script:IconObj = $ic.Icon

    $script:Notify = [System.Windows.Forms.NotifyIcon]::new()
    $script:Notify.Icon = $ic.Icon
    $script:Notify.Text = '炉灵 · 启动中'
    $menu = [System.Windows.Forms.ContextMenuStrip]::new()
    $menu.ShowItemToolTips = $true
    [void]$menu.Items.Add('炉灵')   # 占位，Opening 时重建
    $menu.add_Opening({
            param($sender, $e)
            try { Update-Data -WithFeed; Update-Tooltip; Build-Menu $sender } catch {}
            $e.Cancel = $false
        })
    $script:Notify.ContextMenuStrip = $menu
    $script:Notify.add_DoubleClick({
            Invoke-Safe {
                $c = Get-Conn
                if ($c -and $script:Status) { Start-Process ("http://127.0.0.1:{0}/ui#{1}" -f $c.Port, $c.Token) }
            }
        })
    $script:Notify.Visible = $true

    if (-not $NoDaemon -and -not (Test-Daemon)) {
        try {
            if (-not (Start-Daemon)) { Show-Balloon '炉灵' '守护进程未能在 15 秒内启动' ([System.Windows.Forms.ToolTipIcon]::Warning) }
        } catch { Show-Balloon '炉灵' $_.Exception.Message ([System.Windows.Forms.ToolTipIcon]::Error) }
    }
    Invoke-Poll

    $script:Timer = [System.Windows.Forms.Timer]::new()
    $script:Timer.Interval = 3000
    $script:Timer.add_Tick({ try { Invoke-Poll } catch {} })
    $script:Timer.Start()

    $script:Ctx = [System.Windows.Forms.ApplicationContext]::new()
    [System.Windows.Forms.Application]::Run($script:Ctx)
} finally {
    try { $script:Timer.Stop(); $script:Timer.Dispose() } catch {}
    try { if ($script:Notify) { $script:Notify.Visible = $false; $script:Notify.Dispose() } } catch {}
    try { $script:Mutex.ReleaseMutex() } catch {}
    try { $script:Mutex.Dispose() } catch {}
}
exit 0
