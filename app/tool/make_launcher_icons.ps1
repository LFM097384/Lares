# 由 assets/tray/icon.png 生成 Android 各密度 launcher 图标
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$src = Join-Path $PSScriptRoot '..\assets\tray\icon.png'
$resDir = Join-Path $PSScriptRoot '..\android\app\src\main\res'

$densities = @{
  'mipmap-mdpi'    = 48
  'mipmap-hdpi'    = 72
  'mipmap-xhdpi'   = 96
  'mipmap-xxhdpi'  = 144
  'mipmap-xxxhdpi' = 192
}

$img = [System.Drawing.Image]::FromFile($src)
foreach ($d in $densities.GetEnumerator()) {
  $size = $d.Value
  $bmp = New-Object System.Drawing.Bitmap $size, $size
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = 'HighQualityBicubic'
  $g.SmoothingMode = 'AntiAlias'
  $g.DrawImage($img, 0, 0, $size, $size)
  $out = Join-Path $resDir "$($d.Key)\ic_launcher.png"
  $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  Write-Output "saved: $out"
}
$img.Dispose()
