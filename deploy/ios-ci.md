# iOS / macOS 云端构建指南

无需本地 Mac:`.github/workflows/ios-build.yml` 在 GitHub 免费 macOS runner 上构建。

## 快速开始

1. 把仓库推到 GitHub(`git remote add origin ... && git push -u origin main`)。
2. (可选)在仓库 Settings → Variables 加 `LARES_SIGNALING`(如 `wss://rtc.example.com/ws`);不配则默认回环地址,仅供模拟器。
3. Actions → iOS Build → Run workflow,几分钟后在 Artifacts 下载:
   - `lares-ios-unsigned`(未签名 .ipa)
   - `lares-macos`(macOS .app)

## 未签名 .ipa 怎么用

| 场景 | 做法 |
|---|---|
| **iOS 模拟器**(任何 Mac) | `xcrun simctl install <device> Runner.app`(直接用 build 产物 .app,无需签名) |
| **真机(免费 Apple ID)** | Xcode 打开 `app/ios/Runner.xcworkspace`,选自己团队签名,跑一次;之后 CI 产物可参照重签 |
| **TestFlight / 上架** | 需要 $99/年 Apple Developer,见下方签名配置 |

## 签名(TestFlight / App Store)

在仓库 Secrets 配置后,给 workflow 加签名步骤:

| Secret | 内容 |
|---|---|
| `APPLE_CERT_P12` | 分发证书 p12 的 base64 |
| `APPLE_CERT_PASSWORD` | p12 密码 |
| `PROVISIONING_PROFILE` | 描述文件 base64 |
| `APPSTORE_ISSUER_ID` / `APPSTORE_KEY_ID` / `APPSTORE_PRIVATE_KEY` | App Store Connect API |

然后用 `flutter build ipa`(不带 --no-codesign)+ `xcrun altool` / App Store Connect API 上传。

## Widget 扩展注意

CI 构建只含主 App。**LaresWidget(WidgetKit)需要先在 Xcode 建一次 target**(步骤在 `ios/LaresWidget/LaresWidget.swift` 头部注释),提交 `project.pbxproj` 变更后 CI 才会带上 Widget。
