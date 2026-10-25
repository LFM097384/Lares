#Requires -Version 7
<#
.SYNOPSIS
  注销 ember:// 协议（删除 HKCU\Software\Classes\ember 整个键）。幂等。
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = 'HKCU:\Software\Classes\ember'
if (Test-Path -LiteralPath $root) {
    Remove-Item -LiteralPath $root -Recurse -Force
    Write-Output '已注销 ember:// 协议'
} else {
    Write-Output 'ember:// 协议未注册'
}
