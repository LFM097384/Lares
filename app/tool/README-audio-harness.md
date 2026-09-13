# 逐轨音频捕获验证工具

`audio_capture_harness.dart` + `wav_check.mjs` —— 用来验证「LiveKit 逐轨 PCM 捕获」
在某个平台上是否真的可用。2026-09 用它在 Windows 上跑通了需求⑧的地基。

> 这是**验证工具,不是生产代码**。不要从 `lib/` 里 import 它。
> 生产实现在 `lib/src/recording/`。

## 用法

```powershell
# 1. 起全栈(注意 dev.ps1 会自动挑真实网卡,见其内注释)
pwsh scripts/dev.ps1

# 2. 起说话机器人(发正弦波,提供可验证的远端音轨)
cd server/tool && npm install          # 依赖 @livekit/rtc-node
node speak_bot.mjs                      # 440 Hz
node speak_bot2.mjs                     # 880 Hz(第二个身份,验证归属)

# 3. 跑捕获工具
cd app
flutter run -d windows -t tool/audio_capture_harness.dart

# 4. 独立复核产出的 WAV(不要只信工具自述)
node tool/wav_check.mjs spike_out/u_bot.wav
```

## 2026-09 在 Windows 上的实测结论

| 项 | 结果 |
|---|---|
| `onFrame` 是否触发 | ✅ 是,10.000 ms/帧(160 样本 @16k) |
| 请求的 16000 Hz 是否被遵守 | ✅ 是,未被静默改成 48k |
| 是否真实波形 | ✅ RMS≈6929,98.9% 样本非零 |
| 逐轨说话人归属 | ✅ 440/880 Hz 双音各落各家,比值精确 2:1 |
| 重连后是否需要重新注册 | ✅ **需要**,见下 |

## ⚠️ 两个估频函数不可信,别抄进生产

1. **过零率估频(Schmitt trigger)不可靠** —— 对 440 Hz 正弦报出 297 Hz,
   因为 Opus 的谐波会骗过施密特触发器。
2. **Dart 版 Goertzel 在长缓冲上返回 0.0** —— 递推累加器溢出。
   算法本身没错,但必须**分窗**(建议 ≤16384 样本)并对输入做归一化。

可信的数字来自独立的 `wav_check.mjs`(Node 版 Goertzel,分窗)。
**任何时候都要用独立工具复核,不要采信被测程序的自述。**

## ⚠️ 重连:必须由 TrackSubscribed 驱动重新注册

实测(杀掉 LiveKit 服务端):

```
19:48:55  RoomReconnecting
19:49:00  RoomReconnected        <-- 房间已恢复
                                     ...但整整 40 秒零帧
19:49:40  TrackSubscribed        <-- 新的 track SID
19:49:40  renderer 重新注册
19:49:51  framesThisSec=100      <-- 帧这时才回来
```

`connectionState == connected` 期间帧数是**精确的 0**。
7 次注册里 track SID **每次都变** —— SDK 会销毁 `RemoteAudioTrack` 重建新对象。

**结论:在 `TrackSubscribed` 处理器里注册,绝不跨重连缓存 `AudioTrack` 引用。
`RoomReconnected` 本身不是充分触发点,它比轨道回来早得多。**

未隔离到的情形:会话恢复且同一 track 对象存活(不产生新事件)。
杀服务端总会导致完整重新入房。**该子情形未测,但不构成反证** ——
按 `TrackSubscribed` 注册两种情形都覆盖。

## ⚠️ 其他必须知道的坑

1. **`AudioRendererOptions` 默认 sampleRate 是 24000**,不是 48000。
   必须显式传 `sampleRate: 16000`,否则会在你以为是 16k 时拿到 24k。
2. **失败是完全静默的,不抛异常。** 原生侧解析不到轨道时
   (`MediaTrackForId` 输掉订阅竞争 → "No such track"),Dart 侧只是
   `return false` 加一条 `logger.warning`,`onFrame` 从此不再触发。
   **必须加看门狗**:注册后 ~2s 内没有帧就重新注册 —— 没有错误可捕获。
3. **`channels: 1` 是截断而非混音。** `out_channels = min(requested, actual)`,
   对立体声轨只取第一声道,不是求平均。
4. **上报的 `sampleRate` 字段是回显,不是实测值。** C++ 报的是
   `format_.sample_rate`(请求值)。它恰好为真是因为 `ResampleAudio` 无条件转换。
   **换平台时绝不能拿这个字段当证据 —— 要用已知频率的音测。**
5. **重采样质量**:48k→16k 是精确的 3:1 箱式滤波(三点平均),每次回调无状态。
   该比值下干净、对语音/ASR 够用,但 8 kHz 以上抗混叠差。
   非整数比(如 44.1k)会暴露分块边界伪影。
6. **帧在监听器挂上之前是丢弃而非缓冲的** —— 每个 renderer 开头会丢几十毫秒。
7. **全局共用一个 `AudioRendererOptions` 实例** —— 它按
   (sampleRate, channels, format) 实现了 `==`/`hashCode`;不同实例会在
   同一轨上再开一个原生 sink。
