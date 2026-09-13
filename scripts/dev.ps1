# Lares 本机全栈联调一键启动:LiveKit(dev) + 信令服务 + Web 静态托管
# 用法:pwsh scripts/dev.ps1  (Ctrl+C 停止全部)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# 局域网 IP:模拟器/真机经此地址访问本机服务(--dev 默认只绑回环)
#
# ⚠️ 坑(2026-09 实际踩到):不能简单取「第一个非回环 IPv4」。
#    本机装了 VPN/代理虚拟网卡(QuickFox 10.8.8.1、WSL、Hyper-V、Docker 等),
#    它们经常排在真实无线/有线网卡前面。一旦选中虚拟网卡,LiveKit 会把那个
#    地址写进 ICE candidate 和签发的 token,客户端拿到的就是一个**不可达**
#    的地址 —— 表现为 presence 一切正常、但进房永远停在 disconnected,
#    且没有任何报错,极难排查。
# 策略:优先选「有默认网关、且网卡是 Up 的真实物理网卡」,按路由跃点数排序。
$lanIp = $null
$virtualPattern = 'Loopback|QuickFox|WSL|vEthernet|Hyper-V|VirtualBox|VMware|TAP|Tailscale|ZeroTier|Clash|Wintun|Npcap'
try {
  $best = Get-NetIPConfiguration |
    Where-Object {
      $_.IPv4DefaultGateway -and
      $_.NetAdapter.Status -eq 'Up' -and
      $_.InterfaceAlias -notmatch $virtualPattern
    } |
    Sort-Object { $_.IPv4DefaultGateway.RouteMetric } |
    Select-Object -First 1
  if ($best) { $lanIp = $best.IPv4Address.IPAddress }
} catch { }
if (-not $lanIp) {
  $lanIp = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
      $_.InterfaceAlias -notmatch $virtualPattern -and
      $_.IPAddress -notmatch '^169\.254\.'
    } | Select-Object -First 1).IPAddress
}
if (-not $lanIp) { $lanIp = '127.0.0.1' }
Write-Host "局域网地址: $lanIp" -ForegroundColor Yellow
Write-Host "  若此地址不是你当前 WiFi/有线网卡的地址,进房会一直连不上(见脚本内注释)" -ForegroundColor DarkGray

Write-Host "[1/3] LiveKit dev server (ws://${lanIp}:7880)..." -ForegroundColor Cyan
$lk = Start-Process -PassThru -NoNewWindow `
  -FilePath "$root\server\livekit\livekit-server.exe" -ArgumentList '--dev','--bind','0.0.0.0','--node-ip',$lanIp `
  -RedirectStandardOutput "$root\server\livekit\livekit.log" -RedirectStandardError "$root\server\livekit\livekit.err.log"
Start-Sleep -Seconds 2

Write-Host "[2/3] 信令服务 (ws://${lanIp}:8787)..." -ForegroundColor Cyan
$env:LIVEKIT_URL = "ws://${lanIp}:7880"
$env:LIVEKIT_API_KEY = 'devkey'
$env:LIVEKIT_API_SECRET = 'secret'
$env:LARES_PORT = '8787'
$srv = Start-Process -PassThru -NoNewWindow -FilePath 'node' `
  -ArgumentList 'src/index.js' -WorkingDirectory "$root\server"

Write-Host "[3/3] Web 托管 (http://127.0.0.1:8080)..." -ForegroundColor Cyan
$web = Start-Process -PassThru -NoNewWindow -FilePath 'node' `
  -ArgumentList 'tool/serve_web.mjs 8080' -WorkingDirectory "$root\app"

Write-Host ""
Write-Host "全部启动完成。打开 http://127.0.0.1:8080 (开两个窗口即双人联调)" -ForegroundColor Green
Write-Host "Ctrl+C 停止全部服务"
try {
  Wait-Process -Id $lk.Id, $srv.Id, $web.Id
} finally {
  Stop-Process -Id $srv.Id, $web.Id -Force -ErrorAction SilentlyContinue
}
