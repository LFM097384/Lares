# 契约:插件接口 + 专注学习插件(`lares.focus`)

> 内部实现契约(2026-10)。服务端、App、文档三方以本文为准;改格式先改这里。
> 对外手册:`docs/plugin-api.md`(插件开发者)、`docs/bot-api.md`(REST/SSE)。
> 本契约**不替代** `docs/plans/plugin-protocol.md` 的长期设想(帧命名空间 / caps 协商),
> 而是它的「第二阶段 + 声明式客户端插件」的落地:服务端插件 + https 网页小程序。

## 0. 总则

- 插件 = 一份 manifest。按圈安装,只有圈主能装/卸/启停/改配置(`ownerKey` 闸门,同 `circle_transcript_set`)。
- 两种形态,可兼有:
  - **服务端插件**:manifest 带 `webhook` → 服务器签发 `plg_` token + 每次安装一个 webhook 密钥;服务器把订阅的事件 POST 过去(HMAC 签名)。
  - **网页小程序**:manifest 带 `entry.url`(https)→ 成员在房间里用沙箱 WebView 打开,经 `window.lares` 桥访问受权限约束的能力。
- **只加载网页,从不加载原生代码**(App Store 2.5.2)。
- 内置(第一方)插件按 id 由服务器认识,不需要 URL:目前只有 `lares.focus`。`lares.` 前缀保留给内置。
- 插件状态(shared state)**服务器可见**,E2EE 圈也一样 —— 同意页要写明。

## 1. Manifest

```json
{
  "id": "com.example.hello",          // ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?){1,7}$ ,≤64,`lares.` 前缀保留
  "name": "Hello",                    // 1..40 字
  "version": "1.0.0",                 // 1..32,^[0-9A-Za-z.+-]+$
  "description": "…",                 // 0..500
  "author": "…",                      // 1..80
  "homepage": "https://…",            // 可选,https
  "entry": { "url": "https://…" },    // 可选,https(LARES_PLUGIN_ALLOW_PRIVATE=1 时也接受 http)
  "permissions": ["circle:read", "…"],// 已知权限子集,去重,≤20
  "webhook": { "url": "https://…", "events": ["join", "leave"] }, // 可选
  "settingsSchema": { … }             // 可选,任意 JSON 对象,序列化 ≤8 KB
}
```
- 整个 manifest 序列化 ≤16 KB;未知顶层字段 → 拒绝(`bad_manifest`,`detail` 指出字段)。
- `manifestUrl`:https,经 SSRF 守卫抓取,≤16 KB,5 s 超时,不跟随重定向。

### 权限

| 权限 | 桥接口 / 事件 | 服务端含义 |
|---|---|---|
| `circle:read` | `getCircle()` | — |
| `members:read` | `getMembers()` `getSelf()`,事件 `join` `leave` | webhook `join` `leave` `presence` |
| `chat:read` | 事件 `chat` | webhook `chat`(仅机器人/插件发的,服务器看不到成员聊天) |
| `chat:send` | `sendChat(text)` | — |
| `captions:read` | 事件 `caption` | — |
| `captions:send` | `sendCaption(text, {final})` | — |
| `transcript:read` | `getTranscript(page)`,事件 `transcript` | webhook `transcript` |
| `state:read` | `getState()`,事件 `state` | webhook `plugin_state` |
| `state:write` | `setState(patch)` —— **成员可写**共享状态 | — |
| `storage` | `storage.get/set` | — |
| `focus:read` | — | webhook `focus` |

webhook 的 `events` ⊆ `transcript join leave presence chat plugin_state focus`,且每个事件**必须有对应权限**(上表右列),否则 `bad_manifest`。插件 token(`plg_`)永远能写**本插件**的共享状态,与 `state:write` 无关。

## 2. 安装记录与持久化

`DATA_DIR/plugins.json`:`{ circles: { [circleId]: { [pluginId]: Install } } }`
```
Install = { manifest, builtin:bool, enabled:bool, config:{}, state:{}, rev:int,
            installedAt, webhookSecretEnc?: <明文 whsec_…,仅服务器存;0600 文件>, tokenId?: "b_…" }
```
- 每圈最多 10 个插件。解散圈子 → 删全部安装与 token。
- **公开视图**(`PluginView`,广播给成员,不含 webhook URL / 密钥):
```
{ id, name, version, description, author, homepage?, entry?, permissions, builtin, enabled,
  config, hasWebhook:bool, settingsSchema?, rev }
```

## 3. WS 消息(信令)

圈主操作都带 `{circleId, ownerKey}`;失败统一 `{t:'owner_error', op, circleId, reason, detail?}`。

| 发送 | 成功回执 | reason |
|---|---|---|
| `plugin_install {circleId, ownerKey, pluginId}`(内置) / `{…, manifest}` / `{…, manifestUrl}` | `{t:'plugin_installed', circleId, plugin:PluginView, token?, webhookSecret?}`(token/密钥**只此一次**明文) | `say_hello_first not_registered not_owner bad_request bad_manifest unknown_builtin already_installed too_many manifest_fetch_failed ssrf_blocked save_failed` |
| `plugin_uninstall {circleId, ownerKey, pluginId}` | `owner_ok` | `not_found` … |
| `plugin_set_enabled {circleId, ownerKey, pluginId, enabled}` | `owner_ok` | |
| `plugin_config_set {circleId, ownerKey, pluginId, config}` | `owner_ok` | `bad_config` |
| `plugin_list {circleId}`(**成员可读**,`circleAllowed`) | `{t:'plugins', circleId, items:[PluginView]}` | `plugin_error` |
| `plugin_state_get {circleId, pluginId}` | `{t:'plugin_state', circleId, pluginId, state, rev}` | |
| `plugin_state_set {circleId, pluginId, patch}` | 广播 `plugin_state`(含发起者) | 失败 `{t:'plugin_error', op:'plugin_state_set', circleId, pluginId, reason}`:`not_in_room not_installed disabled forbidden bad_patch too_large rate_limited` |

- 列表变化(装/卸/启停/改配置)→ 向该圈全部连接(`sessionsOfCircle` + 大厅里 `circleAllowed` 的连接)广播 `{t:'plugins', circleId, items}`。
- `circleInfo()`(进 `welcome.circle` 与 `circle_settings`)加 `plugins:[PluginView]`;`circle_summary` 加 `plugins:[{id, enabled}]`(小)。
- 共享状态合并 = **JSON Merge Patch(RFC 7396)**:`null` 删键;合并后序列化 ≤64 KB,否则 `too_large` 且不落盘;`rev` 每次 +1;持久化。成员 `plugin_state_set` 需:在房(`session.circleId === circleId`)、已装且启用、manifest 含 `state:write`、`pluginId !== 'lares.focus'`(专注状态由服务器管)、限速每人 5/s 突发 20。

## 4. 插件 token 与 REST

- 扩展 `bot_tokens.js`:记录加 `kind:'bot'|'plugin'`(缺省 bot)、`pluginId?`;插件 token 前缀 `plg_`(+43 位 base64url)。`bot_token_list` 只列 `kind==='bot'`;插件 token 不能被 `bot_token_revoke` 删。卸载插件 → 吊销 token 并关它的 SSE。插件停用时 token 调任何接口 → `403 {error:'plugin_disabled'}`。
- 插件 token 可调**全部** `/api/v1`(circle / transcript / events / messages / captions / speak),显示名 = manifest.name,`sid:'plugin:<pluginId>'`(机器人仍是 `bot:<id>`)。
- 新增接口(bot 和 plugin token 都能调,除注明外):
  - `GET /api/v1/plugins` → `{items:[PluginView]}`
  - `GET /api/v1/plugins/state` → 仅插件 token,`{pluginId, state, rev}`
  - `POST /api/v1/plugins/state {patch}` → 仅插件 token,合并规则同 §3,`200 {ok, rev}`
  - `GET /api/v1/focus` → §6.5
- SSE 新事件:`plugin_state {circleId, pluginId, state, rev}`、`plugins {circleId, items}`、`focus {…}`(§6.4)。

## 5. Webhook

- 仅 https;**SSRF**:解析 DNS 后拒绝 loopback / 私网(10/8, 172.16/12, 192.168/16, 100.64/10 CGNAT)/ link-local(169.254/16, fe80::/10)/ ULA fc00::/7 / 0.0.0.0/8 / 组播 / 广播 / `::` / `::1` / IPv4-mapped 上述地址。**连接时钉住已校验的 IP**(自定义 `lookup`),防 DNS rebinding。不跟随重定向。`LARES_PLUGIN_ALLOW_PRIVATE=1` 时放开私网与 http(测试用)。安装时与每次投递时都校验。
- 请求:`POST <url>`,`content-type: application/json`,体:
```json
{ "id": "evt_<hex>", "type": "join", "circleId": "c_…", "pluginId": "com.example.hello", "ts": 1790000000000, "data": { … } }
```
- 头:`X-Lares-Event: <type>`、`X-Lares-Delivery: <id>`、`X-Lares-Timestamp: <unix 秒>`、
  `X-Lares-Signature: v1=<hex(HMAC-SHA256(webhookSecret, `${timestamp}.${rawBody}`))>`。接收方应校验 |now−ts| ≤ 300 s。
- 生命周期事件(不需订阅):`installed {token}`(**插件 token 经签名 webhook 交付**,另在安装回执里给圈主一次)、`enabled {enabled}`、`config {config}`、`uninstalled {}`。
- 投递:每个安装一条串行队列,上限 100(超了丢最旧并记日志);超时 5 s;2xx 成功;否则最多 4 次尝试,退避 `base·4^n`(base 默认 1000 ms,`LARES_PLUGIN_RETRY_BASE_MS` 可调);停用的插件不投递(lifecycle 除外)。
- `webhookSecret` 形如 `whsec_<base64url 32B>`。

## 6. 专注学习(`lares.focus`)

### 6.1 配置(`plugin_config_set` 的 `config`,严格校验,缺省补默认)
`{ focusMin:1..180=25, breakMin:1..60=5, rounds:1..12=4, graceSec:0..300=10, membersCanStart:false, chatInBreak:true }`

### 6.2 语义
- 插件**已装且启用** = 本圈处于「专注模式」:房间显示专注 UI;文字聊天与发图隐藏。
- 番茄钟 `phase ∈ idle|focus|break`。**只有 `focus` 段算专注**(2026-10 改):收聊天 / 地图 / 便签 / 小程序、计时、报离开、出房记 `left_early`。`idle`(没开钟)时房间照常、聊天开着、不计时,成员 `state = 'idle'`,卡上有醒目的「开始专注」;`break` 且 `chatInBreak` → 聊天解锁。
- 计时:成员「专注中」计时 = 启用 ∧ 在房 ∧ 未离开 ∧ phase≠break。离开(away)计时 = 启用 ∧ 在房 ∧ away ∧ phase≠break。break 期离开不计也不广播离开提示。
- 多设备:每个(userId, deviceId)连接各自报;该成员**所有在房设备都 away** 才算 away。归属**只看会话**(`session.userId/deviceId`),消息里的 userId 一概忽略 → 无法替别人报离开。

### 6.3 WS
| 发送 | 说明 |
|---|---|
| `focus_away {circleId, since}` | 客户端在宽限期(graceSec)**之后**才发;`since` = 真正离开时刻(服务器时间毫秒,客户端用 `pong.now` 校时)。服务器夹到 `[now−10min, now]`,且不早于该成员本次进房 / 上次回来 |
| `focus_back {circleId}` | 回来 |
| `focus_start {circleId, ownerKey?}` | 开番茄钟:圈主(带 ownerKey 或握手即圈主),或 `membersCanStart` 时任何在房成员 |
| `focus_stop {circleId, ownerKey?}` | 停番茄钟,权限同上 |
| `focus_get {circleId}` | 回 `focus_status` + `focus_board` |

失败:`{t:'focus_error', op, circleId, reason}`(`not_in_room disabled forbidden rate_limited bad_request`)。

服务器推送(给该圈 `sessionsOfCircle`):
```
{t:'focus_status', circleId, now, enabled, config,
 pomodoro:{phase:'idle'|'focus'|'break', endsAt:ms|null, round:int, rounds:int, startedBy?:userId},
 members:[{userId, name, state:'focus'|'away'|'break'|'idle', awaySince:ms|null, focusMs, awayMs}]}   // focusMs/awayMs = 本次(进房以来)累计
{t:'focus_notice', circleId, kind, userId?, name?, awayMs?, phase?, round?}
   kind: 'away'(超过宽限的离开开始)| 'back'(回来,带 awayMs)| 'left_early'(专注期出房)
       | 'phase'(番茄钟换阶段)| 'started' | 'stopped' | 'ended_by_owner'(圈主停用/卸载专注)
{t:'focus_board', circleId, today:[Row], week:[Row], all:[Row]}   Row={userId,name,ms},降序,≤50
```
- 番茄钟状态同时写入 `lares.focus` 的共享插件状态 `{pomodoro:{…}}` 并广播 `plugin_state`(rev 递增),服务器定时推进阶段;最后一轮专注结束 → idle,`focus_notice{kind:'stopped'}`。
- 圈主停用/卸载 `lares.focus` → 结算、番茄钟清零、广播 `focus_notice{kind:'ended_by_owner'}` + `focus_status{enabled:false}`;客户端退出锁定。
- `status` 推送节流:状态变化即推;另每 30 s 推一次以刷新累计值。

### 6.4 SSE / webhook 事件 `focus`
`data = {circleId, kind, userId?, name?, awayMs?, phase?, round?, endsAt?}`,kind 同 `focus_notice`。

### 6.5 `GET /api/v1/focus`
```
200 {circleId, installed, enabled, config, now, pomodoro, members:[…同 focus_status…],
     leaderboard:{today:[Row], week:[Row], all:[Row]}}
```

### 6.6 排行榜持久化
`DATA_DIR/focus/<circleId>.json`:`{names:{uid:name}, days:{'YYYY-MM-DD':{uid:ms}}, totals:{uid:ms}}`。
日界按 `LARES_FOCUS_TZ_OFFSET_MIN`(默认 480 = UTC+8);周 = 本地周一 00:00 起;`days` 只保留 60 天。
累计在每次状态转换、每 30 s、关进程(SIGTERM/SIGINT)时结算落盘(原子写)。解散圈子删文件。

## 7. App 侧(Dart)

- `lib/src/plugins/`:`plugin_models.dart`(Manifest / PluginView / 权限常量)、`plugin_service.dart`(ChangeNotifier,吃信令消息,发 install/uninstall/…/state_set)、`plugin_bridge.dart`(纯 Dart 派发器 + 注入 JS shim)、`plugin_consent.dart`(同意页 + 按圈按插件记住选择,权限集变了重新问)、`plugin_panel.dart`(WebView 面板;无 WebView 的平台 → 用浏览器打开或「此平台不支持」)、`plugin_owner_section.dart`(圈主设置:列表 / 从 URL 或粘贴 manifest 安装 / 启停 / 卸载 / 专注配置)。
- 桥协议:JS → Dart 经 `JavaScriptChannel('LaresBridge')` 发 `{"id":n,"method":"getCircle","args":[…]}`;Dart → JS 用 `window.__laresResolve(id, ok, value)` 与 `window.__laresEmit(event, data)`。错误码:`permission_denied unknown_method bad_args not_available rate_limited`。
- `lib/src/focus/`:`focus_service.dart`(生命周期上报 + 宽限期,时钟可注入;状态模型;番茄钟倒计时)、专注 UI(计时条、座位徽标「专注中 / 离开 2:13」、排行榜 sheet、「锁定专注」)、`focus_lock.dart`(MethodChannel `lares/focus_lock`:Android `startLockTask/stopLockTask/isLocked`;iOS `lares/family_controls` 存根,默认关闭)。

## 8. 实现偏差记录(服务端实现时补记)

- `plugin_list` / `plugin_state_get` 失败也回 `plugin_error {op, circleId, pluginId?, reason}`,reason:`say_hello_first auth_scope rate_limited not_installed`(§3 表格原未列出)。
- `focus_error` 另有 `say_hello_first`(没发 hello);`focus_get` 对无权进该圈的连接回 `forbidden`。
- `owner_error` 对 `bad_manifest` 可带 `detail`(如 `unknown_field:foo`、`id_reserved`);圈主操作有每连接限速,超了回 `rate_limited`。
- `webhookSecretEnc` 字段名沿用,但如 §2 注明存的是明文 `whsec_…`(plugins.json 0600),未做加密。
- 插件 token 调 `GET /api/v1/circle` 时 `bot` 对象额外带 `pluginId`。
- 计时引擎任何结算前先推进到期的番茄钟阶段(防止 tick 迟到把休息记成专注);`pong` 早已带 `now`,未改。
