# Lares 工作交接(2026-09-12)

> 新会话启动指南:读完本文件即可继续。单一事实源:`设计.md`(§8 架构定案、§9 实现状态)。

## 这是什么

「Lares 炉灵」语音陪伴 App(宅火的守护神，随人而动):主屏幕点一下,进入 5~20 人熟人圈的常驻语音空间。
架构:**Flutter 单代码库(iOS/Android/Windows/macOS/Web)+ LiveKit SFU + Node 信令服务**。

- 仓库:https://github.com/LFM097384/Lares (main 分支,已推送全部提交)
- v0.1.0 已发布:https://github.com/LFM097384/Lares/releases/tag/v0.1.0
- CI:`.github/workflows/ios-build.yml`,四端构建**当前全绿**(tag 或手动触发)

## 已实现(全部经过真机/e2e 验证)

一键进房(实测 Windows 0.56s / Web 1.06~1.5s,token 预取+信令 RTC 并行)、presence 大厅(未进房见「X 人在 · 名字」)、轻状态(随时聊/在忙/耳朵在)、多圈子+本地建圈、邀请深链(`lares://circle/<id>?name=X`,圈子卡片有分享图标)、敲门模式(含"未放行不连媒体"隐私门控+圈内授权)、踢人(长按头像)、语音便签(长按录 15s、听过即删、磁盘持久化)、位置共享(Snapchat 式地图,显式开关/30s 节流/出房即停)、改昵称、设置页(WiFi 高音质 48k/24k、免打扰、服务器地址覆盖、后台运行保障)、品牌图标、暗色设计系统。

**入口**:App 内点击、Android Widget(主屏 presence+深链)、Android QS Tile、桌面托盘(Win/macOS)、`lares://join` 深链、Android 主屏固定(requestPinWidget)、iOS WidgetKit 小组件(CI 已嵌入 .ipa)。

**性能/韧性**:闲时 5 分钟媒体降级(LiveKit 日志实证)、断线重连自动回房(服务端重启 12s 内 4 端自愈)、Android 前台服务保活(mic+WiFiLock)、`LARES_AUTO_JOIN` 常驻挂机模式、Lighthouse 4×100、CLS 0.00、Web WASM、弱网 3G 进房 3.3s。

**测试**:客户端 133 项 + 服务端冒烟 61 项 + 鉴权互操作 10 项 + 部署端口判定 11 项,全绿。
`cd app && flutter test` / `cd server && node test/smoke.mjs` / `node test/auth_interop.mjs` /
`bash deploy/test/port_match_test.sh`。`flutter analyze lib` 无告警。

---

## 2026-09 第二轮:8 项新需求(本轮新增,19 个提交)

> 架构决策与证据链的单一事实源:**`docs/research/DECISIONS-2026-09.md`**。
> 动录音/降噪/部署前**务必先读它** —— 里面有两条会改变做法的结论。

| # | 需求 | 状态 |
|---|---|---|
| ① | 改名「Lares 炉灵」+ 品牌叙事 + 炉火图标(六端) | ✅ |
| ② | 主圈子 + 小组件一键加入 | ✅ |
| ③ | 文字 + 图片发送(LiveKit data channel) | ✅ 核心+UI |
| ④ | 自定义服务器地址 + 验证(token / circle 双模式) | ✅ 服务端;客户端进行中 |
| ⑤ | 部署到 RackNerd(端口安全 + 三重机场保护) | ✅ 就绪,**阻塞:等域名** |
| ⑥ | 降噪 | ✅ 客户端等效方案(见下) |
| ⑦ | 自动更新(Windows / Android / macOS) | ✅ |
| ⑧ | Windows 录音 + STT + 说话人归属 | 地基已实测验证,实现中 |

### ⚠️ 两条会改变做法的结论

**1. 「服务器端降噪」在 LiveKit OSS 下不存在。** SFU 从不解码音频,只转发 Opus 包,
配置里没有任何降噪钩子(官方 issue #4029 以 `not_planned` 关闭)。唯一的服务端路径是
独立 Agent 解码→降噪→重编码,1 vCPU/1GB 上跑 5~20 路不可行。**已改为客户端等效方案。**
好消息:Krisp 的 Cloud 限制只针对 agent 侧,**客户端降噪不受限**。
真实增量其实不大 —— Android 最大那块(`MODE_IN_COMMUNICATION`)本来就已生效,
本次净增是高通滤波(默认竟是 `false`)。**Windows 拿不到 Krisp/硬件 AEC**,
设置页会如实显示「已回落到标准」,不骗用户。

**2. 录音「识别出谁说了什么」不需要声纹分离。** LiveKit 房间里每人本就是独立音轨 +
已知身份,归属是一次字典查找。**已在真实 Windows 构建上实测通过**:
两个机器人发 440/880 Hz,各自落进独立且归属正确的文件(实测 426/852 Hz,比值精确 2:1),
`sampleRate: 16000` 被真正遵守,RMS≈6929(真实波形非静音)。准确率 100%、成本 $0。
调研了十家 STT 厂商,**没有一家能可靠做 20 人单麦实时声纹分离**。

### 🔴 录音实现的三个静默失败点(不处理必出 bug)

1. **重连后 renderer 静默失效**。实测:`RoomReconnected` 后房间显示 connected,
   但帧数**精确为 0 长达 40 秒**,直到新的 `TrackSubscribed` + 重新注册才恢复。
   7 次注册里 track SID 每次都变。→ **必须由 `TrackSubscribed` 驱动注册,
   绝不跨重连缓存 `AudioTrack` 引用**;`RoomReconnected` 本身不是充分触发点。
2. **本地轨 `restartTrack()` 清空全部 renderer**(比重连更频繁)。源码逐行核实:
   `stopCapture()` 会 `_captureGroups.clear()`,而 `startCapture()` 只打日志、不恢复。
   谁调用它?**`unmute()`** —— 而本 App 默认静音进房、开关麦是主交互路径。
   **且死掉的 group 仍留在 map 里**,相同 options 再注册会 `putIfAbsent` 到同一具尸体上。
   → 看门狗必须**先用 cancel func 拆掉再重建**,天真的「再注册一次」无效。
3. **失败完全不抛异常**。原生侧解析不到轨道时只是 `return false` 加一条 warning,
   `onFrame` 从此不触发。→ 注册后 ~2s 无帧就重建,**没有错误可捕获**。

细节与其余四条坑见 `app/tool/README-audio-harness.md`(附可复跑的验证工具)。

### 主圈子(需求②)的一个值得保留的设计

**小组件点按发的是不带圈子 id 的裸 `lares://join`**,目标由 App 在进房时从
`CircleStore.primaryCircleId` 现读(`widget_service.dart:104`)。
因此小组件里的数据即使陈旧/缺失/读不出来,**最坏只会让显示文案不准,
永远不会把人带进错误的房间**。iOS 免费签名下 App Groups 可能读不到共享数据,
回落显示的是中性的「炉灵 / 点一下,进你的主圈子」而非可能过期的圈子名 —— 同理。
Android Widget、QS Tile、桌面托盘三个入口共用这同一条 `lares://join` 路径,
一致性是结构性保证的,不靠各处分别维护。

注:旧的深链处理器进的是 `LaresConfig.defaultCircleId`(编译期常量),
**完全无视用户选择** —— 本轮已改为真正 join 主圈,不是只做导航。

### 部署(需求⑤)关键约束

VPS 上 `443/tcp` 是 VLESS+Reality 主入站,`8443`/`3443`/`9721`/`2096` 亦被占用。
**旧 `deploy/docker-compose.yml` 会抢 443,照原样跑会打死用户的翻墙线路。**
现分配:`8444/tcp`(Caddy TLS)、`7881/tcp`、`7882/udp`(单端口 mux)。
`deploy.sh` 有三重机场保护(端口基线 / systemd unit / 443 主动握手),任一失败自动拆栈。
另发现旧配置**媒体路径本来就是断的**(只发布 7882/udp 却声明 port_range 50000-60000)。
TLS 必须走 **DNS-01** —— 站点写成 `domain:8444` 并不能阻止 Caddy 去试 :443 和 :80。

### 本机新坑

- **`scripts/dev.ps1` 曾选错网卡**:取「第一个非回环 IPv4」会命中 QuickFox 代理虚拟网卡
  (10.8.8.1)而非真实 WLAN(10.0.0.185),导致 LiveKit 把不可达地址写进 ICE/token ——
  **presence 一切正常、进房静默失败、零报错**。已改为优先选「有默认网关的真实物理网卡」。
- **git 推送**:schannel TLS 后端握手失败(`SEC_E_NO_CREDENTIALS`,但 TCP 到
  github.com:443 是通的),且 `~/.gitconfig` 被锁。→ 用 **`pwsh scripts/push.ps1`**
  (openssl 后端 + gh token 内联,token 不落盘)。
- `sherpa_onnx 1.13.8` 在本机构建通过(纯预编译 DLL 拷贝,不编译插件 C++,
  故 VS2019 无碍)。模型 int8 228 MB,**不打包**,走首次下载。

## 目录结构

```
Lares/
├─ 设计.md          # 产品+架构+实现状态(单一事实源)
├─ HANDOFF.md       # 本文件
├─ server/          # Node 信令+token 签发+便签 API(+Dockerfile)
│  ├─ test/smoke.mjs   # 22 项端到端冒烟
│  └─ tool/speak_bot.mjs # 说话机器人(验证说话指示)
├─ app/             # Flutter 客户端
│  ├─ lib/             # theme(state/ui/net/rtc/platform 分层清晰)
│  ├─ ios/LaresWidget/ # WidgetKit 源码 + add_widget_target.rb(CI 接入)
│  └─ tool/            # serve_web.mjs、make_icon.ps1 等
├─ deploy/          # docker-compose(Caddy+LiveKit+信令)+ ios-ci.md
└─ scripts/         # dev.ps1(一键起全栈)、fix_symlinks.ps1(必跑)、soak.ps1(浸泡)
```

## 本机环境(Windows 开发机)

- Flutter SDK:`D:\flutter`(3.47.3 stable,已入用户 PATH)
- Android SDK:`D:\Android\Sdk`(Java 21 已有;AVD 名 `lares`,启动:`D:\Android\Sdk\emulator\emulator.exe -avd lares`)
- 便携 CMake:`D:\CMake`(3.31.8);**flutter_tools 已打补丁**(`D:\flutter\packages\flutter_tools\lib\src\windows\visual_studio.dart` 的 cmakePath 优先用便携版——重装 Flutter SDK 需重打)
- **每次 `flutter pub get` 后必须跑**:`pwsh scripts/fix_symlinks.ps1`(目录 Junction 预建插件链接,绕过开发者模式限制)
- 本机全栈:`pwsh scripts/dev.ps1`(自动探测局域网 IP 起 LiveKit+信令+Web)

## 本机联调(局域网)

```powershell
pwsh scripts/dev.ps1   # 起全栈,浏览器开 http://127.0.0.1:8080
# 模拟器/真机:APK 构建时传 --dart-define=LARES_SIGNALING=ws://<当前LAN IP>:8787
```

**血泪教训**:换 WiFi/DHCP 换 IP 后,LiveKit `--node-ip`、信令 `LIVEKIT_URL`、APK 内置地址三处同时失效(presence 在但进房失败)——用 dev.ps1 重启全栈 + 按当前 IP 重建 APK;或在 App 设置页「服务器地址」直接改(免重打包)。

## CI(GitHub Actions)

- 触发:手动 Run 或打 tag(`git tag v0.x.x && git push origin v0.x.x`)
- 产物:iOS unsigned .ipa(含 LaresWidget 扩展)、macOS .app、Android split-abi APK、Windows exe zip
- 仓库 Variables:`LARES_SIGNALING`(当前=ws://10.0.0.185:8787,本机联调用;公网后改 wss 地址)
- iOS Widget 接入:`app/ios/add_widget_target.rb`(xcodeproj gem 幂等脚本,CI 自动跑;要求 iOS 17+)

## iPhone 真机侧载(无需 Mac)

1. CI 下载 `lares-ios-unsigned` artifact → .ipa(本地存了一份在 `D:\Projects\Lares\dist\lares_app.ipa`,可能已旧,以 CI 最新为准)
2. Windows 装 Sideloadly → iPhone 数据线连电脑信任 → 拖入 .ipa → 输 Apple ID(双重认证需 App 专用密码)→ 设置→通用→VPN与设备管理→信任
3. 免费签名 7 天有效,到期重签;长期用 $99 开发者账号走 TestFlight(配置表在 deploy/ios-ci.md)
4. 局域网测试:iPhone 与电脑同 WiFi;App 设置页可改服务器地址
5. 小组件:长按主屏幕→+→搜「炉灵」(免费签名的 App Groups 数据共享可能受限,最坏显示默认文案)

## 已知坑位(都踩过,别再踩)

- **不要全局加 `/await`**(windows/CMakeLists.txt):与 geolocator_windows 的 `/await:strict` 互斥(D8016)。`/utf-8` 保留(中文代码页必需)
- `kotlin.incremental=false`(android/gradle.properties):本机 Kotlin 增量缓存 mmap 冲突
- `home_widget` 锁 0.7.x:0.8 依赖 glance-alpha 需要未发布的 compileSdk 37
- livekit `--dev` 只绑回环:必须 `--bind 0.0.0.0 --node-ip <LAN IP>`
- connectivity_plus 7.3.1 需要 macOS/iOS 26 SDK:CI 必须用 `macos-26` runner
- geolocator_web 与 WASM 不兼容:Web 端走 `location_share_stub.dart`(位置共享仅原生端)
- media_kit 已改惰性初始化(首次播放时):启动期异常不影响 App;播放库选 media_kit 是因为 audioplayers 需 VS2022(本机只有 VS2019)
- 静态托管缓存:应用产物(html/js/mjs/wasm)必须 no-cache,长缓存只给 canvaskit/字体——否则换包不刷新(白屏排查半天)
- Flutter Web Service Worker 会缓存旧 shell:白屏先开全新浏览器上下文验证
- `flutter pub add` 会重写 pubspec.yaml 格式,编辑前重新 read
- **`Sink` 是 interface class**:Dart 3 里只能 `implements` 不能 `extends`(编译级 error)
- **`library;` 必须在所有指令之前**:写长文档注释时容易把它挤到 import 之后 → `library_directive_not_first`
- **`voiceIsolation` 字段是死的**(livekit_client 2.12.0):`options.dart:439` 发出的是
  `{'voiceIsolation': noiseSuppression}`,读错了字段。设它无效(疑似上游 bug)
- **Web + 非空 `deviceId` 会静默丢弃全部音频 DSP 约束**(`options.dart:434` 的守卫)
- **`setAudioSessionOptions()` 有副作用**:会切到 manual 模式,之后 LiveKit 不再按房间
  生命周期管理会话 —— 天真调用反而**退化**现有行为。须紧接着 `setAudioSessionManagementMode(automatic)`
- **LiveKit mux 判定顺序与官方文档相反**:源码先看端口段,只要 `port_range_*` 存在,
  单端口 `udp_port` 就被**静默忽略**
- **`publishData` 不做长度校验**:超 15000 字节只在 SCTP 层静默失败,须自己守住
  (`kStreamChunkSize` 见 `lib/src/types/data_stream.dart:10`)
- **文字长度按字素簇计**,不能用 `String.length`(UTF-16 code unit 会把 👨‍👩‍👧‍👦 拦腰截断)

## 待办(按优先级)

1. **域名 → 上线**(唯一阻塞项):买域名 + A 记录指向 `23.94.115.25` →
   `cd deploy && ./preflight.sh && ./deploy.sh`。浏览器与 iOS 都要求 wss,裸 IP 签不出证书。
2. **收尾需求⑧**:录音 + STT 接线与同意 UI(地基已实测验证,坑位见上)
3. **iPhone 真机验证**:踢人/位置共享/后台保活/小组件数据共享(免费签名 App Groups 待确认)
4. **真机验证降噪/主圈子**:Android 硬件 AEC 听感、小组件刷新 —— 目前只有静态与编译层保证
5. **TestFlight 签名**:$99 开发者账号后按 deploy/ios-ci.md 配 secrets
6. iOS Widget 深化:App Intents 可交互小组件(iOS 17+ 可不跳 App 直接进房)
7. 浸泡测试长期挂机数据(scripts/soak.ps1 → soak.log)
8. 桌面快捷方式 `~/Desktop/一键进圈.lnk` 需手动改名(沙箱外且无生成脚本)

## 快速恢复上下文(新会话第一句话)

> 「继续 Lares 项目:读 D:\Projects\Lares\HANDOFF.md 和 设计.md §9,仓库 github.com/LFM097384/Lares,我要做<某件事>」
