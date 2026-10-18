# 隐名之约 Agent — 核心接口（v0，orchestrator 定稿，实现方可补充但不改语义）

平台无关的会议 agent，受 Chatham House 规则启发 · 非官方。核心不依赖 LiveKit / Lares；平台通过 adapter 接入（Lares LiveKit 首发，Zoom / Teams 预留）。

## v1 愿景：Everything Agent（用户 2026-10-18 指示）
一个有记忆的 agent，经各类插件陪在所有人身边、替人做事。它能拿到的一切信息都是**脱敏**的。三个平面：

| 平面 | 内容 | 存放 | 谁能读 |
|---|---|---|---|
| **原话面 raw** | 实时原话，带说话人 | 只在会话内存里，散会即焚 | 在场成员；室内 AI 只在当场使用 |
| **知识面 knowledge** | 经 Gate 处理、k-of-n 放行的去名知识（观点、决定、待办、公共事实） | **持久化**，按圈子存储，每条带出处（`sid`、放行签名数），**不含说话人** | agent 的长期记忆；外向插件**只能读这一面** |
| **个人面 personal** | 我自己说过的话，以及 agent 替我做的事 | 只在我自己的设备上（可另设个人加密保险箱，后续） | 只有我本人；自述例外 |

规则如下。
- **「不留痕」的精确含义**：原话不留痕；记忆里只有大家同意放行的去名知识。
- **撤回**：每条知识可以被任一放行人日后请求撤回，撤回后变成墓碑，agent 的记忆同步删除。
- **马赛克攻击**：跨会话聚合会提高认人风险。所以检索出的知识在**输出时**还要再过一次 Gate，可以组合重识别的内容不得同时输出。
- **插件**：分两类。
  - 数据源：Lares 房间、Zoom、Teams，以及之后的微信、邮件等。原话先在边缘处理，**只有知识面**进入 agent。
  - 执行器：发群、日历、文档、待办等。
  - 能力格：执行器只能拿知识面。
- **MVP 落地**：
  - 圈子知识库：持久化，只收已放行的条目；
  - 室内 AI 回答时可以检索本圈知识库（「上次我们定了什么」）；
  - bot / 插件 API 只暴露知识库；
  - 提供撤回。

## 托管档（Phase-H）的诚实声明
- 原文（音频 → ASR 文本）经过 Lares 服务器内存，以及云端 ASR（DashScope）和 LLM（DeepSeek）；**不落盘、不写日志、散会即焚**。运营方在技术上无法被完全排除，界面必须如实说明。
- 端上 ASR / LLM、会话密钥、MLS 是后续阶段（见 `docs/plans/chatham/02-design.md` §12）。

## 核心 API（`server/anonym-agent/core/index.mjs`）
```js
createSession({ sid, roster, policy, llm, clock }) -> Session
//   roster: [{ id, name, aliases?, org?, title? }]   // 只在内存
//   policy: { k, flagThreshold=0.7, allowPublicFacts=true }
session.join(member) / session.leave(memberId)
session.ingest({ speakerId, text, ts, final })      // 进 RAM 环形缓冲
session.ask({ askerId, question }) -> { answer }    // 室内问答；只回给房间，不出门
session.draft({ fromTs?, toTs? }) -> Draft          // 经 Gate v2
//   Draft: { draftId, draftHash, items:[{ id, text, roleRisk, reason?, flags[] }], metrics }
session.review({ draftId, memberId, itemId, action: 'keep'|'generalise'|'cut' }) -> Draft  // 改动生成新 draftHash
session.approve({ draftId, draftHash, memberId, pubKey, sig, nonce }) -> { approvals, k, released }
//   sig = Ed25519 over canonical JSON {sid, draftId, draftHash, nonce}；重放（同 nonce）、hash 不符拒绝
session.released(draftId) -> { text } | null       // 唯一出门的东西
session.end() -> Receipt                            // 清空所有缓冲，返回计数 + sha256
```
所有原文只存在 Session 对象内；`end()` 后对象内无原文。任何出门渠道（发群、导出、插件、bot API）只能调用 `released()`。

### 补充形状（实现方 2026-10-18，与服务器集成方对齐）
```js
// 注入的 LLM（gate/llm.mjs 的 createDeepSeekLLM 返回同形）
llm = { chat(messages, { json?, temperature? }) -> Promise<{ text, usage?, finish? }> }   // llm 为 null 时走确定性 mock

createSession({ sid, roster, policy, llm, clock, memory })  // memory = 该圈子的知识库（createMemory 的返回值）；ask 用 memory.recall 做上下文
session.released(draftId) -> { text, items:[{ id, text, kind }] } | null   // items = 未被 cut 的放行条目

// 圈子知识库（core/memory.mjs），每个圈子一个实例
createMemory({ circleId, data?, storage?, roster?, llm? }) -> mem
//   data: 之前 mem.toJSON() 的快照；storage: memoryStorage() | jsonFileStorage(path)，{ load(), save(snapshot) }
mem.addRelease({ sid, draftId, approvals, k, items:[{ id, text, kind? }], approverIds? }) -> addedItems
//   条目：{ id, circleId, text, kind: 'idea'|'decision'|'todo'|'fact', sid, releasedAt, approvals }，永不含说话人
mem.list() -> items          // 墓碑形如 { id, retracted: true }，不含 text
mem.retract(itemId, by?) -> bool
mem.recall(q, { limit }) -> items                      // 字符 bigram + 关键词打分，不含墓碑；室内可用
await mem.recallForOutput(q, { limit, roster?, llm? }) -> items  // 出门前再过 Gate L4（马赛克检查），可组合重识别的条目被丢弃，flags 附在条目上
mem.toJSON() -> snapshot
```

## Gate v2 语义（相对原型的变化）
1. **公共知识放行**：涉及公共世界的事实不脱敏，例如「《三体》是刘慈欣写的」、公众人物的公开言行、已出版作品、公开机构的公开政策。
   - 判别标准：**这条信息能否把话指回某位参会者或其所属机构**。
   - 如果参会者本人就是那位作者 / 公众人物（名单命中，或出现「我那本书」这类自指），按参会者身份处理，要脱敏。
2. **语气中性化**：阴阳怪气、反讽、明褒实贬、口头禅、方言腔、标志性修辞，一律改写成中性的命题陈述，比如「有与会者对该方案的可行性表示怀疑」。语气本身会暴露身份。
   - 保留立场的方向和强度等级（支持 / 质疑 / 强烈反对），去掉表达风格。
3. 其余沿用原型的 L0–L4 和 roleRisk 标记。

## Lares 集成协议（WS，signaling server；MVP）
一个圈子同时只有一场隐名会话，必须由圈主召集，且只能用于已注册的 v2 圈子（env/legacy 圈拒绝）。所有状态只在内存里，服务器重启即焚（等同 `end`）。

客户端发往服务器：
| msg | 字段 | 规则 |
|---|---|---|
| `anon_start` | `circleId, k` | 只有圈主可发，且必须在房间内。`k` 取 2..在场人数，默认 ⌈n/2⌉+1 封顶 n |
| `anon_ack` | `circleId, pubKey(b64 Ed25519)` | 每个成员确认托管声明并登记会话公钥。**未 ack 的成员发来的话不进 agent** |
| `anon_utt` | `circleId, text, ts, final` | 只收 final。来源是该成员自己的云字幕定稿；**不进入 transcript 归档** |
| `anon_ask` | `circleId, question` | 室内问答 |
| `anon_draft` | `circleId` | 任何已 ack 成员都可发起 |
| `anon_review` | `circleId, draftId, itemId, action` | `action`: keep / generalise / cut |
| `anon_approve` | `circleId, draftId, draftHash, nonce, sig` | |
| `anon_end` | `circleId` | 圈主可发；房间最后一人离开时自动结束 |

服务器广播（只发给在房间且已 ack 的成员）：
- `anon_state {circleId, active, sid, k, members:[{id,name,acked}], convenerId}`
- `anon_answer {circleId, askerName, question, answer}`
- `anon_draft {circleId, draft}`
- `anon_approvals {circleId, draftId, count, k}`
- `anon_released {circleId, draftId, text}`
- `anon_ended {circleId, receipt:{counts, sha256}}`
- `anon_error {code}`

会话期间服务器强制执行：
- transcript 归档和 relay 拒收；
- bot SSE 和插件 webhook 不收任何该圈内容；
- AI 语音 bot 不启动，已在的踢出；
- push 不带内容预览；
- 忽略 `LARES_AI_LOG_TEXT`；agent 的错误日志只记 code，不记文本。

`released` 文本可以由成员复制或分享，也通过 bot API `GET /bot/v1/circles/:id/anonym/released` 对外提供（唯一的对外数据源）。

## Adapter 接口（`server/anonym-agent/adapters/*.mjs`）
```js
{ name, start(ctx), stop() }
// ctx: { onUtterance(speakerId, text, ts, final), onMemberJoin(m), onMemberLeave(id),
//        postToRoom(msg), postOutward(text), roster() }
```
- `lares-livekit`：首发。
- `zoom` / `teams`：只实现 stub，另附可行性说明。
