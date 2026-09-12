#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# 构建带 Cloudflare DNS 插件的 Caddy 镜像(LARES_TLS_MODE=dns 需要)
#
# Building Caddy from source is memory-hungry. On the shared 1GB VPS this
# competes with xray for RAM, so we refuse to build there unless forced.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

IMAGE_TAG="${IMAGE_TAG:-lares-caddy:dns}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Colours only when attached to a terminal.
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_RST=$'\033[0m'
else
  C_RED=''; C_YEL=''; C_GRN=''; C_RST=''
fi
err()  { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
warn() { printf '%s[WARN ]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
ok()   { printf '%s[ OK  ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }

# Resolve the compose CLI flavour (v2 plugin preferred).
if docker compose version >/dev/null 2>&1; then
  :
elif ! command -v docker >/dev/null 2>&1; then
  err "未找到 docker,无法构建。"
  exit 1
fi

# Guard: building on a tiny box starves the proxy.
if [ -r /proc/meminfo ]; then
  mem_avail_kb="$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo || echo 0)"
  mem_avail_mb=$(( mem_avail_kb / 1024 ))
  if [ "$mem_avail_mb" -lt 700 ]; then
    warn "可用内存仅 ${mem_avail_mb}MB。在本机编译 Caddy 可能与机场(xray)抢内存,"
    warn "严重时触发 OOM killer 杀掉 xray —— 这正是我们要避免的事。"
    warn ""
    warn "建议改在本地/另一台机器构建后导入:"
    warn "  docker build -t ${IMAGE_TAG} ."
    warn "  docker save ${IMAGE_TAG} | gzip > lares-caddy.tgz"
    warn "  scp lares-caddy.tgz vps:/tmp/"
    warn "  ssh vps 'docker load < /tmp/lares-caddy.tgz'"
    warn ""
    if [ "${FORCE_BUILD:-0}" != "1" ]; then
      err "已中止。确认要在本机构建请设 FORCE_BUILD=1 重跑。"
      exit 1
    fi
    warn "FORCE_BUILD=1 已设置,继续构建……"
  fi
fi

printf '正在构建 %s ……\n' "$IMAGE_TAG"
docker build -t "$IMAGE_TAG" "$SCRIPT_DIR"

ok "镜像构建完成:${IMAGE_TAG}"
printf '\n下一步:在 deploy/.env 中设置\n'
printf '  LARES_CADDY_IMAGE=%s\n' "$IMAGE_TAG"
printf '  LARES_TLS_MODE=dns\n'
printf '  CLOUDFLARE_API_TOKEN=<你的 token>\n'
