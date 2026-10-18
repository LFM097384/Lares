# Lares 信令协议增补:隐名之约(anonym)

> 本文件只记**新增**的消息与接口;其余信令见 `docs/plans/*-contract.md`。
> 实现:`server/src/anonym.js`(核心在 `server/anonym-agent/core/`,规格 `server/anonym-agent/INTERFACE.md`)。
> 测试:`server/test/anonym.mjs`(在 `npm test` 里)。

## 适用范围

- 只用于**已注册的 v2 圈**。env 口令圈 / legacy 圈会回 `not_registered`。
- 每个圈同时只有一场会话。会话只在服务器内存里,重启即丢;知识库(放行后的条目)会持久化。
- 只有真人能参与。AI 助手和机器人身份发来的消息回 `not_allowed`,也不计入人数。
- 最后一个真人离开房间时,会话自动结束(等同 `anon_end`)。

## WebSocket:C→S

| 消息 | 谁能发 | 说明 |
|---|---|---|
| `anon_start {circleId, k?, ownerKey?}` | 圈主,须在房 | 房里至少 2 个真人。`k` 是整数,2 ≤ k ≤ 在房真人数;不传时取 `min(ceil(n/2)+1, n)` |
| `anon_ack {circleId, pubKey}` | 在房成员 | 同意并登记 Ed25519 公钥(32 字节 raw,标准 base64 带填充;base64url 也接受)。重连时用同一公钥再发即可 |
| `anon_utt {circleId, text, ts, final}` | 已 ack | 一句话,上限 2000 字。`final:false` 和未 ack 者发来的话**静默丢弃**(不回错) |
| `anon_ask {circleId, question}` | 已 ack | 上限 500 字 |
| `anon_draft {circleId}` | 已 ack | 让 agent 出一份去名草稿 |
| `anon_review {circleId, draftId, itemId, action}` | 已 ack | `action` 取 `keep` / `generalise` / `cut`。会产生新的 `draftHash` |
| `anon_approve {circleId, draftId, draftHash, nonce, sig}` | 已 ack | 签名格式见下 |
| `anon_end {circleId, ownerKey?}` | 圈主 | |
| `anon_mem_list {circleId, ownerKey?}` | 任一鉴权过的圈成员,不必在房 | |
| `anon_mem_retract {circleId, itemId, ownerKey?}` | 圈主可撤任意条目;其他成员只能撤自己签过的那次放行里的条目 | |

### 签名

```
msg = 规范 JSON(键名排序、无空格) {draftHash, draftId, nonce, sid}
sig = Ed25519(私钥, UTF-8(msg)),标准 base64 带填充
nonce = 16 随机字节的 base64url,无填充(22 字符);同一 nonce 只能用一次
```

测试向量:私钥种子为字节 0..31,对应 `pubKey = A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=`;
取 `sid=S1, draftId=d1, draftHash=h, nonce=AAECAwQFBgcICQoLDA0ODw`,得
`sig = C4fR1aepz6LZ0oEc5B+yelRCzW64Ujp43mSgWkayEd5lvwHWR91fWq3W1lHglmC+DCrocIpB7wue0EzI+ChTBQ==`。

## WebSocket:S→C

| 消息 | 发给谁 | 形状 |
|---|---|---|
| `anon_state` | **房里所有真人**,不论是否 ack(好弹同意页) | `{circleId, active:true, sid, k, convenerId, members:[{id,name,acked}]}`;结束时 `{active:false, ...}` |
| `anon_answer` | 已 ack 的在房成员 | `{circleId, askerName, question, answer}` |
| `anon_draft` | 已 ack | `{circleId, draft:{draftId, draftHash, items:[{id,text,kind,flags}], metrics}}`。`metrics` 原样透传核心给出的内容 |
| `anon_approvals` | 已 ack | `{circleId, draftId, count, k}` |
| `anon_released` | 已 ack | `{circleId, draftId, text}` |
| `anon_ended` | 房里所有真人 | `{circleId, receipt:{counts, sha256}}` |
| `anon_mem` | 请求者 | `{circleId, items:[…]}`。按 `releasedAt` 从新到旧,最多 200 条,不分页 |
| `anon_mem_retracted` | **该圈所有在线成员**(包括在房的和在大厅的) | `{circleId, itemId}` |
| `anon_error` | 请求者 | `{circleId, op, code}`。`op` 是触发错误的消息类型 |

`anon_mem` 的条目有两种:

- 在世条目:`{id, circleId, text, kind, sid, releasedAt, approvals, canRetract}`。`canRetract` 针对每个接收者单独计算:圈主为 true;该次放行的签名人为 true;放行时没记录签名人的条目对所有人为 true。**不下发签名人名单。**
- 墓碑:`{id, circleId, retracted:true, sid, retractedAt}`,不带 `text`。

`code` 的取值有:`say_hello_first` `not_allowed` `unavailable` `bad_request` `not_registered` `not_member` `not_owner`
`e2ee_circle` `not_in_room` `already_active` `too_few` `bad_k` `no_session` `not_acked` `bad_key` `key_mismatch` `bad_text`
`bad_question` `busy` `empty` `hash_mismatch` `bad_nonce` `bad_sig` `replay` `unknown_draft` `rate_limited`
`no_such_item` `already_retracted` `not_approver` `save_failed` `llm_failed` `failed` `unknown_op`。

## 会话期间的强制关闭(服务器端执行,不依赖客户端)

| 通路 | 会话期间的行为 |
|---|---|
| `transcript_append` / `transcript_relay` | `transcript_error{reason:'anonym_active'}` |
| 机器人 SSE、插件 webhook(`botApi.emit` 的全部事件) | 不发。唯一例外是 `knowledge.released` |
| `POST /api/v1/captions` | 409 `anonym_active` |
| AI 语音助手 | 不拉起;已在跑的停掉(`disabled`)。结束后按原规则恢复 |
| 推送 | 按 E2EE 规则脱敏:标题 `Lares`,正文为「有人在你的圈子里」 |
| `cap_token` | 照常签发。客户端要用字幕识别来喂 `anon_utt` |

## HTTP(机器人 / 插件 token,`Authorization: Bearer`)

- `GET /bot/v1/circles/:id/anonym/released`:返回 `{circleId, items:[{sid, draftId, text, releasedAt}]}`。只在内存里保留每圈最近 50 条。
- `GET /bot/v1/circles/:id/anonym/knowledge?q=&limit=`:`limit` 取 1–20,默认 5。返回 `{circleId, items}`,经核心 `recallForOutput` 过滤(马赛克检查 + L4 复核;可能把人认出来的条目会被丢弃)。
- 通用规则:`:id` 必须与 token 所属的圈一致,否则 403 `wrong_circle`;插件 token 需要 `knowledge:read` 权限,否则 403 `permission_required`;无 token 时 401。

## 插件 webhook

- 新权限 `knowledge:read`。
- 新事件 `knowledge.released`,`data = {circleId, sid, draftId, items:[{id, text, kind, sid, releasedAt, approvals}]}`。只含去名后的条目,不含说话人、签名人或原话。

## 存储

- 知识库位于 `DATA_DIR/anonym_memory/<circleId>.json`,只存放行后的条目与墓碑;签名人只以 `sha256('anonym-approver:'+cid+':'+uid)` 的形式保存。
- `circle_delete` 时删除该文件。
- 会话原话、问题、回答、草稿都只在内存,结束即丢;日志只记错误码。
