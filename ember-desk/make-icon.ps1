#Requires -Version 7
<#
.SYNOPSIS
  生成 炉灵 托盘图标 ember.ico（火焰图形，透明背景，多尺寸 PNG 编码 ICO）。
.EXAMPLE
  pwsh -NoProfile -File make-icon.ps1
#>
[CmdletBinding()]
param(
    [string]$OutPath = (Join-Path $PSScriptRoot 'ember.ico'),
    [int[]]$Sizes = @(16, 24, 32, 48, 64, 256)
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function New-FlamePath {
    param([float]$cx, [float]$top, [float]$bottom, [float]$halfWidth)
    # 泪滴形火焰：尖顶在上，圆底在下
    $h = $bottom - $top
    $p = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $tip = [System.Drawing.PointF]::new($cx, $top)
    $bl = [System.Drawing.PointF]::new($cx - $halfWidth, $top + $h * 0.68)
    $bt = [System.Drawing.PointF]::new($cx, $bottom)
    $br = [System.Drawing.PointF]::new($cx + $halfWidth, $top + $h * 0.68)
    # 左侧：尖顶 → 左腰
    $p.AddBezier($tip,
        [System.Drawing.PointF]::new($cx - $halfWidth * 0.15, $top + $h * 0.22),
        [System.Drawing.PointF]::new($cx - $halfWidth * 1.05, $top + $h * 0.38),
        $bl)
    # 左腰 → 底部
    $p.AddBezier($bl,
        [System.Drawing.PointF]::new($cx - $halfWidth * 0.98, $top + $h * 0.90),
        [System.Drawing.PointF]::new($cx - $halfWidth * 0.55, $bottom),
        $bt)
    # 底部 → 右腰
    $p.AddBezier($bt,
        [System.Drawing.PointF]::new($cx + $halfWidth * 0.55, $bottom),
        [System.Drawing.PointF]::new($cx + $halfWidth * 0.98, $top + $h * 0.90),
        $br)
    # 右腰 → 尖顶
    $p.AddBezier($br,
        [System.Drawing.PointF]::new($cx + $halfWidth * 1.05, $top + $h * 0.38),
        [System.Drawing.PointF]::new($cx + $halfWidth * 0.15, $top + $h * 0.22),
        $tip)
    $p.CloseFigure()
    return $p
}

function New-FlamePng {
    param([int]$Size)
    $bmp = [System.Drawing.Bitmap]::new($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.Clear([System.Drawing.Color]::Transparent)
        $s = [float]$Size
        $m = [Math]::Max(0.5, $s * 0.04)

        # 外焰
        $outer = New-FlamePath -cx ($s / 2) -top $m -bottom ($s - $m) -halfWidth ($s * 0.40)
        $rect = [System.Drawing.RectangleF]::new(0, $m, $s, $s - 2 * $m)
        $grad = [System.Drawing.Drawing2D.LinearGradientBrush]::new($rect,
            [System.Drawing.Color]::FromArgb(255, 255, 196, 40),
            [System.Drawing.Color]::FromArgb(255, 226, 64, 16), 90.0)
        $g.FillPath($grad, $outer)
        if ($Size -ge 32) {
            $pen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(200, 170, 40, 10), [float][Math]::Max(1, $s / 48))
            $g.DrawPath($pen, $outer); $pen.Dispose()
        }
        $grad.Dispose(); $outer.Dispose()

        # 内焰（更亮）
        $inner = New-FlamePath -cx ($s / 2) -top ($s * 0.38) -bottom ($s - $m - $s * 0.08) -halfWidth ($s * 0.20)
        $rect2 = [System.Drawing.RectangleF]::new(0, $s * 0.38, $s, $s * 0.55)
        $grad2 = [System.Drawing.Drawing2D.LinearGradientBrush]::new($rect2,
            [System.Drawing.Color]::FromArgb(255, 255, 250, 210),
            [System.Drawing.Color]::FromArgb(255, 255, 214, 70), 90.0)
        $g.FillPath($grad2, $inner)
        $grad2.Dispose(); $inner.Dispose()
    } finally { $g.Dispose() }
    $ms = [System.IO.MemoryStream]::new()
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return , $ms.ToArray()
}

$Sizes = $Sizes | Sort-Object -Unique
$images = foreach ($sz in $Sizes) { , (New-FlamePng -Size $sz) }

$out = [System.IO.MemoryStream]::new()
$w = [System.IO.BinaryWriter]::new($out)
# ICONDIR
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$Sizes.Count)
$offset = 6 + 16 * $Sizes.Count
for ($i = 0; $i -lt $Sizes.Count; $i++) {
    $sz = $Sizes[$i]; $data = $images[$i]
    $dim = if ($sz -ge 256) { 0 } else { $sz }
    $w.Write([byte]$dim); $w.Write([byte]$dim)
    $w.Write([byte]0); $w.Write([byte]0)          # palette, reserved
    $w.Write([uint16]1); $w.Write([uint16]32)      # planes, bpp
    $w.Write([uint32]$data.Length); $w.Write([uint32]$offset)
    $offset += $data.Length
}
foreach ($data in $images) { $w.Write([byte[]]$data) }
$w.Flush()
[System.IO.File]::WriteAllBytes($OutPath, $out.ToArray())
$w.Dispose()

# 校验
$ico = [System.Drawing.Icon]::new($OutPath)
$ok = $ico.Width -gt 0
$ico.Dispose()
Write-Output ("ember.ico written: {0} ({1} bytes, sizes {2}, valid={3})" -f $OutPath, (Get-Item $OutPath).Length, ($Sizes -join '/'), $ok)
