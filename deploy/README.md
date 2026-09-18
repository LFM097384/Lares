# Lares 炉灵 — 公网部署

> ⚠️ **先读这一段。** 本目录的 compose 是为「**与已有服务共存的 VPS**」重写的。
> 目标机器(RackNerd)上 `443/tcp` 是 VLESS+Reality 主入站、`8443/tcp` 是次入站、
> `3443/udp` 是 Hysteria2、`9721` 是 3x-ui 面板。**这些端口绝对不能碰。**
> 历史版本的 compose 把 Caddy 映射到 `80:80` + `443:443` —— 照那样跑会直接
> 抢走 Reality 入站,把翻墙线路打死。现在的配置刻意避开了全部已占用端口。

---

## 两种拓扑(用户已决定:**两套都配,客户端设置页可切**)

| | 路线 A:LiveKit Cloud 托管媒体 | 路线 B:全自托管 |
|---|---|---|
| 媒体(语音) | LiveKit Cloud 全球边缘节点 | 自己的 VPS(Seattle) |
| 信令 | 自己的 VPS | 自己的 VPS |
| 国内延迟 | **更优**(就近边缘接入) | 单点 190ms + 移动 QoS 风险 |
| 隐私 | 语音流经第三方 SFU | 全链路自持 |
| VPS 负载 | 极低(只有一个 Node 进程) | LiveKit + Caddy + Node |
| 成本 | 免费档有额度 | 带宽自担(语音约 30~50kbps/路) |

> 建议:**国内用户日常走 A,隐私敏感场合切 B。** 两者共用同一套信令服务,
> 客户端只是换 `LARES_SIGNALING` 指向和服务端下发的 `LIVEKIT_URL`。

---

## 端口分配(已验证零冲突)

| 端口 | 服务 | 说明 |
|---|---|---|
| `8444/tcp` | Caddy TLS | **不是 443**。客户端 URL 需显式带 `:8444` |
| `7881/tcp` | LiveKit RTC over TCP | 弱网/严格 NAT 兜底 |
| `7882/udp` | LiveKit RTC over UDP | 主媒体通道,**单端口 mux** |
| `8787` | lares-server | 仅容器内 expose,**不发布到宿主** |

**刻意避开**:`443` `8443` `3443` `9721` `2096` `22` `80`

**为什么 UDP 只开一个端口**:官方建议 mux 端口数 ≥ vCPU 数;这台机器 1 vCPU,
1 个端口即最优,同时避免原先 `50000-60000`(10001 个端口)造成的 conntrack 膨胀。
⚠️ LiveKit 源码 `webrtc_config.go` 的判定顺序是「先看端口段,端口段没设才用 mux」,
所以**端口段必须留空**才会真正走 mux。

**⚠️ 宿主端口必须与容器端口一致**:LiveKit 会把端口号写进 ICE candidate,
一旦做端口转换,客户端拿到的候选地址就是错的,媒体必定连不通。

---

## 部署步骤

```bash
cd deploy
cp .env.example .env
$EDITOR .env                 # 填域名、LiveKit 凭据、鉴权密钥

./preflight.sh               # 只读检查,不过就别继续
./deploy.sh                  # 会先自动再跑一次 preflight
```

`deploy.sh` 的三重机场保护:
1. 部署前 `preflight.sh` 记录**端口基线**,不通过直接退出(绝不带病部署)
2. **静态断言**:脚本自检不含任何对 `xray`/`x-ui` 的 `systemctl` 写操作
3. 部署后**三路复核** —— 基线端口是否仍在监听 / systemd unit 是否仍 active /
   `443` 主动 TLS 握手探活。任一失败 → **立即自动拆栈并告警**

出问题:`./rollback.sh`(保留数据)或 `./rollback.sh --purge`(连数据卷一起删)。

---

## TLS 方案(四选一,`.env` 里切 `LARES_TLS_MODE`)

**先分清这台机器是哪一种**,再看表:

| `LARES_TLS_MODE` | 入站端口 | 镜像 | 适用 |
|---|---|---|---|
| `http` | `80` + `443` | 官方 `caddy:2-alpine` | **Lares 专用机器**,最省事 |
| `dns` | **零** | 自建(带 DNS 插件) | **与机场共存的机器** |
| `file` | 零 | 官方 | 证书从别处签好 |
| `selfsigned` | 零 | 官方 | **仅冒烟测试** |

### Lares 专用机器 → `http`

```bash
LARES_TLS_MODE=http
LARES_HTTPS_PORT=443
LARES_HTTP_PORT=80
```

不需要 DNS token,不需要自建镜像,证书全自动。
客户端地址也干净:`wss://rtc.example.com/ws`(不带端口号)。

`preflight.sh` 会**实测** 80/443 是否空闲 —— 有别的服务占着会直接拦下。

### 与机场(xray Reality)共存 → `dns`

```bash
LARES_TLS_MODE=dns
LARES_HTTPS_PORT=8444    # 绝对不能填 443
LARES_HTTP_PORT=8080     # 同理不能填 80
```

必须走 DNS-01。已核对 Caddy 源码:站点即使写成「域名:8444」,
Caddy 依然会尝试 TLS-ALPN-01(去用 `:443`)和 HTTP-01(去用 `:80`)——
**只有 DNS-01 会关闭其它 challenge**。

> 需要带 DNS 插件的 Caddy —— `caddy/Dockerfile` 用 `xcaddy` 现编,
> 跑 `caddy/build-caddy.sh` 即可。官方 `caddy:2-alpine` 不含任何 DNS 插件。

### 自签

浏览器和 iOS **会拒绝**,只能原生端跳过校验用于冒烟,不要用于日常。
Caddy 内置 CA 的叶子证书默认只有 12 小时有效期。

> DNS-01 需要带 DNS 插件的 Caddy —— `caddy/Dockerfile` 用 `xcaddy` 现编,
> 跑 `caddy/build-caddy.sh` 即可。stock `caddy:2-alpine` 不含任何 DNS 插件。

---

## 防火墙

```bash
sudo ufw allow 8444/tcp comment 'Lares TLS'
sudo ufw allow 7881/tcp comment 'Lares RTC TCP'
sudo ufw allow 7882/udp comment 'Lares RTC UDP'
```

> ⚠️ **Docker 发布端口会绕过 UFW**:DNAT 发生在 `DOCKER` 链,先于 ufw 的 `INPUT`
> 规则。compose 里 `ports:` 出现的端口一律**直接对公网开放**,`ufw deny` 拦不住。
> 真要限制来源,得写 `DOCKER-USER` 链规则。
>
> ⚠️ 机器上 **fail2ban 在跑**(3x-ui 自带 IP Limit jail)。不要盲目重置 ufw 规则。

---

## 鉴权(公网必开)

服务端支持 HMAC 挑战/响应,两种模式(见 `server/src/index.js`):

```bash
# 模式一:共享 Bearer Token
LARES_AUTH_MODE=token
LARES_AUTH_TOKEN=$(openssl rand -hex 32)

# 模式二:圈子口令(可按圈子分别设)
LARES_AUTH_MODE=circle
LARES_CIRCLE_PASSCODE=$(openssl rand -hex 16)
LARES_CIRCLE_PASSCODES='{"home":"xxx","work":"yyy"}'

# 两种都收
LARES_AUTH_MODE=token,circle
```

**`LARES_AUTH_MODE=none` 只可用于本机联调。** 缺密钥时服务端会拒绝启动(fail closed)。

> ⚠️ **部署前必须处理**:`clientIp()` 刻意不信任可伪造的 `X-Forwarded-For`。
> 走 Caddy 反代后所有连接共享反代 IP,**限流会退化为全局而非按客户端**。
> 需要在 Caddy 侧解析可信客户端 IP 后再传给上游。

---

## 客户端指向公网

```bash
flutter build apk --release --split-per-abi \
  --dart-define=LARES_SIGNALING=wss://rtc.example.com:8444/ws
flutter build web \
  --dart-define=LARES_SIGNALING=wss://rtc.example.com:8444/ws
```

> 也可以不重新打包 —— App 设置页里直接改「服务器地址」。
> 公网下**不要**再传 `LARES_HOST_ONLY_ICE=true`(那是局域网联调专用)。

---

## 注意事项

- **WSS 是硬要求**:浏览器要安全上下文才给麦克风,iOS ATS 同理。裸 `ws://` 上公网不可行。
- **TURN 默认关闭**:开 TURN 要额外证书和端口,而 UDP mux + ICE/TCP 已覆盖绝大多数 NAT。
  真遇到对称 NAT(部分校园网/企业网)再按 LiveKit 文档开。
- **内存**:机器只有 1 GB 且与 xray 共享。compose 已给每个服务设了内存上限,
  防止泄漏 OOM-kill 掉机场。极限情况可改用 `systemd/` 下的 unit(更省内存,无 Docker 开销)。
- **升级**:`docker compose pull && docker compose up -d`;
  改了 lares-server 则 `docker compose build lares-server && docker compose up -d`。

---

## 已知未验证项

以下在真实 VPS 上跑过 `preflight.sh` 之前都属推断:

- `80/tcp` 是否真的空闲(README 记录为「疑似空闲,未核实」)
- 实际可用内存余量
- Docker 版本与 `docker compose` v2 插件是否就位
- 现有 ufw / iptables 规则形态

`preflight.sh` 会把这些**全部**查一遍并给出 PASS/FAIL。
