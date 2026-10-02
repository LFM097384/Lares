# Lares 信令服务镜像
# 不用 alpine:bot 的 /api/v1/speak 依赖 @livekit/rtc-node,它的原生库只发 glibc
# 版(linux-x64-gnu / arm64-gnu),在 musl 上装不上 → speak 只能返回 501。
FROM node:22-bookworm-slim

# rtc-node 的 Rust 内核从系统证书库加载根证书(不用 Node 自带的),slim 镜像没有它,
# 连 wss:// LiveKit 会报 "no native root CA certificates found"(2026-09 生产实测)。
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY src ./src

ENV LARES_PORT=8787
EXPOSE 8787

# 必需环境变量:
#   LIVEKIT_URL        下发给客户端的 LiveKit 公网地址(wss://rtc.example.com)
#   LIVEKIT_API_KEY / LIVEKIT_API_SECRET
# 可选:
#   LARES_DATA_DIR     数据目录(敲门设置/语音便签,建议挂卷)
# 必须在 VOLUME 之前建好并交给 node:新建命名卷时 Docker 会拷贝这个目录的属主。
# 缺了这一行,卷是 root 所有,以 node 身份运行的服务任何写盘都 EACCES ——
# 生产上敲门设置与注册圈因此从未落盘(2026-09 发现)。已存在的旧卷需一次性 chown。
RUN mkdir -p /app/data && chown node:node /app/data
VOLUME ["/app/data"]
ENV LARES_DATA_DIR=/app/data

USER node
CMD ["node", "src/index.js"]
