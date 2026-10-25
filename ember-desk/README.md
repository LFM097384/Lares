# ember-desk · 炉灵桌面端（Windows 托盘）

炉灵（Ember）的 Windows 桌面端：一个本机守护进程，外加托盘、CLI、MCP、`ember://` 协议四种入口。会议本体在 `../ember/`，各平台插件在 `../ember-jitsi/`、`../ember-zoom/`、`../ember-lares/`。本包**不改 Ember 的去名语义**，只负责按需拉起、监管、停止会议插件，外加几条个人面的输入 / 输出频道。

## 是什么

- **守护进程**（`daemon.mjs`）：只听 `127.0.0.1` 随机端口，带 bearer token 的 HTTP API。单实例。
- **会议**：粘贴一个会议链接，守护进程识别平台，把炉灵送进会。Jitsi 链接直接拉起 `ember-jitsi` 子进程；Zoom、Lares 链接返回中文说明（原因见「会议适配器」）。一次只有一个会议。
- **频道**：输入（提问、口述笔记）、输出（消息流、Windows 通知、朗读、会议聊天）、会议（Jitsi / Zoom / Lares），共 9 个，都在 `channels/` 下，一个文件一个。
- **个人面与会议面分开**：提问的回答、口述笔记只留在本机（消息流、`notes/`），**绝不送进任何会议**。会议里说什么、放行什么，仍完全由会议插件和 Ember 决定。

## 架构

```
  tray.ps1（WinForms 托盘）   cli.mjs   mcp.mjs（stdio MCP）   ember://…（protocol.mjs）
        │                       │          │                       │
        └──────── HTTP 127.0.0.1:<随机端口> + Authorization: Bearer <token> ────────┘
                                   ▼
  daemon.mjs ── api.mjs（Host 校验 / token / 64 KB / SSE /events）── ui.mjs（/ui 静态页）
      │
      ├── registry.mjs ── channels/*.mjs
      │      input:   ask（提问） mic（口述笔记，个人面，只在本机）
      │      output:  feed（feed.jsonl） toast（Windows 通知） tts（朗读） meeting-chat（只报状态）
      │      meeting: meeting-jitsi  meeting-zoom（托管 ember-zoom 服务器）  meeting-lares（说明桩）
      │
      └── session.mjs  MeetingSessionManager（一次一个会话）
             join → links.mjs 解析 → meeting-<adapter>.prepareJoin() → {command,args,env}
             ▼
          子进程 node ember-jitsi/index.mjs --room R --url U --asr … [--k n] [--convener-name X]
             stdout 一行一个 JSON 元数据事件（ready / released / error / exit …）
             离会：stdin 写 {"cmd":"stop"}，15 s 不退再强杀
```

会话状态：`joining` →（插件发 `ready`）→ `in-meeting` →（exit 0）→ `ended`；exit≠0 或 `ready` 之前退出 → `failed`；之后守护进程回到 `idle`，结果留在 `lastSession`。

## 目录

```
ember-desk/
├── daemon.mjs              守护进程：单实例锁、配置 / token / 机密、频道、HTTP API、state.json
├── api.mjs                 HTTP 服务器（鉴权、Host 校验、体积上限、SSE）
├── ui.mjs                  /ui 状态页 HTML（不含数据，token 从 #hash 读）
├── session.mjs             MeetingSessionManager：链接 → 插件子进程，监管与停止
├── links.mjs               会议链接解析与路由（Jitsi / Zoom / Lares）
├── registry.mjs            频道注册表与接口校验
├── config.mjs              config.json、token、机密（env 优先，否则 DPAPI）
├── paths.mjs               状态目录与仓库内路径
├── ps.mjs                  隐藏运行 PowerShell，用户文字经 env base64 传入
├── client.mjs              客户端共用：读 state / token、api()、ensureDaemon()
├── cli.mjs                 命令行
├── mcp.mjs                 MCP stdio 服务器（手写 JSON-RPC 2.0）
├── protocol.mjs            ember:// 处理器
├── channels/               9 个频道（见「频道」）
├── tray.ps1                托盘程序（pwsh 7，WinForms NotifyIcon）
├── start.cmd / start.vbs   无窗口启动托盘
├── setup-secrets.ps1       保存机密（DPAPI）
├── read-secrets.ps1        守护进程解密机密时调用
├── install-protocol.ps1    注册 ember://（HKCU）
├── uninstall-protocol.ps1  注销 ember://
├── make-icon.ps1 / ember.ico  托盘图标
├── tool/observe_join.mjs   真 Jitsi 进会观察脚本（手动集成检查）
└── test/                   node --test ember-desk/（index.js 只是让目录参数能跑）
```

## 安装

前提：

- Windows 10/11，Node ≥ 22（`package.json` engines），PowerShell 7（`pwsh`，托盘和 `.ps1` 都 `#Requires -Version 7`）。Windows PowerShell 5.1（`powershell.exe`）用于通知和朗读（WinRT / System.Speech）。
- Jitsi 会议需要 Playwright Chromium：`npx playwright install chromium`（查找顺序同 `ember-jitsi`，可设 `EMBER_PLAYWRIGHT_DIR`）。
- 口述笔记需要 `ffmpeg` 在 PATH 上（可选；没有则 `mic` 频道显示未配置）。
- 无 npm 依赖。`ws` / playwright 经 `../ember-jitsi/deps.mjs` 解析。

### 机密

```powershell
pwsh ember-desk/setup-secrets.ps1                        # 逐项提示输入（密钥不回显，回车保留旧值）
pwsh ember-desk/setup-secrets.ps1 -FromEnv               # 不提示，取当前环境变量里非空的项
pwsh ember-desk/setup-secrets.ps1 -DashscopeCsv <路径>   # 从 CSV 的 apiKey 行取 LARES_DASHSCOPE_API_KEY
pwsh ember-desk/setup-secrets.ps1 -Clear                 # 删除密钥文件
```

写入 `<状态目录>\secrets.dpapi.json`，每个值是 `ConvertFrom-SecureString` 输出，即 **DPAPI（当前用户）** 加密，换用户、换机器解不开；文件 ACL 收紧到当前用户。可存的项：`LARES_AI_LLM_KEY`、`LARES_AI_LLM_BASE_URL`、`LARES_AI_LLM_MODEL`、`LARES_DASHSCOPE_API_KEY`、`ZOOM_CLIENT_ID`、`ZOOM_CLIENT_SECRET`、`ZOOM_WEBHOOK_SECRET`。守护进程启动时经 `read-secrets.ps1` 解密；**同名环境变量优先**。

### 启动

| 方式 | 说明 |
|---|---|
| 双击 `start.cmd` / `start.vbs` | 无窗口运行 `pwsh -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File tray.ps1`；托盘发现守护进程没在跑就隐藏拉起 `node daemon.mjs` |
| `pwsh ember-desk/tray.ps1 [-NoDaemon]` | 直接起托盘；`-NoDaemon` 不自动拉起守护进程 |
| `pwsh ember-desk/tray.ps1 -SelfTest` | 构建图标和完整菜单，打印 JSON 摘要（`ok` / `menuItems` / `daemon` / `tooltip` / `autostart`），退出 0 |
| `node ember-desk/daemon.mjs` | 只起守护进程。stdout 打印 `{ev:"listening",port,pid}`；已有实例时 `{ev:"already_running",port}`、退出码 3 |

托盘单实例（mutex `Local\EmberDeskTray`）。菜单：状态行（`炉灵 · 空闲` 等）/ 加入会议… / 加入剪贴板中的链接（剪贴板是 https 链接时）/ 离开会议 / 频道 / 最近消息 / 打开状态页 / 开机自启 / 退出。守护进程不在时状态行为「炉灵 · 未运行」，多一项「启动」。`meeting_joined` / `meeting_ended` / `meeting_failed` / `released` 四类消息弹托盘气泡。

**开机自启**：托盘菜单「开机自启」勾选即写 `HKCU:\Software\Microsoft\Windows\CurrentVersion\Run` 的值 `EmberDesk` = `wscript.exe "<目录>\start.vbs"`，取消勾选即删除。

### ember:// 协议

```powershell
pwsh ember-desk/install-protocol.ps1 [-Print]   # -Print 只打印将写入的内容，不改注册表
pwsh ember-desk/uninstall-protocol.ps1          # 删除 HKCU\Software\Classes\ember 整个键
```

注册到 `HKCU\Software\Classes\ember`（幂等，不需要管理员），`shell\open\command` 默认值恰好是：

```
"<node.exe 绝对路径>" "<目录>\ember-desk\protocol.mjs" "%1"
```

路径含双引号时拒绝注册。

## 配置

状态目录：`$EMBER_DESK_HOME`，未设则 `%APPDATA%\ember-desk\`。

| 文件 | 内容 |
|---|---|
| `config.json` | 非机密设置，首次启动写默认值（见下表） |
| `token` | 64 位 hex bearer token，守护进程首次启动生成，ACL 只给当前用户（`icacls /inheritance:r /grant:r`，尽力而为） |
| `state.json` | 运行中守护进程的 `{pid, port, startedAt, version}`，正常退出时删除 |
| `daemon.lock` | 单实例锁（内容是 pid）；pid 已死且端口不答 = 陈旧，自动接管 |
| `secrets.dpapi.json` | `setup-secrets.ps1` 写的 DPAPI 机密 |
| `feed.jsonl` | 消息流，保留最近 500 条 |
| `notes/YYYY-MM-DD.md` | 口述笔记（个人面） |
| `daemon.log` | 守护进程日志，只记元数据 |

| `config.json` 键 | 缺省 | 说明 |
|---|---|---|
| `jitsiHosts` | `["localhost:8443"]` | 直接认作 Jitsi 的 `host[:port]`（小写）；不在表里的主机会被探测 |
| `defaultK` | `null` | 放行门槛 1..20，传给插件 `--k`；`null` = 插件自动 |
| `convenerName` | `null` | 传给插件 `--convener-name`，最长 64 |
| `enabledChannels` | `["feed","toast"]` | 启动时自动开的频道；托盘 / API 启停频道时会改写它 |
| `asr` | `"dashscope"` | `dashscope` / `mock` / `none`，传给插件 `--asr`；没有 DashScope key 时自动降为 `none` |
| `micDevice` | `null` | dshow 麦克风名；`null` = ffmpeg 列出的第一个音频设备 |
| `zoomPort` | `8790` | 可选；托管 ember-zoom 服务器时作为其 `PORT` |

| 环境变量 | 说明 |
|---|---|
| `EMBER_DESK_HOME` | 状态目录（测试用临时目录） |
| `LARES_AI_LLM_KEY`（或 `LARES_AI_LLM_API_KEY`）/ `LARES_AI_LLM_BASE_URL` / `LARES_AI_LLM_MODEL` | 提问用 LLM，也注入插件；缺省 `https://api.deepseek.com`、`deepseek-flash`；无 key → mock 回答 |
| `LARES_DASHSCOPE_API_KEY`，可选 `LARES_DASHSCOPE_HOST` | 朗读（DashScope TTS）、口述笔记 ASR，也注入插件 |
| `ZOOM_CLIENT_ID` / `ZOOM_CLIENT_SECRET` / `ZOOM_WEBHOOK_SECRET` | 三个都有时 `meeting-zoom` 才算已配置 |
| `EMBER_PLAYWRIGHT_DIR` | playwright 包目录（`meeting-jitsi` 的就绪检查用） |
| `EMBER_DESK_JITSI_ENTRY` | 换 Jitsi 插件入口（同时跳过 playwright 检查；测试用） |
| `EMBER_DESK_JITSI_ARGS` | JSON 字符串数组，追加到插件参数后，如 `["--asr","mock","--memory-dir","D:/tmp/m"]` |

机密只注入会议插件子进程的 env，不写日志、不进消息流。

## 频道

| id | 类别 | 作用 | 何时算已配置 | 降级 / 备注 |
|---|---|---|---|---|
| `ask` | input | 提问（托盘 / CLI / MCP / 状态页），回答进消息流（kind `answer`） | 总是 | 无 LLM key → 确定性 mock 回答（`llm:false`）；总在运行 |
| `mic` | input | 口述笔记：ffmpeg dshow 取 16 kHz 单声道 → DashScope 实时 ASR → 每句追加到 `notes/日期.md`，进消息流（kind `note`，不广播到通知 / 朗读） | 有 ffmpeg **且**有 DashScope key | 找不到麦克风 → 启动报错；日志只记字数。**个人面，只在本机，不进会议** |
| `feed` | output | 本地消息流 `feed.jsonl`，托盘「最近消息」与状态页读它 | 总是 | 停了也照记会议事件 |
| `toast` | output | Windows 通知 | 仅 Windows | 顺序：BurntToast（已装时）→ WinRT（powershell.exe）→ 只留消息流（托盘气泡兜底）。限流：间隔 ≥ 3 s、每分钟 ≤ 10 条 |
| `tts` | output | 朗读 | Windows 或有 DashScope key | 有 key 用 DashScope TTS，失败退回 SAPI；串行不叠音；缺省关闭，但 `/speak` 不论开没开都能用 |
| `meeting-chat` | output | 只报告当前会议状态 | 总是 | **不往会议聊天发任何文字**：插件 stdin 只认 `{"cmd":"stop"}`；`send()` 返回 unsupported |
| `meeting-jitsi` | meeting | 按链接拉起 `ember-jitsi` 子进程 | `ember-jitsi/index.mjs` 存在且 playwright 可解析 | 不能单独 start，按链接加入 |
| `meeting-zoom` | meeting | 托管 `ember-zoom/index.mjs`（webhook + Zoom App 侧边栏服务器），stdin stop | 入口存在且三个 `ZOOM_*` 都有 | 可单独 start / stop；按链接加入一律拒绝（见下） |
| `meeting-lares` | meeting | 说明桩 | 永远 false | 由 Lares 服务器按圈拉起，桌面端不启动 |

## 调用方式

### HTTP API

`127.0.0.1:<port>`，端口在 `state.json`，token 在 `token` 文件。除 `/ui` 外都要 `Authorization: Bearer <token>`，否则 401 `{error:"unauthorized"}`。错误体 `{error, message}`，`message` 是中文。

| 端点 | 说明 |
|---|---|
| `GET /status` | `{ok, name:"炉灵", pid, version, state, session, lastSession, channels}`；`state` ∈ `idle` / `joining` / `in-meeting` / `leaving` |
| `POST /join {link, k?, convenerName?}` | 200 SessionInfo；400 链接不合法 / 平台不支持（中文说明）；409 已在会中 |
| `POST /leave` | `{ok, session}`；给插件写 stdin stop，超时强杀 |
| `GET /channels` | 频道状态数组 `{id, kind, name, configured, running, enabled, detail, extra?}` |
| `POST /channels/:id/start` · `/stop` | 启停频道，并改写 `enabledChannels` |
| `POST /ask {text}` | `{answer, llm}` |
| `POST /speak {text}` | `{ok, engine}`，`engine` 为 `dashscope` / `sapi` |
| `GET /feed?n=20` | 最近 n 条（1..500），最新在后，`{at, kind, title, text}` |
| `GET /events` | SSE：`status` / `session` / `feed` / `channel`，15 s 心跳 |
| `POST /quit` | 先回 200，再停会话子进程和频道后退出 |
| `GET /ui` | 静态状态页，**不鉴权、不含数据**；用 `/ui#<token>` 打开，页面从 hash 读 token 调 API |

SessionInfo：`{id, adapter, link, room, state, startedAt, endedAt, exitCode, error, events, released}`，`events` 是见过的插件事件名，`released` 是放行纪要条数。

### CLI

```powershell
node ember-desk/cli.mjs status
node ember-desk/cli.mjs join https://localhost:8443/weekly-sync --k 2 --convener-name 张伟
node ember-desk/cli.mjs leave
node ember-desk/cli.mjs ask 今天下午几点开会
node ember-desk/cli.mjs speak 你好
node ember-desk/cli.mjs channels
node ember-desk/cli.mjs start tts      # / stop <id>
node ember-desk/cli.mjs quit
```

加 `--json` 输出原始 JSON。`join` / `ask` / `speak` / `start` 会自动拉起守护进程；`status` 等只报告「炉灵没有在运行」。

| 退出码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 错误，或守护进程没在运行 |
| 2 | 用法错误 |
| 4 | 忙（409，已在会中） |

### MCP

`mcp.mjs` 是 stdio MCP 服务器（协议缺省 `2025-06-18`），第一次 `tools/call` 时自动拉起守护进程。

| 工具 | 参数 |
|---|---|
| `ember_status` | 无 |
| `ember_join_meeting` | `link`（必需），`k`（1..20），`convener_name` |
| `ember_leave_meeting` | 无 |
| `ember_ask` | `text` |
| `ember_speak` | `text` |
| `ember_channels` | 无 |

客户端配置：

```json
{"mcpServers":{"ember-desk":{"command":"node","args":["D:/Projects/Lares/ember-desk/mcp.mjs"]}}}
```

### ember://

| 形式 | 作用 |
|---|---|
| `ember://join?link=<URL 编码的 https 会议链接>` | 拉起守护进程并进会 |
| `ember://leave` | 离会 |
| `ember://status` | 用通知显示状态 |
| `ember://open` | 用 explorer 打开 `http://127.0.0.1:<port>/ui#<token>` |

结果用 Windows 通知显示。校验是严格白名单：只认上面 4 个动作和 `link` 参数；未知动作 / 未知参数 / 重复参数、带用户名 / 端口 / `#` / 路径、含引号 / 反引号 / `<>` / `\` / `^` / `|` / 空白 / 控制字符 / `%00`（解码前后都查）一律拒绝，退出码 2；`link` 还要过链接检查（只收 https、不带凭据）。操作失败退出码 1。

## 会议适配器

`links.mjs` 只收 `https:` 链接，拒绝 URL 内凭据、控制字符、超过 2048 字符。按顺序判断：

| 平台 | 识别 | 结果 |
|---|---|---|
| Zoom | 主机是 `zoom.us` / `*.zoom.us` / `zoom.com` / `*.zoom.com`，路径 `/j/<9-12 位>`、`/wc/<号>`、`/wc/join/<号>`、`/s/<号>` | **拒绝**（`zoom_needs_rtms`）：炉灵经 Zoom RTMS 接入，要先在 Zoom Marketplace 配好 RTMS App（webhook 指向本机服务器的 HTTPS 隧道），再由主持人开启 RTMS，或参会者在 Zoom App 侧边栏邀请。三个 `ZOOM_*` 机密都有时，`meeting-zoom` 频道可在本机托管 ember-zoom 服务器 |
| Lares | 主机名含 `lares`，或路径以 `/circle/` 开头 | **拒绝**（`lares_server_spawned`）：由 Lares 服务器（`server/src/anonym_supervisor.js`）按圈拉起，请在 Lares 应用里由圈主开启 |
| Jitsi | `host[:port]` 在 `jitsiHosts` 里；否则探测 `GET /config.js`，再试 `/libs/lib-jitsi-meet.min.js`，返回 200 即认作 Jitsi（4 s 超时，只有 localhost / 127.0.0.1 接受自签证书） | 房间名取路径第一段，须匹配 `[A-Za-z0-9_.-]{1,64}`，转小写；拉起 `ember-jitsi` |
| 其它 | 不在表里也探测不到 | 400 `unknown_host`，提示在 `jitsiHosts` 里加上它 |

Jitsi 服务器的要求（匿名进会、不开 lobby、JVB 地址可达等）见 `../ember-jitsi/README.md`。

## 如何新增频道

在 `channels/` 放一个 `.mjs`，`export default (ctx) => channel`（可以 async），守护进程启动时按文件名顺序加载。接口（`registry.mjs` 校验）：

```
{ id, kind: 'input'|'output'|'meeting', name, describe(), configured(), start(), stop(), send?(msg), status() }
```

- `id` 匹配 `[a-z][a-z0-9-]{0,31}`，不得重复；`status()` 返回 `{running, detail, extra?}`。
- 输出频道的 `send({title, text, kind})` 在运行时收到广播（目前守护进程只广播给 `toast`、`tts`）。
- `ctx` 字段：`config()`（当前 config）、`secrets`、`env`、`stateDir`、`log(msg)`（只记元数据）、`emit(item, {outputs})`（写一条消息流）、`session()`（MeetingSessionManager）、`changed(ch)`（推 SSE `channel`）、`overrides`（测试注入）。
- 会议频道 id 必须是 `meeting-<adapter>`，并实现 `prepareJoin(parsed, {k, convenerName})`：返回 `{command, args, env, cwd?}` 交给会话管理器拉起，或抛带 `status` / `code` 的 Error（中文 message 原样返回给用户）。子进程须遵守插件约定：stdout 一行一个 JSON（`ready` / `released{items}` / `error` …），stdin `{"cmd":"stop"}` 优雅退出，exit 0 = 正常。新平台还要在 `links.mjs` 里加识别。

最小例子 `channels/output-log.mjs`：

```js
export default function outputLog(ctx) {
  let running = false;
  let n = 0;
  return {
    id: 'log', kind: 'output', name: '计数',
    describe: () => '只数一数收到几条消息',
    configured: () => true,
    async start() { running = true; },
    async stop() { running = false; },
    status: () => ({ running, detail: `已收 ${n} 条` }),
    async send(msg) { if (!running) return false; n++; ctx.log(`log kind=${msg.kind}`); return true; },
  };
}
```

## 安全模型

- **只听 127.0.0.1**，随机端口。
- **bearer token**：32 字节随机，存在 `token` 文件，ACL 只给当前用户；比较前两边先 sha256 再 `timingSafeEqual`，长度也不泄露。
- **Host 头**必须是 `127.0.0.1:<port>` 或 `localhost:<port>`，否则 403（防 DNS rebinding）。POST 体只收 `application/json`（415），上限 64 KB（413）。响应带 `no-store` / `nosniff` / `no-referrer`。
- **`/ui`** 不鉴权但不含任何数据；token 放在 URL `#hash` 里（不随请求发送），页面用 `textContent` 写内容，CSP 只许同源连接、禁止被嵌入。
- **ember://** 严格白名单（见上）；注册表命令行把 `%1` 作为独立参数交给 node，**不经 shell 拼接**；`open` 只用 `explorer.exe` 打开固定格式的本机 URL。
- **PowerShell**：通知、朗读、机密解密的用户文字 / 路径一律经 env（`EMBER_DESK_PAYLOAD` 是 base64 的 UTF-8 JSON）或 `-File` 参数传入，不拼进命令行。
- **机密**：DPAPI（当前用户）加密，存在用户状态目录，**不在仓库里**；只注入插件子进程 env，不写日志、不进消息流、不进 API 响应（状态里只给「有没有」）。
- **日志**：`daemon.log` 只记元数据（事件种类、退出码、字数）；不记会话内容、笔记内容。
- 会议内的信任模型（显示名不是认证、托管密钥、k-of-n 按 endpoint 计数）不因桌面端改变，见 `../ember-jitsi/README.md`。

## 验证了什么 / 没验证什么

**单测（`node --test ember-desk/`，37 个，全过）**：`api`（鉴权、Host、体积、SSE）、`channels`（各频道配置判断、降级、限流）、`daemon`（单实例、陈旧锁、启动退出）、`links`（链接路由与拒绝）、`mcp`（JSON-RPC 与工具）、`protocol`（ember:// 校验、注册表命令行）、`registry`（接口校验、广播）、`session`（状态机、stdin stop、强杀，用 `test/fixtures/fake-plugin.mjs`）。

**托盘**：隐藏启动后进程在、守护进程 `/status` 有应答。`tray.ps1 -SelfTest` 返回 `ok:true`，菜单为 `炉灵 · 空闲` / `加入会议…` / `离开会议` / `频道`（9 项）/ `最近消息` / `打开状态页` / `开机自启` / `退出`。

**真 Jitsi，Windows 侧四种入口**（WSL 里的 docker-jitsi-meet，`https://localhost:8443`，观察脚本 `tool/observe_join.mjs`）：

```powershell
node ember-desk/tool/observe_join.mjs --via api|cli|mcp|protocol --end leave|chat [--url https://localhost:8443]
```

| 入口 | 结束方式 | 结果 |
|---|---|---|
| api | `/leave` | 通过 |
| cli | 聊天「@炉灵 结束」 | 通过 |
| mcp | `ember_leave_meeting` | 通过 |
| protocol | 聊天 | 通过 |

每条都确认：参会者列表里有「炉灵」、公开聊天里看到公告、守护进程回到 `idle` 且 `lastSession` 为 `ended`、exit 0。恶意 `ember://`（`%22 & calc & %22`、http 链接、file 链接、重复 `link` 参数）都被拒绝，退出码 2。

**真媒体 e2e，经桌面端会话管理器**（WSL Playwright 容器，3 个模拟真人、真 DashScope ASR、真 LLM；结果见 `test/e2e_via_desk.last.txt`）：

```powershell
pwsh ember-jitsi/tool/run_e2e_wsl.ps1 -ViaDesk    # 或 node ember-jitsi/tool/jitsi_e2e.mjs --via-desk / EMBER_E2E_VIA_DESK=1
```

9/9 通过：ember-jitsi 原有 8 项，加第 [9] 项「桌面端回到 idle，lastSession ended exit 0」。默认模式也是 8/8（更早一次 7/8，第 7 项等聊天超时，属偶发）。

```
PASS [9] ember-desk session manager returns to idle; lastSession ended with exit 0 — state idle, lastSession ended exit 0 events ["host","session","ready","asr_final","released","ended","exit"]
ember-jitsi e2e (via ember-desk): 9/9 checks passed · 2026-10-25T04:59:49.889Z
```

**干净退出**：会中执行 `cli quit`，插件子进程被优雅停止，没有残留的 node / chrome-headless-shell。托盘 `Invoke-Quit` 经测试脚手架调用过（不是真鼠标点击）。守护进程退出后托盘仍在，显示「炉灵 · 未运行」和「启动」。

**输出 / 输入**：朗读走 DashScope；提问拿到真 LLM 回答；通知经 WinRT 弹出；口述笔记的 ffmpeg dshow 采集 + DashScope ASR 能干净地启动和停止（没说话，笔记 0 条）。

**如实的缺口**

- 托盘菜单没有用真鼠标点击自动化测过。
- Windows 侧 Chromium 连 WSL 里的 JVB 时 ICE 不通，所以 Windows 侧入口的进会只验证了信令和聊天，没有媒体；真媒体只在 WSL 容器里验证。
- `meeting-chat` 只报状态：插件没有「发聊天」的 stdin 命令。
- Zoom 不能按链接加入（RTMS）；用真凭据托管 ember-zoom 服务器没测过。
- Lares 只是说明桩。
- SAPI 朗读、BurntToast 通知这两条回退路径没实际跑过。
- 口述笔记没用真实说话验证过转写。
- Windows 通知和托盘气泡可能对同一事件各弹一次。
