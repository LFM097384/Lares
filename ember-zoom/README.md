# ember-zoom · 炉灵在 Zoom 上

炉灵（Ember）是一个坐在会里的 AI，规则受查塔姆规则启发（**非官方，与 Chatham House 无隶属**）：会上说的可以带出去，但不说是谁说的。本体在 `../ember/`，与平台无关。本包是 Zoom 这一半，地位同 `../ember-lares/`（Lares/LiveKit 那一半）。

```
ember-zoom/
├── index.mjs          CLI + 服务器：一个 HTTP 端口承载 webhook + 侧边栏 + hub；每条 RTMS 流一个 Ember 会话
├── server.mjs         node:http 路由；侧边栏静态页带 CSP / HSTS / X-Content-Type-Options / Referrer-Policy
├── webhook.mjs        x-zm-signature v0 验签（±5 min，timingSafeEqual）、endpoint.url_validation、rtms_started/stopped/interrupted 派发
├── rtms_client.mjs    纯 ws 的 RTMS 客户端（信令 1/2 → 媒体 3/4 → 7 → 5；12→13 心跳；8/9 状态；退避重连 3 s→30 s）
├── port.mjs           Ember 平台 port（../ember/PORT.md）：RTMS 事件 / 转写 → port 事件；port.send → 侧边栏 hub
├── hub.mjs            侧边栏 WS hub（/hub）：侧边栏就是「房间」
├── deps.mjs           唯一 npm 依赖 ws（同 lares-bridge/deps.mjs，从 server/node_modules 解析）
├── sidebar/           Zoom App 侧边栏（index.html / app.js / style.css，vanilla JS，无构建）
├── sim/rtms_sim.mjs   本地 RTMS 模拟器（按 docs/plans/chatham/05-zoom-rtms-facts.md）
└── test/              node --test ember-zoom/
```

## 架构

```
  Zoom 会议 ──(参会者在侧边栏点「邀请炉灵」→ zoomSdk.startRTMS → 主持人同意)
      │
      ├─ webhook  POST /webhook  meeting.rtms_started {meeting_uuid, rtms_stream_id, server_urls}
      │                          （先验签；url_validation 也要先验签）
      ▼
  index.mjs ── new RtmsClient ──► 信令 WS ──► 媒体 WS（只要转写 media_type 8；EMBER_ZOOM_ASR=dashscope 时要音频 1）
      │                                │
      │            msg 17 转写 / msg 6 入离会 / msg 9 停止
      ▼                                ▼
  zoomPort ── 'transcript'(zu_<user_id>, text) ──► Ember 会话（session.onTranscript：未 ack 的丢 → IngestGate L0–L3 → 假名账本）
      ▲  'joined' / 'left' / 'message'               │
      │                                              │ state / answer / draft / approvals / released / mem / ended
  hub.mjs（WS /hub）◄──────────────────────────────── port.send
      ▲
  sidebar/（每个参会者自己的 Zoom App 面板）：规则说明 · 我同意（ack + Ed25519 公钥）· 提问 · 纪要草稿审阅 / 签名 · 记忆撤回 · 散会
```

- **转写进 Ember 的入口**：给 `ember/` 加了一个可选 port 事件 `transcript(id, text)`，只在 `port.transcripts === true` 时接上（`ember/agent/session.mjs` 的 `wirePort`）。它和 ASR 定稿走同一个 `session.onTranscript`，所以 ack 门、IngestGate、账本的语义不变。ember-lares 的 port 没有这个标志，不受影响。
- **一条流一个会话**：按 `rtms_stream_id` 区分。记忆作用域 = `hash(account_id:meeting_id)`，周期会议的 meeting_id 不变，所以同一个会就是同一个「圈」。可以用 `EMBER_ZOOM_SCOPE` 固定。
- **召集人**：点「邀请炉灵」的那个侧边栏的人（hub 记下 `zoom_invite`）。没人点过时，取第一个入会的人（Ember 默认）。只有召集人能散会。
- **会议聊天**：默认不发。`EMBER_ZOOM_POST_CHAT=1` 时，**只有** k 人签名放行后的纪要原文，会交给召集人的侧边栏，由它调用 `zoomSdk.sendMessageToChat`。答案、草稿、记忆一律不去聊天。
- **原话**：在进程内存里，经 IngestGate 改写成不带名字的假名账本，最长约 60 s（`MAX_HOLD_MS`）。散会时全部清空，不落盘。落盘的只有放行的条目（`EMBER_MEMORY_DIR/<scope>/`）。stdout 只输出元数据事件。

## 运行

```powershell
$env:ZOOM_CLIENT_ID='…'; $env:ZOOM_CLIENT_SECRET='…'; $env:ZOOM_WEBHOOK_SECRET='…'   # 只放环境变量，不写进任何文件
$env:PORT='8790'                                                                     # 缺省 8790，HOST 缺省 127.0.0.1
$env:LARES_AI_LLM_KEY='…'                                                            # 可选；不设则走确定性 mock 路径
node ember-zoom/index.mjs
```

| 变量 | 说明 |
|---|---|
| `ZOOM_CLIENT_ID` / `ZOOM_CLIENT_SECRET` | App 凭据。RTMS 握手签名 = `hex(HMAC-SHA256(secret, "clientId,meeting_uuid,rtms_stream_id"))` |
| `ZOOM_WEBHOOK_SECRET` | App → Features → Access → Secret Token |
| `PORT` / `HOST` | 监听地址（公网经 HTTPS 隧道进来） |
| `LARES_AI_LLM_BASE_URL` / `LARES_AI_LLM_API_KEY`（或 `LARES_AI_LLM_KEY`）/ `LARES_AI_LLM_MODEL` | 与 ember-lares 相同；缺省 `https://api.deepseek.com`、`deepseek-flash` |
| `EMBER_MEMORY_DIR` | 记忆根目录（缺省 `server/data/ember_zoom_memory`），每个作用域一个子目录 |
| `EMBER_K` | 放行门槛 k（缺省自动：min(n, ⌈n/2⌉+1)，n = 已同意人数） |
| `EMBER_ZOOM_ASR` | `zoom`（缺省，用 RTMS 转写）· `dashscope`（订每人 L16 音频，自备 ASR，需 `LARES_DASHSCOPE_API_KEY`）· `mock` |
| `EMBER_ZOOM_POST_CHAT` | `1` = 放行纪要贴进会议聊天 |
| `EMBER_ZOOM_LANG` | 转写 `src_language`（可选；不设则 `enable_lid`） |
| `EMBER_ZOOM_ALLOW_ORIGINS` | hub 允许的 Origin（逗号分隔；缺省只收同源） |

进程约定同 ember-lares：stdout 一行一个 JSON（`listening` / `session` / `ready` / `host` / `released` / `rtms_stopped` / `ended` / `error` / `exit`），不含会话文字。stdin `{"cmd":"stop"}` 或 SIGINT 时，全部散会后退出（退出码 0；参数错为 2；崩溃为 1）。**Windows 上 SIGTERM 是 TerminateProcess 硬杀**，来不及散会，托管方应先写 stdin stop。这是常驻服务，stdin 关闭不触发退出（与 ember-lares 不同）。

本地联调不需要 Zoom：先起服务，再 `node ember-zoom/sim/rtms_sim.mjs http://127.0.0.1:8790/webhook`（同样三组 env）。模拟器会发签名 webhook、跑握手并播一段短会。侧边栏可以用开发模式在浏览器里打开：`http://127.0.0.1:8790/sidebar/?dev=1&meeting=<sim 的 meeting_uuid>&pid=16778240&name=张伟`。

## 真 Zoom 配置（逐项）

1. **账号条件（外部，我方无法绕过）**
   - 需要 **Zoom Developer Pack**。Basic 免费账号不支持：webhook 不触发，API 报 2310。Pro/Business/Enterprise 也必须加 Developer Pack。
   - 有免费试用，限 **5 路并发流**。
   - 客户端版本：≥ 6.4.10（`startRTMS`）、≥ 6.2.5（`sendMessageToChat`）。
2. **建 App**：marketplace.zoom.us → Develop → Build App → **General app**，选 **User-managed**。内部使用不需要上架审核。
3. **Basic Information**：拿到 Client ID / Client Secret，填进 env。OAuth Redirect URL 填 `https://<你的隧道域名>/sidebar/`。本包不走 OAuth 回调，但 Zoom 要求必填。
4. **Features → Access**
   - 打开 **Event Subscription**，Event notification endpoint URL 填 `https://<你的隧道域名>/webhook`，点 Validate。服务器会对 `endpoint.url_validation` 先验签，再回 `encryptedToken`。
   - 订阅事件：**RTMS → `meeting.rtms_started`、`meeting.rtms_stopped`**（`meeting.rtms_interrupted` 可选）。
   - **Secret Token** 填进 `ZOOM_WEBHOOK_SECRET`。
5. **Features → Surface**
   - 选 **Meetings**。
   - Home URL：`https://<你的隧道域名>/sidebar/`。
   - **Domain Allow List**：加上 `<你的隧道域名>` 和 `appssdk.zoom.us`。
   - **Zoom App SDK → Add APIs**：勾选 `startRTMS`、`stopRTMS`、`getRTMSStatus`、`onRTMSStatusChange`、`getMeetingUUID`、`getUserContext`、`sendMessageToChat`。
   - 打开 In-client App Features 里的 Zoom App SDK。
6. **Scopes**
   - `meeting:read:meeting_transcript`（转写）。
   - 用 `EMBER_ZOOM_ASR=dashscope` 时，再加 `meeting:read:meeting_audio`。
   - RTMS scope 不可选（文档原话）。
   - 若改用 REST 启动（`PATCH /v2/live_meetings/{meetingId}/rtms_app/status`），需要 `meeting:update:participant_rtms_app_status`。本包没有实现 REST 启动。
7. **公网 HTTPS 隧道**：Zoom 只认 HTTPS。可以用 `cloudflared tunnel --url http://127.0.0.1:8790` 或 `ngrok http 8790`，域名每次变化时要回到 3–5 步更新。hub 走同一域名的 `wss://…/hub`，CSP 的 connect-src 已按 Host 头放行。
8. **Local Test → Add**，把 App 装到自己账号。开会后在 Apps 里打开「炉灵」，点「邀请炉灵」。主持人会看到 RTMS 授权请求，同意后服务器收到 `rtms_started`。
9. 建议主持人**关掉 AI Companion**，避免另一个 AI 带名记录，抵消本规则。

## 告知与边界（照实写给参会者）

- 侧边栏的规则说明就是这份告知，原话见 `sidebar/index.html`：原话经过 Zoom、我方服务器内存，以及开启时的云端 LLM，**不落盘**；去名靠规则加模型，**不保证万无一失**，所以要 k 人审过签名才出门。
- Zoom 自己会显示 RTMS 提示（"The content of this meeting is being sent to one or more apps."），这不由我们控制，也不能关。
- **Zoom 侧缓冲**：握手前后 Zoom 可能缓冲最多约 60 s 的数据（`buffer_data`，见 05 §2），这部分在 Zoom 那边，我方无法保证。我方的 60 s 上限只管自己进程内。
- 严格按查塔姆规则（A 档）的会：Chatham House 官方不允许 AI 记录，请不要邀请炉灵。
- 未点「我同意」的人，其发言在 `session.onTranscript` 就被丢弃，但 Zoom 仍然会把它发到我方进程内存。这是 RTMS 的粒度：没有按人过滤的订阅。

## 信任边界（重要）

- **身份是侧边栏自报的**。`zoomSdk.getUserContext()` 的 `participantId` / `screenName` 由客户端 JS 报给 hub，服务端没有可验证的签名。hub 只检查 Origin（缺省同源）和会议 UUID。理论上，知道某会议 meetingUuid 和某人 participantId、又能连上 hub 的人，可以冒充他提问或签名。
- 签名本身是 Ed25519，私钥在本人侧边栏的 WebCrypto 里生成，不可导出，关页即忘。但公钥是 ack 时自报的（TOFU：会话内钉住，换钥报 `key_mismatch`）。所以 k-of-n 防的是「服务器替人放行」，防不了「冒名 ack」。
- **加固路线（未实现）**：
  - 用 Zoom Apps 的 `x-zoom-app-context` 头（Home URL 打开时带，用 Client Secret 解密）在服务端确认 uid / mid，再签发短期 hub token。
  - 或者走用户 OAuth。
- **身份映射（UNCONFIRMED）**：假设 `getUserContext().participantId` 与 RTMS 的 `user_id` 是同一个数。文档没有明说。对不上时，hub 会退回唯一同名匹配，再不行就发一个侧边栏专用 id（`zs_…`）：能提问、能签名，但他说的话不会和他的 ack 对上，会被丢弃（fail closed）。

## 验证了什么 / 没验证什么

**已验证（本机，`node --test ember-zoom/`）**
- webhook：v0 签名、±5 min、篡改 / 错 secret / 缺头 / 超大 / 坏 JSON / 非 POST 的负例；url_validation 先验签。
- 客户端 ↔ 模拟器：握手顺序 1→2→3→4→7→5；两条连接的 12→13；错签名得到 status 3 后停止，不重试；媒体中途断开后退避重连并完整重握手；服务端不发心跳时触发看门狗重握手；msg 9 停止加 stop reason；主动 stop 发 21。
- port 映射；hub 路由（按会议隔离、定向发送、跨源拒绝）；只有 released 去聊天。
- e2e（mock LLM）：脚本含「我是张伟，在星辰科技负责产品」和真名。侧边栏答案无名字；纪要要 2 人签名，放行文本无名字、无星辰科技；LLM 的全部 prompt 里无名字、无单位；会议停止后，第二场会里由签名者撤回记忆，派生文件中零痕迹；非签名者撤回被拒。
- 可选真 LLM e2e（设了 `LARES_AI_LLM_KEY` 才跑）：模拟器 + DeepSeek，答案和放行纪要无名字、无单位。
- 侧边栏 WebCrypto Ed25519 的公钥和签名格式能被 `ember/core/crypto.mjs` 验过（单独脚本核对）。

**未验证（需要真 Zoom，即 Developer Pack 账号）**
- 真 RTMS 服务器的一切细节，模拟器只按 05 的读法实现。具体是：
  - 转写是否有 interim/final 之分（05 UNCONFIRMED）。我们把每条 msg 17 都当定稿；如果真有中间稿，会重复进账本，需要按 `start_time` 去重。
  - msg 4 字段 `payload_encrypted` 还是 `payload_encryption`（05 UNCONFIRMED）。客户端两者都不读，只看 `status_code`。
  - `STREAM_CLOSE_REQ`（21）的字段，05 只给了编号。客户端尽力发送，失败也无妨。
  - 重连后 Zoom 是否补发当前参会名单。模拟器会补发；若真 Zoom 不补，重连后已在会的人要等下一次说话才被看见（`seen()` 会补登）。
  - `participantId` 与 RTMS `user_id` 是否同一编号（见上）。
- 侧边栏在真 Zoom 客户端里的表现：`startRTMS` 的授权流程、`sendMessageToChat` 的长度限制（暂截到 4000 字）、Domain Allow List 是否还要加别的域。
- `EMBER_ZOOM_ASR=dashscope` 路径（每人音频加 DashScope）只做了编解码单测，没跑过真流。
