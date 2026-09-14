<#
  炉火之灵原型 —— CPU 占用实测脚本

  方法学(为什么可信):
    Get-Process 的 .CPU 属性是进程自启动以来累计消耗的**处理器秒数**
    (user + kernel,跨所有核心汇总)。在窗口首尾各取一次,做差,
    除以实际经过的墙钟秒数,得到「平均占用了几个核」。
    再除以 1 得到「单核百分比」,除以逻辑核数得到「整机百分比」。

    这比 Get-Counter 的 % Processor Time 更稳:
    后者在多实例同名进程 / PID 复用时容易取错对象。

  注意:Flutter 桌面应用是多进程的吗?不是 —— Windows 上 flutter run
  会有 flutter_tools(dart.exe)和被测应用两个进程。必须只测**应用**进程,
  不要把 dart.exe 的开销算进来。本脚本按 exe 名精确匹配。

  用法:
    .\measure_cpu.ps1 -ProcessName lares_app -Seconds 60 -Label "idle-calm"
#>
param(
  [string]$ProcessName = 'lares_app',
  [int]$Seconds = 60,
  [string]$Label = 'unnamed',
  [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
$logical = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum

$procs = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
if ($procs.Count -eq 0) {
  Write-Error "找不到进程 '$ProcessName'。先启动原型再跑本脚本。"
  exit 1
}
if ($procs.Count -gt 1) {
  Write-Warning "匹配到 $($procs.Count) 个同名进程,将汇总它们。"
}

# 预热:丢弃第一次读数,避免把启动瞬间的开销算进来
Start-Sleep -Milliseconds 500

$t0 = [datetime]::UtcNow
$cpu0 = 0.0
foreach ($p in $procs) { $p.Refresh(); $cpu0 += $p.CPU }
$ws0 = ($procs | Measure-Object -Property WorkingSet64 -Sum).Sum

Write-Host "[$Label] 采样 $Seconds 秒 (PID: $($procs.Id -join ','))..." -ForegroundColor Cyan
Start-Sleep -Seconds $Seconds

$t1 = [datetime]::UtcNow
$cpu1 = 0.0
foreach ($p in $procs) { $p.Refresh(); $cpu1 += $p.CPU }
$ws1 = ($procs | Measure-Object -Property WorkingSet64 -Sum).Sum

$wall = ($t1 - $t0).TotalSeconds
$cpuSec = $cpu1 - $cpu0
$coresUsed = $cpuSec / $wall
$pctOneCore = $coresUsed * 100
$pctMachine = $pctOneCore / $logical

$result = [pscustomobject]@{
  Label          = $Label
  WallSeconds    = [math]::Round($wall, 2)
  CpuSeconds     = [math]::Round($cpuSec, 3)
  PercentOneCore = [math]::Round($pctOneCore, 2)
  PercentMachine = [math]::Round($pctMachine, 3)
  LogicalCores   = $logical
  WorkingSetMB   = [math]::Round($ws1 / 1MB, 1)
  RssDeltaMB     = [math]::Round(($ws1 - $ws0) / 1MB, 2)
}

$result | Format-List

if ($OutFile) {
  $result | Export-Csv -Path $OutFile -NoTypeInformation -Append -Encoding UTF8
  Write-Host "已追加到 $OutFile" -ForegroundColor Green
}
