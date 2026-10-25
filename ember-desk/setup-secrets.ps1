#Requires -Version 7
<#
.SYNOPSIS
  为 炉灵 保存密钥：以 DPAPI（当前用户）加密写入 <状态目录>\secrets.dpapi.json。
.DESCRIPTION
  状态目录 = $env:EMBER_DESK_HOME，未设置则为 %APPDATA%\ember-desk。
  文件格式：{ "名称": "<ConvertFrom-SecureString 输出>", ... }。绝不回显密钥。
.PARAMETER FromEnv
  不提示，直接从当前环境变量取值（仅写入非空的变量）。
.PARAMETER DashscopeCsv
  从 CSV（每行 key,value）中读取 key 为 apiKey 的值作为 LARES_DASHSCOPE_API_KEY。
.PARAMETER Clear
  删除密钥文件。
#>
[CmdletBinding()]
param(
    [switch]$FromEnv,
    [string]$DashscopeCsv,
    [switch]$Clear
)
$ErrorActionPreference = 'Stop'

$stateDir = if ($env:EMBER_DESK_HOME) { $env:EMBER_DESK_HOME } else { Join-Path $env:APPDATA 'ember-desk' }
$path = Join-Path $stateDir 'secrets.dpapi.json'

if ($Clear) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force; Write-Host "已删除 $path" }
    else { Write-Host "无密钥文件：$path" }
    exit 0
}

# 名称 → @{ Secret = 是否隐藏输入; Optional; Prompt }
$fields = [ordered]@{
    LARES_AI_LLM_KEY        = @{ Secret = $true; Optional = $false; Prompt = 'LLM API Key' }
    LARES_AI_LLM_BASE_URL   = @{ Secret = $false; Optional = $true; Prompt = 'LLM Base URL（可留空）' }
    LARES_AI_LLM_MODEL      = @{ Secret = $false; Optional = $true; Prompt = 'LLM 模型名（可留空）' }
    LARES_DASHSCOPE_API_KEY = @{ Secret = $true; Optional = $false; Prompt = 'DashScope API Key' }
    ZOOM_CLIENT_ID          = @{ Secret = $true; Optional = $true; Prompt = 'Zoom Client ID（可留空）' }
    ZOOM_CLIENT_SECRET      = @{ Secret = $true; Optional = $true; Prompt = 'Zoom Client Secret（可留空）' }
    ZOOM_WEBHOOK_SECRET     = @{ Secret = $true; Optional = $true; Prompt = 'Zoom Webhook Secret（可留空）' }
}

# 读取已有内容（保留未修改的项）
$store = [ordered]@{}
if (Test-Path -LiteralPath $path) {
    try {
        $old = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        foreach ($k in $old.Keys) { if ($old[$k]) { $store[$k] = [string]$old[$k] } }
    } catch { Write-Warning "现有密钥文件无法解析，将覆盖：$path" }
}

function ConvertTo-Dpapi([securestring]$s) { return (ConvertFrom-SecureString -SecureString $s) }
function Test-SecureEmpty([securestring]$s) { return ($null -eq $s -or $s.Length -eq 0) }

$csvKey = $null
if ($DashscopeCsv) {
    if (-not (Test-Path -LiteralPath $DashscopeCsv)) { throw "找不到 CSV：$DashscopeCsv" }
    foreach ($line in (Get-Content -LiteralPath $DashscopeCsv -Encoding utf8)) {
        $i = $line.IndexOf(',')
        if ($i -lt 0) { continue }
        $k = $line.Substring(0, $i).Trim().Trim('"').TrimStart([char]0xFEFF)
        if ($k -eq 'apiKey') { $csvKey = $line.Substring($i + 1).Trim().Trim('"'); break }
    }
    if (-not $csvKey) { throw "CSV 中没有 apiKey 行：$DashscopeCsv" }
}

$changed = [System.Collections.Generic.List[string]]::new()
foreach ($name in $fields.Keys) {
    $f = $fields[$name]
    if ($name -eq 'LARES_DASHSCOPE_API_KEY' -and $csvKey) {
        $store[$name] = ConvertTo-Dpapi (ConvertTo-SecureString -String $csvKey -AsPlainText -Force)
        $changed.Add($name); continue
    }
    if ($FromEnv) {
        $v = [Environment]::GetEnvironmentVariable($name)
        if ($v) {
            $store[$name] = ConvertTo-Dpapi (ConvertTo-SecureString -String $v -AsPlainText -Force)
            $changed.Add($name)
        }
        continue
    }
    $has = $store.Contains($name)
    $suffix = if ($has) { '（回车保留现有值）' } elseif ($f.Optional) { '' } else { '' }
    if ($f.Secret) {
        $ss = Read-Host -AsSecureString -Prompt ($f.Prompt + $suffix)
        if (-not (Test-SecureEmpty $ss)) { $store[$name] = ConvertTo-Dpapi $ss; $changed.Add($name) }
    } else {
        $v = Read-Host -Prompt ($f.Prompt + $suffix)
        if ($v) { $store[$name] = ConvertTo-Dpapi (ConvertTo-SecureString -String $v.Trim() -AsPlainText -Force); $changed.Add($name) }
    }
}

if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
$json = $store | ConvertTo-Json -Depth 2
[System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))

# ACL：仅当前用户（尽力而为）
try {
    $user = if ($env:USERDOMAIN) { "$env:USERDOMAIN\$env:USERNAME" } else { $env:USERNAME }
    & icacls.exe $path /inheritance:r /grant:r "${user}:F" 2>&1 | Out-Null
} catch {}

$missing = @($fields.Keys | Where-Object { -not $fields[$_].Optional -and -not $store.Contains($_) })
Write-Host ("已写入 {0}" -f $path)
Write-Host ("本次更新：{0}" -f $(if ($changed.Count) { $changed -join ', ' } else { '（无）' }))
Write-Host ("已保存项：{0}" -f (@($store.Keys) -join ', '))
if ($missing.Count) { Write-Warning ("缺少必需项：{0}" -f ($missing -join ', ')) }
exit 0
