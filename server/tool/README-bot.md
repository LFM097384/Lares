# Bot 语音接口

让程序以「圈子成员」身份进房、说话、听声。

## 两条路线,别搞混

| 用途 | 用什么 | 为什么 |
|---|---|---|
| **测试 / 压测** | `lares_bot.mjs`(本目录) | 零新增依赖,CI 里跑得快 |
| **AI 炉灵** | [`@livekit/agents`](https://github.com/livekit/agents-js) | 官方框架,自带 STT/LLM/TTS 插件、Silero VAD、语义轮次检测、Worker 编排 |

AI 炉灵**不要**建在 `lares_bot.mjs` 上 —— 那些能力没必要自己造。
但两者底层都是 `@livekit/rtc-node`,所以下面记的坑对两边都适用。

## 快速验证

```bash
# 前置:信令服务在 8787,LiveKit 在 7880
cd server
LARES_SIGNALING=ws://127.0.0.1:8787 node tool/bot_selftest.mjs
```

自检会开两个 bot:一个发 440Hz 正弦波,另一个听并测频。
它验证的是**整条回路**:认证 → 进房 → 发布 → 订阅 → 收帧 → 解码。

实测结果(2026-09-14,本机 + 本地 LiveKit):

| 发送 | 测得 | 偏差 |
|---|---|---|
| 220 Hz | 220.0 Hz | 0.00% |
| 440 Hz | 440.0 Hz | 0.00% |
| 880 Hz | 880.1 Hz | 0.01% |

三频全部吻合,顺带证明了**声纹归属可验证** —— 不同 bot 发不同频率,
收端能分辨是谁在说。

## 用法

```js
import { LaresBot, sineWave } from './lares_bot.mjs';

const bot = new LaresBot({ circleId: 'home', name: '炉灵', passcode: '...' });
bot.onAudio((frame, fromIdentity) => { /* 听 */ });   // 必须在 join() 之前
await bot.join();
await bot.speak(sineWave(440, 3));                     // 说
await bot.leave();
```

环境变量:`LARES_SIGNALING`、`LARES_CIRCLE_PASSCODE`、`LARES_AUTH_TOKEN`。

## 踩过的坑(都是实测,不是推测)

### 1. `subarray` 会让音频静默损坏 ⚠️

**最隐蔽的一个。** 发送端切帧时:

```js
const chunk = pcm16.subarray(a, b);  // ✗ 返回视图,共享同一 ArrayBuffer
const chunk = pcm16.slice(a, b);     // ✓ 返回拷贝
```

`AudioFrame` 要把这块内存跨 FFI 边界交给 Rust 侧。复用同一个 buffer 的
不同区间会让接收端读到错位数据。

**症状极具迷惑性**:
- 单帧测频**正确**(441Hz)
- 能量正常、非零采样占比正常、说话者识别正常
- **只有拼接后才暴露**:整体测出 100Hz —— 正好是 `48000/480`,
  即帧长的倒数,说明帧与帧之间出现了周期性不连续
- **全程零报错**

排查时一度怀疑过 Opus 失真、采样率不匹配、测频算法用错,全都不是。

### 2. 别自己写测频

手写过零法在 220Hz 和 880Hz 上都准(误差 1-2%),**唯独 440Hz 偏差 14%**。
等比例偏移还能校正,这种**只在特定频率失准**的情况说明算法本身不稳。

改用 `pitchfinder` 的 YIN(基于自相关),三频全部 0% 偏差。
它是纯 JS 零原生依赖,只进 `tool/`,不进生产代码。

### 3. 测频必须剔除静音段

收到的流里除了正弦波,还有等尾巴时的静音。静音不过零,
直接拿总时长做分母会把频率算低(440Hz 被算成 344.9Hz)。

### 4. 监听必须在 `connect()` 之前挂

已经在房里的人会在 connect 完成的瞬间触发 `TrackSubscribed`。
晚挂就漏掉他们,症状是「先进来的人听不见,后进来的听得见」。

### 5. 信令连接不能关

拿到 token 后**不要**关掉那条 WebSocket —— presence 就是这条连接,
断了 bot 就从成员列表消失,别人看不到它在。

### 6. 节奏用绝对时间基准

`setTimeout(9)` 每帧多睡 1ms,说一分钟就漂 6 秒。
要对齐到 `start + n*10ms`。

### 7. 带 `prefetch: true` 的 token 不是进房 token

`server/src/index.js:561` 的预取 token 和进房 token 同名 `t: 'token'`,
靠 `prefetch` 字段区分。

### 8. 压测时 userId 必须各不相同

撞车会被服务端当成同一个人挤掉。`LaresBot` 默认加随机后缀。

## 设计原则:bot 必须自己认证

bot 跟真人客户端走**同一套** HMAC 挑战应答,没有后门、没有特权通道。

这不是洁癖:将来上 E2EE 后,密钥由圈口令派生,只有真正持有口令的参与者
才解得开内容。如果 bot 走后门进房,就必须由服务器持有密钥,E2EE 当场失效。

**「bot 必须自己认证」是 E2EE 成立的前提。**
