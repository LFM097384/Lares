# 生成 PNG 压缩格式的 .ico(Vista+ 格式,RC 编译器接受;png-to-ico 的旧式 DIB 会被拒)
$ErrorActionPreference = 'Stop'
$pngPath = Join-Path $PSScriptRoot '..\assets\tray\icon.png'
$icoPath = Join-Path $PSScriptRoot '..\assets\tray\icon.ico'

$png = [System.IO.File]::ReadAllBytes($pngPath)
$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)

# ICONDIR
$bw.Write([uint16]0)      # reserved
$bw.Write([uint16]1)      # type = icon
$bw.Write([uint16]1)      # count
# ICONDIRENTRY(256x256 用 0 表示)
$bw.Write([byte]0)        # width  (0 = 256)
$bw.Write([byte]0)        # height (0 = 256)
$bw.Write([byte]0)        # colors
$bw.Write([byte]0)        # reserved
$bw.Write([uint16]1)      # planes
$bw.Write([uint16]32)     # bitcount
$bw.Write([uint32]$png.Length)
$bw.Write([uint32]22)     # offset (6 + 16)
$bw.Write($png)
$bw.Flush()
[System.IO.File]::WriteAllBytes($icoPath, $ms.ToArray())
Write-Output "saved: $icoPath ($($ms.Length) bytes)"
