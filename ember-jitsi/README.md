# ember-jitsi · 炉灵在 Jitsi Meet 上

炉灵（Ember）是一个坐在会里的 AI，规则受查塔姆规则启发（**非官方，与 Chatham House 无隶属**）：会上说的可以带出去，但不说是谁说的。本体在 `../ember/`，与平台无关（port 约定见 `../ember/PORT.md`）。本包是 Jitsi Meet 这一半，地位同 `../ember-zoom/`、`../ember-lares/`。

## 是什么

- 炉灵是会里一个**真实、可见的参与者**，显示名「炉灵」。实现方式：一个无头 Chromium 页面，加载**目标服务器自己的** `/config.js` 和 `/libs/lib-jitsi-meet.min.js`，用 lib-jitsi-meet 进会。版本自然与服务器一致，不另带一份 Jitsi 库。
- 音频：bot 订阅每个远端参与者的音轨，经 AudioWorklet 重采样成 16 kHz 单声道 Int16（100 ms 一帧），由 Playwright `exposeFunction` 传回 Node，**按 Jitsi endpoint 分人**，送入 Ember 的每人 DashScope 实时 ASR。
- 房间通道就是 **Jitsi 会议聊天**：人发文字命令（公开聊天要 @炉灵，私信不用）。Ember 的协议消息被翻成聊天文字发回，公开的发到公开聊天，私有的走私信。

## 架构

```
  Jitsi 服务器（docker-jitsi-meet：web / prosody / jicofo / jvb）
      │  /config.js、/libs/lib-jitsi-meet.min.js（同源加载）
      │  XMPP over WebSocket（config.websocket，缺省回退 config.bosh）    媒体：JVB（ICE/UDP）
      ▼                                                                  ▼
  无头 Chromium 页面  page/client.js（Playwright page.route 挂在 <服务器>/__ember_jitsi__/client.html）
      │  JitsiConnection → initJitsiConference(room, p2p 关) → setDisplayName('炉灵')
      │  远端音轨 → 静音 <audio> → AudioContext(16 kHz) → AudioWorklet 'ember-tap' → Int16 1600 样本/帧
      │  window.emberAudio(id, b64)        window.emberEvent({participant|name|left|chat|disconnected|track|warn})
      ▼
  bridge.mjs  JitsiBrowserBridge ── on('participant'|'name'|'left'|'audio'|'chat'|'disconnected')
      ▼                              sendPublic(text) / sendPrivate(id, text)
  port.mjs  jitsiPort ── 聊天 → commands.mjs 解析 → 'message'(id, 协议消息)；托管 Ed25519 代签
      │       'joined' / 'left' / 'name' / 'audio'(id, pcm, 16000, 1)
      ▼
  createEmber（../ember）：ack 门（未同意的音频在 ASR 前丢弃）→ DashScope ASR（每人一路）
      → IngestGate L0–L3 → 假名账本 → ask / minutes / k-of-n 放行 / 记忆
      │  state / answer / draft / approvals / released / mem / mem_retracted / error / ended
      ▼
  port.send → 公开聊天（计数、放行纪要、回执）或私信（答案、草稿、记忆，只给已同意者）
```

```
ember-jitsi/
├── index.mjs            CLI 入口：参数 / env → bridge + port + createEmber；stdout JSON 元数据事件；stdin stop / SIGINT
├── port.mjs             Ember port 的 Jitsi 实现：聊天 ↔ 协议消息、公开/私信分流、托管密钥、ANNOUNCE 公告文字
├── commands.mjs         聊天命令解析（纯函数）、HELP 文本、EMBER1 信封
├── bridge.mjs           JitsiBrowserBridge：一个 Chromium context = 一个 Jitsi 参与者（bot 与 e2e 模拟真人共用）
├── page/client.js       页面内脚本：lib-jitsi-meet 进会、逐人 AudioWorklet 抽音、聊天收发；不向 console 打印内容
├── deps.mjs             playwright / ws / Chromium 可执行文件解析（仓库根无 node_modules）
├── tool/jitsi_e2e.mjs   真 Jitsi 端到端验证（3 个模拟真人 + bot 子进程）；结果写 tool/jitsi_e2e.last.txt
├── tool/run_e2e_wsl.ps1 在 WSL2 里的官方 Playwright 容器中跑上面的 e2e（见「没验证什么」）
├── tool/media_probe.mjs 媒体连通性探针：两个 Chromium 进同一房间，报 ICE 状态与 RTP 字节数
└── test/                node --test ember-jitsi/（FakeBridge，无浏览器、无网络）
```

## 部署

### Jitsi 服务器（自建 docker-jitsi-meet）

只在自建 docker-jitsi-meet 上验证过（见下文）。要紧的配置：

- **允许匿名/访客进会**。bot 以 `new JitsiConnection(null, null, …)` 匿名连接，不带 JWT、不带密码。开了 `ENABLE_AUTH`（secure domain / JWT）的部署目前进不去，代码里没有凭据参数（加固路线见「信任模型」）。
- **不要开 lobby**，房间也不要设密码，否则 bot 卡在等待/失败（`conference_failed:*` → 退出码 1）。prejoin 页面是 Jitsi 网页 UI 的东西，bot 不走网页 UI，不受影响。
- **XMPP 走 WebSocket**：页面读 `config.websocket`，没有时回退 `config.bosh`。docker-jitsi-meet 缺省就有 `/xmpp-websocket`。
- **`JVB_ADVERTISE_IPS` 必须是 bot 浏览器能直达的地址**（UDP 10000）。信令和聊天通了不代表媒体通：ICE 不通时 bot 能进会、能聊天，但听不到任何人。可用 `tool/media_probe.mjs` 排查。
- 建议把 bot **跑在 JVB 同机或同一网络**里，少走一段 NAT/防火墙。
- 自签证书：`--url` 的主机是 `localhost` / `127.0.0.1` 时自动接受；其它主机设 `JITSI_INSECURE=1`。

### bot 本机依赖

- Node ≥ 22（`package.json` engines）。
- Playwright + Chromium：`npx playwright install chromium`。`deps.mjs` 依次找 playwright 包：裸 `import` → `server/node_modules` → `EMBER_PLAYWRIGHT_DIR` → npx 缓存（`%LOCALAPPDATA%\npm-cache\_npx\*\node_modules\playwright` 或 `~/.npm/_npx/*`）。Chromium 用 `EMBER_CHROMIUM_PATH`；没设且默认版本缺失时，退回 `ms-playwright`（或 `PLAYWRIGHT_BROWSERS_PATH`）下已有的最新 headless shell / chromium。
- `ws`（DashScope ASR 用）从 `server/node_modules` 解析。

### 运行

```powershell
$env:LARES_DASHSCOPE_API_KEY='…'     # --asr dashscope（缺省）必需；只放环境变量
$env:LARES_AI_LLM_KEY='…'            # 可选；不设则走确定性 mock 路径
node ember-jitsi/index.mjs --room weekly-sync --url https://meet.example.org
```

| 参数 | 说明 |
|---|---|
| `--room <name>` | **必需**。须匹配 `[A-Za-z0-9_.-]{1,64}`；进会时转小写 |
| `--url <https://…>` | Jitsi 服务器（只取 `协议://host[:port]`）。缺省 `JITSI_URL`，再缺省 `https://localhost:8443` |
| `--k <n>` | 放行门槛，整数 1..20。缺省 `EMBER_K`，再缺省自动（Ember：min(n, ⌈n/2⌉+1)，n = 已同意人数） |
| `--memory-dir <dir>` | 记忆目录，**原样使用**（不再拼作用域子目录） |
| `--asr dashscope\|mock\|none` | 缺省 `EMBER_JITSI_ASR`，再缺省 `dashscope` |
| `--scope <id>` | 记忆作用域。缺省 `EMBER_SCOPE`，再缺省 `sha256(服务器 host + "/" + 小写房间名)` 前 24 位：同一服务器同一房间名 = 同一个「圈」 |
| `--convener-name <name>` | 显示名等于它的人优先当召集人（见信任模型） |
| `--headful` | 有界面 Chromium（调试用） |
| `--help` / `-h` | 用法打到 stderr，退出 0 |

| 变量 | 说明 |
|---|---|
| `JITSI_URL` | 服务器地址（`--url` 优先） |
| `JITSI_INSECURE` | `1` = 接受自签证书（localhost / 127.0.0.1 自动） |
| `LARES_AI_LLM_BASE_URL` / `LARES_AI_LLM_API_KEY`（或 `LARES_AI_LLM_KEY`）/ `LARES_AI_LLM_MODEL` | 与 ember-zoom / ember-lares 相同；缺省 `https://api.deepseek.com`、`deepseek-flash`；无 key → mock |
| `LARES_DASHSCOPE_API_KEY` | DashScope 实时 ASR；`--asr dashscope` 时缺失 → 退出码 2。可选 `LARES_DASHSCOPE_HOST` |
| `EMBER_MEMORY_DIR` | 记忆根目录（缺省 `server/data/ember_jitsi_memory`），其下 `<scope>/` 一个子目录 |
| `EMBER_K` | 同 `--k` |
| `EMBER_SCOPE` | 同 `--scope` |
| `EMBER_CONVENER_NAME` | 同 `--convener-name` |
| `EMBER_JITSI_ASR` | 同 `--asr` |
| `EMBER_PLAYWRIGHT_DIR` | playwright 包目录（含 `index.mjs`） |
| `EMBER_CHROMIUM_PATH` | Chromium / headless shell 可执行文件 |

进程约定：

- **stdout** 一行一个 JSON，只有元数据，不含会话文字。本包发 `ready`（`room` / `selfId` / `endpoint` / `llm` / `asr` / `memory` / `k`）、`host`（`{type:'active', on}` 或 `{type:'released', items}`，只有条数）、`asr_final`（`{endpoint, chars}`，只有长度）、`error`、`exit`；Ember 自己还会发 `session` / `released` / `ended` 等。真 e2e 里实际观察到的事件集：`host, session, ready, asr_final, released, ended, exit`。
- **stdin** `{"cmd":"stop"}` 或 **SIGINT**（SIGTERM 同样处理）→ 散会，约 300 ms 后离会、退出；5 s 硬超时。Windows 上 SIGTERM 是硬杀，托管方应先写 stdin stop。stdin 关闭**不**触发退出。
- 会话也会自己结束：召集人发「结束」，或最后一个真人离开。
- **退出码**：`0` 正常（含召集人散会 / 最后一人离开）；`1` 崩溃、启动失败（`start_failed`），或会话未结束时 Jitsi 连接断开（`connection_failed` / `conference_failed` / `kicked` / `page_crash` 等）；`2` 参数错（含缺 `LARES_DASHSCOPE_API_KEY`）。
- 无断线重连：连接断了就退出，由托管方决定是否重起。

## 会内用法

公开聊天里命令要以 `@炉灵`、`＠炉灵`、`@Ember` 或「炉灵，」开头；**私信给炉灵不需要 @**。不带 @ 的普通公开聊天，炉灵不看。

| 命令 | 作用 |
|---|---|
| `@炉灵 同意`（我同意 / ack / agree） | 同意规则。之后才转写你的语音；托管模式下为你的 endpoint 生成签名密钥 |
| `@炉灵 问 <问题>`（或直接 `@炉灵 <一句话>`） | 就刚才的讨论提问；答案私信给所有已同意者 |
| `@炉灵 纪要` | 生成纪要草稿，私信给已同意者审阅 |
| `@炉灵 批准 D1`（不写编号 = 最新草稿） | 批准草稿；k 个不同参会者批准后在公开聊天放行 |
| `@炉灵 保留\|泛化\|删除 D1 <序号>` | 处理标 ⚠（可能暴露身份）的条目；不处理则该条不公开；处理会清空已有批准 |
| `@炉灵 记忆` | 私信列出本圈记忆（M1、M2…） |
| `@炉灵 撤回 M1` | 撤回一条记忆，并从所有派生文件中重建删除；只有当时批准这条的人能撤回 |
| `@炉灵 结束`（散会） | 散会，只有召集人可用 |
| `@炉灵 帮助`（或只发 `@炉灵`） | 命令表，私信回复 |

**公开 vs 私信**

- 公开聊天里只出现：入会公告、「已同意 n 人 · 纪要放行需 k 人批准」、「D1 已获 x/k 人批准」、**已放行的纪要原文**、「记忆 M1 已撤回」、散会回执（放行份数 + 回执 sha256 前 16 位）。
- 答案、草稿、记忆列表**只私信**给当前在场、已同意的人；错误提示只私信给出错的那个人。

## 信任模型（如实）

- **显示名不是认证。** Jitsi 访客可以给自己起任何名字，包括别人的名字或「炉灵」。炉灵只认 endpoint id（XMPP occupant），名字只用于内存里的名单清洗。
- **召集人**：Ember 缺省取 bot 进会时 `participants()` 的第一个人（会里还没人时，就是第一个进来的人）；给了 `--convener-name` / `EMBER_CONVENER_NAME` 时，同名者排到最前。两种方式都能被冒充：抢先进会，或者改成那个名字。
- **托管模式（缺省）**：「@炉灵 同意」时，port 在**进程内存**里为该 endpoint 生成 Ed25519 密钥对；「批准 D1」时由 port 代签。离会或散会时丢弃密钥。所以：
  - k-of-n 的实际含义是「**k 个不同的 Jitsi endpoint 在聊天里说了批准**」。同一个人开多个标签页或多台设备，就是多个 endpoint，一个人可以凑够 k。
  - 运行 bot 的人握有全部私钥，可以伪造任何人的批准。
- **自持密钥模式**：客户端私信 `EMBER1 {json}` 信封，私钥不离开它自己的设备，签名才真正对应密钥持有人：
  1. 私信 `EMBER1 {"t":"ack","pubKey":"<Ed25519 公钥 base64>"}`。此后该 endpoint 标为自持，不能再用托管「同意」/「批准」。
  2. bot 把原始协议消息（`state` 里有 `sid`，`draft` 里有 `draftId` / `draftHash`，以及 `approvals` / `released` / `mem` / `error`）也以 `EMBER1 {…}` 私信给它。
  3. 批准：私信 `EMBER1 {"t":"approve","draftId":…,"draftHash":…,"nonce":…,"sig":…}`，`sig` = Ed25519 对 `canonicalJSON({sid, draftId, draftHash, nonce})` 的签名（`../ember/core/crypto.mjs`）。坏签名回 `bad_sig`，重复 nonce 回 `replay`，换钥回 `key_mismatch`。
  4. 允许的信封操作：`ack` `ask` `skill` `review` `approve` `mem_list` `mem_retract` `end`。信封只收私信，公开发会被拒。
  
  但公钥本身仍是 TOFU：谁先用某个 endpoint ack，谁的钥就被钉住，没有人能证明 endpoint 背后是谁。
- **服务器运营方能看到聊天。** 标准 Jitsi 的聊天和 datachannel 没有端到端加密，走 prosody；草稿、答案的私信也一样。开 Jitsi 的媒体 E2EE（insertable streams）后，bot 解不开音频，也就听不到人。
- **建议**：部署时开 Jitsi 认证（JWT / secure domain），让 XMPP 身份有意义；同时让 bot 也能凭据进会。这需要给 bridge 加凭据参数，**目前未实现**。

## 如实披露

- 「炉灵」出现在参会者列表里，不隐身。
- 进会时在公开聊天发这段公告（`port.mjs` 的 `ANNOUNCE`，原文）：

  ```
  大家好,我是炉灵(Ember),一个 AI 会议助手。我现在在会里,参会者列表里能看到「炉灵」。
  规则(受查塔姆规则启发,非官方):会上说的内容可以带出去,但不说是谁说的。
  · 只有在聊天里发「@炉灵 同意」的人,我才转写其语音;没同意的人,声音在转写之前就丢掉。
  · 我不录音;原话只在内存里改写成不带名字的账本,散会即清空。
  · 纪要先私信给已同意的人审阅,要 k 个不同的参会者批准后才在这里公开,且不带名字和单位。
  · 注意:Jitsi 显示名不是身份认证,批准按「不同的 Jitsi 连接」计数。
  命令:@炉灵 帮助
  ```
- 只转写已「同意」者的语音。未同意者的音频帧仍会经 JVB 到达 bot 的浏览器和进程（Jitsi 没有按人退订的粒度），但在进 ASR 之前就丢弃（单测核对 `droppedUnackedFrames > 0`、该人从未出现在 `asr_final` 里）。Jitsi 隐藏参与者（Jibri 录制器等）不算成员，也不能下命令。
- 不录音。原话只在进程内存里，经 IngestGate 改写成不带名字的假名账本，散会清空。落盘的只有放行条目（记忆目录）。stdout / stderr 只有元数据，页面脚本也不向 console 打印聊天或语音内容。
- 严格按查塔姆规则（A 档）开的会：Chatham House 官方不允许 AI 记录，请不要邀请炉灵。

## 验证了什么 / 没验证什么

**真 Jitsi e2e（`tool/jitsi_e2e.mjs`，结果见 `tool/jitsi_e2e.last.txt`）**

环境：自建 docker-jitsi-meet `stable-11248-2`（WSL2），`https://localhost:8443`，随机房间，k = 2。3 个模拟真人（张伟 / 李秀梅 / 王强），每人一个无头 Chromium，假麦克风（`--use-file-for-fake-audio-capture`）播放 DashScope TTS 合成的真中文语音。bot 作为子进程起 `index.mjs`：真 DashScope ASR，真 DeepSeek LLM（`deepseek-flash`）。所有命令都走 Jitsi 会议聊天。脚本里含真名和单位「星辰科技」。

8 项检查：

1. bot 进真会议，参会者列表里显示「炉灵」，并在聊天里公告。
2. 每人的真实语音被逐人 ASR，按 Jitsi endpoint 区分（定稿字数 `{"张伟":19,"李秀梅":45,"王强":37}`）。
3. 聊天提问 → 答案只私信给已同意者，答案里没有参会者名字。
4. 放行要 k = 2 个不同的人：1 次批准，加同一人重复批准，都不放行；第 2 个不同的人批准后放行。
5. 放行文本无 张伟 / 李秀梅 / 王强，无 星辰科技。
6. 批准人撤回后，Ember 派生记忆文件中零残留；非批准人撤回被拒。
7. 召集人「结束」散会，非召集人被拒；bot 离会并以 0 退出。
8. bot 的 stdout / stderr 里没有原话、名字、单位（11 个探针）。

结果文件摘录：

```
PASS [4] minutes release needs k=2 approvals from distinct humans: 1 approval (and a repeat by the same human) released nothing; the 2nd distinct human released — released-before-k: false
PASS [5] released text has no 张伟/李秀梅/王强 and no 星辰科技 — 227 chars; offenders: []
PASS [6] retract (by an approver) leaves zero trace in Ember's derived memory files — item in 2 file(s) before; after retract: 0 file(s) (of 7); non-approver retract denied: true
PASS [7] 「结束」 by the convener ends the session; non-convener refused; bot leaves the conference and exits 0 — exit 0, left: true
PASS [8] no raw speech text (or names/org) in the bot's stdout/stderr logs — 889 bytes scanned, 11 probes, leaks: 0
bot stdout events: host, session, ready, asr_final, released, ended, exit
ember-jitsi e2e: 8/8 checks passed · 2026-10-24T23:53:08.655Z
```

复现（密钥只走环境变量，脚本不打印、不落盘）：

```powershell
$env:LARES_AI_LLM_KEY='…'; $env:LARES_DASHSCOPE_API_KEY='…'
pwsh ember-jitsi/tool/run_e2e_wsl.ps1          # 可选 -Distro Ubuntu -JitsiUrl https://localhost:8443 -Image mcr.microsoft.com/playwright:v1.64.1-noble
```

**单测（`node --test ember-jitsi/`，31 个，全过）**：命令解析（@ 形式、私信免 @、信封只收私信）；port 形状与事件映射（隐藏参与者排除、音频只转发在场者、公开 / 私信分流、发送失败只记日志）；CLI（参数校验、作用域哈希、`asr_final` 不带文字、退出码 0/1/2、stdin stop、`EMBER_JITSI_ASR`）；FakeBridge 端到端（mock ASR、无 LLM），包括 ack 门、k-of-n、撤回零残留、召集人散会、自持密钥信封计入 k 且托管批准对其被拒、坏签名、断线退出 1、最后一人离开退出 0、日志无名字和原话。

**如实的缺口**

- **WSL2 网络**：Windows 侧的 Chromium 连 WSL2 里的 JVB（mirrored 网络），信令和聊天正常，但 ICE 一直卡在 checking，媒体不通，UDP 回包被丢。所以 e2e 改为在 WSL 主机网络上的官方 Playwright Docker 容器里跑（`tool/run_e2e_wsl.ps1`：`docker run --network host`）。`node ember-jitsi/tool/media_probe.mjs [speech.wav]` 起两个 Chromium 进同一房间，打印双方 `ice=` 状态、inbound/outbound RTP 字节数和接收端响帧数，用来诊断这类问题。
- **没测过**：
  - meet.jit.si 公共服务器（现在要求登录 / JWT，bot 匿名进不去）。
  - 开了认证（JWT / secure domain）的部署、lobby、房间密码、媒体 E2EE。
  - 大房间与 lastN（JVB 只转发部分人音频时，没被转发的人听不到）。
  - 断线重连（没实现，断了就退出）、长会、多人同时说话重叠。
- **身份**：显示名可冒充，k-of-n 按 endpoint 计数（见信任模型）。这是设计上的已知限制，不是没测到。
- **mock LLM 路径**（不设 LLM key）：确定性改写只去名、去单位，中性句子会原样进入草稿和放行文本，去识别化不如真 LLM 路径。
