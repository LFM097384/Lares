# Lares AI 语音助手(`lares.ai-voice`)

圈子房间里的一个语音 AI:叫它的名字提问,它用语音回答,同时把回答发成字幕和聊天。

- 实现:`server/bots/voice-agent/`(独立进程,结构见同目录 [`README.md`](../server/bots/voice-agent/README.md))。
- 接口契约(CLI / 环境变量 / stdout 事件 / 退出码 / 监管规则):[`server/bots/voice-agent/CONTRACT.md`](../server/bots/voice-agent/CONTRACT.md),**以它为准**,本文是给圈主、运维和开发者看的使用手册。
- 服务端监管:`server/src/ai_voice_supervisor.js`;配置归一化:`server/src/ai_voice_config.js`。
- 测试:`server/test/ai_voice.mjs`(回合引擎,mock provider)、`server/test/ai_voice_supervisor.mjs`(监管)、`server/bots/voice-agent/smoke.mjs`(真实 provider 冒烟)。

---

## 1. 架构

### 1.1 它是一名成员,也是一个单独的进程

- 助手以**普通成员**身份进房:走和 App 相同的信令鉴权(HMAC 挑战应答),拿 LiveKit token,发布一条麦克风音轨。
  所有人都能在成员列表里看到它,显示名 = `config.name`(默认「小助手」)。
- userId 固定为 `u_ai_<sha256(circleId) 前 8 位 hex>`(可用 `--user-id` 覆盖),**从不**使用服务器保留的 `bot:` 前缀。
  服务端靠 `u_ai_` 前缀把它排除在「房里有没有真人」之外。`u_ai_` 是**保留前缀**:hello 必须带 supervisor 下发的圈级凭证
  `aiAuth = {circleId, proof: HMAC(LARES_AI_MEMBER_SECRET, nonce:userId:circleId)}`,且 userId 必须是该圈的派生 id,否则 `userId_reserved`。
  凭证只经子进程 env 传递;服务器主钥匙 `LARES_AI_MEMBER_KEY`(不设则每次启动随机)。独立运行没有凭证,默认 id 退回 `u_aibot_<hash>`(按普通成员计数)。
- 它是一个**单独的 Node 进程**,不在信令服务器进程里跑:服务器托管时由 `ai_voice_supervisor.js` 按圈 spawn,
  也可以由圈友在自己机器上独立运行(E2EE 圈只能这样,见 §6)。
- 它**不听**自己、别的 `u_ai_*` 和 `bot:*` 的声音(两个 AI 不会互相对话),也不响应它们的聊天。

### 1.2 数据流

```
 成员 A 的音轨 ─┐   (LiveKit 订阅,48k)
 成员 B 的音轨 ─┼─► 每人一路:重采样 16k ─► 本地能量 VAD 闸门 ──有声才开──► DashScope 实时 ASR
 成员 C 的音轨 ─┘        │  (capack off 的成员直接丢弃)    300ms 预录          qwen3-asr-flash-realtime
                         │                                  静音 1s 后停送        (WebSocket, server_vad)
                         │                                  空闲 20s 关连接               │
                         │                                                          ASR 定稿文本
                         │ 有人开口:TTS 热连接保温 + LLM 连接预热                         │
                         │                                                                ▼
 lares.chat 「@AI …」 ───┼────────────────────────────────────────────────► 触发判定 wake / always / ptt
                         │                                                                │
                         │                                                       费用护栏 caps(每时/每日)
                         │                                                                │
                         │                                         流式 LLM(OpenAI 兼容,qwen-flash)
                         │                                                                │ token 流
                         │                                               增量断句 chunker(首块 ≥4 字就发)
                         │                                                                │ 每块立即 append+commit
                         │                                     热备 TTS 连接(WarmPool)qwen3-tts-flash-realtime
                         │                                                                │ 24k PCM 增量
                         │                                    Player:24k→48k、10ms 帧、绝对时间节拍
                         │                                                                │
                         ▼                                                                ▼
            插话检测(任一人连续有声 ≥200ms)───打断───►   LiveKit AudioSource(48k,队列 200ms)──► 房间
                                                                                          │
                                         字幕 lares.cap {t:'cap', id, seq, text, final} ◄──┤ 每块开始播放时更新
                                         聊天 lares.chat(结束后整句;被打断只发听到的部分+「…」)
                                         stdout {ev:'turn', …延迟…} ──► 监管日志
```

一轮(turn)的步骤:

1. **本地 VAD 闸门**(`audio.mjs EnergyVad`):每个说话人一路,只在本机算能量;有声才打开该人的 ASR 连接,
   连同 300ms 预录一起送出;静音后再送约 1s(让服务端 VAD 判句尾);20s 没声音关连接。没人说话时不向云端送任何音频。
2. **ASR**(`providers/dashscope.mjs DashscopeAsr`):每人一条 WebSocket,16k PCM,服务端 VAD(`threshold 0.2`,`silence_duration_ms 800`)切句,
   只用定稿(`…transcription.completed`)。纯语气词(「嗯」「对啊」)直接丢掉。
3. **触发**(§3):决定这句话要不要答,答的是什么。
4. **费用护栏**(§5):超过每小时 / 每天回合数则不答,在聊天里提示一次(10 分钟内不重复)。
5. **流式 LLM**(`providers/openai_compat.mjs`):系统提示 = `persona` + 名字 + 「不超过 N 字、不要 Markdown」;
   历史保留最近 10 轮,用户消息形如 `昵称: 内容`。`max_tokens` 由 `maxReplyChars` 推出;对 DashScope 的 qwen 系模型关思考(`enable_thinking:false`)。
6. **增量断句**(`chunker.mjs`,`VOICE_CHUNKING`):首块遇到第一个逗号且 ≥4 字就发,之后的块 12..80 字。
   累计字数到 `maxReplyChars` 就截断并中止 LLM。
7. **热 TTS**(`providers/index.mjs WarmPool`):TTS 握手约 1.1~1.3s,所以常备一条已完成 `session.update` 的连接(50s 换新;
   10 分钟没人说话就不再保温,有人开口立刻补)。每块 `input_text_buffer.append` + `commit`(commit 模式),服务端按顺序逐段返回音频。
   一轮用一条连接,用完 / 打断即关,不复用。
8. **播放**(`pipeline.mjs Player`):24k → 48k,切 10ms 帧,按绝对时间节拍送进 LiveKit `AudioSource`(队列只留 200ms,打断时能很快安静)。

### 1.3 字幕、聊天、打断

- **字幕**:每轮一个字幕 id(`cap_ai_…`),发在 `lares.cap` 上,格式与真人字幕相同 `{t:'cap', id, seq, text, final}`。
  每一块**开始播放**时更新一次 partial(字幕跟着声音走,不会抢在声音前面);结束时发 `final`,内容 = 实际说出来的文字。
- **聊天**:一轮结束后把回复发到 `lares.chat`(普通文字消息,发送者是助手自己)。TTS 不可用时只发文字。
- **打断**(`config.interrupt`,默认开):AI 正在说话时,任何人本地 VAD **连续有声 ≥200ms** → 清空 `AudioSource` 队列、
  中止 LLM、关闭 TTS 连接。
- **spoken_until**(`history.mjs`):按每段已送出的样本数减去 `AudioSource` 里还没播的部分,算出对方真正听到了哪个字;
  拉丁单词不从中间切,宁可少算。被打断后,**历史、聊天和最终字幕都只含听到的部分 + 「…」**,
  所以下一轮模型不会以为大家听到了它没说出口的话。
- 一轮进行中又有新请求:只排一个(新的顶掉旧的),排队超过 20s 的丢弃。

### 1.4 延迟埋点

每轮结束 stdout 输出一行(监管进程转成日志):

```json
{"ev":"turn","id":"t_…","trigger":"wake","asrFinalAt":1790000000000,
 "llmFirstTokenMs":412,"firstSentenceMs":520,"ttsFirstAudioMs":830,"ttfaMs":870,
 "replyChars":46,"heardChars":46,"interrupted":false}
```

所有 `…Ms` 都相对 **ASR 定稿时刻**(ptt 则是收到聊天消息的时刻):

| 字段 | 含义 |
|---|---|
| `llmFirstTokenMs` | LLM 第一个文本 token |
| `firstSentenceMs` | 第一块断句送进 TTS |
| `ttsFirstAudioMs` | TTS 第一段音频到达 |
| `ttfaMs` | 第一帧音频交给 `AudioSource`(内部 TTFA) |

默认不带正文;设 `LARES_AI_LOG_TEXT=1` 时额外带 `query` / `reply`(仅调试,服务器托管时别开)。
另有 `usage`(用量增量 + 当日累计)、`cap_reached`、`ready`、`error`、`exit` 事件,见 CONTRACT §2。

## 2. 配置

配置 = 插件 `lares.ai-voice` 的 `config`(圈主用 `plugin_config_set` 设置),独立运行时用 `--config file.json` 或环境变量 `LARES_AI_CONFIG`(JSON 字符串)。
归一化是**宽松**的(`normalizeAiVoiceConfig`):缺的补默认,越界夹紧,超长截断,类型不对的字段回落默认,未知字段丢弃;只有「根本不是对象」才报 `bad_config`。

| 字段 | 类型 / 范围 | 默认 | 含义 |
|---|---|---|---|
| `name` | string ≤16 字 | `小助手` | 显示名,同时也是唤醒词 |
| `wakeWords` | string ≤100 字 | `小助手` | 额外唤醒词,逗号 / 顿号 / 分号分隔(空格算词内,如 `hey lares`) |
| `persona` | string ≤1000 字 | 「你是圈子里的语音小助手。用口语化、温暖、简短的中文回答……」 | 系统提示(人设) |
| `trigger` | `wake` \| `always` \| `ptt` | `wake` | 触发方式,见 §3 |
| `voice` | 标识符 ≤40 字(`[A-Za-z0-9._-]`) | `Cherry` | TTS 音色;改了会丢掉热连接重开 |
| `model` | 标识符 ≤64 字(`[A-Za-z0-9._-]`) | `qwen-flash` | LLM 模型(环境变量 `LARES_AI_LLM_MODEL` 优先) |
| `maxReplyChars` | 整数 20..400 | 120 | 单次回复最多字数(超出截断,并据此限 `max_tokens`) |
| `maxTurnsPerHour` | 整数 1..200 | 30 | 每小时最多回答次数(滑动窗口) |
| `maxTurnsPerDay` | 整数 1..2000 | 200 | 每天最多回答次数(按圈落盘) |
| `interrupt` | bool | `true` | 有人插话时停止说话 |

- 配置会**广播给圈内所有成员**(在 `PluginView.config` 里),所以这里永远不放任何密钥。
- 运行中改配置**热生效**:监管进程往子进程 stdin 写 `{"cmd":"config","config":{…}}`,不重启;改 `name` 会同时改房间里的显示名。
- 打断阈值 `interruptMs`(默认 200)、ASR 空闲关闭等参数目前只能在进程内传给 `VoiceAgent`,不在配置里。

### 环境变量

| 变量 | 作用 |
|---|---|
| `LARES_DASHSCOPE_API_KEY` | DashScope API Key(ASR / TTS 必需;LLM 默认也用它)。服务器托管时从服务器环境继承 |
| `LARES_AI_LLM_BASE_URL` | OpenAI 兼容接口地址,默认 `https://dashscope.aliyuncs.com/compatible-mode/v1` |
| `LARES_AI_LLM_API_KEY` | LLM 的 key,默认同 `LARES_DASHSCOPE_API_KEY` |
| `LARES_AI_LLM_MODEL` | 强制 LLM 模型,覆盖 `config.model` |
| `LARES_AI_TTS_MODEL` | 覆盖 TTS 模型(默认 `qwen3-tts-flash-realtime`) |
| `LARES_DASHSCOPE_HOST` | 覆盖 ASR / TTS 的 WebSocket 主机(默认 `dashscope.aliyuncs.com`,北京) |
| `LARES_AI_PROVIDERS` | `dashscope`(默认)或 `mock` |
| `LARES_AI_CONFIG` | JSON 配置(见上表) |
| `LARES_AI_USAGE_FILE` | 用量 / 回合计数文件路径;服务器托管时 = `DATA_DIR/ai_voice_usage/<circleId>.json` |
| `LARES_SIGNALING` | 信令地址,默认 `ws://127.0.0.1:8787/ws` |
| `LARES_AI_AUTH_SECRET` / `LARES_AI_AUTH_V` | 服务器托管专用:HMAC 密钥(注册圈 = v2 verifier hex)与版本 |
| `LARES_AI_LOG_TEXT` | `1` 时 `turn` 事件带正文(调试用) |

## 3. 触发方式

| `trigger` | 什么时候回答 |
|---|---|
| `wake`(默认) | 一句话里出现名字或唤醒词。「小助手,明天几点集合」→ 问题是「明天几点集合」。**只喊名字**(「小助手?」)则这个人接下来 8 秒内说的下一句直接当问题 |
| `always` | 任何人说完一句(非纯语气词)都回答;句里若带唤醒词会先去掉 |
| `ptt` | 只认文字聊天里以 `@AI` 或 `@名字` / `@唤醒词` 开头的消息,语音一律不触发 |

- **三种模式下**,聊天里 `@AI …` / `@小助手 …`(大小写不敏感,全角 `＠` 也认)都会触发回答;回答仍然是语音 + 字幕 + 聊天。
- 唤醒词匹配(`wake.mjs`):归一化(去标点空白、全角转半角、字母小写)后**任意位置精确出现**都算;
  句首(跳过「嗯 / 那个 / 喂 / hey」等语气词后的前 8 个字)另有容错:常见 ASR 同音字(助↔组 / 主 / 住,手↔首 / 守 …)不算错,
  ≥3 字的唤醒词在句首位置还允许错 1 个字(但首尾字必须对上)。
- 唤醒词至少 2 个字;太常见的词(比如「你好」)会频繁误触发,别用。
- `ptt` 模式下**不做语音识别**:成员的语音一帧都不送 ASR、不开识别连接。本地能量 VAD 照跑,所以插话仍能打断助手。
  运行中改触发方式(如 `wake` → `ptt`)会立即关掉所有已开的识别连接,需要时按新配置重开。

## 4. Provider 与模型

所有云端调用都走阿里云百炼(DashScope)**北京地域**,同一个 API Key。

| 环节 | 默认模型 | 协议 | 文档 |
|---|---|---|---|
| 语音识别 | `qwen3-asr-flash-realtime` | WebSocket `wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=…`,16k PCM,`server_vad` | [实时语音识别 qwen3-asr-flash-realtime](https://help.aliyun.com/zh/model-studio/qwen3-asr-flash-realtime) |
| 对话 | `qwen-flash` | OpenAI 兼容 `POST {base}/chat/completions`,`stream:true`,`stream_options.include_usage` | [OpenAI 兼容接口](https://help.aliyun.com/zh/model-studio/compatibility-of-openai-with-dashscope),base 默认 `https://dashscope.aliyuncs.com/compatible-mode/v1` |
| 语音合成 | `qwen3-tts-flash-realtime` | WebSocket 同上,commit 模式,24k PCM | [交互流程](https://help.aliyun.com/zh/model-studio/interactive-process-of-qwen-tts-realtime-synthesis)、[客户端事件](https://help.aliyun.com/zh/model-studio/qwen-tts-realtime-client-events) |

价格见[模型计费](https://help.aliyun.com/zh/model-studio/model-pricing)。

- **换 LLM**:设 `LARES_AI_LLM_BASE_URL` / `LARES_AI_LLM_API_KEY` / `LARES_AI_LLM_MODEL` 即可接任何 OpenAI 兼容服务;
  只有 base URL 含 `dashscope` 且模型名以 `qwen` 开头时才加 `enable_thinking:false`。ASR / TTS 仍然要 DashScope key。
- **mock**(`--providers mock` 或 `LARES_AI_PROVIDERS=mock`,`providers/mock.mjs`):离线、确定性,不需要任何 key。
  `MockAsr` 每段「有声 → 停」出一句固定台词(默认「小助手，你好」),`MockLlm` 吐固定回复,`MockTts` 输出正弦音。
  用于单测和不想花钱的联调(仍然需要信令 + LiveKit)。服务器设 `LARES_AI_PROVIDERS=mock` 时,监管不要求 DashScope key。
- 冒烟:`node bots/voice-agent/smoke.mjs --key-csv <DashScope 导出的 apiKey.csv>`,三个 provider 各调一次并打印延迟。
- 密钥只放请求头和环境变量,永不打印;错误日志只记错误码,不记内容。

## 5. 费用护栏与费用估算

### 5.1 护栏

| 护栏 | 实现 |
|---|---|
| 每小时回合上限 | `maxTurnsPerHour`,滑动 1 小时窗口;到了之后的请求不答,`@AI` 聊天会收到一句「这一小时回答得有点多了」(10 分钟内不重复)。上限期间**暂停 ASR**(不开识别连接),窗口腾出来后自动恢复 |
| 每日回合上限 | `maxTurnsPerDay`,按**本地日**(进程所在系统时区)计,按圈落盘(`LARES_AI_USAGE_FILE`,保留 14 天),重启不清零。到了先在聊天里说一句,然后进程**以退出码 4 退出**;监管在下一个本地 0 点前不再拉起 |
| 回复长度 | `maxReplyChars` 截断(尽量收在句末 / 逗号);`max_tokens = ceil(1.5 × maxReplyChars) + 16`;字数够了立刻中止 LLM 流 |
| ASR 只在有人说话时计费 | 本地 VAD 闸门 + 300ms 预录 + 1s 拖尾;空闲 20s 关连接;`ptt` 模式和回合上限期间完全不送 ASR(本地 VAD 打断照常),进入 / 离开暂停各记一行 stderr(不含正文) |
| 不白等的请求 | 进行中只排 1 个请求,排队 >20s 丢弃 |
| TTS 保温有上限 | 10 分钟没人说话就不再预开连接;预开失败 3 次暂停 |
| 崩溃不刷钱 | 监管退避 5s→60s,每小时最多重启 5 次;房里没真人 20s 后停掉进程 |

回合数在**真正开始调 LLM 时**记账(被护栏挡掉的不算)。用量文件同时累计 `llmIn` / `llmOut`(token)、`ttsChars`、`asrSec`,监管日志里能看到每次 `usage`。

注意:在 `wake` / `always` 模式下,**ASR 费用跟着「房里有人说话的时长」走**。`ptt` 模式不产生 ASR 费用;每小时 / 每日回合用完后 ASR 也暂停、不再计费(每日上限触发后进程本来就会退出)。

### 5.2 单价(北京地域,人民币,以[官方计费页](https://help.aliyun.com/zh/model-studio/model-pricing)为准)

| 项目 | 单价 |
|---|---|
| ASR `qwen3-asr-flash-realtime` | 0.00033 元/秒 ≈ **1.19 元 / 小时送出的语音** |
| LLM `qwen-flash` | 输入 0.15 元 / 百万 token,输出 1.5 元 / 百万 token |
| TTS `qwen3-tts-flash-realtime` | 1 元 / 万字符 |

### 5.3 算一个例子

一个房间开 1 小时,2 个人各自有 50% 的时间在说话,助手回答 30 次、每次 80 字:

| 项目 | 用量 | 费用 |
|---|---|---|
| ASR | 2 人 × 30 分钟 = 3600 秒(VAD 闸门:只计有人说话的部分;拖尾 / 预录会多出百分之十几) | 3600 × 0.00033 ≈ **1.19 元** |
| LLM 输入 | 30 次 × 约 800 token(系统提示 + 最多 10 轮历史) = 2.4 万 token | ≈ 0.004 元 |
| LLM 输出 | 30 × 约 80 token = 2400 token | ≈ 0.004 元 |
| TTS | 30 × 80 = 2400 字 | 0.24 元 |
| **合计** | | **≈ 1.44 元 / 小时** |

结论:**大头是 ASR(约 83%)**,LLM 几乎可以忽略。想省钱就少让助手挂在长时间多人聊天的房间里;
回合上限主要限制的是 TTS(默认上限下每天最多 200 × 120 = 2.4 万字 ≈ 2.4 元)。被打断时已提交给 TTS 的块照样计费。

## 6. 运行

前提:信令服务器 + LiveKit 都在跑;机器上装了 `@livekit/rtc-node`(服务器的 optionalDependency,或 `npm --prefix tool install` 装到 `server/tool/`,bot 会自动回退去那里找)。下面命令都在 `server/` 目录下执行。

### 6.1 独立运行

```powershell
# 离线 mock:不需要 DashScope key
node bots/voice-agent/index.mjs --circle c_xxx --signaling ws://127.0.0.1:8787/ws --passcode 口令 --auth-v2 --providers mock

# 真实 provider
$env:LARES_DASHSCOPE_API_KEY = '…'      # 只放环境变量,别写进文件
node bots/voice-agent/index.mjs --circle c_xxx --passcode 口令 --auth-v2 --config ai.json

# 端到端加密的圈子:必须 --passcode + --e2ee(密钥按 App 同样方式由口令派生)
node bots/voice-agent/index.mjs --circle c_xxx --passcode 口令 --auth-v2 --e2ee
```

- `--auth-v2`:App 注册的 `c_…` 圈(由口令派生 Argon2 verifier);环境变量里配口令的老式圈不加。
- 进 E2EE 圈却没加 `--e2ee` → 拒绝启动(退出码 2,`circle_requires_e2ee`)。
- 独立运行**不读插件配置**,只用 `--config` / `LARES_AI_CONFIG` / `--name`;也不需要圈主装插件。
- 运行中 stdin 写 `{"cmd":"config","config":{…}}` 热改配置,`{"cmd":"stop"}` / Ctrl+C / SIGTERM 退出。
- 退出码:0 正常,2 参数 / 配置错,3 鉴权失败,4 当日额度用完。
- ⚠️ 非 E2EE 圈如果同时开着插件,服务器也会拉起一个助手,两者默认 userId 相同,可能冲突;要么停用插件,要么给独立进程 `--user-id`。

### 6.2 服务器托管(插件 `lares.ai-voice`)

圈主安装第一方插件(走信令 WS,同 [plugin-api.md §3](plugin-api.md)):

```
{t:'plugin_install', circleId, ownerKey, pluginId:'lares.ai-voice'}
{t:'plugin_config_set', circleId, ownerKey, pluginId:'lares.ai-voice', config:{trigger:'wake', name:'小助手'}}
```

监管(`ai_voice_supervisor.js`)在以下条件**全部**满足时为该圈拉起一个子进程:

- 插件已装且启用;
- 房里至少 1 个真人(不算 `u_ai_*` 和 `bot:*`);
- 圈子**不是**服务端 E2EE(`circleSettings.e2ee === true` 时拒绝,只在日志里说一次;E2EE 圈请用 §6.1 独立运行);
- 服务器设了 `LARES_DASHSCOPE_API_KEY`(或 `LARES_AI_PROVIDERS=mock`);
- 服务器有该圈的鉴权材料:注册圈用存着的 v2 verifier,env 圈用口令(v1);纯 token 鉴权模式下不可用;
- 服务器配了 LiveKit(`RTC_CONFIGURED`),且 bot 入口文件存在。

细节:

- 秘密**只走子进程环境变量**,不进 argv:监管把 verifier 放进 `LARES_AI_AUTH_SECRET`,同时从子进程环境里删掉 `LIVEKIT_*`、`LARES_AUTH_TOKEN`、圈口令、APNs 等服务器自己的密钥。
- 房里没真人 20s 后停(SIGTERM,5s 后 SIGKILL);停用 / 卸载插件、解散圈子、服务器关机都会停。
- 崩溃退避重启(5s → 60s,每小时最多 5 次);被踢出房间而正常退出时不立刻拉回,等房间空过一次或插件重新启用。
- 圈子开了**敲门模式**时,助手无法自行进房(`knock_waiting`),会按崩溃处理并退避。

**部署 TODO**:`server/Dockerfile` 目前只 `COPY src ./src`,镜像里没有 `bots/`,监管会以 `no_bot` 拒绝启动(日志「找不到 bot 入口」)。
生产要用,需要在 Dockerfile 里加一行 `COPY bots ./bots`(依赖 `ws` / `hash-wasm` / `@livekit/rtc-node` 已在 `server/package.json` 里,镜像本来就是 glibc 版 Debian)。

**App 现状**:App 里还**没有**安装 `lares.ai-voice` 的入口,只能用上面的 WS 消息安装;装好后的配置编辑器是原始 JSON 编辑框,不是按 `settingsSchema` 生成的表单。

## 7. 隐私与知情同意

面向用户的说明见 [隐私政策](privacy.md)「AI 助手」一节。实现层面:

- **可见**:助手是房间里看得见的成员,有名字;它说的话同时出现在字幕和聊天里。插件描述里写明了语音会送到阿里云。
- **送到云端的内容**:房里正在说话的成员的语音(VAD 判有声时,含 300ms 预录)→ DashScope ASR;
  识别文字(带说话人昵称)、`@AI` 聊天消息和最近 10 轮对话 → LLM;回复文字 → TTS。全部是北京地域。
- **尊重「提供字幕」开关**:成员在 `lares.cap` 上发过 `capack{on:false}`(即关掉了「有人需要字幕时,识别我的语音」或本次点了停止),
  助手就不再把他的音频送去 ASR,并立即关闭他的识别连接。限制见 §9。
- **不落盘内容**:对话历史只在进程内存里(最近 10 轮),进程退出即丢。服务器只保存用量计数文件(每天的回合数、token 数、TTS 字数、ASR 秒数,保留 14 天,另有最近一小时的回合时间戳),不含任何文字或音频。
- **日志**:默认只记长度和延迟;`LARES_AI_LOG_TEXT=1` 才记正文,服务器托管时不要开。
- **E2EE 圈**:服务器托管直接拒绝。只有知道口令的圈友在**自己的机器上**带 `--passcode --e2ee` 运行时才可用;
  此时解密发生在那台机器上,语音同样会送到 DashScope,应当事先告诉圈友。

## 8. 延迟

<!-- MEASURED -->

本地真机端到端(真 LiveKit `--dev` + 真 Lares 服务器 + DashScope,4 轮,最终一次运行;脚本 `server/tool/ai_voice_e2e.mjs`,记录 `server/tool/ai_voice_e2e.last.txt`)。只有 4 个样本,不给 p90。

| 指标 | 定义 | 实测 |
|---|---|---|
| TTFA(外部) | 真人说完 → 真人收到助手第一帧非静音音频 | p50 **2266ms**(原始 2266 / 2853 / 2354 / 2157) |
| TTFA(内部) | ASR 定稿 → 第一帧开播(`ttfaMs`) | p50 **1052ms** |
| LLM 首 token | ASR 定稿 → 第一个 token(`llmFirstTokenMs`) | 387ms(更早一次运行的冷启动首轮约 1.5s) |
| 首句就绪 | ASR 定稿 → 第一块切好(`firstSentenceMs`) | 432ms |
| TTS 首音频 | ASR 定稿 → TTS 第一段音频(`ttsFirstAudioMs`) | 1051ms(首句发出后约 650ms) |
| ASR 定稿延迟 | 真人说完 → 收到 ASR 定稿 | 1076ms(`server_vad` 静音窗口 800ms;更早一次运行有一个 5.7s 离群值) |
| ASR WS 握手 | 打开识别连接 | 1.0~1.6s(被排队的预录音频掩盖,不在关键路径上) |
| 打断停止延迟 | 真人插话开始 → 助手最后一帧非静音音频 | **355ms**(第 1 次运行 338ms);听到 83 字中的 8 字,聊天和字幕都显示「长城最早是春秋战…」 |
| 回读一致性 | 把助手音频再过一遍 ASR,与聊天里的回复比对 | 100% 一致(CJK 字重合) |

<!-- /MEASURED -->

**时间花在哪**:外部 TTFA ≈ 2.3s 里,ASR 断句(服务端 800ms 静音判定,定稿约在说完后 1.1s)和 TTS 首包(首句发出后约 650ms)是两大头;LLM 首 token(~0.4s)不是瓶颈。
可调的杠杆:把 `silence_duration_ms` 降到 ~500;首块切得更短;换 `cosyvoice-v2`(v2v-lab 实测首包约 580ms)。

初步冒烟数据(`smoke.mjs`,单次,不代表 p50):LLM 首 token 1643ms(冷连接)、TTS 建连 1282ms、TTS 首音频 910ms、ASR 定稿在说话结束后 2058ms。

读这些数时注意:

- 外部 TTFA ≈ ASR 定稿延迟 + 内部 TTFA + 网络与接收端抖动缓冲。ASR 定稿延迟里有服务端 VAD 的 800ms 静音判定,是结构性的。
- TTS 建连(~1.1~1.3s)正常情况下不在关键路径上(热连接);若一轮拿到的是冷连接,TTFA 会多出这一截。
- LLM 首 token 冷热差别大:有人开口时会预热一次 HTTP 连接。
- 打断停止延迟的下限 ≈ 200ms 插话判定 + `AudioSource` 里 ≤200ms 的排队 + 网络。

## 9. 已知局限

- **没有回声消除(AEC)**:助手的声音经别人的扬声器 + 麦克风回来,可能被当成插话打断自己。App 端开了系统 AEC 一般没事;外放场景可关 `interrupt`。
- **插话判定基于能量 VAD**:嘈杂环境、键盘声会误打断;阈值 `interruptMs` 不在配置里。
- **「提供字幕」只通过 `capack` 帧生效**:助手只能看到成员在 `lares.cap` 上发出的 `capack`。App 只在转写记录开着时向全房广播 `capack`,
  否则只回给发过 `capreq` 的人——而助手不发 `capreq`。所以在没开转写记录的圈里,助手**通常看不到**这个偏好,会照常识别。
- **App 没有安装入口**,配置编辑是原始 JSON(§6.2)。
- **Dockerfile 只拷 `src/`,镜像里没有 `bots/`**(§6.2 部署 TODO)。
- **敲门模式的圈**助手进不去(`knock_waiting`,按崩溃退避)。
- **用量文件只存每日计数**:回合数、LLM token、TTS 字数、ASR 秒数,保留 14 天(另有最近一小时的回合时间戳);没有按成员 / 按轮的明细。
- `room.mjs` 的真实 LiveKit 端到端只有手动脚本(`server/tool/ai_voice_e2e.mjs`,见 §8),不在 `npm test` 里;单测只覆盖回合引擎(mock)和监管。
