# ──────────────────────────────────────────────────────────────────────────────
# 带 Cloudflare DNS 插件的 Caddy —— DNS-01 签发专用
#
# 为什么要自建:官方 caddy:2-alpine **不含**任何 DNS provider 插件,
# 而这台机器上 443/80 都不能用来做 ACME 验证,只剩 DNS-01 可走。
#
# 构建:
#   cd deploy/caddy && ./build-caddy.sh
# 或手动:
#   docker build -t lares-caddy:dns .
#
# ⚠️ 构建需要联网拉 Go 模块,且在 1 vCPU / 1GB 的机器上编译 Caddy
#    可能吃掉数百 MB 内存、耗时若干分钟 —— 与机场抢资源。
#    强烈建议在**本地或另一台机器**上 build,然后:
#      docker save lares-caddy:dns | gzip > lares-caddy.tgz
#      scp lares-caddy.tgz vps:/tmp/ && ssh vps 'docker load < /tmp/lares-caddy.tgz'
#    build-caddy.sh 会在检测到低内存时警告。
# ──────────────────────────────────────────────────────────────────────────────

# 固定大版本,避免某天 :2 跳版本导致行为漂移
ARG CADDY_VERSION=2.8.4

FROM caddy:${CADDY_VERSION}-builder-alpine AS builder

# caddy-dns/cloudflare 不发 GitHub release,没有 tag 可锁。
# 需要可复现构建时,把下面改成具体 commit SHA:
#   --with github.com/caddy-dns/cloudflare@<sha>
RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare

FROM caddy:${CADDY_VERSION}-alpine

# 官方镜像的二进制就在 /usr/bin/caddy,原地替换
COPY --from=builder /usr/bin/caddy /usr/bin/caddy

# 自检:插件确实被编译进去了。构建期就暴露问题,别等到线上签不下证书。
RUN caddy list-modules | grep -q '^dns.providers.cloudflare$' \
    || (echo 'FATAL: cloudflare DNS 插件未编译进二进制' >&2; exit 1)
