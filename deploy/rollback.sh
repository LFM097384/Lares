#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Lares 回滚 —— 干净拆除 Lares 栈,然后确认机场健康
#
# 设计目标:**能在慌乱中闭眼跑**。
#   · 不需要参数、不需要先读文档
#   · 缺 .env / 缺基线 / compose 报错 都不影响它继续拆
#   · 只动本项目自己的容器、网络、卷 —— 绝不碰 xray / 3x-ui
#   · 拆完主动汇报机场状态
#
# 用法:
#   ./rollback.sh            # 拆容器和网络,**保留**语音便签等数据
#   ./rollback.sh --purge    # 连数据卷一起删(不可恢复,需二次确认)
#   ./rollback.sh --purge --yes   # 跳过确认(脚本化场景)
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

PURGE=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help)
      sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "未知参数:$arg" ;;
  esac
done

cd "$SCRIPT_DIR"

printf '%s' "$C_CYN"
cat <<'BANNER'
╔══════════════════════════════════════════════════════════════╗
║  Lares 回滚                                                  ║
║  只拆 Lares,绝不触碰机场(xray / 3x-ui)                    ║
╚══════════════════════════════════════════════════════════════╝
BANNER
printf '%s' "$C_RST"

# 断言:我们要删的东西都不属于机场
lares_assert_not_proxy_path "$SCRIPT_DIR"

if ! lares_detect_compose; then
  warn "找不到 docker compose,退化为直接用 docker 命令按项目标签清理。"
  COMPOSE=''
else
  COMPOSE="$LARES_COMPOSE"
  info "使用:$COMPOSE"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "第 1 步:记录当前状态(便于事后复盘)"
# ══════════════════════════════════════════════════════════════════════════════
mkdir -p "$LARES_STATE_DIR" 2>/dev/null || true
ROLLBACK_LOG="$LARES_STATE_DIR/rollback-$(date -u +%Y%m%dT%H%M%SZ).log"
{
  printf '# Lares 回滚于 %s\n\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  printf '## 拆除前容器状态\n'
  if [ -n "$COMPOSE" ]; then
    $COMPOSE ps 2>&1 || true
  else
    docker ps --filter 'label=com.docker.compose.project=lares' 2>&1 || true
  fi
} > "$ROLLBACK_LOG" 2>&1 || true
info "记录写入:$ROLLBACK_LOG"

# 拆之前先抓一遍最新日志,不然容器一删日志就没了
if [ -n "$COMPOSE" ]; then
  $COMPOSE logs --tail 100 > "$LARES_STATE_DIR/last-logs.txt" 2>&1 || true
  info "最后 100 行日志已存:$LARES_STATE_DIR/last-logs.txt"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "第 2 步:确认删除范围"
# ══════════════════════════════════════════════════════════════════════════════
if [ "$PURGE" -eq 1 ]; then
  printf '%s' "$C_YEL"
  cat <<'WARNPURGE'
  ⚠️  --purge 会**永久删除**数据卷:
        lares_lares-data   语音便签、圈子敲门设置
        lares_caddy-data   TLS 证书与 ACME 账号(删了要重新签发,注意速率限制)
        lares_caddy-config
      此操作不可恢复。
WARNPURGE
  printf '%s' "$C_RST"
  if [ "$ASSUME_YES" -ne 1 ]; then
    printf '  确认删除数据卷?输入 %sDELETE%s 继续,其它任意键取消:' "$C_RED" "$C_RST"
    read -r confirm || confirm=''
    if [ "$confirm" != "DELETE" ]; then
      info "已取消 purge,改为只拆容器(保留数据)。"
      PURGE=0
    fi
  fi
else
  info "保留数据卷(如需一并删除请加 --purge)。"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "第 3 步:拆除 Lares 栈"
# ══════════════════════════════════════════════════════════════════════════════
down_ok=0
if [ -n "$COMPOSE" ]; then
  # compose down 可能因为 .env 缺变量而失败,所以失败了还有兜底路径
  if [ "$PURGE" -eq 1 ]; then
    if $COMPOSE down --volumes --remove-orphans; then down_ok=1; fi
  else
    if $COMPOSE down --remove-orphans; then down_ok=1; fi
  fi
fi

if [ "$down_ok" -eq 0 ]; then
  warn "compose down 未成功(常见原因:.env 缺变量导致配置解析失败)。"
  warn "      改用按项目标签直接清理 —— 这条路不依赖 .env。"

  # 按 compose 项目标签精确定位,不会误伤别的容器
  cids="$(docker ps -aq --filter 'label=com.docker.compose.project=lares' 2>/dev/null || true)"
  if [ -n "$cids" ]; then
    # shellcheck disable=SC2086
    docker rm -f $cids >/dev/null 2>&1 && ok "已强制删除 Lares 容器。" || warn "删除容器时出错。"
  else
    info "没有找到属于 lares 项目的容器(可能已经拆干净了)。"
  fi

  docker network rm lares_default >/dev/null 2>&1 && ok "已删除网络 lares_default。" || true

  if [ "$PURGE" -eq 1 ]; then
    for vol in lares_lares-data lares_caddy-data lares_caddy-config; do
      docker volume rm "$vol" >/dev/null 2>&1 && ok "已删除卷 $vol。" || true
    done
  fi
else
  ok "Lares 栈已拆除。"
fi

# 确认真的没有残留
remaining="$(docker ps -q --filter 'label=com.docker.compose.project=lares' 2>/dev/null || true)"
if [ -n "$remaining" ]; then
  fail "仍有 Lares 容器在运行:"
  docker ps --filter 'label=com.docker.compose.project=lares' 2>&1 | sed 's/^/         /' >&2
else
  ok "确认:已无运行中的 Lares 容器。"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "第 4 步:确认机场健康 ★回滚的真正目的★"
# ══════════════════════════════════════════════════════════════════════════════
proxy_ok=1

for unit in "${LARES_PROXY_UNITS[@]}"; do
  set +e
  lares_unit_active "$unit"; rc=$?
  set -e
  case "$rc" in
    0) ok "${unit}.service 运行中。" ;;
    1) fail "${unit}.service **已停止**!"; proxy_ok=0 ;;
    2) info "${unit}.service 未安装(可能是 docker 部署或改了名)。" ;;
  esac
done

info "关键端口现状:"
while IFS= read -r line; do
  pp="${line%% *}"; state="${line##* }"
  if [ "$state" = "listening" ]; then
    printf '         %s%-12s 监听中%s\n' "$C_GRN" "$pp" "$C_RST"
  else
    printf '         %s%-12s 无监听%s\n' "$C_RED" "$pp" "$C_RST"
    case "$pp" in
      443/tcp|8443/tcp|9721/tcp) proxy_ok=0 ;;
    esac
  fi
done <<< "$(lares_capture_occupied_state)"

if lares_probe_tls_port 127.0.0.1 443 8; then
  ok "443/tcp TLS 握手成功 —— Reality 入站在应答。"
else
  warn "443/tcp 握手未成功(可能是对无效 SNI 的正常拒绝)。请用自己的客户端实测。"
fi

# ══════════════════════════════════════════════════════════════════════════════
hr
if [ "$proxy_ok" -eq 1 ]; then
  printf '%s✓ 回滚完成%s  Lares 已拆除,机场看起来正常。\n' "$C_GRN" "$C_RST"
  hr
  printf '\n仍建议用你自己的客户端实测一次翻墙,眼见为实。\n'
  exit 0
fi

printf '%s✗ 回滚完成,但机场状态异常%s\n' "$C_RED" "$C_RST"
hr
printf '\n请立即人工处理:\n'
printf '  sudo systemctl status x-ui\n'
printf '  sudo systemctl restart x-ui\n'
printf '  sudo journalctl -u x-ui -n 100 --no-pager\n'
printf '  ss -tulpn | grep -E ":(443|8443|9721|2096|3443)"\n'
printf '\n注意:Lares 这边已经拆干净了。若机场仍不正常,\n'
printf '      原因很可能与本次部署无关(但仍请核实)。\n'
exit 1
