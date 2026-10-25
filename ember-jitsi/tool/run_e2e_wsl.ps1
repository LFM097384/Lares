# ember-jitsi · 在 WSL2 里的官方 Playwright 容器中跑真 Jitsi e2e(浏览器走 Linux host 网络,媒体 ICE 可直连 JVB)。
# 为什么:WSL mirrored 网络下,Windows 侧 Chromium 到 WSL 里 JVB 的 UDP 回包被丢(ICE 卡在 checking);容器内正常。
# 密钥只走环境变量(WSLENV 传进 WSL,docker -e NAME 继承),不写文件、不打印。
#   $env:LARES_AI_LLM_KEY=…; $env:LARES_AI_LLM_BASE_URL=…; $env:LARES_AI_LLM_MODEL=…   # 可选 $env:LARES_DASHSCOPE_API_KEY
#   pwsh ember-jitsi/tool/run_e2e_wsl.ps1            # -ViaDesk:bot 经 ember-desk 会话管理器拉起(EMBER_E2E_VIA_DESK=1,多一项检查 [9])
param([string]$Distro = 'Ubuntu', [string]$JitsiUrl = 'https://localhost:8443', [string]$Image = 'mcr.microsoft.com/playwright:v1.64.1-noble', [switch]$ViaDesk)
$ErrorActionPreference = 'Stop'
if (-not $env:LARES_DASHSCOPE_API_KEY) {
  $csv = Join-Path $HOME 'Downloads\默认业务空间-apiKey-6421725.csv'
  if (Test-Path $csv) { foreach ($l in Get-Content $csv -Encoding utf8) { $k, $v = $l -split ',', 2; if ($k.Trim() -eq 'apiKey') { $env:LARES_DASHSCOPE_API_KEY = $v.Trim() } } }
}
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$toWsl = { param($p) '/mnt/' + $p.Substring(0, 1).ToLower() + ($p.Substring(2) -replace '\\', '/') }
$pw = (Get-ChildItem "$env:LOCALAPPDATA\npm-cache\_npx" -Directory | ForEach-Object { Join-Path $_.FullName 'node_modules\playwright' } | Where-Object { Test-Path (Join-Path $_ 'package.json') } | Select-Object -First 1)
if (-not $pw) { throw 'playwright package not found in npx cache (run: npx playwright --version)' }
$cache = Join-Path $env:TEMP 'ember-jitsi-e2e-cache'; New-Item -ItemType Directory -Force $cache | Out-Null
$env:JITSI_URL = $JitsiUrl
$env:WSLENV = 'LARES_AI_LLM_KEY:LARES_AI_LLM_API_KEY:LARES_AI_LLM_BASE_URL:LARES_AI_LLM_MODEL:LARES_DASHSCOPE_API_KEY:JITSI_URL'
$deskEnv = if ($ViaDesk) { '-e EMBER_E2E_VIA_DESK=1 ' } else { '' }
$R = & $toWsl $repo; $P = & $toWsl (Split-Path $pw -Parent); $C = & $toWsl $cache
$cmd = "docker run --rm --network host --ipc host -e LARES_AI_LLM_KEY -e LARES_AI_LLM_API_KEY -e LARES_AI_LLM_BASE_URL -e LARES_AI_LLM_MODEL -e LARES_DASHSCOPE_API_KEY -e JITSI_URL $deskEnv" +
  "-e EMBER_PLAYWRIGHT_DIR=/pw/node_modules/playwright -e EMBER_E2E_CACHE=/cache -v '${R}:/repo' -v '${P}:/pw/node_modules:ro' -v '${C}:/cache' -w /repo $Image node ember-jitsi/tool/jitsi_e2e.mjs"
wsl -d $Distro -u root -- bash -lc $cmd
exit $LASTEXITCODE
