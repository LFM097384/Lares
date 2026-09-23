# Lares 信令服务镜像
FROM node:22-alpine

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
