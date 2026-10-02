# 转写记录 + 机器人 API —— 跨端契约(2026-10)

> 服务端与客户端并行实现时以本文件为准。改契约先改这里。

## 1. 实时字幕(LiveKit data,topic `lares.cap`)

- 每个说话者**只跑一个** STT 会话,`{t:'cap',id,seq,text,final}` **广播**(不再带 `destinationIdentities`)。
- 本机开着字幕时自己的话也转写,面板里标「我」(本地直接插入,不靠回环)。
- `capack{on}` 继续表示「我愿意被转写」;对端据此显示「未转写」。
- **机器人字幕帧**(只能由服务器经 RoomService.SendData 发出,接收端 `participant == null` 才认):
  `{t:'cap', id, seq, text, final, bot:{id:'<tokenId>', name:'<机器人名>'}}`
  有 participant 的帧带 `bot` 字段 → 整帧丢弃(防伪造)。

## 2. 聊天(LiveKit data,topic `lares.chat`,4 字节大端长度 + JSON header 帧)

- 机器人文字帧 header:
  `{v:1, t:'text', id:<uuid>, sid:'bot:<tokenId>', sn:'<机器人名>', cid:<circleId>, ts:<ms>, body:'...', bot:true}`
- 接收端:`participant == null` 且 `bot == true` 才按机器人渲染(名字 +「机器人」徽标);
  有 participant 却带 `bot:true` 或 `sid` 以 `bot:` 开头 → 丢弃。participant 为 null 但无 `bot:true` → 照旧丢弃。

## 3. 信令 WS 消息(客户端 → 服务器)

| 消息 | 说明 | 成功回执 | 失败 |
|---|---|---|---|
| `circle_transcript_set {circleId, on, ownerKey}` | 圈主开关转写记录 | `owner_ok {op}` | `owner_error {op, reason}` |
| `transcript_append {circleId, id, text, startedAt}` | 非 E2EE 圈,本人 final 句 | `transcript_appended {circleId, id, seq}` | `transcript_error {op:'append', circleId, reason}` |
| `transcript_get {circleId, before?, limit?}` | 拉历史,`before`=seq,limit ≤200 默认 50,新→旧 | `transcript_page {circleId, items, more}` | `transcript_error {op:'get', ...}` |
| `transcript_clear {circleId, ownerKey}` | 圈主清空(含 E2EE 圈的离线队列) | `owner_ok` + 广播 `transcript_cleared {circleId}` | `owner_error` |
| `transcript_relay {circleId, blob}` | E2EE 圈,密文一条 | `transcript_relayed {circleId, rid}` | `transcript_error {op:'relay', ...}` |
| `transcript_relay_ack {circleId, rids:[...]}` | 已落本地,服务器删队列 | — | — |
| `bot_token_create {circleId, name, ownerKey}` | 只在这里返回明文 token 一次 | `bot_token {circleId, id, name, token, createdAt}` | `owner_error` |
| `bot_token_list {circleId, ownerKey}` | | `bot_tokens {circleId, items:[{id,name,createdAt}]}` | `owner_error` |
| `bot_token_revoke {circleId, id, ownerKey}` | 吊销即时生效(含正在进行的 SSE) | `owner_ok` | `owner_error` |

服务器 → 客户端:
- `circleInfo`(`circle_settings` / welcome 里的圈子信息)新增 `transcript: bool`;`circle_summary` 同样带。
- `transcript_line {circleId, item}`:非 E2EE 圈每追加一条广播给在房成员(可选消费)。
- `transcript_relay {circleId, items:[{rid, blob, ts}]}`:E2EE 密文推送;在线即推,离线在下次 hello/join 后补推。
- `transcript_cleared {circleId}`:客户端清本地存储。

`item` = `{seq, ts, userId, name, id, text, startedAt}`,`ts`/`seq` 由服务器分配,`userId`/`name` 取自已认证会话。

校验:text 1..2000 字;必须在该圈房间里(session.circleId === circleId);每人限速(append 与 relay 各约 2 条/秒、突发 20);
E2EE 圈(`circleSettings.e2ee === true`)`transcript_append` → `reason:'e2ee'`;未开启转写 → `reason:'off'`;blob ≤ 8192 字符。

## 4. E2EE 密文 blob

- 密钥:`HKDF-SHA256(ikm = 本圈 E2EE 共享密钥(E2EEController 交给 LiveKit setSharedKey 的那串 64 位 hex)按 hex 解码得到的 32 字节, salt = utf8(circleId), info = utf8("lares-transcript-v1"), L = 32)`。
- 加密:AES-256-GCM,12 字节随机 nonce,AAD = utf8(circleId)。
- `blob = base64( 0x01 || nonce(12) || ciphertext || tag(16) )`
- 明文 = UTF-8 JSON `{id, uid, name, text, startedAt, ts}`。
- 服务器只存 blob,永不见明文。队列按 userId,每人上限 5000 条 / 30 天;收件人 = 曾进过该圈房间的 userId(持久化名单),不含发送者本人(发送者本地直接落库)。

## 5. 机器人 REST(`/api/v1/`,`Authorization: Bearer <bot token>`)

`GET /circle` · `GET /transcript?before=&limit=` · `GET /events`(SSE)· `POST /messages {text}` · `POST /captions {text, final?}` · `POST /speak`(WAV PCM16 单声道 ≤60 s)。
E2EE 圈 messages/captions/speak/transcript → `409 {error:'e2ee'}`。详见 `docs/bot-api.md`。

## 6. 服务端实现补充(2026-10,服务端落地时补定;客户端照此处理)

- `rid` 是**不透明字符串**(当前形如 `r_<ts36>_<hex>`),客户端只做相等比较,别解析。
- `transcript_append` 对同一 `(userId, id)` **幂等**:重发返回原 `seq`,不重复广播。客户端断线重发可放心。
- `seq` 每圈单调递增,`transcript_clear` 后**不回退**(清空后新条目从清空前的最大 seq+1 起)。
- `transcript_get` 只要求本连接对该圈已认证(circle 模式即证明里的圈),**不要求在房**;E2EE 圈 → `reason:'e2ee'`。
- `bot_token_revoke` 的 `owner_ok` 带 `{op, circleId, id}`。
- relay 推送:在线时推给该圈所有已认证连接(含发送者本人的**其它设备**,不含发送这条连接);离线队列按 userId,发送者本人不入队。
  hello 后立即补推该连接可见圈的积压;circle 模式下 hello 推过则 join 不重复推。收到后务必 `transcript_relay_ack`,否则下次连接还会再推(客户端需按 rid 去重)。
- 失败 reason 全集:
  - `transcript_error op:'append'`:`say_hello_first` `not_in_room` `e2ee` `off` `bad_id`(非字符串/空/>200)`bad_text` `rate_limited` `save_failed`
  - `transcript_error op:'relay'`:`say_hello_first` `not_in_room` `not_e2ee` `off` `bad_blob` `rate_limited` `save_failed`
  - `transcript_error op:'get'`:`say_hello_first` `auth_scope` `e2ee` `bad_request`
  - `owner_error`(本节新增的 op):`say_hello_first` `not_registered` `not_owner` `bad_request` `bad_name`(机器人名 1..32)`too_many`(每圈 ≤20 个 token)`not_found`
- 限速默认 2 条/秒、突发 20(append 与 relay 分开计,按 userId);环境变量 `LARES_TRANSCRIPT_RATE_PER_SEC` / `LARES_TRANSCRIPT_BURST`。
- 机器人定稿字幕(`POST /captions final:true`,非 E2EE 且转写开启)会以 `userId = "bot:<id>"`、`name = 机器人名` 归档并广播 `transcript_line`;客户端按普通条目显示即可。
- REST 额外状态码:`503 rtc_not_configured`(服务器没配 LiveKit)、`502 livekit_failed / speak_failed`、`501 speak_unavailable`(服务器没装 rtc-node)。
  `POST /speak` **同步**:播完才返回 `200 {ok, sampleRate, durationMs, elapsedMs}`。
- `GET /circle` 的成员 `muted` / `speaking` 恒为 `null`(信令服务器不知道这两个状态,如实给 null 而不是猜)。
