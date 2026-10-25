#Requires -Version 7
<#
.SYNOPSIS
  解密 secrets.dpapi.json，向 stdout 输出 JSON 对象 { 名称: 明文 }（供 炉灵 守护进程读取）。
.EXAMPLE
  pwsh -NoProfile -NonInteractive -File read-secrets.ps1 -Path "%APPDATA%\ember-desk\secrets.dpapi.json"
.NOTES
  文件不存在 → 输出 {}，退出 0。无法解密的项被跳过（写一行警告到 stderr，不含值）。
#>
[CmdletBinding()]
param([string]$Path)
$ErrorActionPreference = 'Stop'
if (-not $Path) {
    $stateDir = if ($env:EMBER_DESK_HOME) { $env:EMBER_DESK_HOME } else { Join-Path $env:APPDATA 'ember-desk' }
    $Path = Join-Path $stateDir 'secrets.dpapi.json'
}
$out = [ordered]@{}
if (Test-Path -LiteralPath $Path) {
    $data = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    foreach ($k in $data.Keys) {
        $v = $data[$k]
        if (-not $v) { continue }
        try {
            $out[$k] = [Net.NetworkCredential]::new('', (ConvertTo-SecureString -String ([string]$v))).Password
        } catch {
            [Console]::Error.WriteLine("read-secrets: cannot decrypt $k")
        }
    }
}
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::Out.Write(($out | ConvertTo-Json -Compress -Depth 2))
exit 0
