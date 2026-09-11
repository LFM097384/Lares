# 挂机浸泡监控:每 5 分钟记录房间人数与客户端在线情况
# 目标:验证「桌面/移动挂机不掉线」(§8.4 验收)
$logFile = "D:\Projects\Lares\soak.log"
"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') soak start, expect home=3" | Out-File $logFile
$failStreak = 0
while ($true) {
    try {
        $h = Invoke-RestMethod http://localhost:8787/health -TimeoutSec 5
        $count = $h.circles.home
        $status = if ($count -eq 3) { 'OK' } else { "DEGRADED($count/3)" }
        if ($count -eq 3) { $failStreak = 0 } else { $failStreak++ }
    } catch {
        $status = "SERVER_UNREACHABLE"
        $failStreak++
    }
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $status streak=$failStreak" | Out-File $logFile -Append
    Start-Sleep -Seconds 300
}
