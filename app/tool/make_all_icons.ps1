# 一键重生成 Lares 炉灵 全平台图标(六端)
#
# 源头只有一个:tool/make_icon.ps1 画出的炉火字形。本脚本按各平台规格派生。
# 用法:pwsh tool/make_all_icons.ps1
#
# 覆盖:
#   - assets/tray/icon.png           托盘/应用源图(256)
#   - assets/tray/icon.ico           托盘 .ico(多尺寸)
#   - windows/runner/resources/app_icon.ico   Windows exe 图标(多尺寸)
#   - android .../mipmap-*/ic_launcher.png    五档密度
#   - web/favicon.png + icons/Icon-{192,512}.png + Icon-maskable-{192,512}.png
#   - ios .../AppIcon.appiconset/*.png        按 Contents.json 全尺寸(无 alpha)
#   - macos .../AppIcon.appiconset/*.png      七档尺寸
#
# 注意:
#   * iOS 图标**不允许含 alpha 通道**(App Store 会拒),故 iOS 一律压到不透明背景
#   * maskable 图标字形收进内 80% 安全区(见 make_icon.ps1 -Maskable)
#   * .ico 必须是 PNG 压缩格式;png-to-ico 的旧式 DIB 输出会被 RC 编译器拒绝

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot        # app/
$mk = Join-Path $PSScriptRoot 'make_icon.ps1'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("lares_icons_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

function Render([int]$size, [string]$out, [switch]$Maskable) {
    if ($Maskable) { & $mk -Size $size -Out $out -Maskable | Out-Null }
    else { & $mk -Size $size -Out $out | Out-Null }
}

# 把带 alpha 的 PNG 压到不透明背景(iOS 用)
function Flatten([string]$src, [string]$dst, [int]$size) {
    $img = [System.Drawing.Image]::FromFile($src)
    $bmp = New-Object System.Drawing.Bitmap $size, $size,
        ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::FromArgb(0x12, 0x10, 0x16))
    $g.DrawImage($img, 0, 0, $size, $size)
    $bmp.Save($dst, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose(); $img.Dispose()
}

# 多尺寸 .ico(每个条目都是 PNG 压缩)
function Write-Ico([string]$icoPath, [int[]]$sizes) {
    $entries = @()
    foreach ($s in $sizes) {
        $p = Join-Path $tmp "ico_$s.png"
        Render $s $p
        $entries += , @{ size = $s; bytes = [System.IO.File]::ReadAllBytes($p) }
    }
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([uint16]0)                    # reserved
    $bw.Write([uint16]1)                    # type = icon
    $bw.Write([uint16]$entries.Count)
    $offset = 6 + 16 * $entries.Count       # ICONDIR + 所有 ICONDIRENTRY
    foreach ($e in $entries) {
        $dim = if ($e.size -ge 256) { 0 } else { $e.size }   # 256 用 0 表示
        $bw.Write([byte]$dim)               # width
        $bw.Write([byte]$dim)               # height
        $bw.Write([byte]0)                  # palette colors
        $bw.Write([byte]0)                  # reserved
        $bw.Write([uint16]1)                # planes
        $bw.Write([uint16]32)               # bitcount
        $bw.Write([uint32]$e.bytes.Length)
        $bw.Write([uint32]$offset)
        $offset += $e.bytes.Length
    }
    foreach ($e in $entries) { $bw.Write($e.bytes) }
    $bw.Flush()
    $dir = Split-Path -Parent $icoPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllBytes($icoPath, $ms.ToArray())
    $bw.Dispose(); $ms.Dispose()
    Write-Output "  ico: $icoPath ($($entries.Count) sizes)"
}

Write-Output "[1/6] 源图 + 托盘"
$trayPng = Join-Path $root 'assets\tray\icon.png'
Render 256 $trayPng
Write-Output "  png: $trayPng"
Write-Ico (Join-Path $root 'assets\tray\icon.ico') @(16, 24, 32, 48, 64, 128, 256)

Write-Output "[2/6] Windows exe"
Write-Ico (Join-Path $root 'windows\runner\resources\app_icon.ico') @(16, 24, 32, 48, 64, 128, 256)

Write-Output "[3/6] Android launcher"
$densities = [ordered]@{
    'mipmap-mdpi' = 48; 'mipmap-hdpi' = 72; 'mipmap-xhdpi' = 96
    'mipmap-xxhdpi' = 144; 'mipmap-xxxhdpi' = 192
}
foreach ($d in $densities.GetEnumerator()) {
    $out = Join-Path $root "android\app\src\main\res\$($d.Key)\ic_launcher.png"
    if (Test-Path (Split-Path -Parent $out)) {
        Render $d.Value $out
        Write-Output "  $($d.Key): $($d.Value)px"
    }
}

Write-Output "[4/6] Web"
Render 256 (Join-Path $root 'web\favicon.png')
Render 192 (Join-Path $root 'web\icons\Icon-192.png')
Render 512 (Join-Path $root 'web\icons\Icon-512.png')
Render 192 (Join-Path $root 'web\icons\Icon-maskable-192.png') -Maskable
Render 512 (Join-Path $root 'web\icons\Icon-maskable-512.png') -Maskable
Write-Output "  favicon + 192/512 + maskable 192/512"

Write-Output "[5/6] iOS (无 alpha)"
$iosDir = Join-Path $root 'ios\Runner\Assets.xcassets\AppIcon.appiconset'
if (Test-Path $iosDir) {
    # 文件名 -> 实际像素边长(与 Contents.json 对应)
    $iosIcons = [ordered]@{
        'Icon-App-20x20@1x.png' = 20; 'Icon-App-20x20@2x.png' = 40; 'Icon-App-20x20@3x.png' = 60
        'Icon-App-29x29@1x.png' = 29; 'Icon-App-29x29@2x.png' = 58; 'Icon-App-29x29@3x.png' = 87
        'Icon-App-40x40@1x.png' = 40; 'Icon-App-40x40@2x.png' = 80; 'Icon-App-40x40@3x.png' = 120
        'Icon-App-60x60@2x.png' = 120; 'Icon-App-60x60@3x.png' = 180
        'Icon-App-76x76@1x.png' = 76; 'Icon-App-76x76@2x.png' = 152
        'Icon-App-83.5x83.5@2x.png' = 167
        'Icon-App-1024x1024@1x.png' = 1024
    }
    foreach ($ic in $iosIcons.GetEnumerator()) {
        $raw = Join-Path $tmp "ios_$($ic.Value).png"
        if (-not (Test-Path $raw)) { Render $ic.Value $raw }
        Flatten $raw (Join-Path $iosDir $ic.Key) $ic.Value
    }
    Write-Output "  $($iosIcons.Count) 个尺寸,已压平 alpha"
}

Write-Output "[6/6] macOS"
$macDir = Join-Path $root 'macos\Runner\Assets.xcassets\AppIcon.appiconset'
if (Test-Path $macDir) {
    foreach ($s in 16, 32, 64, 128, 256, 512, 1024) {
        Render $s (Join-Path $macDir "app_icon_$s.png")
    }
    Write-Output "  16/32/64/128/256/512/1024"
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ""
Write-Output "全部完成。Windows 端改图标后需重新构建才生效(资源编译进 exe)。"
