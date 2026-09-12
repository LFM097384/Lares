#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Lares 部署脚本共用库 —— 被 preflight.sh / deploy.sh / rollback.sh 引用
#
# Single source of truth for:
#   - reading deploy/.env the way docker compose reads it (no shell eval)
#   - deriving the set of ports this deployment intends to bind
#   - the "do not touch the proxy" guard rails
#   - proxy baseline capture / comparison
#
# Sourced, never executed directly. Callers must already have set -euo pipefail.
# ──────────────────────────────────────────────────────────────────────────────

# Resolve deploy/ regardless of where the caller was invoked from.
LARES_DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly LARES_DEPLOY_DIR
LARES_ENV_FILE="${LARES_ENV_FILE:-$LARES_DEPLOY_DIR/.env}"

# State captured by preflight, consumed by deploy for before/after comparison.
LARES_STATE_DIR="${LARES_STATE_DIR:-$LARES_DEPLOY_DIR/.state}"

# ── 输出 ──────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  C_RED=$'\033[1;31m'; C_YEL=$'\033[1;33m'; C_GRN=$'\033[1;32m'
  C_CYN=$'\033[1;36m'; C_DIM=$'\033[2m';    C_RST=$'\033[0m'
else
  C_RED=''; C_YEL=''; C_GRN=''; C_CYN=''; C_DIM=''; C_RST=''
fi

# Failure/warning tallies. Callers read these for the PASS/FAIL summary.
LARES_FAILURES=0
LARES_WARNINGS=0

log()   { printf '%s\n' "$*"; }
info()  { printf '%s[ INFO]%s %s\n' "$C_CYN" "$C_RST" "$*"; }
ok()    { printf '%s[  OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s[ WARN]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; LARES_WARNINGS=$((LARES_WARNINGS + 1)); }
fail()  { printf '%s[ FAIL]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; LARES_FAILURES=$((LARES_FAILURES + 1)); }
die()   { printf '%s[FATAL]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
hr()    { printf '%s────────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RST"; }
section() { printf '\n%s▶ %s%s\n' "$C_CYN" "$*" "$C_RST"; }

# ── 机场保护:绝对不许碰的东西 ────────────────────────────────────────────────
# Any path matching these must never be read, written, or touched by us.
# deploy.sh asserts against this list before doing anything.
readonly LARES_FORBIDDEN_PATHS=(
  '/usr/local/x-ui'
  '/etc/x-ui'
  '/usr/local/etc/xray'
  '/etc/xray'
  '/opt/3x-ui'
  '/etc/systemd/system/x-ui.service'
  '/etc/systemd/system/xray.service'
)

# Service names we consider "the proxy". Checked for liveness, never modified.
readonly LARES_PROXY_UNITS=('x-ui' 'xray')

# Ports the proxy owns. Hard conflicts — the deployment must never bind these.
# Format: "port/proto  description"
readonly LARES_OCCUPIED_PORTS=(
  '443/tcp:VLESS+Reality 主入站(伪装 www.apple.com)'
  '8443/tcp:第二 Reality 入站 seattle-low'
  '3443/udp:Hysteria2 入站(移动端)'
  '9721/tcp:3x-ui 管理面板'
  '2096/tcp:订阅端点'
  '22/tcp:SSH(fail2ban 保护中)'
)

# ── .env 读取 ────────────────────────────────────────────────────────────────
# Parse a compose-style .env WITHOUT sourcing it (sourcing would execute code,
# and compose does not do shell expansion anyway — sourcing would be *wrong*,
# not merely unsafe). Returns the raw value, quotes stripped.
env_get() {
  local key="$1" default="${2-}" line value
  if [ ! -r "$LARES_ENV_FILE" ]; then
    printf '%s' "$default"
    return 0
  fi
  # Last assignment wins, mirroring compose behaviour.
  line="$(grep -E "^[[:space:]]*${key}=" "$LARES_ENV_FILE" 2>/dev/null | tail -n 1 || true)"
  if [ -z "$line" ]; then
    printf '%s' "$default"
    return 0
  fi
  value="${line#*=}"
  # Strip surrounding quotes if present.
  case "$value" in
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
  esac
  # Trim trailing whitespace/CR (files edited on Windows carry \r).
  value="${value%$'\r'}"
  value="${value%"${value##*[![:space:]]}"}"
  if [ -z "$value" ]; then
    printf '%s' "$default"
  else
    printf '%s' "$value"
  fi
}

# ── 意图端口推导 ─────────────────────────────────────────────────────────────
# THE anti-drift mechanism: every script derives the port list from here, which
# derives it from the same .env + the same defaults as docker-compose.yml.
# Defaults MUST stay in sync with the ${VAR:-default} values in the compose file.
#
# Emits one "port/proto:description" per line.
lares_intended_ports() {
  local https_port rtc_tcp rtc_udp turn_enabled turn_tls turn_udp

  https_port="$(env_get LARES_HTTPS_PORT 8444)"
  rtc_tcp="$(env_get LARES_RTC_TCP_PORT 7881)"
  rtc_udp="$(env_get LARES_RTC_UDP_PORT 7882)"
  turn_enabled="$(env_get LARES_TURN_ENABLED false)"

  printf '%s/tcp:Caddy TLS(信令+LiveKit+REST)\n' "$https_port"
  printf '%s/tcp:LiveKit ICE/TCP 兜底\n' "$rtc_tcp"
  printf '%s/udp:LiveKit UDP mux(主媒体通道)\n' "$rtc_udp"

  # TURN is off by default; only claim its ports when actually enabled.
  case "$turn_enabled" in
    true|TRUE|True|1|yes)
      turn_tls="$(env_get LARES_TURN_TLS_PORT 5349)"
      turn_udp="$(env_get LARES_TURN_UDP_PORT 3478)"
      printf '%s/tcp:LiveKit TURN/TLS\n' "$turn_tls"
      printf '%s/udp:LiveKit TURN/UDP\n' "$turn_udp"
      ;;
  esac
}

# ── 端口占用探测 ─────────────────────────────────────────────────────────────
# Returns 0 (true) when something is LISTENING on port/proto.
# Uses ss; parses the local-address column so ":8444" doesn't match ":18444".
port_in_use() {
  local port="$1" proto="$2" flag
  case "$proto" in
    tcp) flag='-tlnH' ;;
    udp) flag='-ulnH' ;;
    *)   return 1 ;;
  esac
  # Column 4 (with -H) is Local Address:Port. Strip to the final :port.
  ss $flag 2>/dev/null | awk -v p=":$port" '
    { addr = $4; n = split(addr, a, ":"); if (":" a[n] == p) { found = 1 } }
    END { exit(found ? 0 : 1) }
  '
}

# Who is listening on port/proto (best effort; needs root for process names).
port_owner() {
  local port="$1" proto="$2" flag
  case "$proto" in
    tcp) flag='-tlnpH' ;;
    udp) flag='-ulnpH' ;;
    *)   return 0 ;;
  esac
  ss $flag 2>/dev/null | awk -v p=":$port" '
    { addr = $4; n = split(addr, a, ":");
      if (":" a[n] == p) { $1=$1; print; exit } }' || true
}

# ── 机场基线 ─────────────────────────────────────────────────────────────────
# Capture a normalised, comparable snapshot of the proxy's listening sockets.
# Deliberately records only "proto + listening port" — NOT PIDs and NOT
# established client connections, both of which churn constantly and would
# produce false alarms. A legitimate xray restart changes the PID but keeps the
# same listening set, and that must not read as "the proxy broke".
lares_capture_proxy_baseline() {
  {
    # Listening sockets belonging to xray / x-ui, as "proto port".
    ss -tulnpH 2>/dev/null | awk '
      /xray|x-ui/ {
        proto = $1
        addr  = $5
        n = split(addr, a, ":")
        port = a[n]
        if (port ~ /^[0-9]+$/) print proto, port
      }' | sort -u
  } 2>/dev/null || true
}

# Capture the occupied-port listen state regardless of which process owns it.
# This is the real safety net: even if we cannot see process names (no root),
# we can still assert "something is still listening on 443/tcp".
lares_capture_occupied_state() {
  local entry port proto
  for entry in "${LARES_OCCUPIED_PORTS[@]}"; do
    port="${entry%%/*}"
    proto="${entry#*/}"; proto="${proto%%:*}"
    if port_in_use "$port" "$proto"; then
      printf '%s/%s listening\n' "$port" "$proto"
    else
      printf '%s/%s absent\n' "$port" "$proto"
    fi
  done
}

# Is a systemd unit active? Returns 0 when active, 1 otherwise, 2 when unknown.
lares_unit_active() {
  local unit="$1"
  command -v systemctl >/dev/null 2>&1 || return 2
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    return 0
  fi
  # Distinguish "exists but stopped" from "not installed".
  if systemctl list-unit-files "${unit}.service" >/dev/null 2>&1 &&
     systemctl cat "${unit}.service" >/dev/null 2>&1; then
    return 1
  fi
  return 2
}

# Active liveness probe against the Reality inbound on 443/tcp.
# We cannot speak VLESS, but Reality masquerades as a real TLS site, so a
# successful TLS handshake proves the inbound is answering. Anything less
# (connection refused / timeout) means the proxy is down.
lares_probe_tls_port() {
  local host="$1" port="$2" timeout="${3:-8}"
  if command -v openssl >/dev/null 2>&1; then
    if timeout "$timeout" openssl s_client -connect "${host}:${port}" \
         -servername www.apple.com </dev/null >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi
  # Fallback: bare TCP connect via bash's /dev/tcp.
  if timeout "$timeout" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
    return 0
  fi
  return 1
}

# ── compose CLI 选择 ─────────────────────────────────────────────────────────
# Sets LARES_COMPOSE to the working compose invocation, or fails.
lares_detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    LARES_COMPOSE='docker compose'
    LARES_COMPOSE_KIND='v2-plugin'
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    LARES_COMPOSE='docker-compose'
    LARES_COMPOSE_KIND='v1-legacy'
    return 0
  fi
  LARES_COMPOSE=''
  LARES_COMPOSE_KIND='none'
  return 1
}

# ── 防呆:确认我们从不碰机场配置 ──────────────────────────────────────────────
# Assert that a path we are about to touch is not proxy-owned. Any violation is
# a programming error in these scripts and must abort immediately.
lares_assert_not_proxy_path() {
  local target="$1" forbidden
  for forbidden in "${LARES_FORBIDDEN_PATHS[@]}"; do
    case "$target" in
      "$forbidden"|"$forbidden"/*)
        die "内部断言失败:脚本试图访问机场配置路径 '$target'。已中止,未做任何改动。"
        ;;
    esac
  done
  return 0
}
