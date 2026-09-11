# Lares · 一键进圈

> 主屏幕点一下,即可进入一个小范围朋友圈子的公共语音空间。想来就来,想走就走。

设计与决策见 [`设计.md`](设计.md)(§8 为当前多端化定案)。

## 仓库结构

```
Lares/
├─ 设计.md          # 产品设计 + 架构 + 路线图(单一事实源)
├─ server/          # presence 信令服务 + LiveKit token 签发(Node.js)
└─ app/             # Flutter 客户端(iOS / Android / Windows / macOS 单代码库)
```

## 快速开始

### 0. 本机全栈一键联调(推荐)

```powershell
pwsh scripts/dev.ps1   # LiveKit(dev) + 信令 + Web 托管,打开 http://127.0.0.1:8080
```

已验证:双浏览器窗口进房互通、大厅在线摘要、状态广播、进房耗时 ~1.3s。

### 1. 信令服务

```bash
cd server
npm install

# 仅 presence(无 RTC,用于联调 UI/状态)
npm start            # ws://0.0.0.0:8787

# 完整模式:配置 LiveKit(Cloud 项目或自托管)
$env:LIVEKIT_URL="wss://your-project.livekit.cloud"
$env:LIVEKIT_API_KEY="APIxxxx"
$env:LIVEKIT_API_SECRET="xxxx"
npm start
```

健康检查:`curl http://localhost:8787/health`

### 2. Flutter 客户端

```bash
cd app
flutter pub get

# Windows 桌面
flutter run -d windows --dart-define=LARES_SIGNALING=ws://127.0.0.1:8787

# Android(信令指向局域网内跑 server 的机器)
flutter run -d android --dart-define=LARES_SIGNALING=ws://192.168.x.x:8787
```

| dart-define | 默认 | 说明 |
|---|---|---|
| `LARES_SIGNALING` | `ws://127.0.0.1:8787` | 信令服务地址 |
| `LARES_CIRCLE` | `home` | 默认圈子 id |
| `LARES_CIRCLE_NAME` | `我们的圈` | 默认圈子显示名 |

## 已实现(v0.1,第一阶段第 1~2 周)

- Flutter 单代码库四端工程(iOS/Android/Windows/macOS 脚手架)
- token 化设计系统(暗色优先,`lib/src/theme/`)
- presence 信令:WebSocket + 内存房间态、多端同账号聚合、指数退避重连、心跳
- 一键进房状态机:预连接 → join → token → RTC,进房耗时可见(目标 ≤1.5s)
- LiveKit 音频接入(进房默认静音、active-speaker 说话检测、dynacast/自适应流)
- 房间 UI:呼吸氛围背景、头像状态环、说话波纹自绘、静音/离开主按钮、轻状态(随时聊/在忙/耳朵在)
- 桌面托盘入口:点图标即进出房间(Windows/macOS),图标已生成(`assets/tray/`)
- 响应式布局:桌面侧栏+主区 / 移动整页切换(840dp 断点)
- 断线重连自动恢复原房间;闲时 5 分钟媒体降级(断媒体留 presence),来人/说话自动唤醒
- 大厅 presence 摘要:未进房即见「X 人在 · 名字」(服务端 lobby 广播)
- 测试:5 个 widget/unit 测试全绿;server 10 项端到端冒烟全绿(`node test/smoke.mjs`)
- 本机全栈 e2e 已验证(Web + 本地 LiveKit dev server,双人进房/状态/离开,进房 ~1.3s)

## 本机环境备注(Windows 开发机)

- Flutter SDK:`D:\flutter`(3.47.3 stable,已入用户 PATH)
- Android SDK:`D:\Android\Sdk`(cmdline-tools + platform-36 + build-tools 36,Java 21)
- **无需开发人员模式/管理员**:`pwsh scripts/fix_symlinks.ps1` 用目录联接(Junction)预建插件链接,绕过 symlink 权限限制(Flutter 对已存在的链接直接跳过)。**每次 `pub get`/`pub upgrade` 后要重跑一次**
- `app/android/gradle.properties` 里 `kotlin.incremental=false`:本机构建环境 Kotlin 增量缓存 mmap 注册冲突,关闭后正常(构建稍慢,无碍)
- `app/windows/CMakeLists.txt` 里 `add_compile_options(/utf-8)`:修复中文系统代码页下 flutter_webrtc 的 C4819//WX 错误
- **Windows 工具链补丁(VS2019 专项,重装 Flutter SDK 后需重做)**:
  - 便携版 CMake 在 `D:\CMake`(3.31.8,record_windows 需要 ≥3.23,VS2019 自带仅 3.20);已给 `D:\flutter\packages\flutter_tools\lib\src\windows\visual_studio.dart` 打了补丁让它优先用便携版(补丁见该文件 cmakePath 开头注释「Lares 本机补丁」)
  - 音频播放用 **media_kit**(预编译二进制);~~audioplayers~~ 需要 VS2022 的 cppwinrt/coroutine 支持,VS2019 编不过
- 已验证构建:`flutter build apk --debug` ✓、`flutter build windows --debug` ✓(VS 2019 生成工具 + 便携 CMake)、`flutter build web` ✓
- iOS/macOS 构建需 Mac + Xcode

## 待办(按 §8.4)

- [x] Windows 桌面端构建 + 启动验证(托盘、改昵称)
- [x] Android APK 构建
- [x] 改昵称(广播 + 持久化)
- [x] Android 主屏幕 Widget:presence 推送 + 点 Widget 深链直达进房(`lares://join`,原生 MethodChannel/EventChannel)
- [x] Android 模拟器联调:深链一键进房 ✓(模拟器虚拟网卡延迟偏高,需真机终验)
- [x] 进房延迟优化:token 预取(P0)+ 信令/RTC 并行 + 跳过冗余关麦调用
  - 实测:桌面 Web 冷进房 1429ms / **热进房 1091ms(达标 ≤1.5s)**;Android 模拟器 2.1s(虚拟网卡加成,真机待验)
  - 局域网联调可加 `--dart-define=LARES_HOST_ONLY_ICE=true` 跳过 STUN(本机实测无显著差异,生产勿用)
- [x] 语音便签:没人时留 ≤15s 语音(长按便签键录音),进房见红点、点一下顺序播放、听过即删;`note_added` 实时广播;服务端磁盘持久化 + CORS 已通
- [x] 多圈子:「加个圈子」本地建圈、各圈独立 presence 摘要、点圈即换(自动先退当前圈)、长按删除(默认圈保留);实测切圈进房 1.2~1.4s
- [x] 品牌图标:Android 各密度 mipmap、Windows app_icon.ico、Web favicon 全部替换;Android 应用名「一键进圈」
- [x] 敲门模式(§3.3):长按圈子开启「需敲门」;非空房间加入者先敲门(「敲门中,等里面的人应门…」,30s 超时),房内成员「让他进」放行;空房直接进;**隐私红线:未获放行前客户端不得先连媒体**(预热 token 门控,有单测);设置磁盘持久化、大厅摘要带 knockRequired
- [x] 圈子邀请:长按圈子→「邀请朋友进圈」复制 `lares://circle/<id>?name=X` 链接;朋友点链接(App 自动登记+进房,实测冷启直达)或「粘贴邀请链接」手动进圈
- [x] Android Quick Settings Tile:下拉状态栏一键进房(`LaresTileService`)
- [x] iOS 端源码预埋(无 Mac 先备料,Mac 到位即可构建):`Info.plist`(URL scheme `lares`、麦克风权限、后台 audio)、`SceneDelegate` 深链(与 Android 同协议)、`ios/LaresWidget/` WidgetKit 源码(SwiftUI,暗色品牌样式,含 Xcode 接入步骤注释)、`WidgetService` 跨端 presence 推送(App Group `group.com.example.lares_app`)
- [x] macOS 端源码预埋:entitlements 补齐(network.client + 麦克风)、`Info.plist`(URL scheme/麦克风说明/应用名)、`AppDelegate` 深链(三端同协议)+ **关窗不退出**(托盘挂机语义修正)、深链服务覆盖 macOS
- [x] 闲时媒体降级获生产级实证:LiveKit 日志显示 5 分钟无说话后 RTC 房间因 departure timeout 关闭,presence 三端仍在线
- [x] AvatarOrb 可访问性语义(「正在说话」标签,为说话指示的可测性铺路)
- [x] **说话指示 e2e 验证**:`server/tool/speak_bot.mjs`(Node LiveKit 客户端,经信令拿 token、进房发布 440Hz 正弦波)真实触发 active-speaker,Web 端显示「机器人 · 随时聊 · 正在说话」✓;AvatarOrb 语义标签同步修正(排除子树重复)
- [ ] LiveKit Cloud 项目创建 + 凭据配置,公网多端互通
- [x] Release 构建:APK ✓、`--split-per-abi` 后 **arm64 36.9MB**(原 106MB,-65%)、Windows ✓(已启动);`.ico` 需 PNG 压缩格式(`tool/make_ico.ps1`,png-to-ico 的旧式 DIB 会被 RC 拒)
- [x] 挂机浸泡测试:`scripts/soak.ps1` 每 5 分钟记录 4 客户端(Web×2 + Android + Windows Release)在房情况到 `soak.log`(§8.4 挂机稳定性验收的自动化)
- [x] 常驻挂机端:`LARES_AUTO_JOIN=true` 启动即自动进房(实测 Release 进房 556ms),已加入开机自启(`shell:startup` 快捷方式);桌面快捷方式同步指向 Release
- [x] Web WASM 构建:`flutter build web --wasm` 通过,进房 1325ms 实测(RTC/信令/presence 在 wasm 下全正常)
- [x] **Android 前台服务保活**(浸泡抓到的真问题:后台被系统杀→presence 掉线):仅进房且媒体在线时持有服务(mic 类型 + WiFiLock),出房/闲时降级立即释放;后台 65s presence 存活实证,浸泡自动恢复 streak=0
- [x] 桌面快捷方式:`~/Desktop/一键进圈.lnk`(指向 Release 版)
- [x] 服务端数据目录可配置(`LARES_DATA_DIR`),测试与本机数据隔离
- [x] 公网部署包:`server/Dockerfile` + `deploy/docker-compose.yml`(Caddy 自动 TLS + LiveKit SFU + 信令)+ `deploy/README.md`(Cloud/自托管双路线);信令 WS 支持 `/ws` 路径分流
- [x] 设置页(§2.2):仅 WiFi 下高音质(接 RTC 发布码率 48k/24k,connectivity_plus 判网)、免打扰时段(抑制敲门横幅,支持跨零点)、状态信息(信令地址/上次进房耗时);持久化实测
- [ ] macOS Dock 菜单入口(需 Mac)

### Android 开发备注

- `home_widget` 锁 0.7.x(0.8 依赖 glance 1.3.0-alpha 需要未发布的 compileSdk 37)
- 模拟器/真机访问本机服务:LiveKit 必须 `--bind 0.0.0.0 --node-ip <局域网IP>`(--dev 默认只绑回环),`scripts/dev.ps1` 已自动处理
- 构建 APK 时给模拟器/真机传局域网信令地址:`--dart-define=LARES_SIGNALING=ws://<局域网IP>:8787`
- **局域网 IP 漂移**(实测遇到:DHCP 换网后 10.0.0.185→10.150.49.251):LiveKit node-ip、信令 LIVEKIT_URL、APK 内的 LARES_SIGNALING 三处会同时失效,客户端表现为"presence 在但进房失败"。换网后用 `scripts/dev.ps1` 重启全栈(自动探测当前 IP)并用当前 IP 重建 APK
