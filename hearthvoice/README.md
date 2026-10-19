# 灶语(Hearthvoice)

灶语是一个会在房间里说话的 AI。叫它的名字(默认「灶语」),它就用语音回答,同时发一份文字和字幕。本目录是它**平台无关的本体**:

- 回合引擎:轮流说话、本地能量 VAD、打断、只记「人实际听到的部分」;
- 唤醒词(精确匹配 + ASR 同音 + 句首 1 字容错)和 `@AI` 文字触发;
- LLM 提示词与对话历史,边出 token 边断句,首句短;
- 费用护栏:每小时和每日回答上限,用量落盘,回复截断;
- provider:DashScope 实时 ASR / TTS、OpenAI 兼容的流式 LLM(DeepSeek 等,可回退)、离线 mock。

本体不依赖 Lares 或 LiveKit,经 [PORT.md](./PORT.md) 描述的 port 接入任意平台。它在 Lares 上的插件是 `../hearthvoice-lares/`(插件 id `lares.ai-voice`)。

架构与炉灵相同:本体 `ember/` 对应 `hearthvoice/`,插件 `ember-lares/` 对应 `hearthvoice-lares/`,两个插件共用 Lares 接入层 `../lares-bridge/`。

## 用法

```js
import { createHearthvoice, DashscopeAsr, DashscopeTts, OpenAiCompatLlm } from '../hearthvoice/index.mjs';

const hv = createHearthvoice({
  port,                                   // 平台适配,见 PORT.md
  asr: new DashscopeAsr({ apiKey }),
  tts: new DashscopeTts({ apiKey }),
  llm: new OpenAiCompatLlm({ apiKey }),
  policy: {
    config: { name: '灶语', trigger: 'wake' },   // HearthvoiceConfig,见下
    usageFile: '/data/usage.json',               // 每日上限持久化(可选)
    emit: (ev) => console.log(ev),               // turn / usage / cap_reached …(默认不含正文)
    log: (m) => console.error(m),
    onDailyCap: () => hv.stop(),
  },
});
if (!hv.dailyCapReached()) await hv.start();
hv.setConfig({ trigger: 'always' });
await hv.stop();
```

离线联调:`MockAsr` / `MockLlm` / `MockTts` + `memoryPort()`。

## 配置 HearthvoiceConfig

`config.mjs` 中的 `normalizeConfig`(别名 `normalizeAiVoiceConfig`)负责校验:非法值回落默认,超长截断,数字夹紧。

| 键 | 默认 | 说明 |
|---|---|---|
| `name` | `灶语` | 显示名,也是隐含唤醒词(≤16 字) |
| `wakeWords` | `灶语` | 额外叫法,用逗号、顿号、分号或换行分隔 |
| `persona` | 口语、温暖、简短 | 系统提示 |
| `trigger` | `wake` | `wake` 叫名字 / `always` 每句都答 / `ptt` 只回 `@AI` 文字 |
| `voice` / `model` | `Cherry` / `qwen-flash` | TTS 音色 / LLM 模型 |
| `maxReplyChars` | 120 | 20..400 |
| `maxTurnsPerHour` / `maxTurnsPerDay` | 30 / 200 | 回答次数上限 |
| `interrupt` | true | 有人插话就停 |

配置会广播给房间成员,所以**永远不放密钥**。

## 文件

| 文件 | 作用 |
|---|---|
| `index.mjs` | 公共出口、`createHearthvoice`、`AGENT_NAME` |
| `port.mjs` / `PORT.md` | port 接口、`checkPort`、`memoryPort` |
| `pipeline.mjs` | 回合引擎 `VoiceAgent` 与播放器 `Player`(provider、sink、时钟全部注入) |
| `wake.mjs` | 唤醒词与 `@AI` |
| `chunker.mjs` | 增量断句 |
| `history.mjs` | 「听到了什么」:按已播样本算 spokenUntil |
| `caps.mjs` | 回答上限、用量记账、回复截断 |
| `audio.mjs` | 重采样、能量 VAD、PCM 工具 |
| `config.mjs` | 配置默认值、归一化、设置页 schema |
| `providers/` | `dashscope.mjs`、`openai_compat.mjs`、`mock.mjs`;`index.mjs` 汇总出口并提供 TTS 热连接池 `WarmPool` |
| `deps.mjs` | 可选 npm 依赖 `ws` 的解析 |

## 依赖(选择与理由)

- 零平台依赖。唯一的 npm 依赖是 `ws`,只有 DashScope provider 使用,而且可以通过 `o.WebSocket` 注入。缺省时 `deps.mjs` 先尝试裸 import,再退到同级 `../server/node_modules`(本仓库约定:开发机仓库根没有 node_modules)。都找不到也不会报错,只是 DashScope provider 要求调用方注入 `WebSocket`。
- 本体不读环境变量。按 `LARES_*` 组装 provider 是插件的事,见 `../hearthvoice-lares/providers.mjs`。
- 别的包按相对路径 `../hearthvoice/index.mjs` 引用本体,与 `ember` 相同:不发 npm 包,也不用 workspace。

## 测试

运行 `node --test hearthvoice/`,覆盖以下内容:

- 内存 port 上的完整回合;
- `isHuman` 过滤;
- 热更新与改名;
- 每日上限;
- 「灶语」唤醒同音;
- DashScope 注入(假 WebSocket);
- 平台无关性检查:源码不 import Lares、LiveKit 或 server,也不读 `LARES_*`。

回合引擎的大套件(断句性质测试、打断、上限、DeepSeek 回退等)在 `server/test/ai_voice.mjs`,`cd server; npm test` 会运行它。
