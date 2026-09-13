# Lares 新需求架构决策记录（2026-09）

> 本轮 8 项新需求的技术调研结论与架构定案。调研证据详见同目录其他文件。
> 状态：调研已闭环，实现分批进行中。

## 需求清单与状态

| # | 需求 | 结论 | 状态 |
|---|---|---|---|
| 1 | 应用改名「Lares 炉灵」 | 直接实施 | 进行中 |
| 2 | 主圈子 + 小组件一键加入 | 直接实施 | 进行中 |
| 3 | 文字 + 图片发送 | LiveKit data channel（已为 token 加 `canPublishData`） | 待实施 |
| 4 | 自定义服务器地址 + 验证方式 | HMAC 挑战/响应，两模式：`token` / `circle` | 进行中 |
| 5 | 部署到 RackNerd | **双栈并行**（自托管 + LiveKit Cloud，设置页可切） | 阻塞：等域名 |
| 6 | 服务器端降噪 | ⚠️ **需求不可直接满足**，改为客户端等效方案 | 待实施 |
| 7 | 自动更新 | Windows + Android APK 内更新 + macOS | 待实施 |
| 8 | Windows 录音 + STT + 说话人归属 | 逐轨 PCM 捕获，**不用 ML 声纹分离** | спайк验证中 |

---

## ⚠️ 决策 6：「服务器端降噪」在本架构下不存在

**这是本轮最重要的发现，需求本身需要修正。**

两条独立理由：

1. **LiveKit OSS SFU 从不解码音频** —— 它只转发 Opus RTP 包。完整 `config-sample.yaml` 中唯一的音频相关键是
   `audio.active_level` / `min_percentile` / `update_interval` / `smooth_intervals` / `active_red_encoding`
   以及 `room.enabled_codecs`。**没有任何 APM / 降噪 / 滤波钩子。**
   官方 issue [livekit/livekit#4029](https://github.com/livekit/livekit/issues/4029)
   问的正是「自托管怎么开降噪」，被以 `not_planned` 关闭，答复是「前端开启增强降噪才是正确做法」。

2. **唯一的服务端路径是 LiveKit Agent**（独立进程订阅轨道 → 解码 Opus → 降噪 → 重新编码发布）。
   在 1 vCPU / 1 GB 的 RackNerd 上跑 5~20 路常驻音频不可行：每个 ONNX runtime 约 50 MB RSS，
   外加每人一个有状态 LSTM + 一对 Opus 编解码器。还会让端到端延迟翻倍
   （client → SFU → agent → SFU → clients），并丢掉 SFU 的 simulcast / DTX 透传。

### 对前提的重要修正

Krisp 的 **Cloud 限制只针对 agent 侧的增强模型**（VIVA / BVC）。
**客户端 track processor 不受 Cloud 限制** —— 官方文档把它们列在 "Frontend" 下，无 license key 参数，
[Flutter API](https://pub.dev/documentation/livekit_noise_filter/latest/livekit_noise_filter/LiveKitNoiseFilter-class.html)
也不接受任何 key。**所以 Krisp NC 能用，只是在客户端。**

### 落地方案（按性价比排序，全部零服务器 CPU）

| # | 手段 | 效果 | 成本 | 备注 |
|---|---|---|---|---|
| 1 | `AudioCaptureOptions` 里 `highPassFilter: true` | 中 | ~1 行 | **默认是 `false`**，白捡 |
| 2 | 原生音频会话调优（Android `MODE_IN_COMMUNICATION`） | 中 | ~20 行 | 激活安卓硬件 AEC/NS，实机收益最大 |
| 3 | `livekit_noise_filter`（Krisp NC） | **高** | ~5 行 | iOS/Android/macOS(/Web?)，`isSupported()` 门控 |
| 4 | 客户端 VAD 门控 / 按键说话 | 高 | 低 | **常驻房间场景收益超过任何降噪器** |
| ✗ | Agent + DTLN/RNNoise 服务端 | 高 | **1C/1G 上不可行** | 否决 |

**已验证的 API 事实**（`livekit_client` 2.12.0 源码）：
`noiseSuppression` / `echoCancellation` / `autoGainControl` 默认已是 `true`，
但 **`highPassFilter` 默认 `false`**。另有 `voiceIsolation`、`typingNoiseDetection`、
以及实验性的 `noiseSuppressionMode: AudioProcessingMode{automatic|platform|software}`。

**坑**：若 `Native.bypassVoiceProcessing` 为 true，上述所有约束会被**强制写成 `false`**。

**未验证（需实测）**：`livekit_noise_filter` 依赖 `http` 且 `onPublish(Room)` 收到 Room，
无法排除它对自托管 SFU 发起 entitlement/遥测调用（其仓库路径 404，读不到源码）。
**上线前必须对 `--dev` 服务器实测。** 另：pub.dev 平台标签说仅 Android/iOS/macOS，
但 changelog 说 0.2.0 加了 Web 支持 —— 两处矛盾。Windows 不支持（只能吃 WebRTC APM）。

**许可风险**：Flutter wrapper 是 Apache-2.0，但捆绑的 `krisp-noise-filter-core` 二进制几乎肯定不是；
Web 版同类包明确写 proprietary。商业发布前需法务确认。

---

## 决策 8：Windows 录音 —— 逐轨 PCM，不用声纹分离

**核心洞察：这不是一个 ML 问题。** 因为是 LiveKit 房间，每个远端参与者本来就是
一条独立音频轨 + 已知 `participant.identity`。说话人归属退化为一次字典查找。

### 已验证的 API（读 SDK 源码，非文档）

```dart
CancelListenFunc addAudioRenderer({
  required AudioFrameCallback onFrame,
  AudioRendererOptions options = const AudioRendererOptions(),
});
// AudioFrame { int sampleRate, int channels, Uint8List data, AudioFormat format }
```
定义在 `mixin AudioTrack on Track`，故 `RemoteAudioTrack` / `LocalAudioTrack` 都有。

**Windows 确实有实现**（这是最关键的风险点）：
- `windows/livekit_plugin.cpp` 用 `class AudioRendererSink : public libwebrtc::AudioTrackSink`
  处理 `startAudioRenderer`/`stopAudioRenderer`，走 EventChannel `io.livekit.audio.renderer/channel-<id>`
- `windows/CMakeLists.txt` 编译 `../shared_cpp/audio_renderer.cpp`，内含真实重采样 + int16/float32 转换
- CHANGELOG 2.9.0：「Audio frame capture on Linux/Windows」
- ⚠️ `audio_frame_capture_native.dart` 的文档注释说「iOS/Android/macOS」——**过期文本**，与出货的 C++ 矛盾

版本前提已核对：`pubspec.lock` 锁定 `livekit_client 2.12.0` + `flutter_webrtc 1.6.0`（无 caret）。
2.12.0 要求 Flutter ≥3.38 / Dart ≥3.10；本机 Flutter 3.47.3 满足
（注意 `pubspec.yaml` 仍声明 `sdk: ">=3.8.0 <4.0.0"`，名义下限偏低但实际工具链没问题）。

### 🔴 实现前必须知道的三个坑

1. **只在进房时注册一次 → 重连后静默失效。**
   `_AudioCaptureGroup` 在构造时捕获 rtc track 引用，而 `Track.updateMediaStreamAndTrack()`
   会在重连/重发布时把它换掉。**注册过的 renderer 会悄无声息地死掉，且不报错。**
   → 必须由 `TrackSubscribedEvent` 驱动注册，并在 `RoomReconnectedEvent` 后重新注册。
   **Lares 是常驻应用，重连是常态而非边缘情况 —— 这是本节最要紧的一行。**
2. **监听器挂上之前的帧是丢弃而非缓冲的。** `livekit_plugin.cpp` 原话：
   `// live audio must not be queued while no subscriber is attached — drop the frame instead.`
   每个 renderer 开头会丢几十毫秒。
3. **全局共用一个 `AudioRendererOptions` 实例。** 它按 (sampleRate, channels, format) 实现了
   `==`/`hashCode`：相同 options 共享一条原生管道，不同 options 会在同一轨上再开一个原生 sink。

另：`stopCapture()` 已接入 `Track.stop()`，取消订阅时自动拆除。

### 死路（别浪费时间）

- **`TranscriptionEvent` 事实上已废弃**；现路径是 `room.registerTextStreamHandler('lk.transcription', ...)`。
  但**两者都是只收不发**，承载的是服务端 agent 产生的 STT。纯人类房间里没有 agent，
  客户端在这两个通道上什么都收不到。→ 证实 STT 必须自己在 PCM 上做。
- **`whisper.cpp --diarize` 不是声纹分离**：`examples/cli/cli.cpp` 里
  `estimate_diarization_speaker()` 只比较左右声道能量（`energy0 > 1.1*energy1`），
  且所有调用点都门控在 `pcmf32s.size() == 2`。单声道输入 → 什么都没有，最多 2 人。
  `-tdrz` 给的是话轮边界，不是身份。
- **pyannote 双重 gating 已确认**：需接受 pipeline + `segmentation-3.0` 两个门 + HF token。
  发给终端用户不可行。**sherpa-onnx 完全绕开此问题**（预转换 ONNX 权重走 GitHub release 直下）。
- **`whisper_dart` 在 pub.dev 不存在**（404）。`whisper_flutter_new` 双重不合格：无 Windows + GPL-3.0 传染 + 停更。
- **pub.dev 上没有任何 whisper 包做真正的声纹分离。**
- **Meetily** 已更名 `Zackriya-Solutions/meetily`（Rust/Tauri）：GitHub 简介宣传声纹分离，
  但 README 自己否认（PRO-only / "Coming Soon" / 不同代码库），其 backend 是**已归档**的 legacy 组件。别 fork。

### 选定依赖

```yaml
livekit_client: ^2.12.0   # 已有
sherpa_onnx: ^1.13.8      # ASR + VAD，Apache-2.0，Windows federated 插件 ffiPlugin: true
http: ^1.2.0              # 已有 —— 云端 STT 后端
```
模型：`sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17`（中英，契合中文 UI）+ `silero_vad.onnx`。
sherpa-onnx：14.7k★，Apache-2.0，2026-09 仍活跃。
⚠️ 缺口：`flutter-examples/` 没有 diarization 示例（只有 asr/vad/tts/punctuation），Flutter 接线要留预算。
⚠️ 若将来真要用 diarization，用 `sherpa-onnx-pyannote-segmentation-3-0`，
**不要用 `sherpa-onnx-reverb-diarization-v1`（非商用许可）**。

### 抽象设计（能力导向，非厂商导向）

```dart
abstract class SttBackend {
  bool get supportsDiarization;
  bool get supportsStreaming;
  Stream<TranscriptSegment> transcribe(AudioSource src);
}
```
两种模式：`PerTrackBackend`（归属来自轨道身份）与 `DiarizingBackend`（归属来自厂商）。
这样 Groq 逐轨与 Deepgram 分离能共存，且能在 2027-02 前摘掉 OpenAI 而不动调用点。

### 云端 STT 备选（可配置需求）

| 方案 | $/小时 | 分离 | 流式 | 备注 |
|---|---|---|---|---|
| **本地 sherpa_onnx** | **$0** | 逐轨免费 | 是 | **首选** |
| Cloudflare Whisper | $0.03 | 逐轨无需 | 否 | 最便宜，~4 免费音频小时/天 |
| Groq whisper-large-v3-turbo | $0.04 | 逐轨无需 | 否 | ⚠️ **10 秒最低计费**，分块需 ≥10s |
| AssemblyAI U-2 async + diarize | $0.17 | 是 | 否 | 最便宜的分离方案 |
| Deepgram nova-3 batch | $0.26 | 是（免费） | 否 | 用 `diarize_model`，**别用已废弃的 `diarize=true`** |
| Speechmatics RT | $0.24 | 声称全档含 | 是 | ⚠️ WS 协议未核实，选用前先花 20 分钟读文档 |
| Deepgram nova-3 streaming | $0.58 正常价 | 是（v1 only） | 是 | **按音频秒计费**（非墙钟），常驻场景正确 |
| Azure Fast Transcription | $0.36 | 是 | 否 | **≤2 声道，开分离时连 2 声道都不行** → 服务不了逐轨 |
| OpenAI gpt-4o-transcribe-diarize | $0.36 | 是 | 否 | ❌ **2027-02-26 下线**，且仅 4 人上限 |
| Azure real-time | $1.00 | SDK-only | 是 | ❌ 无 Dart SDK，无 WS 协议规范 |
| Google STT v2 | 未核实 | 部分 | 仅 gRPC | ❌ gRPC + OAuth2 JWT，Dart 最差；Web 端硬阻塞 |

**成本陷阱**：多声道在所有厂商都按声道计费。20 轨 Deepgram batch = **$5.20/小时**，
而 20× Groq 逐轨 = **$0.80/小时**，便宜 6.5 倍**且不需要分离**。
Deepgram 官方文档自己说：一声道一人时所有人都返回 `speaker: 0`，「分离没有用」——**厂商替我们确认了架构判断**。

**AssemblyAI 流式按墙钟计费**（含静音），未关闭的会话在 3 小时上限时按满 3 小时收费，
其文档称这是「最常见的意外账单来源」。**对常驻房间是完全错误的计费模型。**

**十家厂商调研的共同结论**：没有任何一家能可靠做 20 人单麦实时声纹分离
（Google chirp_2 根本不支持；chirp_3 / ElevenLabs Realtime 仅批量；
AssemblyAI 流式上限 10 人；OpenAI 注册上限 4 人；Azure 单声道且已下线多声道分离）。
**逐轨归属不只是更好的选择 —— 对 5~20 人常驻房间是唯一真正可行的方案，同时最便宜、最准确。**

### 兜底方案（若逐轨捕获实测失败）

自托管 Egress track egress → WS 原始 PCM：
- ⚠️ **二进制帧 = 音频，文本帧 = JSON 静音事件** —— 必须按帧类型分支，否则会把 JSON 喂给解码器
- ⚠️ **Egress 仅 Linux/Docker**（Dockerfile 硬编码 `GOOS=linux`，需 Redis + `--cap-add=SYS_ADMIN`）
- ⚠️ track egress 的 `EgressInfo` **不含发布者身份**，官方 workaround 是把身份塞进 WS URL
- ⚠️ 原始流有 **12 小时硬上限** → 常驻房间从第一天就要做 `egress_ended` 轮转
- ⚠️ 未预算风险：~5.76 MB/分钟/轨 × 20 ≈ **166 GB/天**
- 更好的服务端兜底是 **Python LiveKit Agent**（官方 `examples/other/transcription/multi-user-transcriber.py`
  正是多人场景，且 agent 转写自带被转写者身份 → 归属免费）。Python 而非 Node：~30 个 STT 插件 vs ~10。
- `livekit_server_sdk`（pub.dev 1.0.1）虽存在但已废弃且**无 EgressService**。
  **token 签发继续留在 Node 服务端 —— API secret 是项目级主密钥，绝不能进桌面二进制。**

### 实现前的门槛（½ 天 спайк）

1. 真实 Windows 构建上挂 renderer，dump 10 秒 WAV，确认可听 + `sampleRate: 16000` 被遵守
2. 确认 renderer 在强制重连后重新注册可恢复
3. **同意 UI 是阻塞项，不是锦上添花** —— 常驻房间录音涉及伦理与法律

⚠️ 未验证：20 路并发 renderer 的 CPU/GC（每帧跨 EventChannel 进 Dart isolate）。
缓解：只为当前活跃说话者挂 renderer。

---

## 决策 4/5：部署与验证

**部署阻塞项**：浏览器要求 WSS（安全上下文才给麦克风），iOS ATS 同理 —— 裸 IP 签不出证书。
用户决定自行购买域名，届时 Caddy 走 ACME 自动签。

**RackNerd 端口现状（`D:\Projects\racknerd-vps\README.md`）—— 冲突已确认**：

| 端口 | 现有占用 | 影响 |
|---|---|---|
| 443/tcp | **VLESS+Reality 主入站**（伪装 www.apple.com） | ❌ 现成 `deploy/docker-compose.yml` 想让 Caddy 占 443，**会打死代理** |
| 8443/tcp | Reality 次入站 seattle-low | ❌ 不可用 |
| 3443/udp | Hysteria2（移动专用） | ❌ 不可用 |
| 9721/tcp | 3x-ui 面板 | ❌ 不可用 |
| 2096/tcp | 订阅 | ❌ 不可用 |
| 22/tcp | SSH（fail2ban 在跑） | 勿动 |
| 80/tcp | 疑似空闲（未核实） | 可用于 ACME HTTP-01 |

**硬约束**：
- 现有 `deploy/docker-compose.yml` 的 Caddy `80:80` + `443:443` **必须改**，否则打死用户代理
- 机器只有 1 vCPU / 1 GB，与 xray 共享；Docker 开销需计入预算
- UDP 媒体端口段默认 `50000-60000`（10001 个）对 ≤20 人是荒谬的过量，会让 conntrack 膨胀 → 收紧
- **不得改动 xray / 3x-ui 配置**；需带回滚
- 用户在国内，Seattle 190ms；移动 CMI 对该 IP 段有时段性 TCP QoS（已知问题，用户改用联通）

### 旧 deploy 配置中发现的 8 个问题（不止 443 冲突）

1. **`443:443` 会打死 Reality 主入站** —— 已知，本轮的起因。
2. **媒体路径本来就是断的**（独立于 443 冲突）：compose 只发布了 `7882/udp`，
   而 livekit.yaml 却声明 `port_range_start: 50000 / port_range_end: 60000`。
   LiveKit 会在 50000-60000 里分配端口，而那个段**从未被发布** → 公网上媒体根本连不通。
   已用 `git show 05a1873:deploy/docker-compose.yml` 核实属实。
3. **`80:80`** —— 80 端口的「空闲」状态从未被核实过。
4. **鉴权默认全开**：服务端默认 `LARES_AUTH_MODE=none`，而旧 compose 一个鉴权变量都没传
   → 公网上完全开放。现改为 `${LARES_AUTH_MODE:?}`（缺则拒绝启动）。
5. **无内存上限** —— 任何泄漏都可能 OOM-kill 掉 xray。现每容器设 `mem_limit`，合计硬顶 480MB。
6. **无日志轮转** —— json-file 默认无上限，写满 20GB 会把机场一起拖死。现 `max-size:10m, max-file:3`。
7. **TURN 配置根本起不来**：`tls_port>0` 要求 `turn.domain` 有效（否则进程直接退出），
   且 `external_tls:false` 要求提供证书文件 —— 两者都没满足。现默认关闭。
8. **`LIVEKIT_PUBLIC_URL` 不带端口** → 客户端会默认走 443，即机场的端口。preflight 已专门检查。

### 两个反直觉但已核实的坑

- **LiveKit 的 mux 判定顺序与官方文档相反**：源码 `webrtc_config.go` **先检查端口段**，
  `udp_port` 在一个不可达的 `else if` 里。**只要 `port_range_*` 存在，单端口 mux 就被静默忽略。**
  → 新配置完全不写这两个键，并由 `tools/verify_compose.py` 断言。
- **站点写成 `domain:8444` 并不能把 ACME 限制在 8444**：Caddy 仍会尝试 **:443** 的 TLS-ALPN-01
  和 **:80** 的 HTTP-01；`auto_https disable_redirects` **不会**释放 :80（只有 `auto_https off` 会）。
  **只有 DNS-01 才会禁用其他挑战方式** —— 这是本场景必须用 DNS-01 的原因，而非「顺便用」。

### UDP 端口数测算

旧配置 10001 个端口。端口段模式下 LiveKit **每参与者 2 个 UDP 端口**（publisher + subscriber
PeerConnection；轨道是 bundle 的）。20 人 × 2 = 40，含重连 churn ×2 = 80，保守取整 **200**
—— 即便用端口段也只需 200（减少 98%）。**最终选单端口 mux**：官方建议 mux 端口数 ≥ vCPU 数，
本机 1 vCPU → 1 即推荐值。收益：每客户端 1 条 conntrack 而非 2 条、一条防火墙规则、1 个端口攻击面。

### 内存预算（1 GB，约 960MB 可用）

稳态合计 **505MB**（系统 90 / xray 35 / 3x-ui 40 / fail2ban 25 / dockerd+containerd 110 /
shim 30 / LiveKit 90 / Node 55 / Caddy 30），余 ~455MB 舒适。
**但全部峰值叠加 796MB，只剩 ~164MB，偏紧。** 缓解：`mem_limit` 合计硬顶 480MB
（确保泄漏时死的是 Lares 而非机场）+ **建议加 1GB swap**。

**Docker vs systemd**：Docker 固定开销 ~140MB = 总内存 14% = xray 稳态 RSS 的 4 倍，
在这台机器上**不可忽略**。若只跑 Lares 应直接用 systemd。compose 保持为主是因为：
(a) 既有资产；(b) `mem_limit` 本身就是护住机场的机制；(c) 加 swap 后不再是生存问题。
systemd unit 已一并提供且完整。**真正的解法是拓扑 A（媒体走 LiveKit Cloud）** —— 本机降到 ~85MB。

### 端口判定的回归测试

整个安全设计压在「端口是否仍在监听」的 awk 判定上 —— 误判会导致 deploy.sh 拆掉健康的栈，
或漏报真实故障。`deploy/test/port_match_test.sh` 用真实 `ss` 输出形态驱动，11 项全过：
`0.0.0.0:443` / `[::]:443` / `*:443` / `[::1]:443` / `[::ffff:127.0.0.1]:443`、
后缀陷阱（18443 不被误判成 443/8443）、多行命中、空输入、baseline 归一化（IPv6+UDP 正确且不误收 sshd）。

已复核 `set -euo pipefail` 相关风险，均安全：三脚本的 `set -euo pipefail` 都在；
唯一的裸 `grep` 在 `if` 条件里（`set -e` 不作用）；无管道喂 `while read`；无 `local x=$(cmd)` 掩盖退出码。

**用户决定：双栈并行**（自托管 + LiveKit Cloud 免费档），设置页可切 —— 正好契合需求 ④「自定义服务器地址」。
Cloud 走全球边缘节点，对国内用户延迟更优且不让语音流量经过代理机；自托管满足隐私偏好。

**验证方案（用户已定：支持 ①②，不做 ③账号体系）**：
HMAC 挑战/响应，原始密钥不上线：
- `token` 模式：`proof = HMAC_SHA256(key=LARES_AUTH_TOKEN, msg=nonce + ':' + userId)`
- `circle` 模式：`proof = HMAC_SHA256(key=passcode, msg=nonce + ':' + userId + ':' + circleId)`
- nonce 单次有效、60 秒过期；`crypto.timingSafeEqual` 比较（先校验长度，否则会抛）
- 仅用 Node 内置 `node:crypto`（服务端只有 `ws` + `livekit-server-sdk` 两个依赖，
  且 1 核机器上编译 argon2 原生模块不划算 → 不加依赖）
- 失败关闭码 4401（可区分于网络掉线 → 客户端弹密码框而非无脑重连）；限流 4429
- 已发现并需修复的越权：`knock_mode_set` 目前**任何人**都能给空圈设 `knockRequired`；
  `token_prefetch` 接受任意 circleId（真实签 token → 绕过 circle 模式作用域）

**安全提醒（已告知用户，用户接受）**：这台 VPS 的全部价值在于「不引人注意」。
再开一个公网 TLS 服务 + UDP 媒体端口会增加扫描暴露面。
→ 这是把媒体放 LiveKit Cloud 的最强理由，也是双栈方案的由来。

---

## 需求 3：文字 + 图片

走 LiveKit data channel（已在 token grant 加 `canPublishData: true`）。
注意 `设计.md` §2.3 原本明确「不做文字聊天」以免稀释「一键进圈」核心心智 ——
本轮属**用户明确要求的方向调整**，实现时应保持语音为第一公民，文字/图片为辅助。
