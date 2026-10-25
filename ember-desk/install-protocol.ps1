#Requires -Version 7
<#
.SYNOPSIS
  注册 ember:// 协议（HKCU\Software\Classes\ember），由 node protocol.mjs 处理。幂等。
.PARAMETER Print
  只打印将写入的命令行，不修改注册表。
#>
[CmdletBinding()]
param([switch]$Print)
$ErrorActionPreference = 'Stop'

$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { throw '找不到 node.exe，请先安装 Node.js 并加入 PATH' }
$node = [System.IO.Path]::GetFullPath($node)
$dir = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
if ($node.Contains('"') -or $dir.Contains('"')) { throw '路径中包含双引号字符，拒绝注册' }

$handler = Join-Path $dir 'protocol.mjs'
$icon = Join-Path $dir 'ember.ico'
$command = '"' + $node + '" "' + $handler + '" "%1"'

if ($Print) {
    Write-Output "Key:         HKCU\Software\Classes\ember"
    Write-Output "(default):   URL:炉灵 Protocol"
    Write-Output "DefaultIcon: `"$icon`""
    Write-Output "Command:     $command"
    exit 0
}
if (-not (Test-Path -LiteralPath $handler)) { Write-Warning "尚未找到 $handler（仍会注册）" }

$root = 'HKCU:\Software\Classes\ember'
New-Item -Path $root -Force | Out-Null
Set-ItemProperty -LiteralPath $root -Name '(default)' -Value 'URL:炉灵 Protocol'
Set-ItemProperty -LiteralPath $root -Name 'URL Protocol' -Value ''
New-Item -Path "$root\DefaultIcon" -Force | Out-Null
Set-ItemProperty -LiteralPath "$root\DefaultIcon" -Name '(default)' -Value ('"' + $icon + '"')
New-Item -Path "$root\shell\open\command" -Force | Out-Null
Set-ItemProperty -LiteralPath "$root\shell\open\command" -Name '(default)' -Value $command
Write-Output "已注册 ember:// → $command"
