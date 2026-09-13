#!/usr/bin/env bash
# 用真实形态的 ss 输出验证 lib/common.sh 里的 awk 端口匹配
# 关键风险:IPv6 / 通配形式误判 -> deploy.sh 可能误判机场挂了而拆掉健康的栈

# port_in_use 用的是 -tlnH（无 Netid 列），Local Address:Port 在 $4
run_in_use() {
  local port="$1"; shift
  printf '%s\n' "$@" | awk -v p=":$port" '
    { addr = $4; n = split(addr, a, ":"); if (":" a[n] == p) { found = 1 } }
    END { exit(found ? 0 : 1) }
  '
}

# lares_capture_proxy_baseline 用的是 -tulnpH（有 Netid 列），Local Address 在 $5
run_baseline() {
  printf '%s\n' "$@" | awk '
    /xray|x-ui/ {
      proto = $1; addr = $5
      n = split(addr, a, ":"); port = a[n]
      if (port ~ /^[0-9]+$/) print proto, port
    }' | sort -u
}

pass=0; fail=0
chk() { # chk <desc> <expected 0|1> <actual>
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1))
  else echo "  FAIL  $1  (期望 $2 实得 $3)"; fail=$((fail+1)); fi
}

echo "=== port_in_use:各种监听地址形态 ==="

# ss -tlnH 真实输出样例（State Recv-Q Send-Q Local:Port Peer:Port）
IPV4='LISTEN 0      4096         0.0.0.0:443        0.0.0.0:*'
IPV6='LISTEN 0      4096            [::]:443           [::]:*'
WILD='LISTEN 0      511                *:443              *:*'
LOOP6='LISTEN 0     4096           [::1]:443           [::]:*'
MAPPED='LISTEN 0    4096  [::ffff:127.0.0.1]:443        [::]:*'
OTHER='LISTEN 0     4096         0.0.0.0:8444       0.0.0.0:*'
SUFFIX='LISTEN 0    4096         0.0.0.0:18443      0.0.0.0:*'

run_in_use 443 "$IPV4"; chk "IPv4 0.0.0.0:443" 0 $?
run_in_use 443 "$IPV6"; chk "IPv6 [::]:443" 0 $?
run_in_use 443 "$WILD"; chk "通配 *:443" 0 $?
run_in_use 443 "$LOOP6"; chk "IPv6 环回 [::1]:443" 0 $?
run_in_use 443 "$MAPPED"; chk "v4-mapped [::ffff:127.0.0.1]:443" 0 $?
run_in_use 443 "$OTHER"; chk "只有 8444 时查 443 应为未占用" 1 $?
run_in_use 443 "$SUFFIX"; chk "18443 不应被误判成 443" 1 $?
run_in_use 8443 "$SUFFIX"; chk "18443 不应被误判成 8443（后缀陷阱）" 1 $?
run_in_use 443 "$OTHER" "$IPV6"; chk "多行中命中任意一行" 0 $?
run_in_use 443 ""; chk "空输入 -> 未占用" 1 $?

echo ""
echo "=== baseline:xray/x-ui 归一化快照 ==="
# ss -tulnpH（Netid State Recv-Q Send-Q Local:Port Peer:Port Process）
B1='tcp   LISTEN 0 4096    0.0.0.0:443   0.0.0.0:* users:(("xray",pid=1,fd=1))'
B2='tcp   LISTEN 0 4096       [::]:8443     [::]:* users:(("xray",pid=1,fd=2))'
B3='udp   UNCONN 0 0       0.0.0.0:3443   0.0.0.0:* users:(("xray",pid=1,fd=3))'
B4='tcp   LISTEN 0 4096    0.0.0.0:9721   0.0.0.0:* users:(("x-ui",pid=2,fd=1))'
B5='tcp   LISTEN 0 4096    0.0.0.0:22     0.0.0.0:* users:(("sshd",pid=3,fd=1))'

got="$(run_baseline "$B1" "$B2" "$B3" "$B4" "$B5")"
want="$(printf 'tcp 443\ntcp 8443\ntcp 9721\nudp 3443\n' | sort -u)"
echo "--- 实得 ---"; echo "$got"
if [ "$got" = "$want" ]; then echo "  PASS  IPv6 与 UDP 均正确归一化，且未误收 sshd"; pass=$((pass+1))
else echo "  FAIL  期望:"; echo "$want"; fail=$((fail+1)); fi

echo ""
echo "通过 $pass / 失败 $fail"
[ "$fail" -eq 0 ]
