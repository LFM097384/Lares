# lares-bridge — Lares 接入层

这里是 AI 进程接入 Lares 圈子房间的共用实现。灶语插件(`../hearthvoice-lares/`)和炉灵插件(`../ember-lares/`)都通过它进房。它原本是 `server/bots/voice-agent/room.mjs`,现在独立出来,两边就不会各维护一份鉴权和 E2EE 细节了。

## 内容

| 出口 | 说明 |
|---|---|
| `LaresRoom` | 信令 WebSocket 加 LiveKit 房间。职责见下表 |
| `AuthError` / `CircleGoneError` / `E2eeRequiredError` | 握手失败分类:4401 / 4410 / E2EE 圈却没带 `--e2ee`。插件据此决定退出码 |
| `authVerifier(passcode, circleId)` | v2 verifier(Argon2id,盐 `lares-auth-v2:<cid>`) |
| `e2eeKeyHex(passcode, circleId)` | 媒体 E2EE 共享密钥,与 app 同参数 |
| `encodeChatFrame` / `decodeChatFrame` | `lares.chat` 帧(4 字节大端长度 + JSON 头) |
| `CHAT_TOPIC` / `CAPTION_TOPIC` / `AI_STATE_TOPIC` | `lares.chat` / `lares.cap` / `lares.ai` |
| `defaultAiUserId(cid)` / `isLaresHuman(id)` | `u_ai_<sha256 前 8 hex>`;`u_ai_*` 与 `bot:*` 不算真人 |
| `ROOM_RATE` / `FRAME_SAMPLES` / `framesOf` / `monoOf` | 房间音频格式(48 kHz 单声道,480 样本一帧)与入站、出站小工具 |
| `loadRtcNode()` | 动态加载可选的 `@livekit/rtc-node`;装不上时返回 null |
| `WebSocket` / `argon2id` / `importDep` | npm 依赖解析的结果,供插件复用,例如把 `WebSocket` 传给 DashScope provider |

`LaresRoom` 的职责:

| 方面 | 内容 |
|---|---|
| 鉴权 | HMAC 挑战应答(v1 口令 / v2 verifier);服务端托管时还要出示 `aiAuth`(`u_ai_*` 成员凭证) |
| 设备 | `platform:'ai'`,稳定的 `d_ai_*` deviceId |
| 入站 | 订阅真人音轨(事件 `audio`)、`lares.chat` / `lares.cap`(事件 `chat` / `capctl` / `names`)、进出(`joined` / `left`)、断线(`disconnected`) |
| 出站 | 进房时发布音轨 `ai-voice`,`sink()` 提供 `{captureFrame, clear, queuedMs}`;`publishCaption` / `publishState` / `sendChat` / `rename` / `leave` |
| 子类化 | 炉灵的 `AnonRoom` 继承它:改 deviceId、加 `lares.anon` topic 与密封密钥握手、不发音轨 |

## 边界

- 不 import `server/` 下任何源码,也不认识任何 AI 本体(测试会检查,只允许 `node:` 和 `./`)。
- 线协议(topic、帧格式、`u_ai_` 身份、证明算法)与 `server/src/index.js` 的 verifyAuth 和 app 端的 `chat_envelope.dart` 一致。改动这里等于改线协议。

## 依赖(选择与理由)

- 使用方按**相对路径**引入:`import { LaresRoom } from '../lares-bridge/index.mjs'`。与 `ember-lares → ../ember` 相同,不发 npm 包,也不用 workspace。这些包只在本仓库和本镜像里使用,两边布局一致(`/app/server`、`/app/lares-bridge`、`/app/hearthvoice*`、`/app/ember*` 同级)。
- npm 依赖(`ws`、`hash-wasm`、可选 `@livekit/rtc-node`)不单独安装,只认 `server/` 那一份。解析在 `deps.mjs`:
  - 镜像:`/app/node_modules` 软链到 `/app/server/node_modules`,裸 import 直接命中;
  - 开发机:仓库根没有 node_modules,裸 import 失败后按 `../server/package.json` 解析,再退到 `../server/tool/package.json`(验证工具单独装的 rtc-node)。

## 测试

运行 `node --test lares-bridge/`,覆盖以下内容:

- 线协议常量、id、帧往返;
- Argon2 派生;
- 本地 ws 服务器上的信令握手,包括 HMAC 与 aiAuth 证明,以及 4401 / 4410 / E2EE 的错误映射;
- data topic 映射(冒充 bot 的消息丢弃);
- 出站 sink 与各 topic;
- 依赖解析;
- 边界检查。

不进真实 LiveKit。真实媒体链路由 `server/tool/*_prod_e2e.mjs` 手动验证。
