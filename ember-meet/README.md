# ember-meet · 炉灵以「模拟访客」身份进商业会议软件

炉灵（Ember）是一个坐在会里的 AI，规则受查塔姆规则启发（**非官方，与 Chatham House 无隶属**）：会上说的可以带出去，但不说是谁说的。本体在 `../ember/`，与平台无关（port 约定见 `../ember/PORT.md`）。本包地位同 `../ember-jitsi/`、`../ember-zoom/`，管的是**没有开放机器人接口、或者开放了但要注册应用和租户授权**的商业会议软件。

思路：**不注册机器人，不要授权**。在一个模拟环境里装一份会议软件的网页客户端（Playwright Chromium），然后像真人一样操作它：打开会议链接，点「在此浏览器上继续」，填名字「炉灵」，关摄像头和麦克风，加入，在大厅里等组织者放行。进会以后打开平台自带的**实时字幕**，并打开会议聊天。

第一个实现的平台是 **Microsoft Teams 网页版（匿名访客加入）**。Google Meet 和腾讯会议只做了链接识别和接口桩，调用会抛 `not implemented`（见「路线图」）。

## 是什么

- 炉灵是会里一个**真实、可见的参与者**，显示名「炉灵」，在 Teams 名单里标为访客。摄像头和麦克风都关着；浏览器只接假设备（`--use-fake-device-for-media-stream`），绝不打开本机真实的摄像头和麦克风。
- **文字来源是 Teams 实时字幕的 DOM**，不录音、不做 ASR。字幕自带说话人名字，所以一句话归给谁由 Teams 决定。ember-meet 轮询字幕区（默认 700 ms 一次），把逐字变长的半成品合并、去重，等到一句话定稿再按说话人送进 Ember，作为 port 的 `transcript` 事件（`port.transcripts = true`）。
- **会议聊天就是命令和输出通道**：命令语法与 ember-jitsi 相同（直接复用 `../ember-jitsi/commands.mjs`），比如 `@炉灵 同意`、`@炉灵 问 …`、`@炉灵 纪要`、`@炉灵 批准 D1`。Teams 访客**不能发私信**，而且会议聊天会**永久留在会议记录里**，所以炉灵的所有输出都发在公开聊天里，进会时会先发一条公告说明这一点。可能暴露身份的纪要条目（roleRisk）在聊天里只显示「⚠ 内容不公开」，只能泛化或删除，不能原样保留。
- 身份 = **显示名**。同一个显示名在字幕和聊天里映射到同一个 id（`mt_` + 名字哈希），所以一个人在聊天里 `@炉灵 同意` 以后，他的字幕才会进入账本；没同意的人说的话在 Ember 入口就被丢掉。批准签名由 ember-meet 按显示名托管的 Ed25519 密钥代签。**显示名不是认证**：访客可以随便起名，重名的人会被合并成一个人。

## 架构

```
  会议链接（Teams：/l/meetup-join/… 或 /meet/<号>?p=…）
      ▼
  driver.mjs  openBrowser：Playwright Chromium（有头 / 无头；可选持久 profile）+ addInitScript(page/probe.js)
      │  adapter.join(page)：启动页「在此浏览器上继续」→ 名字 → 关摄像头 / 麦克风 → 立即加入 → 大厅等放行
      │  adapter.enableCaptions：更多 → 语言和语音 → 打开实时字幕        adapter.openChat：聊天面板
      │  每 700 ms：readCaptions / readChat（page/probe.js 在页面里一次读完，返回纯数据）
      ▼
  captions.mjs  CaptionTracker：按 DOM 节点跟踪每条字幕 → 稳定 3.5 s / 被下一条顶替 1.2 s / 滚出窗口 → 定稿
      │  节点重渲染（新节点、同一说话人、同前缀）→ 继承，不重复；定稿后又变长 → 只发新增尾巴；改写 → 丢弃
  chat.mjs      ChatTracker：首读当历史不处理；自己发的、回声、无作者的丢弃
      ▼   'caption'(speaker, text)   'chat'(author, text)   'roster'   'disconnected'
  port.mjs  meetPort ── 显示名 → id；聊天 → commands.mjs → 协议消息；托管 Ed25519 代签
      │       'joined' / 'transcript'(id, text) / 'message'(id, obj) / 'left'
      ▼
  createEmber（../ember）：ack 门 → IngestGate → 假名账本 → ask / minutes / k-of-n 放行 / 记忆
      ▼
  port.send → 全部发到公开聊天（driver.sendChat 排队；Shift+Enter 换行，Enter 发送）
```

```
ember-meet/
├── index.mjs                CLI 入口：参数 / env → driver + port + createEmber；stdout JSON 元数据事件；stdin stop / SIGINT
├── urls.mjs                 会议链接识别（纯函数；ember-desk/links.mjs 也用）
├── driver.mjs               通用「模拟用户」驱动：开浏览器、入会、轮询字幕 / 聊天 / 名单、发聊天、离会
├── captions.mjs             字幕去重状态机（半成品 → 定稿，逐人）
├── chat.mjs                 聊天增量跟踪
├── port.mjs                 Ember port 实现：显示名身份、命令、公开输出、公告文字
├── page/probe.js            页面内只读探针 window.__emberMeet（字幕 / 聊天 / 名单 / 开关状态）
├── adapters/index.mjs       adapter 接口与注册表
├── adapters/teams.mjs       Microsoft Teams 网页访客
├── adapters/teams-selectors.mjs  Teams 选择器（一处维护；来源与核对情况见文件头）
├── adapters/google-meet.mjs、tencent.mjs   桩：not implemented
├── sim/make-wav.ps1         Windows SAPI 离线生成说话人 WAV（英文一句 + 中文一句）→ .data/ember-meet/speaker.wav
├── sim/speaker.mjs          模拟第二位参会者「测试用户」：假麦克风播 WAV，开麦进会
├── tool/live.mjs            真会冒烟：一条命令同时拉起炉灵和测试用户
├── tool/reachability.mjs    可达性检查：自动化浏览器能不能打开 Teams 网页（不登录）
├── env/setup-wsl.sh         WSL2 Ubuntu：Xvfb + PulseAudio + Playwright Chromium（幂等）
├── env/run-wsl.ps1          从 Windows 在 WSL 里跑（Xvfb 有头）
├── LIVE-TEST.md             真会冒烟清单
└── test/                    node --test ember-meet/（夹具 HTML + Playwright，离线）
```

### adapter 接口

每个平台一个对象（`adapters/index.mjs` 的 `checkAdapter` 会检查）：

| 成员 | 作用 |
|---|---|
| `name` / `label` / `implemented` | 标识；`implemented:false` 的平台只认链接 |
| `matches(url)` | 这个链接归不归我 |
| `join(page, {url, displayName, timeoutMs, lobbyTimeoutMs, onState, micOn})` | 走完入会流程直到真正进会；失败抛 `AdapterError`（`denied` / `ended` / `lobby_timeout` / `join_timeout`） |
| `enableCaptions(page)` | 打开实时字幕；组织者禁用时返回 `false` |
| `openChat(page)` | 打开聊天面板 |
| `readCaptions(page)` | `{present, items:[{key, speaker, text}]}`，按屏幕顺序 |
| `readChat(page)` | `{present, items:[{key, author, text, mine}]}` |
| `sendChat(page, text)` | 发一条聊天（多行） |
| `participants(page)` | 名单（拿不到就空数组） |
| `inMeeting(page)` | `'in'` / `'ended'` / `'unknown'` |
| `leave(page)` | 只点「离开」，**绝不点「结束会议」** |

加一个平台，就是新写一个这样的对象，再在 `adapters/index.mjs` 和 `urls.mjs` 里登记。驱动、字幕去重、port 都不用动。

## 运行

依赖：Node ≥ 22；Playwright 和 Chromium。仓库根没有 `node_modules`，查找顺序与 ember-jitsi 相同（见 `../ember-jitsi/deps.mjs`）：`EMBER_PLAYWRIGHT_DIR`、各包 `node_modules`、npx 缓存。可以先运行 `npx playwright install chromium`。

### 模式一：Windows 本机

```powershell
# 有头（默认；能看到浏览器，第一次建议这样跑）
node ember-meet/index.mjs --url "<Teams 会议链接>"
# 无头
node ember-meet/index.mjs --url "<Teams 会议链接>" --headless
```

参数：`--url`（必填）、`--headless` / `--headed`、`--profile <目录>` / `--no-profile`、`--k <n>`、`--convener-name <显示名>`、`--name <显示名，缺省 炉灵>`、`--lobby-timeout <秒，缺省 900>`、`--memory-dir <目录>`、`--scope <id>`。

- 持久 profile 默认放在 `.data/ember-meet/profile`（已 gitignore；**不要提交 profile 和 cookie**）。`--no-profile` 每次都用干净的浏览器。
- stdout 一行一个 JSON **元数据**事件：`state`（opening / launcher / prejoin / joining / lobby / in-meeting / captions-on / chat-open …）、`ready`、`caption_final`（只有说话人 id、字数、是否已同意，**没有原文**）、`host`、`error`、`exit`。会上说的话不会出现在 stdout 或日志里。
- 停止：在 stdin 写 `{"cmd":"stop"}`，或按 Ctrl+C。炉灵只会自己「离开」，不会结束会议。
- 退出码：0 正常（散会 / 会议结束 / 被停止），1 入会失败或掉线，2 参数错误或平台未实现。

ember-desk 里直接粘贴 Teams 链接也可以：`ember-desk/links.mjs` 能识别 `teams.microsoft.com`、`*.teams.microsoft.com` 和 `teams.live.com` 的会议链接，然后由 `channels/meeting-teams.mjs` 拉起 `ember-meet/index.mjs`，与 Jitsi 的拉起方式相同。

### 模式二：WSL2 Ubuntu（Xvfb 虚拟显示里的有头 Chromium）

```powershell
# 一次性准备（幂等：apt 装 xvfb / pulseaudio / CJK 字体，Playwright 装到 ~/.ember-meet，最后做自检）
wsl -d Ubuntu -- bash /mnt/d/Projects/Lares/ember-meet/env/setup-wsl.sh
# 运行（-Speaker 同时在 WSL 里拉起模拟说话人）
pwsh -File ember-meet/env/run-wsl.ps1 -Url "<Teams 会议链接>" [-Speaker]
```

有头浏览器在 Xvfb 里跑，比无头更不容易被网页当成自动化。profile 和记忆放在 WSL 自己的 `~/.ember-meet/`。

### 环境变量（只列名字）

| 变量 | 作用 |
|---|---|
| `LARES_AI_LLM_API_KEY`（或 `LARES_AI_LLM_KEY`）、`LARES_AI_LLM_BASE_URL`、`LARES_AI_LLM_MODEL` | LLM，**只用 DeepSeek**；不设就走确定性的无 LLM 路径 |
| `EMBER_K`、`EMBER_CONVENER_NAME`、`EMBER_SCOPE`、`EMBER_MEMORY_DIR` | 同 CLI 参数 |
| `EMBER_MEET_PROFILE`、`EMBER_MEET_HEADLESS` | profile 目录；`1` = 无头 |
| `EMBER_PLAYWRIGHT_DIR`、`EMBER_CHROMIUM_PATH` | 指定 Playwright / Chromium |
| `EMBER_DESK_MEET_ENTRY`、`EMBER_DESK_MEET_ARGS` | ember-desk 覆盖入口 / 追加参数（JSON 数组） |

### 测试

```powershell
node --test ember-meet/        # 28 个：链接识别、字幕去重、聊天跟踪、port 映射 + createEmber 端到端、夹具入会流程
```

夹具在 `test/fixtures/`：`teams-prejoin.html`（启动页 + 预加入页，支持中文界面和「不使用音视频」弹窗）、`teams-lobby.html`（`fx.admit()` / `fx.deny()`）、`teams-meeting.html`（字幕逐字变长、多人发言、节点重渲染、聊天分组、离开 / 结束会议菜单）。夹具里只保留 adapter 依赖的 `data-tid` 和文案，不含微软的任何资源。找不到 Playwright 时浏览器相关的用例会 skip。

真会冒烟见 [`LIVE-TEST.md`](LIVE-TEST.md)。

## 验证了什么（2026-11）

已验证：

- `node --test ember-meet/` 共 29 个全过（Windows 本机无头 Chromium；WSL2 Ubuntu 里 Xvfb 有头 Chromium 也跑过一遍，当时 28 个全过）。覆盖链接识别、字幕去重、聊天跟踪、port 映射、`createEmber` 端到端，以及夹具上的入会、字幕、聊天、离开。
- `env/setup-wsl.sh` 在 WSL2 Ubuntu 24.04 上跑通：Xvfb、PulseAudio、Playwright 1.64.1、Chromium 156，有头自检成功。
- **真 Teams 可达性**（`tool/reachability.mjs`，不登录）：自动化 Chromium 打开 `https://teams.microsoft.com` 能正常渲染，会跳到微软登录页，没有被识别成自动化而拦下。打开 `teams.live.com/meet/<号>` 能渲染启动页。
- **真 Teams 入会前半段**：在 teams.live.com 上用一个**不存在**的会议号，无头 Chromium 走通了启动页（`joinOnWeb`）、填显示名、关摄像头 / 麦克风（实测开关状态由 on 变 off）和点「立即加入」。Teams 随后显示「找不到此会议」，adapter 给出 `not_found`。炉灵和 sim speaker 都这样跑过。

未验证：

- 真会里的大厅、放行、实时字幕菜单、字幕 DOM、聊天面板、离开。这些都需要一个真会议，见 [`LIVE-TEST.md`](LIVE-TEST.md)。
- 中文字幕效果、长会稳定性、工作 / 学校租户的策略差异，以及 `env/run-wsl.ps1` 端到端跑真会。

## 局限

- **选择器很脆**。Teams 网页的 `data-tid` 和文案随时会改，改了就进不去或读不到字幕。所有选择器集中在 `adapters/teams-selectors.mjs`，大多取自开源项目 Vexa（Apache-2.0）。在真 Teams 上只核对了启动页和预加入页（见下文）；大厅、字幕、聊天、离开这几处都没有在真会里核对过。
- **要组织者允许实时字幕**，而且**字幕语言很关键**。Teams 按「会议口语」只识别一种语言；中英混说时，另一种语言会被识别成乱码。组织者或租户策略可以禁用字幕，禁用后炉灵只能用聊天（`ready` 事件里 `captions:false`，聊天里也会说明）。
- **必须由组织者从大厅放行**。访客默认进大厅；默认等 15 分钟，超时就退出。
- **租户策略可能挡掉访客**，也可能**关闭匿名加入**（「Anonymous users can join a meeting」= 关）。遇到这两种情况，没登录的浏览器根本进不了会，ember-meet 目前不做登录。
- **没有逐人音频**。Teams 网页只给混音，所以发言归属完全靠字幕上的名字。名字可以重复，也可以伪造；同名的人会被合并。字幕识别错的话，账本里就是错的字。
- 访客没有私信，所有输出都公开，而且会**永久**留在 Teams 会议聊天里。
- 一个 driver 一个会；崩溃不会自动重连（退出码 1，交给 ember-desk 或使用者重试）。

## 法律与伦理

- 炉灵是**看得见的参与者**：名字就叫「炉灵」，进会立刻在聊天里公告它是什么、做什么、不做什么。不要把它改名伪装成真人。
- **请事先告诉所有参会者**会上有 AI 在读实时字幕、整理匿名纪要，并说明只有聊天里说了「同意」的人，他的话才会进入账本。
- 平台条款：用自动化客户端进会可能违反 Microsoft（以及 Google、腾讯）的服务条款，平台可以随时封堵。是否使用，由使用者自己判断并承担责任；在别人组织的会上使用，要先得到组织者许可。
- 录音 / 录制同意：ember-meet 不录音，只读 Teams 已经显示给每个参会者的字幕。但很多法域（例如美国部分州的「全体同意」规定、GDPR、中国《个人信息保护法》）对**转写和处理他人发言**同样有要求。每个人都明确同意，是最低限度的做法。
- 本仓库不提交任何账号、cookie、profile 或密钥。

## 路线图

- **Google Meet**：很多会议不允许匿名访客，或者要求先登录 Google 账号，这样就要维护一个登录过的 profile，自动化账号还容易被风控。字幕 DOM 结构与 Teams 不同。先做「已登录 profile + 访客请求加入」，再接字幕。
- **腾讯会议**：网页版入会通常要求登录（微信 / 手机号），也常被引导去下载 App。可选的两条路：一是已登录的网页 profile；二是在 Windows 虚拟机或沙箱里装桌面 App，用 UI 自动化读字幕，那时 adapter 接口要换一种「page」。
- Teams：真会核对大厅、字幕和聊天的选择器；选择器失效时的自检和报警；可选登录模式（租户禁止匿名访客时使用）。
