# 用途预设(Purpose)

一个圈子是拿来闲聊、一起自习还是开会,决定了房间里该露出哪些东西。
「用途」把**功能开关 + 插件 + 少量圈设置**打成一包,圈主一键应用。
建圈时选一次,之后在圈主设置 →「功能」→「用途」里随时换。

协议细节(消息格式、错误码、原子性)见 [`plans/features-purpose-contract.md`](plans/features-purpose-contract.md);
本文讲怎么用、怎么写自己的用途。

## 1. 先说功能收纳

房间默认只有两样东西:**语音**和**文字聊天**。其余能力都收在控件排的「更多」里,
而且只有圈主为本圈打开的才会出现 —— 关掉的功能对成员完全不可见,不是灰着。

| 功能键 | 名称 | 新圈默认 | 说明 |
|---|---|---|---|
| `captions` | 实时字幕 | 开 | 语音片段送云端识别(需服务器配置) |
| `transcript` | 转写记录 | 关 | 与圈设置里的「转写记录」是同一个开关 |
| `voiceNotes` | 语音便签 | 开 | 便签音频存在服务器上 |
| `map` | 位置地图 | **关** | 位置只转发给同房成员,不落盘 |
| `recording` | 录音 | **关** | 另受客户端编译开关限制,当前版本未开放 |
| `plugins` | 插件 | 开 | 关掉后第三方插件不能装、webhook 不再投递;内置专注不受影响 |
| `focus` | 专注学习 | 关 | 即内置插件 `lares.focus` 是否已装且启用 |
| `p2p` | 点对点直连 | **关** | 关掉后服务器不转发直连信令 |
| `devTools` | 开发者读数 | **关** | 仅客户端显示 |

已经存在的老圈不受影响:没有设置过功能的圈一律视为全开。

常驻的东西不收:专注进行中的计时卡、本机正在提供字幕的提示、有人录音时的指示器、
转写记录开着时的提示条,都一直在屏幕上。

## 2. 内置用途

| 用途 | 做什么 |
|---|---|
| 💬 闲聊 `chat` | 语音 + 聊天,关字幕、转写、专注 |
| 📚 学习 `study` | 装好并启用「专注学习」(默认 25/5 分钟 × 4 轮),关字幕与便签 |
| 📝 开会 `meeting` | 开转写记录与实时字幕;提醒这类用途与端到端加密不太合拍。选它时可以顺手打开「加上 AI 助手」(默认关) |
| ✏️ 自定义 | 打开代码编辑器,自己写 |

内置用途不碰 `map / recording / p2p / devTools` —— 这几项涉及位置、录音与网络暴露,留给圈主单独决定。

「开会」里的「加上 AI 助手」开关打开时,客户端不发字符串 `"meeting"`,而是发开会的完整 JSON
再加一项 `{ "id": "lares.ai-voice", "enabled": true }`(见下面的示例)。用途 id 仍是 `meeting`、
名字仍是「开会」。AI 助手会把房间里的语音送阿里云百炼 DashScope 识别并生成回答,
端到端加密的圈子用不了(开关不可拨),详见 [`ai-voice-bot.md`](ai-voice-bot.md)。

日后的 AI 纪要机器人同理:一个带 `transcript:read` 权限的插件,在用途的 `plugins` 里加一项即可。

## 3. 用途 JSON

```json
{
  "v": 1,
  "id": "study-hall",
  "name": "自习室",
  "icon": "📚",
  "description": "一起专注,少说话",
  "features": { "focus": true, "captions": false, "voiceNotes": false },
  "plugins": [
    { "id": "lares.focus", "enabled": true, "config": { "focusMin": 50, "breakMin": 10, "rounds": 3 } }
  ],
  "settings": { "transcript": false, "knockRequired": false, "e2eeWarning": false }
}
```

| 字段 | 规则 |
|---|---|
| `v` | 可省;给了必须是 `1` |
| `id` | 必填,`^[a-z0-9][a-z0-9_-]{0,31}$` |
| `name` | 必填,1–24 个字 |
| `icon` | 可选,一个 emoji(≤ 8 个码点) |
| `description` | 可选,≤ 200 字 |
| `features` | 可选,键必须是上表的功能键,值为布尔;没写的键保持不变 |
| `plugins` | 可选,≤ 10 项。每项恰好一个来源:`id`(内置插件 `lares.focus` / `lares.ai-voice`,或本圈已装插件)、`manifest`(完整 manifest 对象)、`manifestUrl`(https 地址);另可带 `enabled`(默认 `true`)与 `config`(对象,≤ 4 KB) |
| `settings` | 可选,只认 `transcript`、`knockRequired`、`e2eeWarning`,值为布尔 |

另外几条:

- 整份 JSON ≤ 32 KB;出现未知字段直接拒绝,不静默忽略。
- 第三方 manifest 和「安装插件」走**同一套**校验:字段、权限、webhook 事件与权限匹配、地址必须是公网 https。
- 自相矛盾的写法会被拒:`features.transcript` 与 `settings.transcript` 不同;`features.focus` 与 `lares.focus` 项的 `enabled` 不同;同一个插件写两次。
- 用途里**没提到**的已装插件不动:不卸载,也不停用。
- 端到端加密不能由用途改。`e2eeWarning: true` 只是让客户端提醒「这个用途和加密不太合拍」。
- 应用是**原子**的:要么全部生效,要么什么都没变。新装的带 webhook 插件,其 token 与签名密钥只在应用成功那一刻给圈主看一次。

### 示例:开会 + AI 助手

选用途时打开「加上 AI 助手」发出去的就是这一份(内置插件写 `id` 即可,配置用默认:叫「小助手」才回答):

```json
{
  "v": 1,
  "id": "meeting",
  "name": "开会",
  "icon": "📝",
  "features": { "captions": true, "transcript": true, "voiceNotes": false, "focus": false, "plugins": true },
  "plugins": [
    { "id": "lares.ai-voice", "enabled": true }
  ],
  "settings": { "e2eeWarning": true }
}
```

想换名字或触发方式,给这一项加 `config`,例如 `{ "id": "lares.ai-voice", "config": { "name": "会议助手", "trigger": "wake" } }`。

### 示例:开会 + 自己的纪要机器人

```json
{
  "id": "standup",
  "name": "站会",
  "icon": "🧍",
  "features": { "transcript": true, "captions": true, "voiceNotes": false, "plugins": true },
  "plugins": [
    { "manifestUrl": "https://bots.example.com/minutes/lares-plugin.json", "enabled": true }
  ],
  "settings": { "e2eeWarning": true }
}
```

### 示例:安静的家庭圈

```json
{
  "id": "family",
  "name": "家里",
  "icon": "🏠",
  "features": { "captions": false, "transcript": false, "voiceNotes": true, "map": true, "focus": false }
}
```

## 4. 分享码

用途可以导出成一串分享码,别的圈主粘贴就能导入:

```
lares-purpose:H4sIAAAAAAAACj2OvUoDQRSF3-XU15AgNvcd4guIxWTmbjI4zoT5CciyYJc6pAuIFhZiYQQV4_tsZEsfQdxgyvNx_moswCOCNWCkXMzNyUw5B4JX1wJGt3xuvx72L48gWB08GD_36w0IRpKOdp5tD9vdbffx2e7W329PtH9dddv3bnsHQiUqlygJXKMKuiRwjkUIWvXZBK6US0JYBKvlPGT5Rw1h7srU_nku6sNHp6KkwaGIIF5NnJhjZfCVnR6XxtaDz4aESRR11avRkBBD8SaBT5vmsvkFBNw-xgEBAAA
```

格式:`lares-purpose:` + base64url(gzip(UTF-8 JSON)),不带 `=` 填充。上面这串就是第 3 节开头那份「自习室」(去掉了 `settings`)。

- **导出**:圈主设置 →「功能」→「导出分享码」。导出的是圈子**当前实际配置**:用途名牌、9 个功能键、所有已装插件(第三方给完整 manifest,含 webhook 地址)及启用状态与配置、圈设置。不含任何 token、密钥或插件共享状态。
- **导入**:「导入分享码」粘贴 → 预览将要改动的内容 →「应用」。也可以在代码编辑器里点「从分享码导入」,先改再应用。
- 解码后的 JSON 同样 ≤ 32 KB,解压上限 64 KB,超出即拒。

自己编码一份(Node):

```js
const zlib = require('node:zlib');
const code = 'lares-purpose:' + zlib.gzipSync(Buffer.from(JSON.stringify(purpose))).toString('base64url');
```

## 5. 代码编辑器

「自定义」打开一个等宽字体的编辑器:边写边校验,错误给出字段路径(如 `plugins[1].manifestUrl`)
和原因;JSON 语法错误给出行列。校验不过时「应用」按钮不可点。服务器还会再严格校验一遍,
以服务器的结论为准(例如抓不到 manifest、webhook 地址解析到内网)。

## 6. 成员看到什么

- 圈子列表和房间顶部会淡淡地标出当前用途(图标 + 名字)。
- 用途改动了隐私相关的配置(转写、云端字幕、插件、专注追踪、加密、录音、地图)时,
  成员下次进圈会看到一次隐私告知,见 [`privacy.md`](privacy.md)。
