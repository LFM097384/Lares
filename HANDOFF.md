# Lares 工作交接(2026-09-12)

> 新会话启动指南:读完本文件即可继续。单一事实源:`设计.md`(§8 架构定案、§9 实现状态)。

## 这是什么

「一键进圈」语音陪伴 App:主屏幕点一下,进入 5~20 人熟人圈的常驻语音空间。
架构:**Flutter 单代码库(iOS/Android/Windows/macOS/Web)+ LiveKit SFU + Node 信令服务**。

- 仓库:https://github.com/LFM097384/Lares (main 分支,已推送全部提交)
- v0.1.0 已发布:https://github.com/LFM097384/Lares/releases/tag/v0.1.0
- CI:`.github/workflows/ios-build.yml`,四端构建**当前全绿**(tag 或手动触发)

## 已实现(全部经过真机/e2e 验证)

一键进房(实测 Windows 0.56s / Web 1.06~1.5s,token 预取+信令 RTC 并行)、presence 大厅(未进房见「X 人在 · 名字」)、轻状态(随时聊/在忙/耳朵在)、多圈子+本地建圈、邀请深链(`lares://circle/<id>?name=X`,圈子卡片有分享图标)、敲门模式(含"未放行不连媒体"隐私门控+圈内授权)、踢人(长按头像)、语音便签(长按录 15s、听过即删、磁盘持久化)、位置共享(Snapchat 式地图,显式开关/30s 节流/出房即停)、改昵称、设置页(WiFi 高音质 48k/24k、免打扰、服务器地址覆盖、后台运行保障)、品牌图标、暗色设计系统。

**入口**:App 内点击、Android Widget(主屏 presence+深链)、Android QS Tile、桌面托盘(Win/macOS)、`lares://join` 深链、Android 主屏固定(requestPinWidget)、iOS WidgetKit 小组件(CI 已嵌入 .ipa)。

**性能/韧性**:闲时 5 分钟媒体降级(LiveKit 日志实证)、断线重连自动回房(服务端重启 12s 内 4 端自愈)、Android 前台服务保活(mic+WiFiLock)、`LARES_AUTO_JOIN` 常驻挂机模式、Lighthouse 4×100、CLS 0.00、Web WASM、弱网 3G 进房 3.3s。

**测试**:客户端 10 项 + 服务端冒烟 22 项,全绿(`cd server && node test/smoke.mjs`)。

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
5. 小组件:长按主屏幕→+→搜「一键进圈」(免费签名的 App Groups 数据共享可能受限,最坏显示默认文案)

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

## 待办(按优先级)

1. **iPhone 真机验证**:踢人/位置共享/后台保活/小组件数据共享是否正常(免费签名 App Groups 待确认)
2. **公网化**:LiveKit Cloud 免费账号(零成本)或用户 RackNerd VPS(deploy/ 一条命令;VPS 是翻墙机,动前需用户明确许可)
3. **TestFlight 签名**:$99 开发者账号后按 deploy/ios-ci.md 配 secrets
4. iOS Widget 深化:App Intents 可交互小组件(iOS 17+ 可不跳 App 直接进房)
5. 浸泡测试长期挂机数据(scripts/soak.ps1 → soak.log)

## 快速恢复上下文(新会话第一句话)

> 「继续 Lares 项目:读 D:\Projects\Lares\HANDOFF.md 和 设计.md §9,仓库 github.com/LFM097384/Lares,我要做<某件事>」
