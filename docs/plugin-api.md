# Lares 插件 API

插件让第三方往一个圈子里加功能:一个计分板、一个小游戏、一个把事件转发到别处的服务,或者第一方的「专注学习」。
跨端格式以 [`docs/plans/plugin-focus-contract.md`](plans/plugin-focus-contract.md) 为准,本文是给插件开发者和圈主看的使用手册。REST / SSE 的通用约定(token 头、错误格式、限速、PowerShell 注意事项)见 [`docs/bot-api.md`](bot-api.md),这里不重复。

完整可运行的例子:[`docs/examples/plugin-hello/`](examples/plugin-hello/)。

---

## 0. 概览

**插件 = 一份 manifest。** 它按圈安装,只有圈主能装、卸、启停、改配置。一个插件可以是下面两种形态之一,也可以两者都是:

- **服务端插件**:manifest 带 `webhook`。安装后服务器签发一个插件 token(`plg_…`)和一个 webhook 密钥(`whsec_…`),之后把订阅的事件签名后 POST 到你的 URL。插件 token 能调全部 `/api/v1` 接口,用法和机器人 token 一样。
- **网页小程序**:manifest 带 `entry.url`(https)。成员在房间里打开它,App 用**沙箱 WebView** 加载这个网页,网页经 `window.lares` 桥访问受权限约束的能力(读成员、发聊天、读写共享状态……)。

第一方插件由服务器按 id 认识,不需要 URL,目前只有 `lares.focus`(§9)。`lares.` 前缀保留给第一方。

> **关于 App Store 审核指南 2.5.2**:Lares 的插件**只加载网页内容**,运行在 App 的沙箱 WebView 里,能做的事仅限 `window.lares` 桥暴露的接口;App **从不下载、加载或执行原生代码或可执行文件**,插件也无法改变 App 本身的功能或绕过系统权限。服务端插件完全运行在开发者自己的服务器上。

> **隐私提示**:插件的共享状态(§7)**存在服务器上,服务器可见**,端到端加密(E2EE)的圈子也一样。安装和首次打开插件时 App 会在同意页写明这一点。不要把需要端到端保密的内容放进共享状态。

## 1. Manifest

```json
{
  "id": "com.example.hello",
  "name": "Hello",
  "version": "1.0.0",
  "description": "一个演示插件",
  "author": "Example",
  "homepage": "https://example.com/plugin-hello/",
  "entry": { "url": "https://example.com/plugin-hello/index.html" },
  "permissions": ["circle:read", "members:read", "chat:send", "state:read", "state:write", "storage"],
  "webhook": { "url": "https://example.com/hooks/lares", "events": ["join", "leave", "plugin_state"] },
  "settingsSchema": { "type": "object" }
}
```

| 字段 | 必填 | 规则 |
|---|---|---|
| `id` | 是 | 反向域名风格,`^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?){1,7}$`,≤64 字;`lares.` 前缀保留 |
| `name` | 是 | 1..40 字。也是插件在聊天、字幕里显示的名字 |
| `version` | 是 | 1..32 字,`^[0-9A-Za-z.+-]+$` |
| `description` | 否 | 0..500 字 |
| `author` | 是 | 1..80 字 |
| `homepage` | 否 | https URL |
| `entry.url` | 否 | https URL(服务器设了 `LARES_PLUGIN_ALLOW_PRIVATE=1` 时也接受 http,仅供测试) |
| `permissions` | 是 | 已知权限(§2)的子集,去重,≤20 项 |
| `webhook.url` | 否 | https URL,受 SSRF 规则约束(§6) |
| `webhook.events` | 否 | ⊆ `transcript join leave presence chat plugin_state focus`,每个事件都要有对应权限 |
| `settingsSchema` | 否 | 任意 JSON 对象,序列化后 ≤8 KB。圈主改配置时 App 可据此出表单 |

- 整个 manifest 序列化后 ≤16 KB。
- **未知的顶层字段一律拒绝**(`bad_manifest`,`detail` 指出哪个字段),所以别往里塞自定义键。
- 也可以只给 URL(`manifestUrl`):服务器经 SSRF 守卫抓取,https、≤16 KB、5 秒超时、**不跟随重定向**。

## 2. 权限

| 权限 | 网页桥(§8) | 服务端(webhook 事件) |
|---|---|---|
| `circle:read` | `getCircle()` | — |
| `members:read` | `getMembers()` `getSelf()`,事件 `join` `leave` | `join` `leave` `presence` |
| `chat:read` | 事件 `chat` | `chat`(只有机器人 / 插件发的,服务器看不到成员聊天) |
| `chat:send` | `sendChat(text)` | — |
| `captions:read` | 事件 `caption` | — |
| `captions:send` | `sendCaption(text, {final})` | — |
| `transcript:read` | `getTranscript(page)`,事件 `transcript` | `transcript` |
| `state:read` | `getState()`,事件 `state` | `plugin_state` |
| `state:write` | `setState(patch)` —— **成员可写**共享状态 | — |
| `storage` | `storage.get/set` | — |
| `focus:read` | — | `focus` |

- webhook 订阅了某事件却没声明对应权限 → 安装时 `bad_manifest`。
- 插件 token 永远能写**本插件**的共享状态(`POST /api/v1/plugins/state`),与 `state:write` 无关;`state:write` 只决定**成员**能不能经网页桥写。
- 权限集变了(升级 manifest),App 会重新弹同意页。

## 3. 安装与管理(圈主,走信令 WS)

圈主操作都带 `{circleId, ownerKey}`(与 `bot_token_create` 相同的闸门)。失败统一回 `{t:'owner_error', op, circleId, reason, detail?}`。

| 发送 | 成功 |
|---|---|
| `{t:'plugin_install', circleId, ownerKey, pluginId}`(第一方,如 `lares.focus`) | `{t:'plugin_installed', circleId, plugin, token?, webhookSecret?}` |
| `{t:'plugin_install', circleId, ownerKey, manifest}`(粘贴 manifest 对象) | 同上 |
| `{t:'plugin_install', circleId, ownerKey, manifestUrl}`(给 URL,服务器抓) | 同上 |
| `{t:'plugin_uninstall', circleId, ownerKey, pluginId}` | `{t:'owner_ok', …}` |
| `{t:'plugin_set_enabled', circleId, ownerKey, pluginId, enabled}` | `{t:'owner_ok', …}` |
| `{t:'plugin_config_set', circleId, ownerKey, pluginId, config}` | `{t:'owner_ok', …}` |
| `{t:'plugin_list', circleId}`(**成员可读**) | `{t:'plugins', circleId, items:[PluginView]}` |
| `{t:'plugin_state_get', circleId, pluginId}`(成员) | `{t:'plugin_state', circleId, pluginId, state, rev}` |
| `{t:'plugin_state_set', circleId, pluginId, patch}`(成员) | 向全房广播 `plugin_state`(发起者也收到) |

- `token`(`plg_…`)和 `webhookSecret`(`whsec_…`)**明文只在 `plugin_installed` 里出现这一次**,只有带 webhook 的插件才有。token 另外会经签名的 `installed` webhook 交给你的服务器(§5),所以通常不需要圈主手动转交。
- 列表变化(装 / 卸 / 启停 / 改配置)时,服务器向该圈全部连接广播 `{t:'plugins', circleId, items}`。`welcome.circle` 和 `circle_settings` 里也带 `plugins:[PluginView]`。
- 卸载插件会吊销它的 token、关掉它的 SSE;解散圈子删掉全部安装。

**PluginView**(公开视图,广播给成员,**不含** webhook URL 和密钥):

```
{ id, name, version, description, author, homepage?, entry?, permissions, builtin, enabled,
  config, hasWebhook, settingsSchema?, rev }
```

**`owner_error.reason`**:

| reason | 含义 |
|---|---|
| `say_hello_first` | 还没发 `hello` |
| `not_registered` | 圈子不是 App 注册的 `c_…` 圈 |
| `not_owner` | `ownerKey` 不对 |
| `bad_request` | 消息字段缺失 / 类型不对 |
| `bad_manifest` | manifest 不合规,`detail` 说明原因(如 `unknown_field:foo`) |
| `unknown_builtin` | `pluginId` 不是已知的第一方插件 |
| `already_installed` | 本圈已装同 id 插件(先卸载再装新版) |
| `too_many` | 每圈最多 10 个插件 |
| `manifest_fetch_failed` | 抓 `manifestUrl` 失败(超时、非 2xx、过大、不是 JSON、重定向) |
| `ssrf_blocked` | URL 指向私网 / 回环等地址(§6) |
| `save_failed` | 服务器落盘失败 |
| `not_found` | 卸载 / 启停 / 改配置时本圈没装这个插件 |
| `bad_config` | `config` 不合规(非对象、>4 KB,或第一方插件校验不过) |

**`plugin_state_set` 失败**回 `{t:'plugin_error', op:'plugin_state_set', circleId, pluginId, reason}`,reason ∈ `not_in_room not_installed disabled forbidden bad_patch too_large rate_limited`(`forbidden`:manifest 没有 `state:write`,或对 `lares.focus` 写状态)。`plugin_list` / `plugin_state_get` 失败同样回 `plugin_error`,reason ∈ `say_hello_first auth_scope rate_limited not_installed`。

**大小限制**:manifest ≤16 KB,`settingsSchema` ≤8 KB,`config` ≤4 KB,单次 `patch` ≤16 KB,合并后的 `state` ≤64 KB,每圈 ≤10 个插件。

## 4. 插件 token 与 REST

带 webhook 的插件安装后得到一个插件 token:`plg_` + 43 位 base64url。用法和机器人 token(`lrb_…`)一样:

```
Authorization: Bearer plg_xxxxxxxx…
```

- 能调**全部** `/api/v1` 接口(`circle` `transcript` `events` `messages` `captions` `speak`),规则与限速同 [`bot-api.md`](bot-api.md)。
- 显示名 = manifest 的 `name`;聊天 header 里的发送者是 `sid:'plugin:<pluginId>'`(机器人是 `bot:<id>`)。
- 插件 token 不出现在 `bot_token_list` 里,也不能被 `bot_token_revoke` 删掉;吊销它的唯一办法是卸载插件。
- 插件**停用**期间,token 调任何接口 → `403 {"error":"plugin_disabled"}`;**卸载**后 → `401 unauthorized`,正在连着的 SSE 立即被关掉。

### 新增接口

| 接口 | 谁能调 | 返回 |
|---|---|---|
| `GET /api/v1/plugins` | bot 与 plugin token | `{items:[PluginView]}` |
| `GET /api/v1/plugins/state` | 仅 plugin token | `{pluginId, state, rev}` |
| `POST /api/v1/plugins/state` `{patch}` | 仅 plugin token | `200 {ok:true, rev}` |
| `GET /api/v1/focus` | bot 与 plugin token | 专注状态 + 排行榜,见 §9.5 |

用 bot token 调 `/plugins/state` → `403 {"error":"plugin_token_required"}`。`patch` 不合法 → `400 bad_patch`;合并后超过 64 KB → `413 too_large`(不落盘)。

```powershell
$B = 'https://lares.example.com'; $T = 'plg_…'
curl.exe -s -H "Authorization: Bearer $T" "$B/api/v1/plugins"
curl.exe -s -H "Authorization: Bearer $T" "$B/api/v1/plugins/state"
'{"patch":{"counter":3,"note":null}}' | curl.exe -s -X POST -H "Authorization: Bearer $T" -H "Content-Type: application/json" --data-binary '@-' "$B/api/v1/plugins/state"
curl.exe -s -H "Authorization: Bearer $T" "$B/api/v1/focus"
```

### 新增 SSE 事件(`GET /api/v1/events`)

| event | data |
|---|---|
| `plugin_state` | `{circleId, pluginId, state, rev}` 某插件的共享状态变了 |
| `plugins` | `{circleId, items:[PluginView]}` 插件列表变了 |
| `focus` | `{circleId, kind, userId?, name?, awayMs?, phase?, round?, endsAt?}` 专注事件,见 §9.4 |

## 5. Webhook

服务器向 `webhook.url` 发 `POST`,`Content-Type: application/json`:

```json
{ "id": "evt_9f2c…", "type": "join", "circleId": "c_…", "pluginId": "com.example.hello",
  "ts": 1790000000000, "data": { "circleId": "c_…", "userId": "u_…", "name": "小明", "status": "free" } }
```

`ts` 是毫秒;`data` 与同名 SSE 事件的 `data` 相同。请求头:

| 头 | 值 |
|---|---|
| `X-Lares-Event` | 事件类型,同体里的 `type` |
| `X-Lares-Delivery` | 投递 id,同体里的 `id`(重试时不变,可用来去重) |
| `X-Lares-Timestamp` | Unix **秒** |
| `X-Lares-Signature` | `v1=<hex(HMAC-SHA256(webhookSecret, "<timestamp>.<rawBody>"))>` |

### 事件

| type | 需要的权限 | data |
|---|---|---|
| `transcript` | `transcript:read` | 转写条目,同 `/transcript` 的 item |
| `join` / `leave` / `presence` | `members:read` | 同 SSE |
| `chat` | `chat:read` | 机器人 / 插件经 `/messages` 发的消息(成员聊天服务器看不到) |
| `plugin_state` | `state:read` | `{circleId, pluginId, state, rev}`(只推**本插件**的) |
| `focus` | `focus:read` | 同 SSE `focus` |

**生命周期事件**不需要订阅,一定会发:

| type | data |
|---|---|
| `installed` | `{token}` —— 插件 token,经签名 webhook 交付 |
| `enabled` | `{enabled}` 圈主启用 / 停用 |
| `config` | `{config}` 圈主改了配置 |
| `uninstalled` | `{}` 之后 token 失效 |

### 投递

- 每个安装一条**串行**队列,上限 100 条,满了丢最旧的(服务器记日志)。
- 单次超时 5 秒;任何 2xx 算成功;否则最多尝试 4 次,退避 `base·4^n`(base 默认 1000 ms → 1 s、4 s、16 s;服务器环境变量 `LARES_PLUGIN_RETRY_BASE_MS` 可调)。
- 插件停用期间不投递普通事件(生命周期事件照发)。
- 同一事件可能投递不止一次,按 `X-Lares-Delivery` 去重。

### 校验签名

1. 取**原始请求体字节**(别先 `JSON.parse` 再序列化,字节一变签名就对不上)。
2. 检查 `|now − X-Lares-Timestamp| ≤ 300` 秒,防重放。
3. 计算 `HMAC-SHA256(secret, timestamp + "." + rawBody)` 的 hex,与 `v1=` 后面的值做**常数时间比较**。

完整可运行的接收端(Node ≥18,无依赖):

```js
// webhook-receiver.mjs —— LARES_WEBHOOK_SECRET=whsec_… node webhook-receiver.mjs
import http from 'node:http';
import crypto from 'node:crypto';

const SECRET = process.env.LARES_WEBHOOK_SECRET;
const PORT = Number(process.env.PORT || 8788);
if (!SECRET) { console.error('请设置 LARES_WEBHOOK_SECRET'); process.exit(1); }

function verify(headers, raw) {
  const ts = String(headers['x-lares-timestamp'] || '');
  const sig = String(headers['x-lares-signature'] || '');
  if (!/^\d+$/.test(ts) || !sig.startsWith('v1=')) return false;
  if (Math.abs(Math.floor(Date.now() / 1000) - Number(ts)) > 300) return false;
  const expected = crypto.createHmac('sha256', SECRET)
    .update(ts + '.').update(raw).digest();          // raw 是 Buffer,原样参与计算
  const got = Buffer.from(sig.slice(3), 'hex');
  return got.length === expected.length && crypto.timingSafeEqual(got, expected);
}

http.createServer((req, res) => {
  if (req.method !== 'POST') { res.writeHead(405).end(); return; }
  const chunks = [];
  let size = 0;
  req.on('data', (c) => { size += c.length; if (size > 1 << 20) req.destroy(); else chunks.push(c); });
  req.on('end', () => {
    const raw = Buffer.concat(chunks);
    if (!verify(req.headers, raw)) { res.writeHead(401).end('bad signature'); return; }
    const evt = JSON.parse(raw.toString('utf8'));
    console.log(new Date().toISOString(), evt.type, evt.id, JSON.stringify(evt.data));
    if (evt.type === 'installed') {
      // evt.data.token 是插件 token(plg_…),存到安全的地方,用来调 /api/v1
    }
    res.writeHead(200, { 'content-type': 'text/plain' }).end('ok');
  });
}).listen(PORT, () => console.log(`listening on :${PORT}`));
```

同样的文件在 [`docs/examples/plugin-hello/webhook-receiver.mjs`](examples/plugin-hello/webhook-receiver.mjs)。处理慢的逻辑请先回 200 再异步做,超过 5 秒会被当成失败重试。

## 6. SSRF 规则

`manifestUrl`、`webhook.url` 在**安装时**和**每次投递时**都要过这层检查:

- 只允许 `https:`。
- 解析 DNS 后,任一地址落在下列范围就拒绝(`ssrf_blocked`):回环(127/8、`::1`)、私网 10/8、172.16/12、192.168/16、CGNAT 100.64/10、link-local 169.254/16 与 `fe80::/10`、ULA `fc00::/7`、0.0.0.0/8、`::`、组播、广播,以及映射到上述地址的 IPv4-mapped IPv6。
- 连接时**钉住已校验的 IP**,防 DNS rebinding;**不跟随重定向**(3xx 视为失败)。
- 本地测试:服务器设 `LARES_PLUGIN_ALLOW_PRIVATE=1` 时放开私网地址和 `http:`。**生产环境不要开。**

## 7. 共享状态

每个已装插件有一份按圈的共享状态:一个 JSON 对象 + 版本号 `rev`。

- 写入是 **JSON Merge Patch(RFC 7396)**:`patch` 的键覆盖原值;值为 `null` 删除该键;嵌套对象递归合并;数组整体替换。
  ```
  state  {"counter":1, "names":{"a":"小明"}, "tmp":true}
  patch  {"counter":2, "names":{"b":"小红"}, "tmp":null}
  结果   {"counter":2, "names":{"a":"小明","b":"小红"}}
  ```
- 每次成功写入 `rev` +1,持久化到服务器,并向全房(网页桥事件 `state`、WS `plugin_state`、SSE / webhook `plugin_state`)广播**完整**新状态。
- 合并是「后写覆盖」的,没有条件写。要做计数之类的并发敏感操作,接受偶尔丢一次更新,或者让服务端插件(插件 token)当唯一写入者。
- 限制:单次 patch ≤16 KB,合并后 ≤64 KB(超了整次拒绝,不落盘);成员经桥 / WS 写每人 5 次/秒(突发 20)。
- 谁能写:插件自己(插件 token,总是可以);在房成员(manifest 含 `state:write` 时)。`lares.focus` 的状态只由服务器写。

> ⚠️ **共享状态服务器可见。** 即使圈子开了端到端加密,共享状态也是明文存在服务器上的 —— 它不走 LiveKit 的加密通道。同理,插件网页本身由第三方服务器提供,网页能读到的东西,那台服务器也可能拿到。

## 8. 网页桥 `window.lares`

网页小程序在 App 的沙箱 WebView 里运行。App 在页面加载前注入 `window.lares`;页面在普通浏览器里打开时它**不存在**,请做兜底(例:显示「请在 Lares 里打开」)。

**所有方法都返回 Promise。** 失败时 reject 一个 `Error`,`err.code` 为下列之一:

| code | 含义 |
|---|---|
| `permission_denied` | manifest 没声明对应权限,或成员在同意页拒绝了 |
| `unknown_method` | 没有这个方法(App 版本较旧) |
| `bad_args` | 参数不合法 |
| `not_available` | 当前不可用(不在房、E2EE 圈不支持、插件已停用、平台不支持……) |
| `rate_limited` | 太快了,稍后再试 |

| 方法 / 事件 | 权限 | 说明 |
|---|---|---|
| `getCircle()` | `circle:read` | → `{id, e2ee, transcript, …}`,当前圈子 |
| `getMembers()` | `members:read` | → `[{userId, name, status}]`,在房成员 |
| `getSelf()` | `members:read` | → `{userId, name, status}`,打开插件的这个成员 |
| `on(event, cb)` | 见下 | 订阅事件,返回取消订阅函数 |
| `sendChat(text)` | `chat:send` | 以**当前成员**身份发一条聊天(1..2000 字),App 会标明来自哪个插件 |
| `sendCaption(text, {final})` | `captions:send` | 以当前成员身份发字幕;同一句先若干 partial 再 `final:true` |
| `getState()` | `state:read` | → `{state, rev}` |
| `setState(patch)` | `state:write` | JSON Merge Patch(§7),→ `{rev}`;成功后所有人(含自己)收到 `state` 事件 |
| `storage.get(key)` | `storage` | → 之前存的值或 `null`。**本机本人私有**,按圈 + 插件隔离,不上传服务器 |
| `storage.set(key, value)` | `storage` | `value` 须可 JSON 序列化;传 `null` 删除 |
| `getTranscript(page)` | `transcript:read` | `page` 可选 `{before, limit}`,返回同 `GET /api/v1/transcript`;E2EE 圈 → `not_available` |

`on(event, cb)` 的事件:

| event | 权限 | cb 收到 |
|---|---|---|
| `chat` | `chat:read` | `{id, senderId, senderName, body, ts}` 房间里的聊天(含成员的,由 App 本地转交) |
| `caption` | `captions:read` | `{id, userId, name, text, final}` 实时字幕 |
| `transcript` | `transcript:read` | 新的转写条目 |
| `join` / `leave` | `members:read` | `{userId, name, status?}` |
| `state` | `state:read` | `{state, rev}` 本插件共享状态变了 |

> 网页里的 `chat` / `caption` 事件由 App 在本机转交,E2EE 圈里也能收到(App 已解密);这与服务端插件不同 —— 服务器看不到成员聊天。成员同意页会说明这一点。

```js
if (!window.lares) {
  document.body.textContent = '请在 Lares 里打开';
} else {
  const circle = await lares.getCircle();
  const off = lares.on('state', ({ state, rev }) => render(state));
  await lares.setState({ counter: 1 });
  try { await lares.sendChat('hi'); }
  catch (e) { if (e.code === 'permission_denied') alert('没有发聊天的权限'); }
}
```

### 传输细节

实现桥的一侧可以不关心;想自己调试或在别的宿主里模拟时用得到:

- JS → App:App 注册 `JavaScriptChannel` 名为 **`LaresBridge`**,注入的 shim 调 `LaresBridge.postMessage(JSON.stringify({id, method, args}))`,`id` 为递增整数,`method` 如 `"getCircle"`、`"storage.get"`,`args` 为参数数组。
- App → JS 回执:`window.__laresResolve(id, ok, value)`。`ok === true` 时 `value` 为结果;否则 `value` 为 `{code, message?}`,shim 据此 reject。
- App → JS 事件:`window.__laresEmit(event, data)`,shim 分发给 `on(event, cb)` 注册的回调。
- 页面在 WebView 沙箱里:不能访问 App 的其它数据,不能调原生接口,外链在系统浏览器打开。没有 WebView 的平台(如部分桌面端)会改为在浏览器打开或提示「此平台不支持」,此时 `window.lares` 不存在。

## 9. 专注学习(`lares.focus`)

第一方插件。圈主用 `{t:'plugin_install', circleId, ownerKey, pluginId:'lares.focus'}` 安装,不需要 manifest。

### 9.1 配置

`plugin_config_set` 的 `config`,严格校验,缺的字段补默认值,越界 → `bad_config`:

| 字段 | 范围 | 默认 | 含义 |
|---|---|---|---|
| `focusMin` | 1..180 | 25 | 番茄钟专注时长(分钟) |
| `breakMin` | 1..60 | 5 | 休息时长(分钟) |
| `rounds` | 1..12 | 4 | 轮数 |
| `graceSec` | 0..300 | 10 | 离开多久才算「离开」(秒) |
| `membersCanStart` | bool | `false` | 普通成员能否开 / 停番茄钟 |
| `chatInBreak` | bool | `true` | 休息期解锁文字聊天 |

### 9.2 语义

- 插件**已装且启用** = 本圈处于专注模式:房间显示专注 UI,文字聊天与发图隐藏。
- 番茄钟可选。不开番茄钟时一直算专注期。番茄钟 `phase ∈ idle | focus | break`;`break` 期且 `chatInBreak` 时聊天解锁。
- **计时**:专注中 = 启用 ∧ 在房 ∧ 未离开 ∧ phase≠break;离开计时 = 启用 ∧ 在房 ∧ 离开 ∧ phase≠break。休息期离开既不计时也不广播。
- **离开**由 App 判断(切到后台、锁屏等),过了宽限期 `graceSec` 才上报。一个成员**所有在房设备都离开**才算离开。归属只看连接本身,消息里的 `userId` 被忽略 —— 没法替别人报离开。

### 9.3 WS 消息

| 发送 | 说明 |
|---|---|
| `{t:'focus_away', circleId, since}` | 宽限期过后才发;`since` = 真正离开的服务器时间(毫秒,客户端用 `pong.now` 校时)。服务器把它夹到 `[now−10min, now]`,且不早于本次进房 / 上次回来 |
| `{t:'focus_back', circleId}` | 回来了 |
| `{t:'focus_start', circleId, ownerKey?}` | 开番茄钟:圈主,或 `membersCanStart` 时任何在房成员 |
| `{t:'focus_stop', circleId, ownerKey?}` | 停番茄钟,权限同上 |
| `{t:'focus_get', circleId}` | 回一条 `focus_status` 和一条 `focus_board` |

失败:`{t:'focus_error', op, circleId, reason}`,reason ∈ `say_hello_first not_in_room disabled forbidden rate_limited bad_request`。

服务器推送(给在房连接):

```
{t:'focus_status', circleId, now, enabled, config,
 pomodoro:{phase:'idle'|'focus'|'break', endsAt:ms|null, round, rounds, startedBy?},
 members:[{userId, name, state:'focus'|'away'|'break', awaySince:ms|null, focusMs, awayMs}]}

{t:'focus_notice', circleId, kind, userId?, name?, awayMs?, phase?, round?}

{t:'focus_board', circleId, today:[Row], week:[Row], all:[Row]}     Row = {userId, name, ms}
```

- `focusMs` / `awayMs` 是本次进房以来的累计。`focus_status` 在状态变化时立即推,另外每 30 秒推一次刷新累计值。
- `focus_notice.kind`:`away`(超过宽限的离开)、`back`(回来,带 `awayMs`)、`left_early`(专注期出房)、`phase`(番茄钟换阶段,带 `phase` `round`)、`started`、`stopped`、`ended_by_owner`(圈主停用或卸载了专注)。
- `focus_board` 每榜降序,最多 50 行。
- 番茄钟状态同时写进 `lares.focus` 的共享状态 `{pomodoro:{…}}` 并广播 `plugin_state`。服务器定时推进阶段;最后一轮专注结束 → `idle` + `focus_notice{kind:'stopped'}`。
- 圈主停用 / 卸载 → 结算、番茄钟清零,广播 `focus_notice{kind:'ended_by_owner'}` 和 `focus_status{enabled:false}`,客户端退出锁定。

### 9.4 SSE / webhook 事件 `focus`

`data = {circleId, kind, userId?, name?, awayMs?, phase?, round?, endsAt?}`,`kind` 同 `focus_notice`。webhook 订阅需要 `focus:read`。

### 9.5 `GET /api/v1/focus`

```powershell
curl.exe -s -H "Authorization: Bearer $T" "$B/api/v1/focus"
```
```json
{"circleId":"c_…","installed":true,"enabled":true,
 "config":{"focusMin":25,"breakMin":5,"rounds":4,"graceSec":10,"membersCanStart":false,"chatInBreak":true},
 "now":1790000000000,
 "pomodoro":{"phase":"focus","endsAt":1790001200000,"round":1,"rounds":4,"startedBy":"u_owner"},
 "members":[{"userId":"u_…","name":"小明","state":"focus","awaySince":null,"focusMs":600000,"awayMs":0}],
 "leaderboard":{"today":[{"userId":"u_…","name":"小明","ms":3600000}],"week":[…],"all":[…]}}
```

没装时 `installed:false`、`enabled:false`。bot 和 plugin token 都能调,E2EE 圈也能调(专注数据不涉及通话内容)。

### 9.6 排行榜

- 存在服务器 `DATA_DIR/focus/<circleId>.json`:`{names, days:{'YYYY-MM-DD':{userId:ms}}, totals}`。
- **日界**按服务器环境变量 `LARES_FOCUS_TZ_OFFSET_MIN`(分钟,默认 480 = UTC+8);**周**从本地周一 00:00 起;`days` 只保留最近 60 天,`all` 用累计总量。
- 每次状态转换、每 30 秒、服务器关进程时结算并原子落盘。解散圈子删除该文件。

## 10. 服务器环境变量速查

| 变量 | 默认 | 作用 |
|---|---|---|
| `LARES_PLUGIN_ALLOW_PRIVATE` | 未设 | `1` 时 webhook / manifestUrl / entry 允许私网地址与 http(仅测试) |
| `LARES_PLUGIN_RETRY_BASE_MS` | 1000 | webhook 重试退避的 base |
| `LARES_FOCUS_TZ_OFFSET_MIN` | 480 | 专注排行榜日界的时区偏移(分钟) |
