#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Lares 部署脚本 —— 幂等、可重跑、机场优先
#
# 流程:
#   1. 跑 preflight.sh,不过就直接退出(绝不带病部署)
#   2. 记录回滚快照(当前运行的容器 / 镜像)
#   3. 断言:全程不碰 xray / 3x-ui 的任何配置与 unit
#   4. 拉起 / 更新 stack
#   5. 等健康:lares-server /health、LiveKit、TLS 证书
#   6. **复检机场是否仍然存活**(与 preflight 基线对比)—— 全脚本最重要的一步
#      一旦发现机场受影响,立即拆掉新栈并大声报警
#
# 用法:
#   ./deploy.sh              # 正常部署
#   ./deploy.sh --no-build   # 跳过镜像构建(只重启)
#   ./deploy.sh --skip-preflight  # ⚠️ 危险,仅在你刚跑过 preflight 时用
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

DO_BUILD=1
SKIP_PREFLIGHT=0
for arg in "$@"; do
  case "$arg" in
    --no-build)       DO_BUILD=0 ;;
    --skip-preflight) SKIP_PREFLIGHT=1 ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "未知参数:$arg" ;;
  esac
done

cd "$SCRIPT_DIR"

# ── 断言:本脚本永不触碰机场 ──────────────────────────────────────────────────
# 这不只是注释里的承诺,而是可执行的检查。所有我们会写入的路径都过一遍白名单。
# 任何一处命中机场路径都会立刻 die,且此时尚未做任何改动。
assert_proxy_untouched_by_design() {
  local p
  for p in "$SCRIPT_DIR" "$LARES_STATE_DIR" "$LARES_ENV_FILE"; do
    lares_assert_not_proxy_path "$p"
  done
  # 显式声明:本脚本从不执行任何形如 systemctl <verb> x-ui/xray 的写操作。
  # 我们只用 `systemctl is-active`(只读查询)。若日后有人加了写操作,
  # 下面这条 grep 自检会在部署时报警。
  if grep -nE 'systemctl[[:space:]]+(start|stop|restart|reload|disable|enable|mask)[[:space:]]+.*(x-ui|xray)' \
       "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/lib/*.sh 2>/dev/null | grep -v '^[^:]*:[0-9]*:[[:space:]]*#'; then
    die "内部断言失败:脚本中出现了对 xray/x-ui 的 systemctl 写操作。已中止。"
  fi
  ok "断言通过:本次部署不会读写任何 xray / 3x-ui 配置或 unit。"
}

printf '%s' "$C_CYN"
cat <<'BANNER'
╔══════════════════════════════════════════════════════════════╗
║  Lares 部署                                                  ║
║  原则:机场(xray / 3x-ui)的可用性高于一切                  ║
╚══════════════════════════════════════════════════════════════╝
BANNER
printf '%s' "$C_RST"

# ══════════════════════════════════════════════════════════════════════════════
section "第 1 步 / 共 6 步:部署前体检"
# ══════════════════════════════════════════════════════════════════════════════
if [ "$SKIP_PREFLIGHT" -eq 1 ]; then
  warn "已跳过 preflight(--skip-preflight)。请确保你刚刚手动跑过。"
  if [ ! -f "$LARES_STATE_DIR/occupied.baseline" ]; then
    die "找不到基线文件,无法在部署后比对机场状态。请先跑 ./preflight.sh"
  fi
else
  if ! "$SCRIPT_DIR/preflight.sh"; then
    die "体检未通过,已中止部署。请先解决上面列出的问题。"
  fi
fi

assert_proxy_untouched_by_design

lares_detect_compose || die "找不到可用的 docker compose。"
COMPOSE="$LARES_COMPOSE"
info "使用:$COMPOSE"

# 校验 compose 文件本身(会展开所有 ${VAR},缺变量会在这里就报错)
if ! $COMPOSE config >/dev/null 2>"$LARES_STATE_DIR/compose-config.err"; then
  fail "docker compose config 校验失败:"
  sed 's/^/         /' "$LARES_STATE_DIR/compose-config.err" >&2
  die "请修正 .env 或 docker-compose.yml 后重试。"
fi
ok "compose 配置校验通过。"

# ══════════════════════════════════════════════════════════════════════════════
section "第 2 步 / 共 6 步:记录回滚快照"
# ══════════════════════════════════════════════════════════════════════════════
lares_assert_not_proxy_path "$LARES_STATE_DIR"
mkdir -p "$LARES_STATE_DIR"
SNAPSHOT="$LARES_STATE_DIR/rollback-$(date -u +%Y%m%dT%H%M%SZ).txt"
{
  printf '# Lares 部署前快照 %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  printf '# 仅记录本项目自己的容器/镜像,不含系统任何其它内容\n\n'
  printf '## 当前 lares 栈容器\n'
  $COMPOSE ps --format '{{.Name}}\t{{.Image}}\t{{.State}}' 2>/dev/null || printf '(无)\n'
  printf '\n## 当前镜像\n'
  docker images --format '{{.Repository}}:{{.Tag}}\t{{.ID}}' 2>/dev/null |
    grep -E 'lares|livekit|caddy' || printf '(无)\n'
} > "$SNAPSHOT"
ok "快照:$SNAPSHOT"
info "回滚方式:./rollback.sh(或 $COMPOSE down)"

# ══════════════════════════════════════════════════════════════════════════════
section "第 3 步 / 共 6 步:拉起 stack"
# ══════════════════════════════════════════════════════════════════════════════
tls_mode="$(env_get LARES_TLS_MODE dns)"
https_port="$(env_get LARES_HTTPS_PORT 8444)"
domain="$(env_get LARES_DOMAIN '')"

# DNS 模式需要自建镜像;不存在就现场构建(并警告内存开销)
if [ "$tls_mode" = "dns" ]; then
  caddy_image="$(env_get LARES_CADDY_IMAGE '')"
  if [ -n "$caddy_image" ] && ! docker image inspect "$caddy_image" >/dev/null 2>&1; then
    warn "镜像 $caddy_image 不存在,现在构建(编译 Caddy 比较吃内存)……"
    IMAGE_TAG="$caddy_image" "$SCRIPT_DIR/caddy/build-caddy.sh"
  fi
fi

if [ "$DO_BUILD" -eq 1 ]; then
  info "构建 lares-server 镜像……"
  $COMPOSE build lares-server
fi

info "启动服务(up -d)……"
# --remove-orphans:清掉改名/删掉的旧服务,保证幂等
$COMPOSE up -d --remove-orphans

# ══════════════════════════════════════════════════════════════════════════════
section "第 4 步 / 共 6 步:等待服务就绪"
# ══════════════════════════════════════════════════════════════════════════════
wait_for() {
  # wait_for <描述> <超时秒> <命令...>
  local desc="$1" timeout="$2"; shift 2
  local waited=0
  printf '         等待 %s ' "$desc"
  while [ "$waited" -lt "$timeout" ]; do
    if "$@" >/dev/null 2>&1; then
      printf ' 就绪\n'
      return 0
    fi
    printf '.'
    sleep 2
    waited=$((waited + 2))
  done
  printf ' 超时\n'
  return 1
}

# 用 compose 的服务名执行,不依赖「lares-lares-server-1」这种由 compose
# 自动生成、会随版本变化的容器名。
probe_lares_health() {
  $COMPOSE exec -T lares-server node -e \
    "require('http').get('http://127.0.0.1:8787/health',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"
}

# LiveKit 镜像里不保证有 curl/wget,所以从 lares-server 容器(有 node)去探
# 内网的 livekit:7880。健康时返回 200;节点统计陈旧时返回 406(不是 503)。
probe_livekit() {
  $COMPOSE exec -T lares-server node -e \
    "require('http').get('http://livekit:7880/',r=>process.exit([200,406].includes(r.statusCode)?0:1)).on('error',()=>process.exit(1))"
}

# 4a. lares-server /health
if wait_for "lares-server /health" 60 probe_lares_health; then
  ok "lares-server /health 正常。"
else
  fail "lares-server 未能就绪。最近日志:"
  $COMPOSE logs --tail 40 lares-server 2>&1 | sed 's/^/         /' >&2
fi

# 4b. LiveKit 信令端口
if wait_for "LiveKit 信令端口" 60 probe_livekit; then
  ok "LiveKit 信令端口应答正常。"
else
  if [ "$($COMPOSE ps -q livekit 2>/dev/null | head -n1 | xargs -r \
          docker inspect -f '{{.State.Running}}' 2>/dev/null)" = "true" ]; then
    warn "探针未通过,但 LiveKit 容器处于运行状态。请查看日志确认。"
  else
    fail "LiveKit 容器未在运行。最近日志:"
  fi
  $COMPOSE logs --tail 40 livekit 2>&1 | sed 's/^/         /' >&2
fi

# 4c. TLS:证书是否真的签下来并能服务
section "第 5 步 / 共 6 步:验证 TLS"
if [ "$tls_mode" = "dns" ]; then
  info "DNS-01 首次签发通常需要 30~90 秒(要等 DNS TXT 记录传播)……"
  tls_timeout=180
else
  tls_timeout=30
fi

tls_ok=0
if command -v openssl >/dev/null 2>&1 && [ -n "$domain" ]; then
  waited=0
  printf '         等待 TLS 证书 '
  while [ "$waited" -lt "$tls_timeout" ]; do
    if printf '' | timeout 10 openssl s_client -connect "127.0.0.1:${https_port}" \
         -servername "$domain" 2>/dev/null | grep -q 'BEGIN CERTIFICATE'; then
      printf ' 就绪\n'
      tls_ok=1
      break
    fi
    printf '.'
    sleep 5
    waited=$((waited + 5))
  done
  [ "$tls_ok" -eq 1 ] || printf ' 超时\n'
fi

if [ "$tls_ok" -eq 1 ]; then
  cert_info="$(printf '' | timeout 10 openssl s_client -connect "127.0.0.1:${https_port}" \
    -servername "$domain" 2>/dev/null |
    openssl x509 -noout -subject -issuer -dates 2>/dev/null || true)"
  ok "TLS 端口 ${https_port} 正在提供证书:"
  printf '%s\n' "$cert_info" | sed 's/^/         /'
  if printf '%s' "$cert_info" | grep -qi 'Caddy Local Authority'; then
    warn "这是 Caddy 自签证书 —— 浏览器与 iOS 会拒绝。仅可用于冒烟测试。"
  fi
else
  if [ "$tls_mode" = "selfsigned" ]; then
    warn "未能验证 TLS(selfsigned 模式下可忽略,自行 curl -k 测试)。"
  else
    fail "TLS 端口 ${https_port} 未能提供有效证书。"
    fail "  DNS-01 常见原因:CLOUDFLARE_API_TOKEN 权限不足、域名不在该 CF 账号下、"
    fail "  或 DNS 尚未传播。查看日志:$COMPOSE logs caddy"
    $COMPOSE logs --tail 30 caddy 2>&1 | sed 's/^/         /' >&2
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
section "第 6 步 / 共 6 步:复检机场是否仍然存活 ★最重要★"
# ══════════════════════════════════════════════════════════════════════════════
# 这是整个脚本存在的理由。前面所有步骤失败都只是「Lares 没起来」,
# 而这一步失败意味着「主人和朋友们翻不了墙了」—— 严重性完全不同。
proxy_broken=0

# (a) 占用端口逐一比对基线
if [ -f "$LARES_STATE_DIR/occupied.baseline" ]; then
  current_occupied="$(lares_capture_occupied_state)"
  printf '%s' "$current_occupied" > "$LARES_STATE_DIR/occupied.after"

  while IFS= read -r base_line; do
    [ -n "$base_line" ] || continue
    pp="${base_line%% *}"
    base_state="${base_line##* }"
    cur_line="$(printf '%s\n' "$current_occupied" | grep "^${pp} " || true)"
    cur_state="${cur_line##* }"

    if [ "$base_state" = "listening" ] && [ "$cur_state" != "listening" ]; then
      fail "★ 端口 $pp 部署前在监听,现在**不在了** —— 机场很可能被影响了!"
      proxy_broken=1
    fi
  done <<< "$(cat "$LARES_STATE_DIR/occupied.baseline")"

  if [ "$proxy_broken" -eq 0 ]; then
    ok "所有机场端口仍在监听,与部署前基线一致。"
  fi
else
  warn "缺少基线文件,无法做前后比对。"
fi

# (b) systemd 单元仍然 active
for unit in "${LARES_PROXY_UNITS[@]}"; do
  set +e
  lares_unit_active "$unit"; rc=$?
  set -e
  case "$rc" in
    0) ok "${unit}.service 仍在运行。" ;;
    1) fail "★ ${unit}.service **已停止** —— 请立即检查!"; proxy_broken=1 ;;
    2) : ;; # 未安装,preflight 已经说明过
  esac
done

# (c) 主动握手探活
if lares_probe_tls_port 127.0.0.1 443 8; then
  ok "443/tcp TLS 握手成功 —— Reality 入站仍在应答。"
else
  # preflight 时若也失败过,说明是该入站的正常行为,不算回归
  if grep -q '^443/tcp listening' "$LARES_STATE_DIR/occupied.baseline" 2>/dev/null &&
     ! port_in_use 443 tcp; then
    fail "★ 443/tcp 已无监听 —— 机场挂了!"
    proxy_broken=1
  else
    warn "443/tcp 握手未成功,但端口仍在监听(可能是 Reality 对无效 SNI 的正常拒绝)。"
    warn "      请用你自己的客户端实测一次以确认。"
  fi
fi

# ── 机场受损 → 立即自动拆栈 ──────────────────────────────────────────────────
if [ "$proxy_broken" -eq 1 ]; then
  printf '\n%s' "$C_RED"
  cat <<'ALERT'
╔══════════════════════════════════════════════════════════════╗
║  ⚠⚠⚠  机场状态异常 —— 正在自动拆除 Lares 新栈  ⚠⚠⚠          ║
╚══════════════════════════════════════════════════════════════╝
ALERT
  printf '%s' "$C_RST"
  warn "为把机场恢复到部署前状态,现在执行 down(不删数据卷)……"
  $COMPOSE down --remove-orphans || true

  printf '\n%s请立刻人工确认以下各项:%s\n' "$C_RED" "$C_RST"
  printf '  1. systemctl status x-ui xray\n'
  printf '  2. ss -tulpn | grep -E ":(443|8443|9721|2096|3443)"\n'
  printf '  3. 用你自己的客户端实测能否翻墙\n'
  printf '  4. 需要时:sudo systemctl restart x-ui\n'
  printf '\n注意:Lares 已拆除,但**机场的恢复需要你亲自确认**。\n'
  exit 2
fi

# ══════════════════════════════════════════════════════════════════════════════
hr
if [ "$LARES_FAILURES" -gt 0 ]; then
  printf '%s✗ 部署完成但有 %d 项失败%s(机场未受影响)。请检查上面的错误。\n' \
    "$C_YEL" "$LARES_FAILURES" "$C_RST"
  hr
  exit 1
fi

printf '%s✓ 部署成功%s  机场未受影响。\n' "$C_GRN" "$C_RST"
hr
printf '\n客户端连接地址:\n'
printf '  信令   wss://%s:%s/ws\n' "$domain" "$https_port"
printf '  LiveKit %s\n' "$(env_get LIVEKIT_PUBLIC_URL '')"
printf '\n构建命令示例:\n'
printf '  flutter build web --dart-define=LARES_SIGNALING=wss://%s:%s/ws\n' "$domain" "$https_port"
printf '\n常用运维:\n'
printf '  %s logs -f lares-server\n' "$COMPOSE"
printf '  %s ps\n' "$COMPOSE"
printf '  ./rollback.sh          # 拆掉 Lares(保留数据)\n'
exit 0
