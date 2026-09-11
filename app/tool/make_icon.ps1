# 生成 Lares 托盘/应用图标:深暖底 + 余烬橙同心波纹
# 用法:pwsh tool/make_icon.ps1  -> assets/tray/icon.png
param([int]$Size = 256)

Add-Type -AssemblyName System.Drawing

$out = Join-Path $PSScriptRoot '..\assets\tray'
New-Item -ItemType Directory -Force -Path $out | Out-Null

$bmp = New-Object System.Drawing.Bitmap $Size, $Size
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'

# 背景:深暖灰紫圆角方
$bg = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(0x12, 0x10, 0x16))
$g.Clear([System.Drawing.Color]::Transparent)
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$r = [int]($Size * 0.22)
$rect = [System.Drawing.Rectangle]::new(0, 0, $Size, $Size)
$path.AddArc($rect.X, $rect.Y, $r, $r, 180, 90)
$path.AddArc($rect.Right - $r, $rect.Y, $r, $r, 270, 90)
$path.AddArc($rect.Right - $r, $rect.Bottom - $r, $r, $r, 0, 90)
$path.AddArc($rect.X, $rect.Bottom - $r, $r, $r, 90, 90)
$path.CloseFigure()
$g.FillPath($bg, $path)

# 波纹:三环 + 中心点,余烬橙,外环渐隐
$ember = [System.Drawing.Color]::FromArgb(0xFF, 0x8A, 0x5C)
$cx = $Size / 2; $cy = $Size / 2
foreach ($i in 1..3) {
    $alpha = [int](230 - ($i - 1) * 70)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb($alpha, $ember)), ([float]($Size * 0.045))
    $d = [int]($Size * (0.18 + 0.20 * $i))
    $g.DrawEllipse($pen, $cx - $d / 2, $cy - $d / 2, $d, $d)
    $pen.Dispose()
}
$dot = [System.Drawing.SolidBrush]::new($ember)
$dd = [int]($Size * 0.14)
$g.FillEllipse($dot, $cx - $dd / 2, $cy - $dd / 2, $dd, $dd)

$pngPath = Join-Path $out 'icon.png'
$bmp.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Output "saved: $pngPath"
