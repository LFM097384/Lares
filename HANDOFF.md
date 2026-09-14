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
| ③ | 文字 + 图片发送(LiveKit data channel) | ✅ 含选图(file_selector) |
| ④ | 自定义服务器地址 + 验证(token / circle 双模式) | ✅ 含设置页与「测试连接」 |
| ⑤ | 部署到 RackNerd(端口安全 + 三重机场保护) | ✅ 就绪,**阻塞:等域名** |
| ⑥ | 降噪 | ✅ 客户端等效方案(见下) |
| ⑦ | 自动更新(Windows / Android / macOS) | ✅ |
| ⑧ | Windows 录音 + STT + 说话人归属 | ✅ 完成但**整体隐藏**(LARES_RECORDING 默认 false)|

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
- **`WebSocketChannel.ready` 的失败是异步抛出的**:不显式接住会让一次普通的
  「连不上」升级成未捕获异常崩溃。域名写错/端口没开必现 —— 生产 URL 是非标端口
  `wss://host:8444/ws`,这条几乎注定会被触发。已在 `signaling_client.dart` 与
  `connection_test.dart` 修掉(由真实联调测试打在无人监听端口上炸出来的)。

## 🔐 上线后优先处理(安全)

**当前凭据是长期有效的共享密钥,存在 `shared_preferences` 里 —— 四端全明文**
(Android XML / iOS plist / Windows 本地文件 / Web localStorage)。
代码注释与设置页均已如实标注,`AuthCredential.toString()` 永不输出明文(有测试钉住)。

按性价比排序的改进建议:

1. **服务端签发短期 token(如 24h)+ 本地只存刷新凭据** —— 这比加密存储更治本:
   加密只是提高读取门槛,短期化直接限制了泄露后的价值。
   本仓库已有先例:LiveKit token 本来就是 2h TTL,是**鉴权共享密钥**目前还是长期的。
2. 其次才是 `flutter_secure_storage`(Keychain / Keystore / DPAPI)。迁移面很小 ——
   `SettingsStore` 已把凭据读取收敛到 `credentialFor()` 一个出口。
3. **Web 端考虑干脆不持久化口令**(每次会话手输):localStorage 在 XSS 面前没有防御。

威胁模型上讲句公道话:目标是 5~20 人熟人圈、设备是自己的。明文在此场景下不是致命缺陷,
但「共用电脑」与「Web 端 XSS」是两个真实的口子。

## 📋 部署上线后的验证清单(按优先级)

域名到手、真实 `wss://` 跑起来后依次确认:

1. **移动端真实休眠 / 切网 —— 第一优先,理由见下**
   4401 的「只重试一次」设计前提是「休眠导致 nonce 过期」。**这是代码里唯一一处
   建立在无法测试的假设之上的逻辑。** 若该假设在真实世界不成立(唤醒后连续两次失败),
   客户端会**永久停止重连**并落入 `AuthPhase.failed` —— 用户拿着完全正确的口令,
   却看到「口令不对,进不去」,且**不重启 App 就不会自愈**。
   这是一个静默且会误导用户的失败,直接打在「常驻陪伴」这个核心承诺上,
   而且只在真机用了几小时后才出现。

   > 为什么不是把 TLS 排第一:TLS 是**闸门**不是**风险** —— 证书错了第一次连接就
   > 响亮地失败,没人可能不小心带着它上线。清单的价值与「被静默漏掉的概率」成正比。

   **复现步骤(很便宜)**:进房 → 锁屏 → 放置 30 分钟以上(远超 60s nonce TTL,
   且进入 Android Doze)→ WiFi 切蜂窝 → 唤醒。观察是否自行恢复,记录 `AuthPhase` 变迁。
   失败特征:凭据正确却停在 `failed`。

   **若确认失败,修法很小**:把重试改为**按时间**而非按次数限流 ——
   「每 N 分钟允许一次」而不是「一共只允许一次」。既保住防 4429 的性质,
   又消掉永久锁死的尾部风险。
2. **真实 TLS 证书链 / SNI**:联调测试走的是 `ws://127.0.0.1`,证书行为(尤其
   Android 对用户 CA 的限制)未验证;`briefNetworkError()` 的证书提示文案是按异常文本猜的。
3. **非标端口 8444 穿越真实网络**:URL 解析有测试,但企业防火墙/运营商放行情况未知。
4. **进房延迟 ≤1.5s 实测**:握手多了一次 challenge 往返,但发生在启动期而非进房时,
   理论上不影响 —— 真机数字没测过,确认一次 `controller.lastJoinLatency`。
5. **4429 真实触发**:联调没真去打满 10 次失败(会污染服务端限流表),
   60s 退避分支只在假通道里验过。
6. **CJK 输入法**:Enter 是否在候选词选择中途误发。`flutter test` 测不了,
   中文用户群下这条很重要,需真机 Windows/Android 输入法实测。

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

### `flutter_secure_storage` 的 Windows 端需要 VS 的 ATL 组件

`flutter_secure_storage_windows_plugin.cpp` 要 `atlstr.h`。
本机 VS2019 默认**不装** ATL/MFC,表现是:

- `flutter analyze` 零告警 ✅
- `flutter test` 全绿 ✅
- `flutter build windows` **fatal error C1083: 无法打开 atlstr.h** ❌

解决:Visual Studio Installer → 修改 → 勾 ATL(约 200MB)。

⚠️ **版本必须与实际构建用的 MSVC 工具集匹配**,这里踩过一次:
第一次装了列表里的「C++ v14.20 ATL for v142」,ATL 落在
`VC\Tools\MSVC\14.20.27508\atlmfc\`,而构建用的是 **14.29** ——
`atlstr.h` 明明躺在磁盘上,编译器依旧报 C1083。

先查本机装了哪些工具集、各自有没有 ATL:

```powershell
Get-ChildItem "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Tools\MSVC" -Directory |
  ForEach-Object { "$($_.Name): $(if (Test-Path "$($_.FullName)\atlmfc\include\atlstr.h") { 'ATL 有' } else { 'ATL 无' })" }
```

构建取**版本号最高**的那个,它必须有 ATL。在 Installer 的「单个组件」页
搜 `ATL`,勾**不带版本号后缀**(标「最新」)的那一项最稳妥。

### `LNK1104: 无法打开文件 lares_app.exe`

会伪装成上面那个问题,但它**不是缺组件** —— 是**上一个构建还在运行**
占着文件,桌面快捷方式启动的实例最常见。

```powershell
Stop-Process -Name lares_app -Force
```

> **CI 不受影响**:`windows-latest` runner 自带完整 VS 含 ATL。
> 以上两条纯粹是本机环境问题,别误以为是依赖选错了。

同类教训:analyze 和 test 都不碰原生编译,**加了带原生代码的插件之后
必须真的跑一次 `flutter build`**。此前 sherpa_onnx 也是这一类。

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

1. **域名 → 上线**(唯一阻塞项)。
   **进行中**:用户已申请 `laresproject.eu.org`,待批复。
   NS 已指向 Cloudflare:`kate.ns.cloudflare.com` / `pete.ns.cloudflare.com`。

   > Cloudflare 托管 DNS 正是我们需要的:部署默认走 **DNS-01**,零入站端口。
   > 这不是图省事 —— 站点即使写成 `domain:8444`,Caddy 仍会去试 :443 和 :80,
   > 而 **443 是用户 Reality 主入站**。只有 DNS-01 能真正禁用其他挑战方式。

   批复后需要的东西:
   - Cloudflare API Token,权限 `Zone.Zone:Read` + `Zone.DNS:Edit`
   - A 记录指向 `23.94.115.25`
   - 建议先用 Let's Encrypt **staging** 跑一次,避免撞速率限制
   - 带 DNS 插件的 Caddy 镜像**在本地构建后 `docker save`/`scp`/`docker load`**,
     不要在 VPS 上编译(会跟 xray 抢内存)

   然后:`cd deploy && ./preflight.sh && ./deploy.sh`
2. **收尾需求⑧**:录音 + STT 接线与同意 UI(地基已实测验证,坑位见上)
3. **iPhone 真机验证**:踢人/位置共享/后台保活/小组件数据共享(免费签名 App Groups 待确认)
4. **真机验证降噪/主圈子**:Android 硬件 AEC 听感、小组件刷新 —— 目前只有静态与编译层保证
5. **TestFlight 签名**:$99 开发者账号后按 deploy/ios-ci.md 配 secrets
   ⚠️ **账号注册是全流程唯一的长周期项**(个人账号审批数天~两周,中国大陆
   开发者可能要额外身份验证)。用户**尚未注册**,应最先启动,与开发并行。
6. iOS Widget 深化:App Intents 可交互小组件(iOS 17+ 可不跳 App 直接进房)
7. 浸泡测试长期挂机数据(scripts/soak.ps1 → soak.log)
8. 桌面快捷方式 `~/Desktop/一键进圈.lnk` 需手动改名(沙箱外且无生成脚本)

## 🍎 App Store 上架(2026-09-13 启动,进行中)

目标:**仅 iOS,仅非中国区**(规避 ICP 备案 —— 服务器在 RackNerd 美国,拿不到备案)。
Mac 用**按小时租的云 Mac**(MacinCloud)做一次性 Xcode 配置。功能**全量提交**,含位置共享。

### ⚠️ 最高风险项:Guideline 1.2「anonymous chat」

Apple 于 **2026-02-06** 专门修订 1.2,把 "random or anonymous chat" 明确纳入管辖:
<https://developer.apple.com/news/?id=d75yllv4>
2026-06 已据此下架真实 app(ShareChat 旗下 Vibely,语音社交),开发方抗辩无效。

原文危险句(1.2):
> Apps with user-generated content or services that end up being used primarily for
> ... **random or anonymous chat** ... do not belong on the App Store and
> **may be removed without notice.**

另有 1.1.6 独立风险句:"Apps that enable anonymous or prank phone calls ... will be rejected."

**我们的抗辩点(已核实可证明,不是嘴上说说)**:
- `grep` 全 `app/lib`:**零陌生人发现机制** —— 无匹配、无推荐、无附近的人、无公开房间列表
- `server/src/index.js:767`:开鉴权后 `/health` **主动不吐圈子清单**
  (注释原文:「那是给扫描器用的侦察面」)—— 连圈子的存在都不可枚举
- 进入**必须**持有口令/邀请码,是 closed / invite-only 拓扑,非随机匹配

**已定的应对(用户决策,勿推翻)**:
- **保持无账号体系**,用「设备身份 + 圈内稳定昵称」与「匿名」切割
- 关键因果:**「屏蔽某用户」这条 1.2 要求倒逼出稳定身份的必要性**。
  昵称若可随意改,屏蔽就是假功能(对方改名即绕过),审核员一测就穿。
  所以稳定身份不是装饰,它是屏蔽能成立的前提,也顺带成了「非匿名」最强证据。
- 屏蔽的键**必须是 identity,不是昵称**
- 文案一律避开「匿名 / 随机 / 陌生人」,强调 closed / invite-only / 熟人小圈

> 1.2 原文**没有**「服务器不落盘就豁免」的例外(已通读确认)。
> 不要指望用「我不存储」免除四项措施。

### 硬性阻断项(不改必拒)

| # | 问题 | 证据 | 状态 |
|---|---|---|---|
| 1 | ~~Bundle ID 仍是 `com.example.*`~~ | `project.pbxproj`、`Runner.entitlements:7` App Group、`Info.plist:19` URLName | **已改** → `com.lfm097384.lares`(Apple 侧 11 处联动;Android 包名另议) |
| 2 | **无任何 `.xcprivacy` 隐私清单** | 全仓库 glob 无结果;2024-05 起强制 | 进行中 |
| 3 | `UIBackgroundModes` 声明 `fetch` 但**零使用** | `Info.plist:35`;grep 无 `BGTaskScheduler` | 待删(`audio` 保留,语音房真需求) |
| 4 | CI 产物**不是可上传的 ipa** | `ios-build.yml:38` `--no-codesign` + `:46` 手工 zip Payload | 侧载可用,上传必被拒收 |
| 5 | 零合规资产 | 无隐私政策/服务条款/支持页;三者均为 ASC **必填 URL** | 待做 |
| 6 | UGC 三件套缺失(1.2) | 无屏蔽、无举报、无 EULA | 进行中 |
| 7 | **iOS 选图功能实际不可用** | 见下「已确诊」 | ✅ 已修 |

### 2026-09-13 已完成(本轮)

| 事项 | 结果 |
|---|---|
| UGC 三件套(屏蔽/举报/EULA) | 9 新 + 6 改,+94 测试 |
| iOS 选图修复 | UTI 补齐,+20 测试 |
| Bundle ID → `com.lfm097384.lares` | 12 文件 |
| `PrivacyInfo.xcprivacy` | 已写 + **已接进 Copy Bundle Resources** |
| `ITSAppUsesNonExemptEncryption` = false | Info.plist |
| 删未使用的 `UIBackgroundModes: fetch` | 2.5.4 拒绝理由 |
| 位置补声明 CoarseLocation | 保守声明,理由见清单内注释 |
| Widget 版本号与主 App 联动 | 从 pubspec 读,单一事实源 |
| 录音残留清理 + 移除 sherpa_onnx | **-21.4MB**,符号归零 |
| `url_launcher` | 举报 mailto + 隐私政策链接 |

验证:**441 测试全绿**、`flutter analyze lib` 零告警、干净重建通过。
(测试数 506→441 是移走 `recording_stt_test.dart` 的 65 项,降幅精确匹配。)

### 录音隐藏:从「大部分剔除」到「完全剔除」

二进制符号扫描实测,**干净重建**后 `app.so` 里:
`RecordingConsentController` / `RemoteRecorder` / `rec_stop` / `member_rec` /
`SherpaSttBackend` / `OfflineRecognizer` —— **全部零命中**;
阳性对照 `VoiceNotesController` / `BlockStore` 正常命中(证明搜索方法有效)。

两个关键修复:
1. `main.dart` 的 `RecordingConsentController` 原本**无条件实例化**,
   让 `recording_consent.dart` 成为「可达的活代码」,tree-shaking 剔不掉它
   (另外 11 个文件都被剔除了)。改成跟 `recordingEnabled` 走即可。
2. **tree-shaking 对原生库完全无效**。`sherpa_onnx` 已连同 `stt_sherpa.dart`
   与其测试移到 `app/_disabled/recording_stt/`(有 README 写恢复步骤)。
   移走时 `lib/` 下对它的引用是**零** —— 原作者刻意做了分层。

> ⚠️ 验证这件事本身有坑:第一次构建后 DLL **仍在**,那是 CMake 增量残留。
> `flutter clean` 后必须**重跑 `scripts/fix_symlinks.ps1`**(clean 会删掉 junction),
> 再构建才看得到真实结果。只信第一次构建会得出「移除失败」的错误结论。

### ⚠️ 已确诊:iOS 选图必然失败(我上一轮误报为「已打通」)

`image_source_io.dart:54-57` 的 `XTypeGroup` **只给了 `extensions`**,而
`file_selector_ios-0.5.3+6/lib/file_selector_ios.dart:65-69` 要求 `uniformTypeIdentifiers`
非空,否则 `throw ArgumentError`。该异常被 `image_source_io.dart:73-75` 静默吞掉。

**表现:按钮渲染、可点击、点了没反应,零错误提示。**
(我当时只在 Windows 上验证过 —— Windows 实现读 `extensions`,所以过了。
这正是本文档自己记录过的那类「静默失败」陷阱。)

→ 审核员点一个没反应的按钮 = Guideline 2.1 现成拒绝理由,提审前必须修。

### ✅ 更正:Widget target **不需要**手动建(我上一轮说错了)

`ios-build.yml:30-33` 有 `ruby ios/add_widget_target.rb` 在**程序化注入**,幂等,已跑过 19 次。
`deploy/ios-ci.md:36` 那句「需要先在 Xcode 建一次 target」是**过时文档**。
→ 云 Mac 的用途仅剩:证书/描述文件配置与本地 Archive(若不走 CI 签名)。

该脚本 `:21-24` 从父 target **动态读** bundle id,故改 Bundle ID 时 Widget 自动跟随;
但 `:8` 的 `APP_GROUP` 是硬编码,必须手改。

### 🔴 审核可达性 vs 端口占用:已决定另开一台 VPS

调研查实:**2.1「无法审查」才是这类 app 的真实杀手**,不是自定义服务器本身
(4.7 不适用;最强反证是 Element X 以「连接任意服务器」为主打宣传语且获批)。
实证 —— Pi-hole 客户端被拒,原因是答复 Apple「本 app 无公共端点、无法提供凭据」。
Apple 要求演示后端**固定 DNS + 443 + 系统信任证书**(勿用动态 DNS)。

但本项目 VPS 上 **443 = 机场 VLESS+Reality 主入站**,动不得,
故 `deploy/docker-compose.yml` 把 Caddy 钉死在 8444(见该文件头 4-16 行警告)。
→ 冲突是**结构性**的:8444 在企业网络/部分运营商会被防火墙拦掉,
   审核员一测连不上 = 2.1 拒绝,且这**不是写审核备注能解释掉的**。
   注意这不止影响审核 —— 上架后真实用户同样会撞到 8444 被拦。

**决定:另开一台便宜 VPS 专跑 Lares,独占 443。**
顺带解决:现有 1 vCPU/1GB 要同时扛 xray + LiveKit + Caddy + Node,内存本就吃紧。
→ `deploy/` 现有端口规避逻辑对新机器不再必要,但**先别删**:
   旧机器仍是机场宿主,配置需保留以防回退。

### Bundle ID(已定,不可逆,勿再改)

`com.example.laresApp` → **`com.lfm097384.lares`**;App Group → `group.com.lfm097384.lares`。
选它而非 `eu.org.laresproject.lares`:**Bundle ID 不该被一个未定的外部依赖(域名审批)卡住**,
且 Apple 从不验证域名所有权。一旦在 Apple 后台注册即**永久绑定、不可改、不可删除重用**。

**已于 2026-09-13 完成**,实际联动 12 个文件(比原估的 9 处多):除 pbxproj / entitlements /
Info.plist / xcconfig / `add_widget_target.rb` 外,还有两处**运行时真正读 App Group 的代码**——
`lib/src/platform/widget_service.dart:24`(Dart 侧写入)与 `ios/LaresWidget/LaresWidget.swift:16`
(Swift 侧读取);这两处若漏改,entitlements 授权的 group 无人读写,小组件会**静默**空白。
另含 `map_panel.dart:46` 发给 OSM 的 User-Agent(用 `com.example` 不礼貌且可能被瓦片服务器封)、
`macos/Runner/Info.plist:23` 深链 URLName、`windows/runner/Runner.rc` 的 CompanyName/版权。
Android 包名**暂不动**:改了等于换 app,已装用户无法升级。

### 服务器会落盘的用户内容:只有语音便签

`server/src/index.js:678`「MVP:磁盘 JSON 存储(audio 为 base64),听过即删」。
用户决定**保留并如实申报**。
→ 隐私标签须填 Audio Data;**但这反而有利**:1.2 的「移除内容」要求
从「架构上做不到」变成「做得到」。文字/图片/实时语音仍是纯转发不落盘。

### 已确认**不是**问题的(别重复排查)

- **自动更新在 iOS 上合规**:`installer_io.dart:398` 是 `UpdateCapability.notifyOnly`,
  只提示不下载不安装 —— 最易致命的 2.5.2 红线一开始就绕开了。
  但 `:402` 的文案对用户说「侧载 .ipa」,上架版必须改口径。
- 无分析 SDK、无崩溃上报、无广告、无内购 —— 隐私标签可以填得很干净
- 图片走 `file_selector`(文档选择器),**不碰相册**,不需要相册权限串
- 麦克风/位置权限串已存在且写得合规(`Info.plist:22-25`)

### 审核员如何进入(邀请码门禁的必答题)

方案:**专用审核圈子 + 预置演示内容**。固定口令写在审核备注里,
圈内要有可见的文字/图片消息,**让审核员能实际点到举报和屏蔽按钮**。
→ 审核期间 VPS 必须在线(Apple "Before You Submit" 明确要求后端活动)。

## 快速恢复上下文(新会话第一句话)

> 「继续 Lares 项目:读 D:\Projects\Lares\HANDOFF.md 和 设计.md §9,仓库 github.com/LFM097384/Lares,我要做<某件事>」
