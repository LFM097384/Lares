# Lares 信令协议增补:隐名之约(anonym)v2

> 本文件只记**新增**的消息与接口;其余信令见 `docs/plans/*-contract.md`。
> 规格:`ember/AGENT-V2.md` §1–§3。服务端实现:`server/src/anonym.js`(元数据)+ `server/src/anonym_supervisor.js`(托管进程)。
> 测试:`server/test/anonym.mjs`(在 `npm test` 里)。
>
> v1 的 `anon_start / ack / utt / ask / draft / review / approve / end / mem_*` 和 `GET …/anonym/released` **已删除**。
> 会话内容(原话、问题、回答、草稿、签名)不再经过信令服务器,改在 agent 与客户端之间处理(见 AGENT-V2.md)。

## 角色

- **agent** 是圈里的一个成员,身份为 `u_ai_anon_<sha256(cid)[:8]>`。它与灶语(AI 语音,`lares.ai-voice`)`u_ai_<sha256(cid)[:8]>` 是不同的 id。
  - hello 必须带 `aiAuth {circleId, proof}`,其中 `proof = HMAC-SHA256-hex(memberSecret, "${nonce}:${userId}:${circleId}")`。
  - `memberSecret` 按角色单独派生,所以灶语的凭证冒充不了隐名 agent。
  - 凭证只对凭证所属的那个圈有效。
- **托管模式**:服务器按圈拉起 `ember-lares/index.mjs`(炉灵的 Lares 插件),可用 `LARES_ANONYM_AGENT_ENTRY` 覆盖入口。启动需要 LiveKit 已配置。
  - argv 只有 `--circle <cid> --signaling ws://127.0.0.1:<port>/ws`。
  - 子进程 env 删掉 `LIVEKIT_*`、`LARES_APNS_*`、`LARES_AUTH_TOKEN`、`LARES_CIRCLE_PASSCODE(S)`、`LARES_AI_MEMBER_KEY`。
  - 子进程 env 加上 `LARES_ANONYM_USER_ID`、`LARES_AI_MEMBER_SECRET`、`LARES_AI_AUTH_SECRET`/`LARES_AI_AUTH_V`、`LARES_ANONYM_K`(有 k 时才设)、`LARES_ANONYM_E2EE`(`0`/`1`)、`LARES_ANONYM_HOSTED=1`、`LARES_ANONYM_MEMORY_DIR=DATA_DIR/anonym_memory/<cid>`、`LARES_SIGNALING`。
  - `LARES_DASHSCOPE_API_KEY` 与 `LARES_AI_LLM_*` 照常传下去,供 ASR 和 LLM 使用。
  - 停止时先在 stdin 写 `{"cmd":"stop"}`,再发 SIGTERM,5 s 后发 SIGKILL。
  - 退出码 0 表示会话结束,邀请随之作废。非 0 表示崩溃:只要邀请还在、房里有人,就按退避重拉,每小时最多 5 次。
  - 房里没有真人超过 20 s,停掉进程并作废邀请。
- **独立自托管**:agent 用同样的协议自行连接,服务器不拉进程。
- **E2EE 圈可以用**:媒体密钥由圈主密封后交给 agent,服务器只转发密文。
- 只用于**已注册的 v2 圈**。env 口令圈 / legacy 圈回 `not_registered`。
- 隐名 agent 被邀请或在场期间,灶语(AI 语音)不进房,已在房的会被停掉(`disabled`)。agent 走后按原规则恢复。

## WebSocket:C→S

| 消息 | 谁能发 | 说明 |
|---|---|---|
| `anon_agent_invite {circleId, k?, ownerKey?}` | 圈主,须在房 | 整数 `k` 取 2–20,原样经 env 交给 agent。回 `anon_ok`。已邀请或已在场时回 `already_active` |
| `anon_agent_dismiss {circleId, ownerKey?}` | 圈主 | 停掉进程,强制关闭立即解除。幂等 |
| `anon_agent_key {circleId, sealed, x25519Pub?, ownerKey?}` | 圈主 | `sealed` 是密封后的媒体密钥(base64 / base64url / hex,≤ 4096)。服务器**原样**只转给该圈的 agent 连接。带了 `x25519Pub` 而与 agent 当前公钥不符时,回 `stale_key` |
| `anon_agent_hello {circleId, x25519Pub}` | 仅该圈的 agent 连接 | 服务器转给在房圈主,形式为 `anon_agent_keyreq`。之后进房的圈主也会补收 |
| `anon_active {circleId, on}` | 仅该圈的 agent 连接 | 开 / 关下表的强制关闭 |
| `anon_released_notice {circleId, itemIds[]}` | 仅该圈的 agent 连接 | 1–200 个 id。服务器读记忆文件,触发插件 webhook `knowledge.released` |

圈主身份的判断有两种:握手时带了 ownerKey,或本条消息带了 `ownerKey`。agent 连接发来的 invite / dismiss / key 一律回 `not_allowed`;非 agent 连接发来的 hello / active / released_notice 也回 `not_allowed`。

## WebSocket:S→C

| 消息 | 发给谁 | 形状 |
|---|---|---|
| `anon_agent_keyreq` | 在房的圈主连接 | `{circleId, x25519Pub}` |
| `anon_agent_key` | 仅 agent | `{circleId, sealed, x25519Pub?}` |
| `anon_agent_state` | 该圈所有在线成员(在房和在大厅的都发);有人进房时补推 | `{circleId, present, active, invited}` |
| `anon_ok` | 请求者 | `{circleId, op, …}` |
| `anon_error` | 请求者 | `{circleId, op, code}` |

`code` 的取值:`say_hello_first` `bad_request` `not_member` `rate_limited` `not_allowed` `not_registered` `not_owner`
`not_in_room` `bad_k` `unavailable` `busy` `already_active` `no_agent` `stale_key` `unknown_op`。

## 强制关闭(`anon_active{on:true}` 期间,服务器端执行)

| 通路 | 行为 |
|---|---|
| `transcript_append` / `transcript_relay` | 回 `transcript_error{reason:'anonym_active'}` |
| 机器人 SSE、插件 webhook(`botApi.emit` 的全部事件) | 不发。唯一例外是 `knowledge.released` |
| `POST /api/v1/captions` | 409 `anonym_active` |
| 灶语(AI 语音) | 不进房。agent 在场期间本来就互斥 |
| 推送 | 按 E2EE 规则脱敏:标题 `Lares`,正文为「有人在你的圈子里」 |

agent 断开、被踢、被 dismiss 或解散圈时,强制关闭自动解除。

## HTTP(机器人 / 插件 token,`Authorization: Bearer`)

- `GET /bot/v1/circles/:id/anonym/knowledge?q=&limit=`
  - `limit` 取 1–20,默认 5。返回 `{circleId, items:[{id, text, kind?, sid?, draftId?, releasedAt?, approvals?}]}`。
  - 服务器只调用 `ember/core/filememory.mjs` 的 `readReleasedKnowledge(DATA_DIR/anonym_memory/<cid>, q)`,只读已放行条目,字段按白名单过滤。
  - `:id` 必须与 token 所属的圈一致,否则 403 `wrong_circle`。
  - 插件 token 需要 `knowledge:read` 权限,否则 403 `permission_required`。
  - 无 token 时 401。
- `GET …/anonym/released` 已删除,返回 404。

## 插件 webhook

- 权限 `knowledge:read`。
- 事件 `knowledge.released`,`data = {circleId, items:[…同上白名单…]}`,只含 `anon_released_notice` 里列出且记忆文件中确实已放行的条目。

## 存储

- agent 的文件记忆位于 `DATA_DIR/anonym_memory/<circleId>/`,格式由 agent 定义(AGENT-V2.md §7)。服务器只读,不写。
- `circle_delete` 删除整个目录,连同 v1 遗留的 `<circleId>.json`。
- 服务器日志只记错误码,不记公钥、密文或条目文本。
