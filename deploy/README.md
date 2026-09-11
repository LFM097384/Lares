# Lares 公网部署

两种路线,按场景二选一。

## 路线 A:LiveKit Cloud(推荐,最省事)

1. 在 [cloud.livekit.io](https://cloud.livekit.io) 建项目,拿 `LIVEKIT_URL / API_KEY / API_SECRET`。
2. 只需部署 `lares-server`(信令+便签,单容器或 `node src/index.js` + PM2/systemd 均可):
   ```bash
   cd server && docker build -t lares-server .
   docker run -d --name lares -p 8787:8787 \
     -e LIVEKIT_URL=wss://your-project.livekit.cloud \
     -e LIVEKIT_API_KEY=xxx -e LIVEKIT_API_SECRET=xxx \
     -v lares-data:/app/data lares-server
   ```
3. 用任意反代(Caddy/Nginx/Cloudflare)给 8787 挂 TLS,WS 路径 `/ws`。

## 路线 B:全自托管(本目录 docker-compose)

包含:Caddy(自动 TLS)+ LiveKit SFU + lares-server。

1. 一台有公网 IP 的 VPS(≥1C1G 即可,语音 SFU 很轻),装好 Docker。
2. 域名 A 记录指向 VPS(如 `rtc.example.com`)。
3. 防火墙放行:`80,443/tcp`(TLS/HTTP)、`7881/tcp`、`7882/udp`(RTC 主通道)、`50000-60000/udp`(媒体端口段)、`5349/tcp`(TURN)。
4. 配置并启动:
   ```bash
   cd deploy
   cp .env.example .env   # 填域名和凭据
   docker compose up -d
   docker compose logs -f lares-server
   ```

## 客户端指向公网

```bash
# 移动端/桌面端
flutter build apk --release --split-per-abi \
  --dart-define=LARES_SIGNALING=wss://rtc.example.com/ws
# Web
flutter build web --dart-define=LARES_SIGNALING=wss://rtc.example.com/ws
```

> 客户端不要再传 `LARES_HOST_ONLY_ICE=true`(仅局域网联调用)。

## 注意事项

- **WSS 是必须的**:浏览器要求安全上下文,移动 ATS 同理,不要裸 ws 上公网。
- **TURN**:多数家用/办公 NAT 下 UDP 直连即可;对称 NAT(部分校园网/企业网)需要 TURN,compose 已内置基础配置,严格环境按 LiveKit 文档再调。
- **成本**:自托管 LiveKit 不收分钟费,但带宽自担;语音每路约 30~50kbps。
- **升级**:`docker compose pull && docker compose up -d`;lares-server 改动后 `docker compose build lares-server && docker compose up -d`。
