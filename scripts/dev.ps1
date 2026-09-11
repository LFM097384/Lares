# Lares 本机全栈联调一键启动:LiveKit(dev) + 信令服务 + Web 静态托管
# 用法:pwsh scripts/dev.ps1  (Ctrl+C 停止全部)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# 局域网 IP:模拟器/真机经此地址访问本机服务(--dev 默认只绑回环)
$lanIp = (Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.IPAddress -notmatch '^169\.254\.' } |
  Select-Object -First 1).IPAddress
if (-not $lanIp) { $lanIp = '127.0.0.1' }
Write-Host "局域网地址: $lanIp" -ForegroundColor Yellow

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
