# Lares 机器人 API(`/api/v1/`)

让外部程序(脚本、智能音箱桥、AI 助手)以**机器人**的身份接入一个圈子:读成员和转写记录、订阅实时事件、发聊天、发字幕、说一段话。
跨端格式以 [`docs/plans/transcript-bot-contract.md`](plans/transcript-bot-contract.md) 为准,本文是给调用方看的使用手册。

- 实现:`server/src/bot_api.js`(路由与限速)、`bot_tokens.js`(token)、`livekit_senddata.js`(服务器代发 LiveKit 数据包)、`bot_speak.js`(WAV → 房间音频)。
- 测试:`server/test/bot_api.mjs`(假 LiveKit)、`server/tool/bot_api_e2e.mjs`(真 LiveKit + curl.exe,实测记录见同目录 `bot_api_e2e.last.txt`)。

---

## 1. 拿 token(圈主,走信令 WS)

token 只能由**圈主**在已注册的圈子(App 新建的 `c_…` 圈)里签发,消息都要带 `ownerKey`:

| 发送 | 成功 | 失败 |
|---|---|---|
| `{t:'bot_token_create', circleId, name, ownerKey}` | `{t:'bot_token', circleId, id, name, token, createdAt}` | `{t:'owner_error', op, reason}` |
| `{t:'bot_token_list', circleId, ownerKey}` | `{t:'bot_tokens', circleId, items:[{id, name, createdAt}]}` | 同上 |
| `{t:'bot_token_revoke', circleId, id, ownerKey}` | `{t:'owner_ok', op, circleId, id}` | 同上 |

- `token` 形如 `lrb_` + 43 位 base64url,**明文只在 `bot_token` 里出现这一次**;服务器的 `DATA_DIR/bot_tokens.json` 只存 sha256。丢了就吊销再建。
- `name` 1..32 字,用作聊天/字幕/转写里显示的名字。每圈最多 20 个 token。
- 吊销立即生效:之后的请求返回 401,正在连着的 SSE 被服务器立刻关掉。解散圈子(`circle_delete`)会删掉该圈全部 token。
- `reason`:`say_hello_first` `not_registered` `not_owner` `bad_request` `bad_name` `too_many` `not_found`。

## 2. 调用约定

```
Authorization: Bearer lrb_xxxxxxxx…
```

- 一个 token 只属于一个圈,所有接口作用于这个圈。可选查询参数 `?circleId=` 用来自检:与 token 的圈不符 → `403 wrong_circle`。
- 请求/响应都是 UTF-8 JSON(`/speak` 的请求体是 WAV,`/events` 是 SSE)。
- 错误统一是 `{"error": "<code>", ...}`。

| 状态 | `error` | 含义 |
|---|---|---|
| 400 | `bad_json` `bad_text` `bad_id` `bad_query` `bad_wav` | 请求不合法(`bad_wav` 附 `detail`) |
| 401 | `unauthorized` | 没带 / 错的 / 已吊销的 token |
| 403 | `wrong_circle` | `?circleId=` 与 token 的圈不符 |
| 404 | `not_found` | 没有这个接口 |
| 409 | `e2ee` | 圈子开了端到端加密,见 §5 |
| 413 | `too_large` | JSON 体 > 16 KB,或 WAV > 6 MB |
| 429 | `rate_limited` `speak_busy` | 限速;响应头 `Retry-After`(秒),体里 `retryAfterMs` |
| 501 | `speak_unavailable` | 服务器没装 `@livekit/rtc-node`,不能说话 |
| 502 | `livekit_failed` `speak_failed` | LiveKit 那边出错 |
| 503 | `rtc_not_configured` | 服务器没配 LiveKit(只影响 messages/captions/speak) |

**PowerShell 注意**:Windows PowerShell 5.1 里 `curl` 是 `Invoke-WebRequest` 的别名,下面的例子请用 **`curl.exe`**。
JSON 体在 PowerShell 里引号转义很麻烦,最省事的是用 `--data-binary '@body.json'`(或 `@-` 配合管道)。
`Invoke-RestMethod` 也可以:`irm -Method Post -Uri $u -Headers @{Authorization="Bearer $t"} -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes('{"text":"你好"}'))`
—— 中文务必像这样转成 UTF-8 字节再发,否则 5.1 会按本地代码页编码。

下文例子假设:

```bash
B=https://lares.example.com   # 你的服务器
T=lrb_xxxxxxxx                # bot token
```

## 3. 接口

### `GET /api/v1/circle`

```bash
curl.exe -H "Authorization: Bearer $T" $B/api/v1/circle
```
```json
{"id":"c_…","name":null,"e2ee":false,"transcript":true,
 "members":[{"userId":"u_…","name":"圈主","status":"free","muted":null,"speaking":null}],
 "bot":{"id":"b_…","name":"E2E 机器人"}}
```
`members` 是当前在房的人。`name` 恒为 `null`(圈名只存在客户端);`muted` / `speaking` 恒为 `null`(信令服务器不知道这两个状态)。E2EE 圈也能调,`e2ee: true`。

### `GET /api/v1/transcript?before=&limit=`

```bash
curl.exe -H "Authorization: Bearer $T" "$B/api/v1/transcript?limit=20"
```
```json
{"circleId":"c_…","transcript":true,"more":false,
 "items":[{"seq":2,"ts":1790963831800,"userId":"u_owner","name":"圈主","id":"e2e-1","text":"圈主说的一句话","startedAt":1790963830800}]}
```
新→旧;`before` = seq(不含),翻下一页传上一页最小的 seq;`limit` 1..200,默认 50。圈主关掉转写后,已有记录仍然可读;E2EE 圈 → 409。

### `GET /api/v1/events`(SSE)

```bash
curl.exe -N -H "Authorization: Bearer $T" $B/api/v1/events
```

每个事件:

```
id: 7
event: transcript
data: {"seq":2,"ts":…,"userId":"u_owner","name":"圈主","id":"e2e-1","text":"…","startedAt":…}

```

另有注释行 `: keepalive`,每 25 秒一次(环境变量 `LARES_SSE_KEEPALIVE_MS`),防止反代掐断空闲连接。`id` 每条连接内从 1 递增,**不支持 `Last-Event-ID` 续传**;断线后重连,再用 `/transcript` 补齐缺的 seq。

| event | data |
|---|---|
| `ready` | 连上后第一条:`{circleId, bot:{id,name}, e2ee, transcript, members:[{userId,name,status}]}` |
| `transcript` | 新的转写条目(同 `/transcript` 的 item),含成员 App 上传的和机器人自己的定稿字幕 |
| `transcript_cleared` | `{circleId}`,圈主清空了记录 |
| `join` | `{circleId, userId, name, status}` 有人进房 |
| `leave` | `{circleId, userId, name}` 有人离房 |
| `presence` | `{circleId, userId, name, status}` 在房成员改了状态 |
| `chat` | 本圈任意一个机器人经 `/messages` 发出的消息(header 原样,见下)。**成员在 App 里发的聊天不会出现在这里** —— 那些走 LiveKit 数据通道,服务器看不到 |

E2EE 圈:SSE 照常连着,但只会有 `ready/join/leave/presence/transcript_cleared`。

### `POST /api/v1/messages`

```bash
echo '{"text":"你好,我是机器人 👋"}' | curl.exe -X POST -H "Authorization: Bearer $T" -H "Content-Type: application/json" --data-binary @- $B/api/v1/messages
```
→ `200 {"ok":true,"id":"<uuid>","ts":1790963831781}`

`text` 1..2000 字。服务器调 LiveKit `RoomService/SendData` 把消息广播到房间(topic `lares.chat`),帧格式与 App 聊天完全相同,header 为
`{v:1, t:'text', id, sid:'bot:<botId>', sn:<机器人名>, cid, ts, body, bot:true}`。App 只在**数据包没有发送者参与者**(即服务器代发)时认 `bot:true`,参与者冒充的会被丢掉。
房里没人时消息直接丢失(不存储、不补发)。

### `POST /api/v1/captions`

```bash
echo '{"text":"今天天气","final":false}' | curl.exe -X POST -H "Authorization: Bearer $T" -H "Content-Type: application/json" --data-binary @- $B/api/v1/captions
echo '{"text":"今天天气不错","final":true}' | curl.exe -X POST -H "Authorization: Bearer $T" -H "Content-Type: application/json" --data-binary @- $B/api/v1/captions
```
→ `200 {"ok":true,"id":"bc_…","seq":2,"final":true,"archivedSeq":5}`

- 一句话可以先发若干条 partial(`final` 省略或 false),最后发一条 `final:true`。同一句的 partial 和 final **共用同一个 id**(服务器自动续用;也可以自己传 `id`,≤200 字),定稿后下一句换新 id。
- 帧(topic `lares.cap`):`{t:'cap', id, seq, text, final, bot:{id, name}}`,`seq` 按 token 递增。
- 非 E2EE 圈且开着转写时,`final` 句会以 `userId:"bot:<id>"` 归档并广播(`archivedSeq` 是它的 seq;没归档时为 `null`)。

### `POST /api/v1/speak`

```bash
curl.exe -X POST -H "Authorization: Bearer $T" -H "Content-Type: audio/wav" --data-binary "@hello.wav" $B/api/v1/speak
```
→ `200 {"ok":true,"sampleRate":24000,"durationMs":2000,"elapsedMs":2323}`

- 请求体是 WAV:PCM 16 bit、**单声道**、任意采样率、≤60 秒、≤6 MB。可以带 `LIST` 等附加块,也接受 WAVE_FORMAT_EXTENSIBLE 头。
  其它格式 → `400 bad_wav`,`detail` ∈ `not_riff_wave` `truncated_chunk` `missing_fmt` `bad_fmt` `missing_data` `not_pcm` `not_16bit` `not_mono` `bad_sample_rate` `empty` `too_long`。
- **同步**:服务器以 `bot:<id>` 身份进房、实时推流、播完(含一小段尾音缓冲)才返回 200,所以 2 秒的音频大约 2.3 秒返回。HTTP 客户端的超时要设得比音频长。
- 同一个 token 同时只能说一段(否则 `429 speak_busy`)。需要服务器装了 `@livekit/rtc-node`(`server/package.json` 的 optionalDependency),没装 → 501。
- 实测(`bot_api_e2e.mjs`,真 LiveKit 1.13.6):2 s 440 Hz 24 kHz WAV,监听端收到 48 kHz 音频,YIN 测频 440.0 Hz。

## 4. 限速与大小

| 范围 | 限制 |
|---|---|
| 每个 token 所有请求 | 60 次/分钟(令牌桶,突发 60) |
| `/messages` + `/captions` 合计 | 每 token 10 条/10 秒(突发 10,之后 1 条/秒) |
| `/speak` | 每 token 6 次/分钟,且同时只能 1 段 |
| JSON 请求体 | ≤ 16 KB |
| 文本 | 1..2000 字 |
| WAV | ≤ 6 MB、≤ 60 秒 |

超限返回 429 和 `Retry-After`。partial 字幕也计数,发 partial 别太勤(建议 ≥ 300 ms 一条)。

## 5. 端到端加密(E2EE)的圈子

E2EE 圈里,聊天、字幕、音频都用**由圈口令派生的密钥**加密,服务器没有这把密钥。所以服务器既不能替机器人发言,也读不到内容:

- `/messages` `/captions` `/speak` `/transcript` → `409 {"error":"e2ee"}`;`/circle` 和 `/events` 照常可用。
- 要在 E2EE 圈里收发,机器人必须**自己持有圈口令**,像一个成员一样进房。用 `server/tool/lares_bot.mjs`:

```js
import { LaresBot } from './lares_bot.mjs';
const bot = new LaresBot({ circleId: 'c_…', name: '助手', passcode: '圈口令', authVersion: 2, e2ee: true,
                           signaling: 'wss://lares.example.com/ws' });
bot.onChat((m) => console.log(m.senderName, m.body));
bot.onCaption((c) => c.final && console.log('字幕', c.text));
await bot.join();
await bot.sendChat('你好');
await bot.sendCaption('一句字幕', { final: true });
await bot.speak(pcm16At48k);
```

实测(`bot_api_e2e.mjs`):`e2ee:true` 时音频和数据包都被加密 —— 同口令的一端测得 440 Hz、收到聊天/字幕;口令对但没设密钥的一端测出约 19 kHz 的噪声,一条聊天也解不出。
注意:这样的机器人知道口令,权限等同成员(能听到所有人)。它在成员列表里是普通成员,不带"机器人"标记。

## 6. 速查:curl.exe 全流程(PowerShell)

```powershell
$B = 'http://127.0.0.1:8787'; $T = 'lrb_…'
curl.exe -s -H "Authorization: Bearer $T" "$B/api/v1/circle"
'{"text":"hi"}' | curl.exe -s -X POST -H "Authorization: Bearer $T" -H "Content-Type: application/json" --data-binary '@-' "$B/api/v1/messages"
curl.exe -s -X POST -H "Authorization: Bearer $T" -H "Content-Type: audio/wav" --data-binary '@C:\tmp\tone.wav' "$B/api/v1/speak"
curl.exe -N -H "Authorization: Bearer $T" "$B/api/v1/events"     # Ctrl+C 结束
```
PowerShell 7 往原生程序的管道默认是 UTF-8;5.1 先设 `$OutputEncoding = [Text.UTF8Encoding]::new($false)` 再用管道发中文。
