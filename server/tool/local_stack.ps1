<#
.SYNOPSIS
  Local Lares stack on this Windows machine (no Docker): livekit-server --dev + signaling server.

.DESCRIPTION
  start  : starts LiveKit (127.0.0.1:7880, devkey/secret) and server/src/index.js (port 8787,
           data dir .local-server\data, circle auth like prod) as background processes.
  stop   : kills both process trees (including AI child processes spawned by the server).
  status : shows listeners / pids / log paths.

  Secrets are NEVER stored in this file or written anywhere by it:
    LARES_DASHSCOPE_API_KEY  from env, else read from -KeyCsv (apiKey,<key> row) into the process env only.
    LARES_AI_LLM_KEY / LARES_AI_LLM_BASE_URL / LARES_AI_LLM_MODEL  from the caller's env (optional;
                              without them the voice AI falls back to DashScope qwen-flash).
    LARES_AI_MEMBER_KEY      from env, else freshly generated per start (memory only).
    LARES_CIRCLE_PASSCODE    from env, else random per start (e2e tools register their own v2 circles).

  Logs: .local-server\livekit.log, .local-server\server.log (stdout+stderr merged; the e2e tools
  in --local mode tail server.log).

.EXAMPLE
  $env:LARES_AI_LLM_KEY='sk-...'; $env:LARES_AI_LLM_BASE_URL='https://api.deepseek.com'; $env:LARES_AI_LLM_MODEL='deepseek-flash'
  pwsh server/tool/local_stack.ps1 start
  cd server/tool; node ai_voice_prod_e2e.mjs --local; node anonym_v2_prod_e2e.mjs --local --only plain
  pwsh server/tool/local_stack.ps1 stop
#>
param(
  [Parameter(Position = 0)][ValidateSet('start', 'stop', 'status', 'restart')][string]$Action = 'status',
  [int]$Port = 8787,
  [string]$KeyCsv = 'C:\Users\Liu_F\Downloads\默认业务空间-apiKey-6421725.csv'
)
$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Root = Join-Path $Repo '.local-server'
$Data = Join-Path $Root 'data'
$LkExe = Join-Path $Root 'livekit-server.exe'
$LkLog = Join-Path $Root 'livekit.log'
$SrvLog = Join-Path $Root 'server.log'
$PidFile = Join-Path $Root 'pids.json'
$ServerDir = Join-Path $Repo 'server'

function Get-ListenerPid([int]$p) {
  $c = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { return [int]$c.OwningProcess } else { return $null }
}
function Wait-Http([string]$url, [int]$ms) {
  $t0 = Get-Date
  while (((Get-Date) - $t0).TotalMilliseconds -lt $ms) {
    try { $null = Invoke-WebRequest $url -TimeoutSec 1 -SkipHttpErrorCheck; return $true } catch { Start-Sleep -Milliseconds 250 }
  }
  return $false
}
function Stop-Tree([int]$procId) {
  if ($procId -and (Get-Process -Id $procId -ErrorAction SilentlyContinue)) { & taskkill.exe /T /F /PID $procId *> $null }
}

function Start-Stack {
  New-Item -ItemType Directory -Force -Path $Root, $Data | Out-Null
  if (-not (Test-Path $LkExe)) { throw "missing $LkExe (download livekit_<ver>_windows_amd64.zip from github.com/livekit/livekit/releases)" }
  $pids = @{}

  # ── LiveKit ──
  if (Get-ListenerPid 7880) { Write-Host "livekit: 7880 already listening (pid $(Get-ListenerPid 7880)), reusing" }
  else {
    $lk = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "`"`"$LkExe`" --dev --bind 127.0.0.1 > `"$LkLog`" 2>&1`"" -WindowStyle Hidden -PassThru
    $pids.livekitWrapper = $lk.Id
    if (-not (Wait-Http 'http://127.0.0.1:7880' 15000)) { throw "livekit did not come up; see $LkLog" }
    Write-Host "livekit: up on ws://127.0.0.1:7880 (pid $(Get-ListenerPid 7880))"
  }

  # ── secrets → env only ──
  if (-not $env:LARES_DASHSCOPE_API_KEY -and (Test-Path -LiteralPath $KeyCsv)) {
    foreach ($line in Get-Content -LiteralPath $KeyCsv -Encoding utf8) {
      $k, $v = $line -split ',', 2
      if ($k.Trim() -eq 'apiKey') { $env:LARES_DASHSCOPE_API_KEY = $v.Trim() }
    }
  }
  if (-not $env:LARES_DASHSCOPE_API_KEY) { Write-Warning 'LARES_DASHSCOPE_API_KEY not set: captions / ASR / TTS disabled' }
  if (-not $env:LARES_AI_LLM_KEY -and -not $env:LARES_AI_LLM_API_KEY) { Write-Warning 'LARES_AI_LLM_KEY not set: voice AI uses DashScope qwen-flash, Ember uses its mock path' }
  if (-not $env:LARES_AI_MEMBER_KEY) { $env:LARES_AI_MEMBER_KEY = -join ((1..32) | ForEach-Object { '{0:x2}' -f (Get-Random -Maximum 256) }) }
  if (-not $env:LARES_CIRCLE_PASSCODE) { $env:LARES_CIRCLE_PASSCODE = "local-$(-join ((1..8) | ForEach-Object { '{0:x2}' -f (Get-Random -Maximum 256) }))" }

  # ── signaling server (prod-like env, see deploy/docker-compose.yml) ──
  if (Get-ListenerPid $Port) { throw "port $Port already in use (pid $(Get-ListenerPid $Port)); run 'stop' first" }
  $env:LIVEKIT_URL = 'ws://127.0.0.1:7880'
  $env:LIVEKIT_API_URL = 'http://127.0.0.1:7880'
  $env:LIVEKIT_API_KEY = 'devkey'
  $env:LIVEKIT_API_SECRET = 'secret'
  $env:LARES_AUTH_MODE = 'circle'
  $env:LARES_PORT = "$Port"
  $env:LARES_DATA_DIR = $Data
  $env:LARES_TRUST_PROXY = 'auto'
  # local e2e registers several throwaway circles per run; prod default is 5/h
  if (-not $env:LARES_CIRCLE_CREATE_PER_HOUR) { $env:LARES_CIRCLE_CREATE_PER_HOUR = '100' }
  Add-Content -LiteralPath $SrvLog -Value "`n===== local_stack start $(Get-Date -Format o) =====" -Encoding utf8
  $node = (Get-Command node).Source
  $srv = Start-Process -FilePath 'cmd.exe' -WorkingDirectory $ServerDir -ArgumentList '/c', "`"`"$node`" src\index.js >> `"$SrvLog`" 2>&1`"" -WindowStyle Hidden -PassThru
  $pids.serverWrapper = $srv.Id
  if (-not (Wait-Http "http://127.0.0.1:$Port/health" 20000)) { throw "server did not come up; see $SrvLog" }
  $h = Invoke-RestMethod "http://127.0.0.1:$Port/health"
  Write-Host "server: up on ws://127.0.0.1:$Port/ws (pid $(Get-ListenerPid $Port)) rtcConfigured=$($h.rtcConfigured)"
  Write-Host "logs: $SrvLog  |  $LkLog  |  data: $Data"
  $pids | ConvertTo-Json | Set-Content -LiteralPath $PidFile -Encoding utf8
}

function Stop-Stack {
  $pids = if (Test-Path $PidFile) { Get-Content $PidFile -Raw | ConvertFrom-Json } else { $null }
  foreach ($procId in @($pids.serverWrapper, (Get-ListenerPid $Port))) { Stop-Tree $procId }
  foreach ($procId in @($pids.livekitWrapper, (Get-ListenerPid 7880))) { Stop-Tree $procId }
  Remove-Item $PidFile -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 500
  Write-Host "stopped. 7880 listening: $([bool](Get-ListenerPid 7880)); $Port listening: $([bool](Get-ListenerPid $Port))"
}

switch ($Action) {
  'start' { Start-Stack }
  'stop' { Stop-Stack }
  'restart' { Stop-Stack; Start-Stack }
  'status' {
    Write-Host "livekit 7880 pid: $(Get-ListenerPid 7880)"
    Write-Host "server $Port pid: $(Get-ListenerPid $Port)"
    Write-Host "logs: $SrvLog  |  $LkLog"
  }
}
