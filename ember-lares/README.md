# ember-lares · 炉灵的 Lares 插件

把平台无关的炉灵(`../ember/`)接进 Lares 房间。只做 Lares 这一半:

- **进房**:`room.mjs` 里的 `AnonRoom extends LaresRoom`,负责信令 HMAC / aiAuth、LiveKit 订阅逐人音轨,以及 data channel。
- **传输**:`port.mjs` 的 `laresPort(room, {circleId})`,把房间包装成 Ember port(见 `../ember/PORT.md`)。会话消息走 LiveKit data topic `lares.anon`,reliable,单条上限 16 KB。
- **E2EE 密封密钥握手**:信令上发 `anon_agent_hello`(带 X25519 公钥),收 `anon_agent_key`(圈主客户端封好的媒体密钥),再用 `../ember/agent/sealing.mjs` 解封。格式见 `../ember/SEALING.md`。
- **托管 spawn 契约**:`index.mjs` 是 CLI 入口,服务器的 `server/src/anonym_supervisor.js` 按圈拉起它。

## 线协议名不改

为了与已发布的 app 和服务器保持兼容,以下名字一律不动:

- 消息与信令:`anon_*`(`anon_active`、`anon_released_notice`、`anon_agent_hello`、`anon_agent_key`、`anon_error`…)
- data topic:`lares.anon`
- 身份:`u_ai_anon_<sha256(cid)[:8]>`,`deviceId` 前缀 `d_anon_`
- env:`LARES_ANONYM_*`

只有显示名改成了「炉灵」。`port.mjs` 是 Ember 中立事件与这些线协议名之间唯一的映射处:`notifyHost({type:'active'})` 对应 `anon_active`,`{type:'released'}` 对应 `anon_released_notice`。

## 进程契约

```
node ember-lares/index.mjs --circle <cid> [--signaling ws://…/ws] [--passcode p] [--auth-v2] [--e2ee] [--sealed-key] [--k n] [--memory-dir d] [--asr dashscope|mock|none]
```

- 托管时的 env:
  - `LARES_ANONYM_HOSTED=1`
  - `LARES_ANONYM_USER_ID`
  - `LARES_ANONYM_CONVENER`:只有它能散会
  - `LARES_ANONYM_E2EE`:为 `1` 时走密封密钥
  - `LARES_ANONYM_K`
  - `LARES_ANONYM_MEMORY_DIR`
  - `LARES_AI_MEMBER_SECRET`
  - `LARES_AI_AUTH_SECRET` / `LARES_AI_AUTH_V`
  - `LARES_SIGNALING`
  - `LARES_DASHSCOPE_API_KEY`
  - `LARES_AI_LLM_BASE_URL` / `LARES_AI_LLM_API_KEY`(或 `LARES_AI_LLM_KEY`)/ `LARES_AI_LLM_MODEL`
- stdin:收到 `{"cmd":"stop"}` 就散会退出。SIGTERM / SIGINT 同理。
- stdout:一行一个 JSON 事件(`ready` / `session` / `released` / `ended` / `error` / `exit`),不含任何会话文字。
- 退出码:
  - `0`:会话结束,或圈子已解散
  - `1`:崩溃或断线。服务器在邀请有效期内会重启它。
  - `2`:参数错误
  - `3`:鉴权失败

## 依赖(选择与理由)

- 进房按**相对路径**引用 `../lares-bridge/index.mjs`(`LaresRoom`,`AnonRoom` 继承它),DashScope ASR 引用 `../hearthvoice/providers/dashscope.mjs`,都不复制。`lares-bridge` 是 Lares 接入层,灶语和炉灵共用:鉴权、E2EE、rtc-node 加载这些细节只存在一处,复制的话迟早会漂移。DashScope provider 属于灶语本体,平台无关,ws 从 lares-bridge 注入。
- 炉灵本体按相对路径 `../ember/index.mjs` 引用。
- 代价是这些包必须同级放置。仓库和镜像都满足:`/app/server`、`/app/lares-bridge`、`/app/hearthvoice`、`/app/ember`、`/app/ember-lares`。
- npm 依赖(`ws`、`hash-wasm`、可选的 `@livekit/rtc-node`)不单独安装,从 `server/node_modules` 解析:
  - 开发机:`lares-bridge/deps.mjs` 按 `../server/package.json` 解析;
  - 镜像:`/app/node_modules` 是指向 `/app/server/node_modules` 的软链。

  详见 `server/Dockerfile` 与 `lares-bridge/README.md`。
## 测试

`node --test ember-lares/`。测试用 FakeRoom,不出网,也不进 LiveKit,覆盖线协议映射、退出码、CLI 和密封握手。生产 E2E 在 `server/tool/anonym_v2_prod_e2e.mjs`:它留在 `server/tool`,因为需要 tool 目录装的 `@livekit/rtc-node` 和 `lares_bot.mjs`,导入路径已改为指向 `../../ember/`。
