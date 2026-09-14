<#
  截图脚本 —— 抓取原型窗口的客户区。

  用 PrintWindow 而不是全屏截图,这样不会把桌面背景/其他窗口拍进去,
  也不依赖窗口在最前面。PW_RENDERFULLCONTENT (0x2) 对
  GPU 加速的窗口(Flutter 用 ANGLE/D3D)是必需的,否则拍出来是黑的。

  用法: .\capture.ps1 -ProcessName lares_app -Out shots\01-idle.png
#>
param(
  [string]$ProcessName = 'lares_app',
  [Parameter(Mandatory = $true)][string]$Out,
  [int]$DelaySeconds = 0
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinCap {
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }

$p = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { Write-Error "找不到带窗口的进程 '$ProcessName'"; exit 1 }

$h = $p.MainWindowHandle
[void][WinCap]::SetForegroundWindow($h)
Start-Sleep -Milliseconds 400

$r = New-Object WinCap+RECT
[void][WinCap]::GetClientRect($h, [ref]$r)
$w = $r.Right - $r.Left
$hh = $r.Bottom - $r.Top
if ($w -le 0 -or $hh -le 0) { Write-Error "窗口尺寸无效 ($w x $hh)"; exit 1 }

$bmp = New-Object System.Drawing.Bitmap($w, $hh)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
# 0x2 = PW_RENDERFULLCONTENT,GPU 合成的窗口必须带这个标志
$ok = [WinCap]::PrintWindow($h, $hdc, 2)
$g.ReleaseHdc($hdc)
$g.Dispose()

if (-not $ok) { Write-Warning "PrintWindow 返回 false,图可能不完整" }

$dir = Split-Path -Parent $Out
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$bmp.Save((Resolve-Path -LiteralPath (Split-Path -Parent $Out)).Path + '\' + (Split-Path -Leaf $Out), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

Write-Host "已保存 $Out ($w x $hh)" -ForegroundColor Green
