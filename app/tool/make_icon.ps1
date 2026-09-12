# 生成 Lares 炉灵 托盘/应用图标:深暖底 + 余烬橙炉火
#
# 品牌叙事:「Lares,宅火的守护神,随人而动」
# 旧图标是「点击进圈」的同心波纹;改名后字形改为炉火(灶台上的一簇火焰),
# 配色沿用原有的余烬暖橙 #FF8A5C / 深暖炭 #121016——它本来就是炉火色系。
#
# 用法:
#   pwsh tool/make_icon.ps1                  -> assets/tray/icon.png (256, 圆角)
#   pwsh tool/make_icon.ps1 -Size 512        -> 指定边长
#   pwsh tool/make_icon.ps1 -Maskable        -> 满幅无圆角 + 字形收进内 80%(Android/PWA maskable)
#   pwsh tool/make_icon.ps1 -Out path.png    -> 指定输出
param(
    [int]$Size = 256,
    [switch]$Maskable,
    [string]$Out
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# ── 品牌色 ────────────────────────────────────────────────────────────────
$COL_BG    = [System.Drawing.Color]::FromArgb(0x12, 0x10, 0x16)  # 深暖炭
$COL_EMBER = [System.Drawing.Color]::FromArgb(0xFF, 0x8A, 0x5C)  # 余烬橙(品牌主色)
$COL_CORE  = [System.Drawing.Color]::FromArgb(0xFF, 0xC9, 0x7A)  # 焰心暖黄
$COL_HEART = [System.Drawing.Color]::FromArgb(0xFF, 0xE8, 0xC0)  # 最亮焰心

$bmp = New-Object System.Drawing.Bitmap $Size, $Size
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'
$g.InterpolationMode = 'HighQualityBicubic'
$g.Clear([System.Drawing.Color]::Transparent)

# maskable 图标:字形必须收进内 80% 安全区(外圈会被各家 launcher 裁成圆/方/水滴)
$inset = if ($Maskable) { 0.10 } else { 0.0 }
$scale = 1.0 - 2 * $inset

# 归一化坐标 -> 实际像素(含 maskable 内缩)
function P([double]$x, [double]$y) {
    [System.Drawing.PointF]::new(
        [float](($x * $scale + $inset) * $Size),
        [float](($y * $scale + $inset) * $Size))
}
function N([double]$v) { [float]($v * $scale * $Size) }

# ── 背景 ──────────────────────────────────────────────────────────────────
$bgBrush = [System.Drawing.SolidBrush]::new($COL_BG)
if ($Maskable) {
    # 满幅填充,不留圆角:交给 launcher 自己裁形
    $g.FillRectangle($bgBrush, 0, 0, $Size, $Size)
} else {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $r = [int]($Size * 0.22)
    $path.AddArc(0, 0, $r, $r, 180, 90)
    $path.AddArc($Size - $r, 0, $r, $r, 270, 90)
    $path.AddArc($Size - $r, $Size - $r, $r, $r, 0, 90)
    $path.AddArc(0, $Size - $r, $r, $r, 90, 90)
    $path.CloseFigure()
    $g.FillPath($bgBrush, $path)
    $path.Dispose()
}
$bgBrush.Dispose()

# ── 炉火的光晕(真正的径向渐变,避免同心圆硬边)────────────────────────────
$cx = (0.5 * $scale + $inset) * $Size
$glowCy = (0.60 * $scale + $inset) * $Size
$glowD = N 0.86
$glowPath = New-Object System.Drawing.Drawing2D.GraphicsPath
$glowPath.AddEllipse($cx - $glowD / 2, $glowCy - $glowD / 2, $glowD, $glowD)
$pgb = New-Object System.Drawing.Drawing2D.PathGradientBrush $glowPath
$pgb.CenterPoint = [System.Drawing.PointF]::new([float]$cx, [float]$glowCy)
$pgb.CenterColor = [System.Drawing.Color]::FromArgb(58, $COL_EMBER)
$pgb.SurroundColors = @([System.Drawing.Color]::FromArgb(0, $COL_EMBER))
# 让亮度集中在中心附近,外缘平滑到 0
$blend = New-Object System.Drawing.Drawing2D.Blend 3
$blend.Positions = @([float]0.0, [float]0.45, [float]1.0)
$blend.Factors = @([float]0.0, [float]0.22, [float]1.0)
$pgb.Blend = $blend
$g.FillPath($pgb, $glowPath)
$pgb.Dispose(); $glowPath.Dispose()

# ── 焰形(不对称,尖端向右上卷曲——这是「火」区别于「水滴」的关键)────────
# 归一化控制点,y 越小越靠上。火焰重心约在 (0.5, 0.60)。
function New-FlamePath([double]$k) {
    # $k:整体缩放系数(1.0 = 外焰),围绕重心缩放
    $ax = 0.50; $ay = 0.60
    function S([double]$x, [double]$y) {
        P (($x - $ax) * $k + $ax) (($y - $ay) * $k + $ay)
    }
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    # 从卷曲的尖端出发,沿右侧下行:先内收出一个「腰」,再外扩成饱满的下摆
    $p.AddBezier((S 0.545 0.115), (S 0.560 0.225), (S 0.640 0.290), (S 0.690 0.395))
    $p.AddBezier((S 0.690 0.395), (S 0.742 0.500), (S 0.748 0.612), (S 0.706 0.706))
    $p.AddBezier((S 0.706 0.706), (S 0.664 0.802), (S 0.586 0.858), (S 0.500 0.858))
    # 左侧上行:下摆 -> 左腰(比右侧更内收,形成不对称)
    $p.AddBezier((S 0.500 0.858), (S 0.402 0.858), (S 0.318 0.792), (S 0.286 0.690))
    $p.AddBezier((S 0.286 0.690), (S 0.252 0.582), (S 0.286 0.472), (S 0.372 0.398))
    # 内焰肩部:向上收束,并在中途形成火焰特有的「反曲」
    $p.AddBezier((S 0.372 0.398), (S 0.430 0.348), (S 0.462 0.300), (S 0.470 0.242))
    # 回到尖端:尖端偏右,收成一个利落的钩
    $p.AddBezier((S 0.470 0.242), (S 0.478 0.186), (S 0.512 0.144), (S 0.545 0.115))
    $p.CloseFigure()
    return $p
}

# 外焰:余烬橙 -> 焰心暖黄的竖向渐变
$flame = New-FlamePath 1.0
$fb = $flame.GetBounds()
if ($fb.Height -gt 0) {
    $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        [System.Drawing.PointF]::new($fb.X, $fb.Y),
        [System.Drawing.PointF]::new($fb.X, $fb.Bottom),
        $COL_EMBER, $COL_CORE)
    $g.FillPath($lg, $flame)
    $lg.Dispose()
} else {
    $sb = [System.Drawing.SolidBrush]::new($COL_EMBER)
    $g.FillPath($sb, $flame); $sb.Dispose()
}
$flame.Dispose()

# 内焰:更亮更小,略微下沉,形成焰心
$inner = New-FlamePath 0.50
$ib = $inner.GetBounds()
if ($ib.Height -gt 0) {
    $lg2 = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        [System.Drawing.PointF]::new($ib.X, $ib.Y),
        [System.Drawing.PointF]::new($ib.X, $ib.Bottom),
        $COL_CORE, $COL_HEART)
    $g.FillPath($lg2, $inner)
    $lg2.Dispose()
}
$inner.Dispose()

# ── 灶台(炉):火焰下方一道厚横条,把「火」锚成「炉火」而非通用火苗 ──────
$hearthW = 0.46
$hearthH = 0.075
$hx = (0.5 - $hearthW / 2)
$hy = 0.845
$hRect = [System.Drawing.RectangleF]::new(
    [float](($hx * $scale + $inset) * $Size),
    [float](($hy * $scale + $inset) * $Size),
    (N $hearthW), (N $hearthH))
$hPath = New-Object System.Drawing.Drawing2D.GraphicsPath
$hr = (N $hearthH)
if ($hr -lt 1) { $hr = 1 }
$hPath.AddArc($hRect.X, $hRect.Y, $hr, $hr, 180, 90)
$hPath.AddArc($hRect.Right - $hr, $hRect.Y, $hr, $hr, 270, 90)
$hPath.AddArc($hRect.Right - $hr, $hRect.Bottom - $hr, $hr, $hr, 0, 90)
$hPath.AddArc($hRect.X, $hRect.Bottom - $hr, $hr, $hr, 90, 90)
$hPath.CloseFigure()
$hb = [System.Drawing.SolidBrush]::new($COL_EMBER)
$g.FillPath($hb, $hPath)
$hb.Dispose(); $hPath.Dispose()

# ── 保存 ──────────────────────────────────────────────────────────────────
if (-not $Out) {
    $dir = Join-Path $PSScriptRoot '..\assets\tray'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $Out = Join-Path $dir 'icon.png'
}
$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Output "saved: $Out  ($Size px$(if($Maskable){', maskable'}else{''}))"
