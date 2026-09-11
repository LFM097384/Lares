# 用目录联接(Junction)预建 Flutter 插件链接,绕过 Windows 开发者模式限制。
# 原理:Flutter 工具对已存在的插件链接直接跳过(flutter_plugins.dart:1272),
# 而目录 Junction 不需要 SeCreateSymbolicLinkPrivilege。
# 用法:pwsh scripts/fix_symlinks.ps1   (每次 pub get/upgrade 后重跑一次)
$ErrorActionPreference = 'Stop'
$appDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'app'
$manifest = Get-Content (Join-Path $appDir '.flutter-plugins-dependencies') | ConvertFrom-Json

$targets = @{
  android = Join-Path $appDir 'android\.plugin_symlinks'
  windows = Join-Path $appDir 'windows\flutter\ephemeral\.plugin_symlinks'
  linux   = Join-Path $appDir 'linux\flutter\ephemeral\.plugin_symlinks'
}

$created = 0
foreach ($platform in $targets.Keys) {
  $plugins = $manifest.plugins.$platform
  if (-not $plugins) { continue }
  $dir = $targets[$platform]
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  foreach ($p in $plugins) {
    $link = Join-Path $dir $p.name
    $target = $p.path -replace '\\\\', '\'
    if (Test-Path $link) { continue }
    New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    $created++
  }
}
Write-Host "插件 Junction 就绪(新建 $created 个)"
