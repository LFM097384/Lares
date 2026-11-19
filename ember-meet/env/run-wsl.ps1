# ember-meet · 在 WSL2 Ubuntu 里跑(Xvfb 虚拟显示 + PulseAudio + 有头 Chromium)。先跑一次 env/setup-wsl.sh。
#   pwsh -File ember-meet/env/run-wsl.ps1 -Url "<Teams 会议链接>" [-Speaker] [-Distro Ubuntu] [-- 其它 index.mjs 参数]
#   -Speaker:同时在 WSL 里拉起模拟说话人(需要先在 Windows 上生成 .data/ember-meet/speaker.wav)
# LLM 只用 DeepSeek:把 Windows 当前会话里的 LARES_AI_LLM_* 通过 WSLENV 传进 WSL(只传名字列表里的这几个,值不打印)。
param(
  [Parameter(Mandatory = $true)][string]$Url,
  [switch]$Speaker,
  [string]$Distro = 'Ubuntu',
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)
$ErrorActionPreference = 'Stop'
$repoWin = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$repo = (wsl -d $Distro -- wslpath -a ($repoWin -replace '\\', '/')).Trim()
$pass = @('LARES_AI_LLM_API_KEY', 'LARES_AI_LLM_KEY', 'LARES_AI_LLM_BASE_URL', 'LARES_AI_LLM_MODEL', 'EMBER_K', 'EMBER_CONVENER_NAME') | Where-Object { Test-Path "env:$_" }
$env:WSLENV = (@($env:WSLENV) + $pass | Where-Object { $_ }) -join ':'
$quote = { param($s) "'" + ($s -replace "'", "'\''") + "'" }
$extra = ($Rest | ForEach-Object { & $quote $_ }) -join ' '
$u = & $quote $Url
# profile 与记忆留在 WSL 自己的家目录里(Linux 文件系统,不跨 /mnt/d)
$script = @"
set -e
export EMBER_PLAYWRIGHT_DIR="`$HOME/.ember-meet/node_modules/playwright"
export EMBER_MEET_PROFILE="`$HOME/.ember-meet/profile"
export EMBER_MEMORY_DIR="`$HOME/.ember-meet/memory"
pulseaudio --check 2>/dev/null || pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 || true
cd $repo
if [ "$($Speaker.IsPresent)" = "True" ]; then
  xvfb-run -a -s '-screen 0 1366x860x24' node ember-meet/sim/speaker.mjs --url $u --headed --wav .data/ember-meet/speaker.wav &
  SPK=`$!
  trap 'kill `$SPK 2>/dev/null || true' EXIT
fi
xvfb-run -a -s '-screen 0 1366x860x24' node ember-meet/index.mjs --url $u --headed $extra
"@
wsl -d $Distro -- bash -lc ($script -replace "`r", '')
exit $LASTEXITCODE
