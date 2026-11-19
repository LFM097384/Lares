# Lares 项目状态总结（2026-11）

> 截至 commit `3fce083`（2026-11-17）。事实来源：各目录 README、`git log`（共 193 个 commit）、`ember/bench/archive/README.md`，以及 2026-11-18 在本机重跑的单测。查不到依据的条目都标了「未验证」。

## 一句话

**Lares 圈子**是一个给小圈子朋友用的「一键进房」语音空间（Flutter 客户端 + Node 信令 + LiveKit）。圈子里可以请两个 AI 进来：**灶语 Hearthvoice**，叫它名字就用语音回答；**炉灵 Ember**，一个按查塔姆规则（受其启发，非官方）工作的会议 AI，会上的内容可以带出去，但不暴露是谁说的。两个 AI 的本体都与平台无关（`hearthvoice/`、`ember/`），通过插件接入 Lares（`hearthvoice-lares/`、`ember-lares/`，共用接入层 `lares-bridge/`）。炉灵另有 Zoom、Jitsi 插件和 Windows 托盘端。

## 组件现状

状态含义：**可用** = 单测全过，并且跑过端到端（生产或真实服务器）；**实验** = 单测全过，但只在模拟器、本机或部分链路上验证过；**未验证** = 只有 stub 或文档，或者近期没有可查的运行证据。

| 组件 | 作用 | 状态 | 入口 | 最后相关 commit |
|---|---|---|---|---|
| `app/` | Flutter 客户端（iOS / Android / Windows / macOS / Web） | 可用（iOS 走 TestFlight，见下） | `app/lib/` | `61c60dd` 2026-10-18 |
| `server/` | presence 信令、LiveKit token、圈子注册与鉴权、AI 进程 supervisor | 可用（本机栈；生产 VM 已停） | `server/src/index.js` | `060b8c7` 2026-10-18 |
| `lares-bridge/` | AI 进程接入 Lares 房间的共用层（鉴权、E2EE、帧） | 可用 | `lares-bridge/index.mjs` | `61c60dd` 2026-10-18 |
| `hearthvoice/` | 灶语本体：回合引擎、唤醒词、费用护栏、provider | 可用 | `hearthvoice/index.mjs` | `060b8c7` 2026-10-18 |
| `hearthvoice-lares/` | 灶语的 Lares 插件（`lares.ai-voice`） | 可用 | `hearthvoice-lares/index.mjs` | `61c60dd` 2026-10-18 |
| `ember/` | 炉灵本体：隐私闸门 L0–L4、agent 会话、skills、文件记忆 | 可用（闸门的 bench 结论为 FAIL，见下节） | `ember/index.mjs` | `3fce083` 2026-11-17 |
| `ember/bench/` | EmberBench 去识别化评测，v1–v5 | 已结束（用户决定停测） | `ember/bench/run.mjs`、`ember/bench/archive/` | `3fce083` 2026-11-17 |
| `ember-lares/` | 炉灵的 Lares 插件（E2EE 密封密钥握手、spawn 契约） | 可用 | `ember-lares/index.mjs` | `060b8c7` 2026-10-18 |
| `ember-jitsi/` | 炉灵的 Jitsi Meet 插件（无头 Chromium bot） | 实验（真 Jitsi e2e 8/8，只在 WSL 容器里跑通） | `ember-jitsi/index.mjs` | `be5c96d` 2026-10-25 |
| `ember-zoom/` | 炉灵的 Zoom 插件（RTMS 客户端、webhook、侧边栏） | 实验（只在模拟器上验证，未连真 Zoom） | `ember-zoom/index.mjs` | `a840ec6` 2026-10-24 |
| `ember-desk/` | 炉灵的 Windows 托盘端（守护进程、CLI、MCP、`ember://`） | 实验（Jitsi 经桌面端 9/9） | `ember-desk/daemon.mjs`、`start.cmd` | `be5c96d` 2026-10-25 |
| `ember/adapters/zoom.mjs` | 指针，已迁到 `ember-zoom/`，调用即抛错 | — | — | `a840ec6` 2026-10-24 |
| `ember/adapters/teams.mjs` | Teams stub，只有设计注释 | 未验证（未实现） | — | `5eaed90` 2026-10-18 |
| `deploy/` | Docker Compose（Caddy + LiveKit + 信令）、Azure 指南、preflight | 未验证（Azure 订阅已停，生产不可用） | `deploy/deploy.sh` | `61c60dd` 2026-10-18 |
| `site/` | Astro 官网 + Pages 流水线 | 未验证（近期无运行记录） | `site/`（`npm run build`） | `3923223` 2026-09-19 |
| `docs/` | 隐私政策、条款、支持页、插件 / bot API、设计方案 | 文档 | `docs/index.md` | — |

### 已验证（有证据）

| 项 | 证据 |
|---|---|
| `node --test ember/`：234 个，233 过，1 跳过（真 LLM 测试，无 key 时跳过），0 失败 | 2026-11-18 本机重跑 |
| `ember-lares` 8/8、`ember-zoom` 26 过 1 跳过（共 27）、`ember-jitsi` 31/31、`ember-desk` 37/37、`hearthvoice` 15/15、`hearthvoice-lares` 8/8、`lares-bridge` 12/12 | 2026-11-18 本机重跑，不设任何 key |
| 炉灵 Jitsi 真媒体 e2e 8/8（真 DashScope ASR + 真 DeepSeek） | `ember-jitsi/tool/jitsi_e2e.last.txt`，2026-10-24 |
| 炉灵经 ember-desk 的 Jitsi e2e 9/9 | `ember-desk/test/e2e_via_desk.last.txt`，2026-10-25 |
| ember-desk 四种入口（api / cli / mcp / protocol）在真 Jitsi 上进会和离会，只验证了信令和聊天，没有媒体 | `ember-desk/README.md` |
| 炉灵 Lares 生产 e2e 两圈全过；本机栈 e2e 修复了自报机构漏网 | commit `4eaa62c`、`5eaed90`、`060b8c7` 2026-10-18 |
| 灶语生产 e2e：TTFA p50 约 2.0s，打断 451ms | commit `91677b9` 2026-10-03 |
| 生产 e2e：转写自己的话、资料卡 | commit `860d062` 2026-10-04 |
| Zoom 插件与 RTMS 模拟器的 e2e（mock LLM） | `ember-zoom/README.md`，在 `node --test ember-zoom/` 内 |

### 未验证

- 真 Zoom（RTMS、侧边栏授权、`EMBER_ZOOM_ASR=dashscope` 真流）一次都没跑过。
- Jitsi：Windows 侧 Chromium 连 WSL 里的 JVB 时 ICE 不通，Windows 侧没有媒体；meet.jit.si、JWT、lobby、断线重连都没测过。
- Teams：只有 stub。
- 生产部署：Azure 订阅停用后生产 VM 停机，2026-10-18 起改用本机栈 `server/tool/local_stack.ps1`。
- iOS TestFlight 构建 51–54（Lares app，含灶语和炉灵）的真机检查。仓库里没有记录构建号：记忆库里有 51（`090a6b6`/`4eaa62c`）和 53（`5eaed90`），52 和 54 查不到来源。
- `server` 的 `npm test` 和 Flutter 测试这次没有重跑。
- `site/` 的构建这次没有重跑。

## 炉灵隐私关口与 EmberBench 结论

**闸门分层**：L0 结构清洗（去说话人、打乱顺序）→ L0P 全量化名和受控揭名（v5，仅公开模式）→ L1 确定性 PII → L2 机构与职衔 → L3 LLM 去归属改写 → L4 归属攻击加泛化循环。输出还要 k-of-n 参会者 Ed25519 签名才能放出房间。实现在 `ember/core/gate/`。

**最终 v5 封存测试**（`2026-11-17T0037-public-test`，60 场 MeetingBank 会议，闸门 `deepseek:deepseek-flash`，代码 `c39d66b`）：

| 指标 | 结果 | 判定 |
|---|---|---|
| P1（每 claim 泄露比特，+L4 − ideas-only） | −0.03 [−0.14, 0.07] | PASS（阈值：CI 上界 ≤ 0.25） |
| C（T8 / T9 v3 / T11 均值） | 0.83（0.83 / 0.78 / 0.87） | PASS（≥ 0.80） |
| 硬零 T1 v5 | 34（私人名字 14、约束位置呼语 18、私人席位 1、绑定机构 1） | FAIL |
| 硬零 T2 v5 | 5 | FAIL |
| 硬零 T6 v5 | 3 | FAIL |
| **总判定** | | **FAIL** |

**P13 事后修补**（2026-11-17，用户结束测试之后）：泄露审计发现的问题修在 `ember/core/gate/pseudonym.mjs` 和 `gate.mjs`，只在化名模式下生效。在已用掉的 test-v5 输出上离线回放：T1 v5 34 → 7，T2 v5 5 → 0，T6 v5 3 → 0。这是事后回放，构造上偏乐观，**不是确认运行**，P1 和 C 也没有重算。要确认，得用新的留出集重新预注册。

**测试已按用户决定结束**。全部运行、作废记录和已知局限见 `ember/bench/archive/README.md`（本文件夹 `attachments/` 里有副本），最终卡片见 `attachments/trustcard-v5.md`。

## 模型与密钥政策

- **炉灵闸门和 bench 今后只用 DeepSeek**（`deepseek:deepseek-flash`）。bench 默认值已改为只用 DeepSeek，DashScope key 文件加载器也已删除（commit `14a6194`）。
- **DashScope 上的 Qwen / Kimi key 不再使用。** 以往 bench 运行里的攻击者、评审、对齐器和标注者用过它（`dashscope:qwen-plus`、`dashscope:kimi-k3`）。因此存档里与攻击者相关的数字，本项目目前无法自行复现。只用 DeepSeek 可以运行闸门，但跑不了评测：`run.mjs` 拒绝攻击者与闸门同属一家。
- 闸门的 LLM 由调用方注入。各插件读 `LARES_AI_LLM_API_KEY`（或 `LARES_AI_LLM_KEY`）、`LARES_AI_LLM_BASE_URL`（默认 `https://api.deepseek.com`）、`LARES_AI_LLM_MODEL`（默认 `deepseek-flash`）。没有 key 时走确定性 mock。
- **待用户决定：ASR 仍在用 DashScope。** `ember-lares`（`--asr dashscope`）、`ember-jitsi`（默认 `--asr dashscope`）、`ember-zoom`（`EMBER_ZOOM_ASR=dashscope` 时）和 `ember-desk`（朗读、口述笔记）读的是 `LARES_DASHSCOPE_API_KEY`。灶语的 ASR / TTS 也走 DashScope，LLM 是 DeepSeek，失败时回落到 `qwen-flash`（commit `b61e016`）。这个 key 和上面停用的是不是同一把？要不要换 ASR 供应商？
- 密钥存放位置：环境变量；ember-desk 另有 DPAPI 加密文件 `%APPDATA%\ember-desk\secrets.dpapi.json`。仓库里不存任何密钥值。

## 待办 / 未完成

1. **生产部署**：Azure 订阅停用、VM 停机。需要重新部署（`deploy/`、`deploy/AZURE.md`），并跑一遍生产 e2e（`server/tool/*_prod_e2e.mjs`）。
2. **iOS TestFlight 构建 51–54 的真机检查**（Lares app，含灶语和炉灵）。
3. **App Store 隐私标签**（营养标签）填写和核对；提审前还要实测举报邮箱 `support@laresapp.org` 能收信（`HANDOFF.md`）。
4. **轮换 DeepSeek API key**：它出现过在日志里。
5. **Zoom 真机测试**：需要 Zoom Developer Pack 账号和 RTMS App，`ember-zoom/README.md` 的「未验证」清单要逐项跑。
6. **Jitsi 在 WSL 下的验证**：Windows 侧 ICE 不通，媒体只在 WSL 容器里验证过。
7. **职衔掩码的取舍**：P13 把在场非民选发言者的职衔（如 "city manager"）一律改写为 "city staff"，代价是话题性提及也被改写（METHOD P13）。保留还是放宽，要用户定。
8. **ASR 供应商**（见上节）。
9. 其他已知缺口：`createEmber` 和 agent 会话还没接 `publicContext / pseudonym / strictness`（archive §8）；Teams 未实现；ember-desk 的 Lares 频道只是说明桩，托盘没有用真鼠标测过；Jitsi bot 断线不重连；APNs 推送密钥未配（2026-09，来自记忆库，未在仓库核实）。

## 如何运行

```powershell
# 单测（不需要 key，不出网）
node --test ember/            # 234 个：233 过 / 1 跳过
node --test ember-lares/ ; node --test ember-zoom/ ; node --test ember-jitsi/ ; node --test ember-desk/
node --test hearthvoice/ ; node --test hearthvoice-lares/ ; node --test lares-bridge/
cd server; npm test           # 信令和灶语回合引擎大套件（本次未重跑）

# 本机全栈（LiveKit dev + 信令）
pwsh server/tool/local_stack.ps1 start    # stop / status

# 各插件（key 只放环境变量）
node ember-lares/index.mjs --circle <cid> --signaling ws://127.0.0.1:8787/ws --passcode <p> --auth-v2 --asr mock
node hearthvoice-lares/index.mjs --circle <cid> --signaling ws://127.0.0.1:8787/ws --passcode <p> --auth-v2 --providers mock
node ember-zoom/index.mjs ; node ember-zoom/sim/rtms_sim.mjs http://127.0.0.1:8790/webhook   # 需要三个 ZOOM_* 变量
node ember-jitsi/index.mjs --room weekly-sync --url https://localhost:8443 --asr mock
node ember-desk/daemon.mjs     # 或双击 ember-desk/start.cmd 启动托盘
node ember-desk/cli.mjs status
```

细节见 `components.md`，时间线见 `timeline.md`。
