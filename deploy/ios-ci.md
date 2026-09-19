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

## 签名并上传 TestFlight(已实现,无需 Mac)

`ios-build.yml` 里的 `testflight` job 用 **App Store Connect API 自动签名** ——
xcodebuild 拿 API 密钥自己去创建和下载证书与描述文件。
**不需要**在本地生成 CSR、p12 或 mobileprovision,证书过期也不用管。

### 一、生成 API 密钥(只做一次)

1. [App Store Connect](https://appstoreconnect.apple.com) →
   **Users and Access** → **Integrations** → **App Store Connect API**
2. 选 **Team Keys**(不要 Individual Key ——
   个别工具在个人密钥的上传环节有长期已知问题)
3. **+** 新建,Access 选 **App Manager**
4. 下载 `.p8` 文件 —— **只能下载一次**,丢了只能重新建
5. 记下页面上的 **Key ID**(10 位)和 **Issuer ID**(UUID)

### 二、找 Team ID

[developer.apple.com/account](https://developer.apple.com/account) →
Membership details → **Team ID**(10 位)。

### 二点五、先在 ASC 建好 App 记录

⚠️ **上传前 App Store Connect 里必须已有这个 App**,否则 altool 会报
「没有找到对应的 App」。

1. [App Store Connect](https://appstoreconnect.apple.com) → **我的 App** → **+**
2. 平台 iOS;名称「炉灵」;主要语言 简体中文
3. **套装 ID 选 `com.lfm097384.lares`**
   —— 下拉里没有的话,先去
   [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list)
   注册这个 Identifier,记得勾上 **App Groups**(Widget 要用)
4. SKU 随便填个内部编号,如 `lares-ios-001`

这一步只做一次,和下面的 Secrets 互不依赖。

### 三、配 Secrets

仓库 → Settings → Secrets and variables → Actions → New repository secret:

| Secret | 内容 |
|---|---|
| `ASC_KEY_ID` | Key ID,10 位 |
| `ASC_ISSUER_ID` | Issuer ID,UUID |
| `ASC_PRIVATE_KEY` | `.p8` 的**全部文本**,含 `-----BEGIN PRIVATE KEY-----` 与 `-----END PRIVATE KEY-----` 两行 |
| `APPLE_TEAM_ID` | Team ID,10 位 |

⚠️ `ASC_PRIVATE_KEY` 用文本编辑器打开 `.p8` 整个复制,别漏首尾两行。
workflow 会校验格式,不对会直接失败并提示。

### 四、跑

Actions → **Platform Builds** → Run workflow →
勾选 **「签名并上传到 TestFlight」** → Run。

约 15–25 分钟。上传成功后 ASC 侧还要处理 5–30 分钟,
之后 TestFlight 里就能看到,用 iPhone 装上即可。

### 设计说明

- **build number 用 `github.run_number`**,不用 pubspec 里的 `+N`。
  ASC 拒收重复 build number(ITMS-90189),而手写的数字重跑一次就撞号。
- **走 `xcodebuild archive` + `exportArchive`**,不用 `flutter build ipa`。
  后者在 `path_provider_foundation` 2.6.0 下会漏掉 `Runner.app`
  (flutter#187752),产出结构无效的 ipa,而报错要到上传时才出现、
  且完全指不到原因。我们已用 `dependency_overrides` 钉回 2.5.1,
  workflow 里另有一步**拆开 ipa 检查 `Payload/*.app`** 作为第二道保险。
- **先 validate 再 upload**。validate 免费且快,能提前抓出签名、
  权限、隐私清单问题,省掉一次漫长上传。
- **`method` 用 `app-store-connect`**,旧的 `app-store` 已弃用。
- **只在手动勾选时运行**。每次上传占一个 build number,
  误触会浪费号段并在 ASC 里堆垃圾构建。

### 常见错误

| 现象 | 原因 |
|---|---|
| `.p8 格式不对` | Secret 粘贴时漏了 BEGIN/END 行 |
| ITMS-90189 | build number 重复 —— 重跑一次即可(run_number 会自增) |
| `FailedToExpandPackage` | ipa 结构坏了,检查 `dependency_overrides` 是否还在 |
| `No profiles found` | Team ID 错,或 API 密钥权限不是 App Manager |
| ITMS-90742 | 隐私清单缺条目,见 `app/ios/Runner/PrivacyInfo.xcprivacy` |

## Widget 扩展注意

CI 构建只含主 App。**LaresWidget(WidgetKit)需要先在 Xcode 建一次 target**(步骤在 `ios/LaresWidget/LaresWidget.swift` 头部注释),提交 `project.pbxproj` 变更后 CI 才会带上 Widget。
