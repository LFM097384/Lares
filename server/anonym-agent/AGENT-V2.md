# 隐名之约 Agent v2：作为 AI 成员加入圈子（orchestrator 定稿，2026-10-18）

用户指示：
- agent 以**成员**身份加入圈子，信令服务器**不处理会话内容**；agent 可以托管在我们的服务器上。
- 端到端加密圈子也要能用。
- 核心是**入口脱敏**。
- 提供 skill：按需**导出会议纪要**、**回答问题**。
- 记忆以**文件**形式维护，采用调研结论里的非向量化方案（见 `docs/plans/chatham/05-memory-research.md`）。

v1 中由服务器处理内容的部分（`server/src/anonym.js` 里的 `anon_*` 会话逻辑）**全部移除**。

## 1. 拓扑
```
成员客户端 ──LiveKit 音频 + data topic "lares.anon"（E2EE 圈内加密）──▶ anonym agent（u_ai_* 成员）
                                                                    │
信令服务器：只负责邀请 / 停止 agent、鉴权、转发密封密钥、强制关闭开关
```
- agent 进程：`server/bots/anonym-agent/`，复用 `server/bots/voice-agent/room.mjs` 的 `LaresRoom`（入房、订阅音频、data channel、E2EE `sharedKey`）和它的 DashScope ASR provider。
- 身份是 `u_ai_*`，复用现有 aiAuth 机制，`deviceId` 前缀区分。显示名「隐名之约 · AI」。
- 托管模式：supervisor 按圈子 spawn 子进程，套路同 `ai_voice_supervisor.js`。独立模式：`node server/bots/anonym-agent/index.mjs --circle --passcode [--e2ee]`。
- **同一圈子里隐名 agent 和语音 AI bot 互斥**：隐名 agent 在场时，语音 bot 停止。

## 2. E2EE 圈子：密封密钥
1. agent 启动时生成临时 X25519 密钥对，经它自己的信令 WS 连接发送 `anon_agent_hello {circleId, x25519Pub}`。
2. 服务器把 `anon_agent_keyreq {circleId, x25519Pub}` 转发给在房间里的圈主。
3. 圈主客户端用 X25519 + HKDF-SHA256 + AES-256-GCM（或 ChaCha20-Poly1305）把**媒体密钥 hex**（`lares-e2ee-v2` 派生值，不是口令）密封给该公钥，发送 `anon_agent_key {circleId, sealed}`。
4. 服务器只转发密文，交给 agent。
5. agent 解封后以 `sharedKey` 入房。

**诚实声明（界面上必须写）**：托管 agent 运行期间内存里有媒体密钥，运营方技术上无法被完全排除；想完全排除运营方，就在自己的设备上运行独立模式。非 E2EE 圈子跳过这一步。

## 3. 信令服务器（只管元数据）
| msg | 方向 | 规则 |
|---|---|---|
| `anon_agent_invite {circleId, k?}` | 圈主 → 服务器 | ownerGate，已注册圈子，圈主在房间里。spawn agent，k 经 env 传给 agent |
| `anon_agent_dismiss {circleId}` | 圈主 → 服务器 | 停止 agent |
| `anon_agent_hello / keyreq / key` | 见 §2 | 只转发 |
| `anon_active {circleId, on}` | agent → 服务器 | 只接受该圈 aiAuth 通过的 `u_ai_*` 连接。服务器据此打开或关闭强制开关 |
| `anon_agent_state {circleId, present, active}` | 服务器 → 圈内成员 | 广播给圈内在线成员 |

强制开关沿用 v1 已测试过的部分：
- transcript append 和 relay 拒收（`anonym_active`）；
- bot SSE 和插件 webhook 静默；
- 语音 AI bot 停止；
- push 去预览；
- bot `captions` 返回 409。

最后一个真人离开时，agent 自行结束会话并退出。

bot API：`GET /bot/v1/circles/:id/anonym/knowledge?q=` 改为读 agent 写下的记忆文件（同机同 `DATA_DIR`），且只读**已放行**部分；`/released` 一并移除或改为读文件。插件 webhook `knowledge.released` 由服务器监视 agent 的 `anon_released` 通知触发（agent 经 WS 发 `anon_released_notice {circleId, itemIds}`，服务器再从文件读取）。

## 4. 会话协议（LiveKit data，topic `lares.anon`，JSON，reliable）
客户端 → agent（`destinationIdentities` 设为 agent）：
| t | 字段 |
|---|---|
| `ack` | `pubKey`（Ed25519，b64） |
| `ask` | `q` |
| `skill` | `name`（`minutes` / `answer` / `topics` …）, `args` |
| `review` | `draftId, itemId, action`（keep / generalise / cut） |
| `approve` | `draftId, draftHash, nonce, sig`（canonical JSON，同 `client-canonicalisation.md`） |
| `mem_list` / `mem_retract` | `itemId` |
| `end` | 圈主才行 |

agent → 全房间广播（客户端按 ack 状态自行显示；内容都已脱敏）：
- `state {sid, k, members:[{id, name, acked}], convenerId, active}`
- `answer {qid, q, a}`
- `draft {draft}`
- `approvals {draftId, count, k}`
- `released {draftId, text}`
- `mem {items}`，`mem_retracted {itemId}`
- `ended {receipt}`
- `error {op, code}`

`state` 里的 `members.name` 只用来显示同意状态；LLM 永远看不到它。

**同意规则**：只转写已 ack 成员的音频，未 ack 的成员音频直接丢弃，不送 ASR。ack 时 agent 记录公钥（会话内钉住，成员离开即遗忘）。

## 5. 入口脱敏（核心）
```
音频 ─▶ ASR（DashScope，只对已 ack 成员）─▶ 原话 utt {speakerId, text}
      ─▶ IngestGate：
           L0 结构清洗；
           L1 PII + 名单（LiveKit 名字 + aliases）；
           L2 机构；
           speakerId → 会话假名（P1、P2…）；
           公共知识保留；
           每 ~20 秒或 ~600 字一批过 L3 改写（中性化语气，去自指）
      ─▶ 脱敏账本 ledger（只在内存里）
原话缓冲在 L3 完成后**立即清空**（最长 60 秒）。LLM 推理、所有 skill、记忆写入**只读 ledger**。
```
- 假名映射只存在于 IngestGate 内部，skill 拿不到。ledger 里是「P2 认为……」。
- 出门前（导出纪要）仍然要走：L4 检查 → roleRisk 标记 → 审阅 → k-of-n 签名放行。只有已放行的内容才写入长期记忆。
- `answer` 只在房间里显示，不出门，但同样只基于 ledger 加记忆。

## 6. Skills
模仿 Agent Skills 的格式：`server/anonym-agent/skills/<name>/SKILL.md`（front-matter：`name`、`description`、`outputs: room|release`）加 `run.mjs`。agent 启动时加载。

调用方式：
- 客户端显式发 `skill`；
- 或在 `ask` 里由 LLM 路由，例如「帮我出个纪要」会路由到 `minutes`。

MVP skills：
- `answer`：用 ledger 加记忆检索回答问题，结果留在房间里。
- `minutes`：按需导出会议纪要，包括议题、观点、决定、待办、公共事实，不带说话人。输出走 draft → 审阅 → 放行。放行后以 markdown 形式发 `released`，同时写入记忆。

## 7. 文件记忆
按调研结论实现，接口为：
```
remember(items, {sid, draftId, approvals})
recall(q, {limit})
recallForOutput（防拼图）
consolidate()
retract(itemId, by)
list()
```
目录：`DATA_DIR/anonym_memory/<cid>/`。删除圈子时整个目录删除。撤回必须同时传播到合并摘要（重新生成）。

## 8. 客户端
- 圈主在房间「更多」里点「邀请隐名之约 AI」（发 `anon_agent_invite`）；也可以「请 AI 离开」。
- E2EE 圈：收到 `keyreq` 后弹确认（附 §2 的诚实声明），再密封密钥发出。
- 同意页、标识条、问 AI、导出纪要（skill 按钮）、出门稿审核、签名放行、散会、圈子记忆：UI 沿用 v1。传输层从信令 WS 改为 LiveKit data `lares.anon`。
- 客户端不再把自己的字幕喂给服务器：agent 自己听、自己转写。
