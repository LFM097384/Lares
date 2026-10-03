# lares.ai-voice — 圈子里的 AI 语音助手

接口契约(CLI / 环境变量 / stdout 事件 / 退出码)见 [CONTRACT.md](./CONTRACT.md)。通常由服务端
`src/ai_voice_supervisor.js` 按圈拉起;下面是手动运行和开发说明。

## 结构

| 文件 | 作用 |
|---|---|
| `index.mjs` | CLI 入口 + 进程内入口 `runVoiceBot()`;stdin 命令、SIGTERM、退出码 |
| `room.mjs` | 信令鉴权(HMAC 挑战)+ LiveKit(rtc-node 动态加载)+ 聊天/字幕帧 |
| `pipeline.mjs` | 回合引擎 `VoiceAgent` + 播放器 `Player`(纯逻辑,provider/sink/时钟全注入) |
| `chunker.mjs` | 增量断句(移植自 v2v-lab,性质测试同款) |
| `wake.mjs` | 唤醒词(精确 + 同音 + 句首 1 字容错)、`@AI` 文字触发 |
| `caps.mjs` | 每小时 / 每日回合上限、用量记账(落盘)、回复截断 |
| `history.mjs` | 「听到了什么」:按已播样本算 spokenUntil,历史只留听到的部分 |
| `audio.mjs` | 重采样、能量 VAD、PCM 工具 |
| `providers/` | `dashscope.mjs`(实时 ASR/TTS)、`openai_compat.mjs`(流式 LLM)、`mock.mjs`、`index.mjs`(工厂 + TTS 热连接池) |
| `smoke.mjs` | 真实 provider 冒烟:各调一次,打印延迟 |

## 运行

```powershell
# 离线 mock(不需要密钥;仍需信令服务 + LiveKit)
node bots/voice-agent/index.mjs --circle c_xxx --signaling ws://127.0.0.1:8787/ws --passcode 口令 --auth-v2 --providers mock

# 真实 provider
$env:LARES_DASHSCOPE_API_KEY = '…'      # 只放环境变量,别写进文件
node bots/voice-agent/index.mjs --circle c_xxx --passcode 口令 --auth-v2 --e2ee

# 冒烟
node bots/voice-agent/smoke.mjs --key-csv <DashScope 导出的 apiKey.csv>
```

运行时 stdin 可写 `{"cmd":"config","config":{…}}` 热改配置、`{"cmd":"stop"}` 退出。

进程内(测试 harness):

```js
import { runVoiceBot } from './bots/voice-agent/index.mjs';
const bot = await runVoiceBot({ circleId, signaling, passcode, authV2: true, providers: 'mock', emit: (ev) => events.push(ev) });
bot.setConfig({ trigger: 'always' });
await bot.stop();          // 返回退出码
```

只测回合引擎、不进房:`new VoiceAgent({ config, providers, sink, room })`,喂 `onAudioFrame()` / `onChat()`,见 `test/ai_voice.mjs`。

## 设计要点

- **延迟**:TTS 握手 ~1.1s,所以常备一条热连接(`WarmPool`,50s 换新,有人开口时补);
  有人开口时预热 LLM 连接。LLM 一边出 token 一边断句(首块用 `VOICE_CHUNKING` 的短首句),每块立刻送 TTS。
- **不做开场白**(「嗯,」之类):热连接下 TTFA 已在 1s 级别,固定开场白让每句一个味。
- **打断**:任何人本地 VAD 连续有声 ≥200ms → 清空 AudioSource 队列(只留 200ms)、中止 LLM、关 TTS 连接。
  按已送出样本数(减去 sink 未播部分)算 `spokenUntil`;历史、聊天、最终字幕都只含听到的部分 + `…`。
- **隐私**:回过 `capack{on:false}` 的成员不送 ASR;不听自己和别的 `u_ai_*`;正文默认不写日志(`LARES_AI_LOG_TEXT=1` 才写)。
- **ASR 省钱**:每人一条连接,本地 VAD 有声才开(带 300ms 预录),空闲 20s 关。
- **触发**:`wake` 喊名字(只喊名字则下一句当问题,8s 内有效);`always` 每句都答;`ptt` 只认聊天 `@AI` / `@名字`(三种模式下 `@AI` 都有效)。
- 回合进行中再来的请求只排一个(新的顶掉旧的),超过 20s 的丢弃。

## 已知局限

- 没有回声消除:AI 自己的声音会经别人的扬声器 + 麦克风回来,可能被当成插话。App 端开了系统 AEC 一般没事;外放场景可关 `interrupt`(阈值 `interruptMs` 目前只能在进程内传给 `VoiceAgent`)。
- 打断判定用的是能量 VAD,嘈杂环境会误触发。
- `room.mjs` 还没在真实 LiveKit 房间里跑过,也没有端到端自动化测试;单测只覆盖回合引擎(mock)。
