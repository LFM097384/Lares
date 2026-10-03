# 契约:功能收纳 · 用途预设 · 进圈隐私告知

状态:实现中。服务端与 App 两侧以本文为准;有分歧先改本文。

## 0. 名词

- **功能(feature)**:房间里「语音 + 文字聊天」以外的可选能力。圈主按圈开关。
- **用途(purpose)**:一组功能 + 插件 + 圈设置的打包,一键应用。内置 `chat` 闲聊 / `study` 学习 / `meeting` 开会,另可自定义(JSON / 分享码)。
- **隐私告知**:进圈(加入 / 添加圈子)时弹一次的单屏摘要;隐私相关配置变了(哈希变)才再弹。

## 1. 功能键

| 键 | 含义 | 存储 | 服务端闸门 |
|---|---|---|---|
| `captions` | 实时字幕(云端 ASR) | `features.captions` | `cap_token` → `cap_error{reason:'feature_off'}` |
| `transcript` | 转写记录 | **就是**既有 `circleSettings[cid].transcript`,不另存 | 既有 `transcript_append` → `off` |
| `voiceNotes` | 语音便签 | `features.voiceNotes` | `POST /notes` → 403 `{error:'feature_off'}` |
| `map` | 位置共享 / 地图 | `features.map` | `loc` 静默丢弃,回 `{t:'error', message:'feature_off'}` |
| `recording` | 录音(另受客户端编译开关 `LARES_RECORDING`) | `features.recording` | `rec_start` 不回显(客户端因此永不开始采集),回 `{t:'rec_error', reason:'feature_off'}` |
| `plugins` | 第三方插件 | `features.plugins` | 非内置 `plugin_install` → `owner_error{reason:'feature_off'}`;webhook 扇出跳过非内置插件;客户端隐藏第三方插件入口 |
| `focus` | 专注学习 | **就是** `lares.focus` 插件「已装且启用」,不另存 | 既有(插件停用即无专注) |
| `p2p` | 点对点直连 | `features.p2p` | `p2p_signal` 丢弃,回 `{t:'error', message:'feature_off'}` |
| `devTools` | 开发者读数(进房延迟等)与 P2P 调试入口 | `features.devTools` | 仅客户端 |

语音与文字聊天永远开,不是功能键。

**默认值**
- 老圈(`circleSettings[cid].features` 不存在):存储型键全部 `true`(行为不变)。
- 新注册圈(hello 带 register 且登记成功):写入 `features = {captions:true, voiceNotes:true, plugins:true, map:false, recording:false, p2p:false, devTools:false}`。
- env 圈:同老圈,全开;env 圈没有圈主,不能改。

**下发**:`circleInfo()`(welcome.circle / circle_settings / bot_api)与 `circle_summary` 都带
`features: {captions, transcript, voiceNotes, map, recording, plugins, focus, p2p, devTools}`(9 个布尔,全量、已解析出派生值)。
`circleInfo()` 与 `circle_summary` 另带 `purpose: {id, name, icon?, builtin} | null`。
`GET /api/v1/circle` 增加 `features` 与 `purpose`。

## 2. 改功能

```
→ {t:'circle_features_set', circleId, ownerKey, features:{<键>: bool, ...}}   // 部分合并,至少一个键
← {t:'owner_ok', op:'circle_features_set', circleId}
← {t:'owner_error', op:'circle_features_set', circleId, reason}               // say_hello_first | not_registered | not_owner | bad_request | save_failed
```
- 未知键 / 非布尔 → `bad_request`。
- `transcript` 写 `circleSettings[cid].transcript`(与 `circle_transcript_set` 同一个位)。
- `focus:true` → 没装就装内置 `lares.focus`(默认配置)并启用;装了就启用。`focus:false` → 停用(不卸载,保留配置与排行)。
- 成功后:`broadcastLobbySummary` + `broadcastCircleSettings`(+ 插件变化时插件列表广播)。

## 3. 用途

### 3.1 JSON 结构

```json
{
  "v": 1,
  "id": "study-hall",
  "name": "自习室",
  "icon": "📚",
  "description": "一起专注,少说话",
  "features": { "focus": true, "captions": false },
  "plugins": [
    { "id": "lares.focus", "enabled": true, "config": { "focusMin": 50, "breakMin": 10 } },
    { "manifestUrl": "https://example.com/lares-plugin.json", "enabled": true, "config": {} },
    { "manifest": { "id": "com.example.timer", "name": "…", "version": "1.0.0", "author": "…", "permissions": [] } }
  ],
  "settings": { "transcript": false, "knockRequired": false, "e2eeWarning": false }
}
```

校验(服务端严格,客户端编辑器镜像同一套规则给即时报错):
- 整体 UTF-8 JSON ≤ 32 KB;顶层只认 `v,id,name,icon,description,features,plugins,settings`;`v` 可省,给了必须是 1。
- `id`:`^[a-z0-9][a-z0-9_-]{0,31}$`,必填。`name`:1–24 字符(按码点),必填。`icon`:≤ 8 码点的字符串(一个 emoji)。`description`:≤ 200 码点。
- `features`:对象,键 ⊆ 功能键,值布尔。可部分:没写的键不动。
- `plugins`:数组 ≤ 10 项;每项键只认 `id|manifest|manifestUrl`(恰好一个)、`enabled`(布尔,默认 true)、`config`(对象,≤ 4 KB)。
  - `id`:内置插件 id(`lares.focus`、`lares.ai-voice`),或本圈已装插件的 id(只改启用 / 配置)。
  - `manifest` / `manifestUrl`:与 `plugin_install` **同一套**校验(`validateManifest`、抓取、SSRF、webhook 地址解析)。已装同 id → 当作更新启用 / 配置,不重装、不换 token。
  - 内置插件 config 走它自己的规范化(`normalizeFocusConfig` / `normalizeAiVoiceConfig`)。
- `settings`:键 ⊆ `transcript, knockRequired, e2eeWarning`,值布尔。E2EE 不能由用途改。
- 冲突即拒:`features.transcript` 与 `settings.transcript` 不同;`features.focus` 与 `lares.focus` 项的 `enabled` 不同;同一插件出现两次。
- 用途里**没提到**的插件不动(不卸载、不停用)。
- 安装后总数仍不得超过每圈 10 个。
- 圈子 `features.plugins` 为 false 而用途要装第三方插件:用途里若同时写了 `features.plugins:true` 就放行,否则 `feature_off`。(按「应用后」的值判断:用途写了 `features.plugins:false` 又要装新的第三方插件,同样 `feature_off`;已装的第三方插件只改启用 / 配置不受此限。)

错误:`owner_error{op:'circle_purpose_apply', reason:'bad_purpose', detail:'<路径>:<原因>'}`;插件问题沿用插件的 reason(`bad_manifest` / `ssrf_blocked` / `manifest_fetch_failed` / `too_many` / `unknown_builtin`),detail 前缀 `plugins[i]`。

### 3.2 内置用途

| id | 名 | icon | features | plugins | settings |
|---|---|---|---|---|---|
| `chat` | 闲聊 | 💬 | captions:false, transcript:false, voiceNotes:true, focus:false | — | — |
| `study` | 学习 | 📚 | captions:false, transcript:false, voiceNotes:false, focus:true | `lares.focus` enabled,默认配置 | — |
| `meeting` | 开会 | 📝 | captions:true, transcript:true, voiceNotes:false, focus:false, plugins:true | —(给日后 AI 纪要机器人留位:它是一个带 `transcript:read` 的插件,用途 JSON 里加一项即可) | e2eeWarning:true |

`map / recording / p2p / devTools` 内置用途一律不碰(它们是圈主单独决定的事)。
「自定义」不是服务端预设,是客户端打开编辑器。

### 3.3 应用

```
→ {t:'circle_purpose_apply', circleId, ownerKey, purpose: 'chat'|'study'|'meeting' | {…JSON…}}
← {t:'purpose_applied', circleId, purpose:{id,name,icon?,builtin}, secrets:[{pluginId, token, webhookSecret}]}   // 只发给圈主这一条连接;新装的带 webhook 插件的凭据只出现这一次
← {t:'owner_ok', op:'circle_purpose_apply', circleId}
← {t:'owner_error', op:'circle_purpose_apply', circleId, reason, detail?}
```
原子性:先全部校验(含抓 manifest、解析 webhook 地址)→ 签 token → 在内存里改圈设置与插件表 → 两份都落盘。任一步失败:两份都回滚到快照、吊销本次签的 token,回 `owner_error`,不广播。成功后才广播(插件列表 + 摘要 + 圈设置)并投生命周期 webhook。

存储:`circleSettings[cid].purpose = {id, name, icon?, description?, builtin, e2eeWarning?}`。

### 3.4 导出

```
→ {t:'circle_purpose_export', circleId, ownerKey}
← {t:'circle_purpose', circleId, purpose:{…JSON…}}
```
导出当前实际配置:当前 purpose 的 id/name/icon/description(没有则 `id:'custom', name:'自定义'`)、9 个功能键全量、所有已装插件(内置给 `id`;第三方给完整 `manifest`,含 webhook 地址 —— 只给圈主)及其 enabled / config、`settings:{transcript, knockRequired, e2eeWarning}`。不含 token / 密钥 / 共享状态。

### 3.5 分享码

`lares-purpose:` + base64url(gzip(UTF-8 JSON)),无填充。解码后 JSON ≤ 32 KB,解压上限 64 KB(防炸弹)。服务端 `purpose.js` 与客户端各有一份编解码;两边用同一份夹具互测。

## 4. 进圈隐私告知(纯客户端)

哈希输入(规范化后 sha256,取前 16 hex):
- `transcript`(转写开 → 语音经云端识别并在服务器存档;E2EE 圈存的是密文)
- `captions` = 服务器配了字幕 且 `features.captions`(语音片段送阿里云 DashScope 识别)
- 启用的插件:每个 `{id, permissions(排序), hasWebhook}`(按 id 排序)。**不含** `lares.ai-voice`(它走下面的 `ai`)
- `ai` = 内置 AI 语音助手 `lares.ai-voice` 已装且启用(房里的语音送阿里云百炼 DashScope 识别并生成回答)。告知里单独一行,不计入「插件 N 个」;只在为 true 时写入规范结构(`"ai":true`),没开 AI 的圈哈希与旧版一致
- `focus`(专注追踪:谁在专注、离开时长)
- `e2ee`(true/false/null)
- `recording`、`map`

显示时机:本机加入 / 添加圈子后首次拿到该圈完整 circleInfo,或之后哈希变了,且本机该圈存的 ack 哈希 ≠ 当前哈希 → 弹一次。普通进房不弹。圈主本人不弹(自己定的配置),但静默记 ack。
存储:`SharedPreferences` 键 `lares.privacyAck.<circleId>` = 哈希。
