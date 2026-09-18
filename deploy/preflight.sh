#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Lares 部署前体检 —— **严格只读**,不做任何修改
#
# 这台 VPS 同时在跑机场(xray / 3x-ui),是主人和朋友们翻墙的命根子。
# 本脚本在部署前回答一件事:「现在动手,会不会把机场搞挂?」
#
# 只读保证:全程只有 ss / free / df / systemctl is-active / docker info /
#           ufw status / iptables -S / nft list 这类查询命令。
#           不写文件(除了自己的 .state 基线目录)、不改防火墙、
#           不碰 xray / 3x-ui 的任何配置或 unit。
#
# 退出码:0 = 全部通过(允许部署);非 0 = 有硬阻断项(禁止部署)
#
# 用法:
#   ./preflight.sh          # 体检并写入基线
#   ./preflight.sh --quiet  # 只输出结论(给 deploy.sh 调用)
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

QUIET=0
for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=1 ;;
    -h|--help)
      sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "未知参数:$arg" ;;
  esac
done

# Minimum free RAM (MiB) below which deploying is unsafe on this shared box.
: "${LARES_MIN_FREE_MB:=250}"
# Minimum free disk (MiB).
: "${LARES_MIN_DISK_MB:=2048}"

printf '%s' "$C_CYN"
cat <<'BANNER'
╔══════════════════════════════════════════════════════════════╗
║  Lares 部署前体检(只读)                                    ║
║  目标:确认部署不会影响正在运行的机场(xray / 3x-ui)        ║
╚══════════════════════════════════════════════════════════════╝
BANNER
printf '%s' "$C_RST"

if [ "$(id -u)" -ne 0 ]; then
  warn "非 root 运行:ss 看不到进程名、systemctl / ufw 部分信息可能缺失。"
  warn "      建议用 sudo 重跑以获得完整体检结果。"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "1/8  配置文件与鉴权"
# ══════════════════════════════════════════════════════════════════════════════
if [ ! -r "$LARES_ENV_FILE" ]; then
  fail "找不到 $LARES_ENV_FILE —— 请先 cp .env.example .env 并填写。"
else
  ok "读取配置:$LARES_ENV_FILE"

  # 域名
  domain="$(env_get LARES_DOMAIN '')"
  tls_mode="$(env_get LARES_TLS_MODE dns)"
  if [ -z "$domain" ]; then
    fail "LARES_DOMAIN 为空。还没有域名请设 LARES_TLS_MODE=selfsigned 并填服务器公网 IP。"
  elif [ "$domain" = "rtc.example.com" ]; then
    fail "LARES_DOMAIN 还是示例值 rtc.example.com,请改成真实域名。"
  else
    ok "LARES_DOMAIN = $domain"
  fi

  # TLS 模式
  case "$tls_mode" in
    http)
      ok "LARES_TLS_MODE = http(HTTP-01 自动签发,要求独占 80/443)"
      # 这个模式唯一的风险:80/443 上已经有别的东西。
      # Caddy 抢不到端口会启动失败;更糟的情况是这台机器上跑着机场,
      # 那会把 Reality 入站直接打掉。所以这里必须实测,不能只看配置。
      _hp="$(env_get LARES_HTTPS_PORT 8444)"
      _pp="$(env_get LARES_HTTP_PORT 8080)"
      if [ "$_hp" != "443" ] || [ "$_pp" != "80" ]; then
        fail "http 模式要求 LARES_HTTPS_PORT=443 且 LARES_HTTP_PORT=80"
        fail "  当前:HTTPS=$_hp HTTP=$_pp —— Caddyfile.http 用的是标准端口,对不上。"
      fi
      if command -v ss >/dev/null 2>&1; then
        for _p in 80 443; do
          # 排除 docker-proxy 自己:重新部署时旧容器可能还占着
          if ss -ltnp 2>/dev/null | grep -E ":${_p}\b" |
               grep -qv 'docker-proxy'; then
            fail "端口 ${_p} 已被占用(非 docker-proxy):"
            ss -ltnp 2>/dev/null | grep -E ":${_p}\b" | sed 's/^/        /'
            fail "  这台机器上有别的服务在用它。若是机场,**改用 LARES_TLS_MODE=dns**。"
          else
            ok "端口 ${_p} 可用"
          fi
        done
      else
        warn "没有 ss 命令,无法核实 80/443 是否空闲 —— 请自行确认。"
      fi
      _img="$(env_get LARES_CADDY_IMAGE 'caddy:2-alpine')"
      if [ "$_img" = "caddy:2-alpine" ]; then
        ok "用官方镜像即可(http 模式不需要 DNS 插件)"
      else
        warn "LARES_CADDY_IMAGE=$_img —— http 模式用官方 caddy:2-alpine 就够了。"
      fi
      ;;
    dns)
      ok "LARES_TLS_MODE = dns(推荐:DNS-01,零入站端口,不碰 80/443)"
      if [ -z "$(env_get CLOUDFLARE_API_TOKEN '')" ]; then
        fail "dns 模式需要 CLOUDFLARE_API_TOKEN(权限 Zone.Zone:Read + Zone.DNS:Edit)。"
      else
        ok "CLOUDFLARE_API_TOKEN 已设置"
      fi
      caddy_image="$(env_get LARES_CADDY_IMAGE 'caddy:2-alpine')"
      if [ "$caddy_image" = "caddy:2-alpine" ]; then
        fail "dns 模式需要带 DNS 插件的自建镜像,但 LARES_CADDY_IMAGE 仍是官方 caddy:2-alpine。"
        fail "  官方镜像不含 DNS provider,证书签不下来。请先 cd caddy && ./build-caddy.sh"
      else
        ok "LARES_CADDY_IMAGE = $caddy_image"
        if command -v docker >/dev/null 2>&1 &&
           docker image inspect "$caddy_image" >/dev/null 2>&1; then
          if docker run --rm --entrypoint caddy "$caddy_image" list-modules 2>/dev/null |
               grep -q '^dns\.providers\.cloudflare$'; then
            ok "镜像内确认含 dns.providers.cloudflare 插件"
          else
            fail "镜像 $caddy_image 里没有 dns.providers.cloudflare 插件,DNS-01 会失败。"
          fi
        else
          warn "本机尚无镜像 $caddy_image;deploy.sh 会尝试构建或拉取。"
        fi
      fi
      ;;
    file)
      ok "LARES_TLS_MODE = file(自备证书)"
      cert_dir="$(env_get LARES_CERT_DIR "$SCRIPT_DIR/certs")"
      if [ ! -d "$cert_dir" ]; then
        fail "证书目录不存在:$cert_dir"
      else
        ok "证书目录:$cert_dir"
      fi
      ;;
    selfsigned)
      warn "LARES_TLS_MODE = selfsigned —— 自签证书,**浏览器与 iOS 会拒绝连接**。"
      warn "      仅可用于买到域名前的冒烟测试,且叶子证书默认只有 12 小时有效期。"
      ;;
    *)
      fail "LARES_TLS_MODE 取值非法:'$tls_mode'(可选 http / dns / file / selfsigned)"
      ;;
  esac

  # ── 鉴权:公网部署绝不能裸奔 ──────────────────────────────────────────────
  auth_mode="$(env_get LARES_AUTH_MODE '')"
  if [ -z "$auth_mode" ]; then
    fail "LARES_AUTH_MODE 未设置。公网部署必须填 token 或 circle(compose 也会拒绝启动)。"
  elif [ "$auth_mode" = "none" ]; then
    fail "LARES_AUTH_MODE=none 意味着任何人都能连上你的信令服务、白嫖带宽甚至进你的圈子。"
    fail "  公网部署请改成 token 或 circle。"
  else
    ok "LARES_AUTH_MODE = $auth_mode"
    # 逐个模式核对密钥是否给全 —— lares-server 启动时也会校验,但提前拦更省事
    _has_token=0; _has_circle=0
    case ",$auth_mode," in *,token,*) _has_token=1 ;; esac
    case ",$auth_mode," in *,circle,*) _has_circle=1 ;; esac
    if [ "$_has_token" -eq 1 ] && [ -z "$(env_get LARES_AUTH_TOKEN '')" ]; then
      fail "模式含 token,但 LARES_AUTH_TOKEN 为空(生成:openssl rand -hex 32)。"
    fi
    if [ "$_has_circle" -eq 1 ] &&
       [ -z "$(env_get LARES_CIRCLE_PASSCODE '')" ] &&
       [ -z "$(env_get LARES_CIRCLE_PASSCODES '')" ]; then
      fail "模式含 circle,但 LARES_CIRCLE_PASSCODE 与 LARES_CIRCLE_PASSCODES 均为空。"
    fi
  fi

  # LiveKit 凭据
  for var in LIVEKIT_API_KEY LIVEKIT_API_SECRET LIVEKIT_PUBLIC_URL; do
    val="$(env_get "$var" '')"
    if [ -z "$val" ]; then
      fail "$var 未设置。"
    elif printf '%s' "$val" | grep -q 'change-me\|example\.com'; then
      fail "$var 仍是示例值($val),请改成真实值。"
    fi
  done

  # LIVEKIT_PUBLIC_URL 必须带上非标端口,否则客户端会去连 443(机场端口!)
  pub_url="$(env_get LIVEKIT_PUBLIC_URL '')"
  https_port="$(env_get LARES_HTTPS_PORT 8444)"
  if [ -n "$pub_url" ] && [ "$https_port" != "443" ]; then
    if ! printf '%s' "$pub_url" | grep -q ":${https_port}\b"; then
      fail "LIVEKIT_PUBLIC_URL='$pub_url' 没带端口 :${https_port}。"
      fail "  客户端会默认去连 443 —— 那是机场的端口,必然失败。"
      fail "  应写成 wss://<域名>:${https_port}"
    else
      ok "LIVEKIT_PUBLIC_URL 已正确携带端口 :${https_port}"
    fi
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
section "2/8  机场(xray / 3x-ui)基线"
# ══════════════════════════════════════════════════════════════════════════════
# 这一节的目的是「记录一个已知良好的状态」,部署后 deploy.sh 会拿它做对比。
proxy_seen=0
for unit in "${LARES_PROXY_UNITS[@]}"; do
  set +e
  lares_unit_active "$unit"; rc=$?
  set -e
  case "$rc" in
    0) ok "systemd 单元 ${unit}.service:active(运行中)"; proxy_seen=1 ;;
    1) warn "systemd 单元 ${unit}.service:已安装但**未运行**" ;;
    2) info "systemd 单元 ${unit}.service:未安装(可能装在 docker 里或改了名)" ;;
  esac
done

# 不依赖 systemd:直接看进程
if pgrep -x xray >/dev/null 2>&1 || pgrep -f 'x-ui' >/dev/null 2>&1; then
  ok "进程检测:发现 xray / x-ui 进程在运行"
  proxy_seen=1
fi

if [ "$proxy_seen" -eq 0 ]; then
  warn "没有检测到运行中的 xray / x-ui。"
  warn "      如果机场本来就该在跑,说明它**现在已经是挂的** —— 请先修好再部署,"
  warn "      否则部署后无法区分「是我搞挂的」还是「本来就挂」。"
fi

info "机场当前监听端口:"
proxy_ports="$(lares_capture_proxy_baseline)"
if [ -n "$proxy_ports" ]; then
  printf '%s\n' "$proxy_ports" | sed 's/^/         /'
else
  warn "      无法识别机场进程的监听端口(通常是因为非 root,看不到进程名)。"
  warn "      将退化为「按端口」比对基线,仍然有效。"
fi

info "关键占用端口现状:"
while IFS= read -r line; do
  printf '         %s\n' "$line"
done <<< "$(lares_capture_occupied_state)"

# 主动探活:Reality 入站会伪装成正常 TLS 站点,握手成功即证明它在应答
if lares_probe_tls_port 127.0.0.1 443 6; then
  ok "443/tcp TLS 握手成功 —— Reality 入站正在应答"
else
  warn "443/tcp TLS 握手未成功。可能是 Reality 对本地回环/无效 SNI 的正常拒绝行为,"
  warn "      也可能机场真的有问题。请在部署前用你自己的客户端确认一次。"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "3/8  端口冲突检查(核心)"
# ══════════════════════════════════════════════════════════════════════════════
# 意图端口从 lib/common.sh 推导,而它读的是与 compose 同一份 .env 和同一组默认值。
# 不存在「脚本里另抄一份端口清单」的漂移风险。
intended="$(lares_intended_ports)"

info "本次部署打算绑定的端口:"
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  pp="${entry%%:*}"
  desc="${entry#*:}"
  printf '         %-12s %s\n' "$pp" "$desc"
done <<< "$intended"
printf '\n'

conflict_found=0
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  pp="${entry%%:*}"
  desc="${entry#*:}"
  port="${pp%%/*}"
  proto="${pp#*/}"

  # (a) 与已知占用清单硬碰撞?
  for occ in "${LARES_OCCUPIED_PORTS[@]}"; do
    occ_pp="${occ%%:*}"
    occ_desc="${occ#*:}"
    if [ "$pp" = "$occ_pp" ]; then
      fail "端口冲突:$pp($desc)撞上了 $occ_desc"
      fail "  这会直接影响机场,**禁止部署**。请修改 .env 换一个端口。"
      conflict_found=1
    fi
  done

  # (b) 实际上是否已经有人在听?
  if port_in_use "$port" "$proto"; then
    owner="$(port_owner "$port" "$proto")"
    # 已经是我们自己的容器在听 = 重跑部署,属正常
    if printf '%s' "$owner" | grep -q 'docker\|containerd'; then
      warn "$pp 已被占用,但看起来是本项目已有的容器(重复部署属正常):"
      warn "      $owner"
    else
      fail "$pp($desc)已被占用:"
      fail "      ${owner:-<无法识别持有者,请用 sudo 重跑>}"
      conflict_found=1
    fi
  else
    ok "$pp 空闲($desc)"
  fi
done <<< "$intended"

if [ "$conflict_found" -eq 0 ]; then
  ok "未发现端口冲突。"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "4/8  80/tcp 是否真的空闲(解决「据说没占用」的未知项)"
# ══════════════════════════════════════════════════════════════════════════════
if port_in_use 80 tcp; then
  warn "80/tcp **已被占用**:"
  warn "      $(port_owner 80 tcp)"
  warn "      → 说明「80 端口空着」的假设不成立,HTTP-01 方案不可用。"
  warn "      → 好消息:默认的 DNS-01 根本不需要 80 端口,不受影响。"
else
  ok "80/tcp 确实空闲。"
  info "      不过默认方案(DNS-01)不需要它。除非你明确要用 HTTP-01,"
  info "      否则**建议保持 80 空着**,不要给 Lares 增加一个暴露面。"
fi

if port_in_use 443 tcp; then
  ok "443/tcp 有人监听 —— 与「机场在跑」的预期一致。"
else
  fail "443/tcp **没有任何监听** —— 机场极可能已经挂了!"
  fail "  请先确认机场状态,不要在这种情况下部署。"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "5/8  内存与磁盘"
# ══════════════════════════════════════════════════════════════════════════════
if [ -r /proc/meminfo ]; then
  mem_total_mb=$(( $(awk '/^MemTotal:/{print $2;exit}' /proc/meminfo) / 1024 ))
  mem_avail_mb=$(( $(awk '/^MemAvailable:/{print $2;exit}' /proc/meminfo) / 1024 ))
  swap_total_mb=$(( $(awk '/^SwapTotal:/{print $2;exit}' /proc/meminfo) / 1024 ))
  info "内存:总 ${mem_total_mb}MB / 可用 ${mem_avail_mb}MB / swap ${swap_total_mb}MB"

  if [ "$mem_avail_mb" -lt "$LARES_MIN_FREE_MB" ]; then
    fail "可用内存仅 ${mem_avail_mb}MB,低于安全阈值 ${LARES_MIN_FREE_MB}MB。"
    fail "  ⚠️ 这台机器只有 1GB 且要与机场共存。内存不足时 Linux 的 OOM killer"
    fail "     很可能挑中占用最大的进程 —— 那往往就是 xray。机场会当场被杀。"
    fail "  建议:先加 swap(见 README「内存预算」),或减小 LARES_MEM_* 上限。"
  elif [ "$mem_avail_mb" -lt 400 ]; then
    warn "可用内存 ${mem_avail_mb}MB 偏紧。部署后请盯一会儿 free -m。"
  else
    ok "可用内存充足(${mem_avail_mb}MB)。"
  fi

  if [ "$swap_total_mb" -eq 0 ]; then
    warn "未配置 swap。1GB 机器强烈建议加 1GB swap 作为 OOM 缓冲:"
    warn "      sudo fallocate -l 1G /swapfile && sudo chmod 600 /swapfile"
    warn "      sudo mkswap /swapfile && sudo swapon /swapfile"
    warn "      echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab"
  else
    ok "已配置 swap ${swap_total_mb}MB。"
  fi
fi

disk_avail_mb="$(df -Pm "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "${disk_avail_mb:-}" ]; then
  info "磁盘可用:${disk_avail_mb}MB(${SCRIPT_DIR})"
  if [ "$disk_avail_mb" -lt "$LARES_MIN_DISK_MB" ]; then
    fail "磁盘可用空间不足 ${LARES_MIN_DISK_MB}MB,拉镜像会失败。"
  else
    ok "磁盘空间充足。"
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
section "6/8  Docker"
# ══════════════════════════════════════════════════════════════════════════════
if ! command -v docker >/dev/null 2>&1; then
  fail "未安装 docker。"
else
  ok "docker 已安装:$(docker --version 2>/dev/null || echo '版本未知')"
  if docker info >/dev/null 2>&1; then
    ok "docker 守护进程运行中。"
  else
    fail "docker 守护进程未运行或当前用户无权限(试试 sudo)。"
  fi

  set +e
  lares_detect_compose; compose_rc=$?
  set -e
  case "$LARES_COMPOSE_KIND" in
    v2-plugin)
      compose_ver="$(docker compose version --short 2>/dev/null || echo '?')"
      ok "docker compose v2 插件可用(v${compose_ver})"
      # 内联 configs.content 需要 >= 2.23.1
      case "$compose_ver" in
        ?*)
          major="${compose_ver%%.*}"; rest="${compose_ver#*.}"
          minor="${rest%%.*}"
          if [ "${major:-0}" -eq 2 ] 2>/dev/null && [ "${minor:-0}" -lt 23 ] 2>/dev/null; then
            fail "compose v${compose_ver} 过旧:本 compose 用到内联 configs.content(需 ≥ 2.23.1)。"
          fi
          ;;
      esac
      ;;
    v1-legacy)
      fail "只找到旧版 docker-compose(v1)。本项目用到 v2 才支持的内联 configs.content。"
      fail "  请安装 v2 插件:sudo apt install docker-compose-plugin"
      ;;
    *)
      [ "$compose_rc" -ne 0 ] && fail "既没有 docker compose(v2)也没有 docker-compose(v1)。"
      ;;
  esac
fi

# ══════════════════════════════════════════════════════════════════════════════
section "7/8  防火墙现状(只看,不改)"
# ══════════════════════════════════════════════════════════════════════════════
if command -v ufw >/dev/null 2>&1; then
  ufw_state="$(ufw status 2>/dev/null | head -n 1 || echo 'unknown')"
  info "ufw:$ufw_state"
  ufw status numbered 2>/dev/null | sed 's/^/         /' || true
else
  info "未安装 ufw。"
fi

if command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
  nft_lines="$(nft list ruleset 2>/dev/null | wc -l)"
  info "nftables 规则集共 ${nft_lines} 行(未展开,避免刷屏)。"
fi
if command -v iptables >/dev/null 2>&1; then
  ipt_lines="$(iptables -S 2>/dev/null | wc -l || echo 0)"
  info "iptables 规则共 ${ipt_lines} 条。"
  if iptables -S 2>/dev/null | grep -q 'DOCKER'; then
    info "检测到 DOCKER 链 —— 见下方关于 ufw 失效的说明。"
  fi
fi

if systemctl is-active --quiet fail2ban 2>/dev/null; then
  ok "fail2ban 运行中(保护 SSH)。"
  warn "⚠️  fail2ban 通过 iptables/nftables 动态插拔封禁规则。"
  warn "     盲目执行 'ufw reset'、'ufw --force enable' 或大改防火墙,"
  warn "     可能冲掉 fail2ban 的链、或把你自己的 SSH 关在门外 ——"
  warn "     在一台你正远程操作、且承载着机场的机器上,这是真实的失联风险。"
  warn "     → 只做「增量 allow」,永远不要 reset;并且先开一个备用 SSH 会话。"
fi

printf '\n'
info "若需从公网访问,需要放行的端口(⚠️ 下面这些命令**本脚本不会执行**):"
printf '\n'
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  pp="${entry%%:*}"
  desc="${entry#*:}"
  port="${pp%%/*}"
  proto="${pp#*/}"
  printf '         sudo ufw allow %s/%s comment %s\n' "$port" "$proto" "'Lares: ${desc}'"
done <<< "$intended"
printf '\n'
warn "但请先读 README「防火墙」:Docker 发布端口会**绕过 ufw**(DNAT 在 DOCKER 链,"
warn "      先于 ufw 的 INPUT 生效)。也就是说 compose 里 ports: 写了的端口,"
warn "      即使 ufw 没 allow 也已经对公网开放了。上面的命令主要用于"
warn "      「ufw 默认拒绝 + 你希望规则表意清晰」的场景,不是安全边界。"

# ══════════════════════════════════════════════════════════════════════════════
section "8/8  保存基线"
# ══════════════════════════════════════════════════════════════════════════════
# 唯一的写操作,且只写我们自己的目录 —— 不碰系统任何位置。
lares_assert_not_proxy_path "$LARES_STATE_DIR"
mkdir -p "$LARES_STATE_DIR"
lares_capture_proxy_baseline   > "$LARES_STATE_DIR/proxy-ports.baseline"
lares_capture_occupied_state   > "$LARES_STATE_DIR/occupied.baseline"
date -u +'%Y-%m-%dT%H:%M:%SZ'  > "$LARES_STATE_DIR/preflight.timestamp"
ok "基线已保存到 $LARES_STATE_DIR/(供 deploy.sh 部署后比对)"

# ══════════════════════════════════════════════════════════════════════════════
hr
if [ "$LARES_FAILURES" -gt 0 ]; then
  printf '%s✗ FAIL%s  %d 个硬阻断项,%d 个警告。**禁止部署**,请先逐条解决。\n' \
    "$C_RED" "$C_RST" "$LARES_FAILURES" "$LARES_WARNINGS"
  hr
  exit 1
fi

if [ "$LARES_WARNINGS" -gt 0 ]; then
  printf '%s✓ PASS%s  无阻断项,但有 %d 个警告 —— 请确认你理解每一条后再部署。\n' \
    "$C_GRN" "$C_RST" "$LARES_WARNINGS"
else
  printf '%s✓ PASS%s  全部检查通过,可以部署。\n' "$C_GRN" "$C_RST"
fi
hr
printf '下一步:./deploy.sh\n'
exit 0
