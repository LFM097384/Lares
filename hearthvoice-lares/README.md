# hearthvoice-lares — 灶语(Hearthvoice)的 Lares 插件

灶语是圈子里会说话的 AI:叫它名字(默认「灶语」)就回答。本目录是它接入 Lares 的插件进程,
线上身份仍是插件 `lares.ai-voice`、成员 id `u_ai_<8 hex>`(线协议不变)。

接口契约(CLI / 环境变量 / stdin / stdout 事件 / 退出码)见 [CONTRACT.md](./CONTRACT.md)。通常由服务端
`server/src/ai_voice_supervisor.js` 按圈拉起(入口可用 `LARES_AI_VOICE_ENTRY` 覆盖);下面是手动运行和开发说明。

## 三部分

| 目录 | 作用 |
|---|---|
| `../hearthvoice/` | 灶语本体:回合引擎、唤醒词、断句、费用护栏、ASR/LLM/TTS provider。平台无关,经 port 接入(`PORT.md`) |
| `../lares-bridge/` | Lares 接入层:`LaresRoom`(信令 HMAC / AI 成员凭证 / LiveKit / E2EE)、帧编解码、依赖解析。与炉灵(`ember-lares`)共用 |
| `hearthvoice-lares/`(本目录) | 插件:CLI、LARES_* 环境变量 → provider、`LaresRoom` → port、stdin 命令、退出码 |

| 文件 | 作用 |
|---|---|
| `index.mjs` | CLI 入口 + 进程内入口 `runVoiceBot()`;stdin 命令、SIGTERM、退出码(`process.exitCode`) |
| `port.mjs` | `laresVoicePort(room)`:`LaresRoom` → 灶语 port(`names`→`name`,出站音轨 = `room.sink()`) |
| `providers.mjs` | `createProviders(kind, {env})` / `createLlm(env)`:按 `LARES_*` 组装 provider;日志前缀 `[ai-voice]` |
| `smoke.mjs` | 真实 provider 冒烟:各调一次,打印延迟 |
| `CONTRACT.md` | 与服务端 supervisor 的进程契约 |

## 依赖(选择与理由)

- 三个包都按**相对路径**互相引用(`../hearthvoice/index.mjs`、`../lares-bridge/index.mjs`),与 `ember-lares → ../ember` 一致;
  不发 npm 包、不用 workspace,因为它们只在这个仓库和这个镜像里用,相对路径在两边的布局相同:
  `/app/server`、`/app/lares-bridge`、`/app/hearthvoice`、`/app/hearthvoice-lares`、`/app/ember`、`/app/ember-lares`。
- 不 import `server/` 下任何源码;`server/` 只按路径 spawn `index.mjs`(以及读 `../hearthvoice/config.mjs` 做配置校验)。
- npm 依赖(`ws`、`hash-wasm`、可选 `@livekit/rtc-node`)不单独安装,从 `server/node_modules` 解析:
  - 开发机:`lares-bridge/deps.mjs` 裸 import 失败后按 `../server/package.json`(再 `../server/tool/package.json`)解析;
  - 镜像:`/app/node_modules` 是指向 `/app/server/node_modules` 的软链,裸 import 直接命中(见 `server/Dockerfile`)。

## 运行

```powershell
# 离线 mock(不需要密钥;仍需信令服务 + LiveKit)
node hearthvoice-lares/index.mjs --circle c_xxx --signaling ws://127.0.0.1:8787/ws --passcode 口令 --auth-v2 --providers mock

# 真实 provider
$env:LARES_DASHSCOPE_API_KEY = '…'      # 只放环境变量,别写进文件
node hearthvoice-lares/index.mjs --circle c_xxx --passcode 口令 --auth-v2 --e2ee

# 冒烟
node hearthvoice-lares/smoke.mjs --key-csv <DashScope 导出的 apiKey.csv>
```

运行时 stdin 可写 `{"cmd":"config","config":{…}}` 热改配置、`{"cmd":"stop"}` 退出。

进程内(测试 harness):

```js
import { runVoiceBot } from './hearthvoice-lares/index.mjs';
const bot = await runVoiceBot({ circleId, signaling, passcode, authV2: true, providers: 'mock', emit: (ev) => events.push(ev) });
bot.setConfig({ trigger: 'always' });
await bot.stop();          // 返回退出码
```

## 测试

`node --test hearthvoice-lares/`:假房间上的 port 映射、`runVoiceBot` 全流程(mock provider)、CLI 退出码。
回合引擎的大套件在 `server/test/ai_voice.mjs`(`cd server; npm test` 会跑)。
## 设计要点(本体,详见 ../hearthvoice/README.md)

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
- 端到端只有生产 E2E 脚本 `server/tool/ai_voice_prod_e2e.mjs`(手动跑);单测覆盖回合引擎(mock)与 port 映射(假房间)。
