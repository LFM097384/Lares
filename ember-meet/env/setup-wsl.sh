#!/usr/bin/env bash
# ember-meet · WSL2 Ubuntu 运行环境(幂等,可反复跑):Xvfb(虚拟显示)+ PulseAudio(虚拟声卡)+ Playwright Chromium(有头,跑在 Xvfb 里)。
#   wsl -d Ubuntu -- bash /mnt/d/Projects/Lares/ember-meet/env/setup-wsl.sh
# 需要:Node >= 22、sudo。Playwright 装到 ~/.ember-meet/node_modules(不污染仓库);浏览器装到 ~/.cache/ms-playwright。
set -euo pipefail

PREFIX="${EMBER_MEET_WSL_HOME:-$HOME/.ember-meet}"
PW_VERSION="${EMBER_MEET_PLAYWRIGHT_VERSION:-1.64.1}"
say() { printf '[setup-wsl] %s\n' "$*"; }

command -v node >/dev/null || { say "node not found (need >= 22)"; exit 1; }
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 22 ] || { say "node $NODE_MAJOR too old (need >= 22)"; exit 1; }

PKGS=(xvfb xauth pulseaudio pulseaudio-utils fonts-noto-cjk fonts-noto-color-emoji)
MISSING=()
for p in "${PKGS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p"); done
if [ "${#MISSING[@]}" -gt 0 ]; then
  say "apt install: ${MISSING[*]}"
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${MISSING[@]}"
else
  say "apt packages present"
fi

mkdir -p "$PREFIX"
cd "$PREFIX"
[ -f package.json ] || printf '{"name":"ember-meet-wsl","private":true,"type":"module"}\n' > package.json
if [ "$(node -p "try{require('./node_modules/playwright/package.json').version}catch{''}")" != "$PW_VERSION" ]; then
  say "npm install playwright@$PW_VERSION"
  npm install --no-audit --no-fund --silent "playwright@$PW_VERSION"
else
  say "playwright $PW_VERSION present"
fi

# Chromium + 系统依赖(install-deps 用 apt,已装则很快)
say "playwright install-deps chromium"
sudo env "PATH=$PATH" npx --yes playwright install-deps chromium >/dev/null
say "playwright install chromium"
npx --yes playwright install chromium >/dev/null

# 自检:Xvfb 下有头 Chromium 能起来,PulseAudio 能起来
say "self-test"
pulseaudio --check 2>/dev/null || pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 || say "pulseaudio did not start (audio optional; captions do not need it)"
xvfb-run -a -s "-screen 0 1366x860x24" node --input-type=module -e "
const { chromium } = await import('$PREFIX/node_modules/playwright/index.mjs');
const b = await chromium.launch({ headless: false, args: ['--use-fake-ui-for-media-stream','--use-fake-device-for-media-stream'] });
const v = b.version(); await b.close(); console.log(JSON.stringify({ ok: true, chromium: v, headed: true, display: process.env.DISPLAY }));
"
say "done. EMBER_PLAYWRIGHT_DIR=$PREFIX/node_modules/playwright"
