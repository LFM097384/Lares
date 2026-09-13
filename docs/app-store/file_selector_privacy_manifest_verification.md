# file_selector 隐私清单（PrivacyInfo.xcprivacy）查证报告

核查日期：基于当前 flutter/packages `main` 分支与 pub.dev API 实时抓取。

---

## 核心结论（TL;DR）

1. `file_selector_ios` **自带** PrivacyInfo.xcprivacy，首次加入版本 **0.5.1+8**（2024-01-12）。
2. `file_selector_macos` **自带** PrivacyInfo.xcprivacy，首次加入版本 **0.9.4+1**（2024-09-24）。
3. **两个清单的内容都是"空清单"**：`NSPrivacyAccessedAPITypes` 为空数组（macOS 版本连该键都没有），`NSPrivacyCollectedDataTypes` 为空，`NSPrivacyTracking` 为 `false`。**没有任何 reason code**（不存在 C617.1 / CA92.1 / DDA9.1 / 0A2A.1 / 3B52.1 等）。
4. **项目实际锁定的版本已全部包含隐私清单**（已在对应 release tag 上逐字验证，见第 5 节）：
   - `file_selector_ios` **0.5.3+6** ≥ 0.5.1+8 ✅ **已包含**
   - `file_selector_macos` **0.9.5+1** ≥ 0.9.4+1 ✅ **已包含**
   - 无需升级，无需手工补充清单。

---

## 1. 平台支持

`file_selector`（app-facing 包）支持 **Android / iOS / Linux / macOS / Web / Windows**，**含 iOS**。

pubspec 中 `flutter.plugin.platforms` 声明（取自 1.0.3 版本的 pubspec）：

```
android → file_selector_android
ios     → file_selector_ios
linux   → file_selector_linux
macos   → file_selector_macos
web     → file_selector_web
windows → file_selector_windows
```

README 支持矩阵：Android SDK 21+ / iOS 12+ / Linux Any / macOS 10.14+ / Web Any / Windows 10+。

证据：
- https://pub.dev/packages/file_selector （200）
- https://pub.dev/api/packages/file_selector （200，含 1.0.3 完整 pubspec）

---

## 2. file_selector_ios

### 是否自带清单
**是。**

### 首次加入版本
**0.5.1+8**，pub.dev 发布时间 **2024-01-12T05:46:38Z**。

CHANGELOG 原文（0.5.1+8 条目）：
```
## 0.5.1+8
- Adds privacy manifest.
- Updates minimum supported SDK version to Flutter 3.10/Dart 3.0.
```

### 文件路径（注意 SPM 迁移导致路径变更）

| 时期 | 路径 | 抓取结果 |
|---|---|---|
| 0.5.1+8 起（初始） | `packages/file_selector/file_selector_ios/ios/Resources/PrivacyInfo.xcprivacy` | **200 成功** |
| 当前 main（SPM 迁移后） | `packages/file_selector/file_selector_ios/ios/file_selector_ios/Sources/file_selector_ios/Resources/PrivacyInfo.xcprivacy` | **200 成功** |
| 任务中假设的 `ios/Classes/Resources/` | `.../ios/Classes/Resources/PrivacyInfo.xcprivacy` | **404 —— 该路径下文件不存在**（main 与 v0.5.1+8 tag 均 404） |

路径迁移由 PR **#6672**「[file_selector] Add support for SPM」（2024-05-06）完成。

podspec 确认清单被打包（当前 main）：
```ruby
s.resource_bundles = {'file_selector_ios_privacy' => ['file_selector_ios/Sources/file_selector_ios/Resources/PrivacyInfo.xcprivacy']}
```

### NSPrivacyAccessedAPITypes 逐字内容

当前 main 分支文件**完整逐字内容**：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSPrivacyTrackingDomains</key>
	<array/>
	<key>NSPrivacyAccessedAPITypes</key>
	<array/>
	<key>NSPrivacyCollectedDataTypes</key>
	<array/>
	<key>NSPrivacyTracking</key>
	<false/>
</dict>
</plist>
```

v0.5.1+8 tag 处的文件内容**与上述完全一致**（逐字相同）。

**逐条说明：**
- `NSPrivacyAccessedAPITypes`：**空数组 `<array/>`**。**没有任何 `NSPrivacyAccessedAPIType` 条目，因此没有任何 `NSPrivacyAccessedAPITypeReasons` reason code。**
- `NSPrivacyCollectedDataTypes`：空数组。
- `NSPrivacyTracking`：`false`。
- `NSPrivacyTrackingDomains`：空数组。

---

## 3. file_selector_macos

### 是否自带清单
**是。**

### 首次加入版本
**0.9.4+1**，pub.dev 发布时间 **2024-09-24T03:53:46Z**。

CHANGELOG 原文（0.9.4+1 条目）：
```
## 0.9.4+1
- Adds privacy manifest.
- Updates minimum supported SDK version to Flutter 3.19/Dart 3.3.
```

### 文件路径

| 路径 | 抓取结果 |
|---|---|
| `packages/file_selector/file_selector_macos/macos/file_selector_macos/Sources/file_selector_macos/Resources/PrivacyInfo.xcprivacy`（main 与 v0.9.4+1 tag） | **200 成功** |
| `.../macos/Classes/Resources/PrivacyInfo.xcprivacy` | **404 —— 不存在** |
| `.../macos/Resources/PrivacyInfo.xcprivacy` | **404 —— 不存在**（GitHub commits API 查该路径返回空数组 `[]`，确认该路径从未有过此文件） |

注：macOS 侧因为在 SPM 迁移（2024-05）**之后**才加清单（2024-09），所以一开始就直接落在 SPM 布局路径下，没有经历路径迁移。

podspec 确认（当前 main）：
```ruby
s.resource_bundles = {'file_selector_macos_privacy' => ['file_selector_macos/Sources/file_selector_macos/Resources/PrivacyInfo.xcprivacy']}
```

### NSPrivacyAccessedAPITypes 逐字内容

main 分支与 v0.9.4+1 tag 文件**完整逐字内容（两者一致）**：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSPrivacyTrackingDomains</key>
	<array/>
	<key>NSPrivacyCollectedDataTypes</key>
	<array/>
	<key>NSPrivacyTracking</key>
	<false/>
</dict>
</plist>
```

**逐条说明：**
- `NSPrivacyAccessedAPITypes`：**该键在 macOS 清单中完全不存在**（与 iOS 版不同，iOS 版有一个空数组）。因此同样**没有任何 reason code**。
- `NSPrivacyCollectedDataTypes`：空数组。
- `NSPrivacyTracking`：`false`。
- `NSPrivacyTrackingDomains`：空数组。

---

## 4. 引入隐私清单的 PR / Issue 证据

### iOS：PR #5846 `[various] Add iOS privacy manifests`
- 合并 commit：`c5349bc9a5be1cbef9c13571d9d6d2b506240b20`，作者 stuartmorgan，日期 **2024-01-12T04:27:39Z**
- commit message 关键原文摘录：
  > Adds privacy manifests to all iOS plugins. ... **Only `shared_preferences` has a non-empty manifest, as it is our only plugin that uses a required reason API, and none of our plugins themselves collect private data.**
- 这段话直接解释了为什么 file_selector_ios 的清单是空的。
- Fixes 的 issue：flutter/flutter#131495、#139756、#139757、#139758、#139759、#139760；另见 #139761
- PR 链接：https://github.com/flutter/packages/pull/5846
- Commit 链接：https://github.com/flutter/packages/commit/c5349bc9a5be1cbef9c13571d9d6d2b506240b20

### macOS：PR #7687 `[various] Adds macOS privacy manifests`
- 合并 commit：`21d99dcc16c904871ad81efcc009c90d57c6c5b2`，作者 stuartmorgan，日期 **2024-09-24T01:16:06Z**
- commit message 原文摘录：
  > macOS privacy manifest enforcement is rolling out soon, so this brings all macOS plugins into alignment with our iOS policy of always having a manifest... Very few plugins are affected because most share the implementation package with iOS...
- Fixes：flutter/flutter#155564
- PR 链接：https://github.com/flutter/packages/pull/7687
- Commit 链接：https://github.com/flutter/packages/commit/21d99dcc16c904871ad81efcc009c90d57c6c5b2

### SPM 路径迁移：PR #6672 `[file_selector] Add support for SPM`
- commit：`45a4573cc0dbdbb61a46f1b0cd2755c1cb1a0018`，**2024-05-06T20:06:00Z**
- Fixes：flutter/flutter#146903
- https://github.com/flutter/packages/pull/6672

### 关于 flutter/flutter#143624
任务中提到的 issue #143624 **未在本次查证中出现于任何证据链**（#5846 与 #7687 的 commit message 中列出的 issue 编号均不含 143624）。**未查证到其与 file_selector 的关联，如需引用请人工确认。**

---

## 5. 版本满足性判断（基于项目实际 pubspec.lock）

### 实际锁定版本（由项目 `pubspec.lock` 提供）

| 包 | pubspec 声明 | **实际锁定版本** |
|---|---|---|
| file_selector | `^1.0.3` | **1.1.0** |
| file_selector_ios | （传递依赖） | **0.5.3+6** |
| file_selector_macos | （传递依赖） | **0.9.5+1** |
| file_selector_platform_interface | （传递依赖） | 2.7.0 |

注：`^1.0.3` 允许 `>=1.0.3 <2.0.0`，故解析到 1.1.0 完全合规。1.1.0 的约束为 `file_selector_ios: ^0.5.0`、`file_selector_macos: ^0.9.5`。

### 最终判断

| 包 | 含清单最低版本 | 实际锁定版本 | 是否满足 | 验证方式 |
|---|---|---|---|---|
| file_selector_ios | 0.5.1+8 | **0.5.3+6** | ✅ **是，已包含隐私清单** | 直接抓取 `file_selector_ios-v0.5.3+6` tag 上的清单文件，HTTP 200 |
| file_selector_macos | 0.9.4+1 | **0.9.5+1** | ✅ **是，已包含隐私清单** | 直接抓取 `file_selector_macos-v0.9.5+1` tag 上的清单文件，HTTP 200 |

**这不是靠版本号大小推断的结论，而是在两个锁定版本对应的 git tag 上逐字抓取到了清单文件本体。**

### 锁定版本上的清单逐字内容

**file_selector_ios 0.5.3+6**（tag `file_selector_ios-v0.5.3+6`）：
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSPrivacyTrackingDomains</key>
	<array/>
	<key>NSPrivacyAccessedAPITypes</key>
	<array/>
	<key>NSPrivacyCollectedDataTypes</key>
	<array/>
	<key>NSPrivacyTracking</key>
	<false/>
</dict>
</plist>
```

**file_selector_macos 0.9.5+1**（tag `file_selector_macos-v0.9.5+1`）：
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSPrivacyTrackingDomains</key>
	<array/>
	<key>NSPrivacyCollectedDataTypes</key>
	<array/>
	<key>NSPrivacyTracking</key>
	<false/>
</dict>
</plist>
```

内容与各自首发版本（0.5.1+8 / 0.9.4+1）及 `main` 分支**完全一致**，自加入以来未被修改。`NSPrivacyAccessedAPITypes` 仍为空 / 缺失，**依然没有任何 reason code**。

### 清单确实会被打进产物（两条构建路径均已验证，均在锁定版本 tag 上）

**CocoaPods 路径** —— podspec 的 `resource_bundles`：
- iOS 0.5.3+6：`s.resource_bundles = {'file_selector_ios_privacy' => ['file_selector_ios/Sources/file_selector_ios/Resources/PrivacyInfo.xcprivacy']}`
- macOS 0.9.5+1：`s.resource_bundles = {'file_selector_macos_privacy' => ['file_selector_macos/Sources/file_selector_macos/Resources/PrivacyInfo.xcprivacy']}`

**Swift Package Manager 路径** —— Package.swift 的 `resources: [.process("Resources")]`，两个包均有该声明，清单位于各自 `Sources/<name>/Resources/` 下，故被 SPM 正确打包。

因此无论项目走 CocoaPods 还是 SPM，隐私清单都会进入最终 framework 产物。

### 结论与行动建议
**无需任何操作。** 项目当前锁定的 file_selector_ios 0.5.3+6 与 file_selector_macos 0.9.5+1 均已自带 PrivacyInfo.xcprivacy，且打包配置正确。之前关于「Flutter SDK 需 >= 3.19.0 否则 macOS 侧降级」的顾虑已不适用 —— 实际锁定版本 0.9.5+1 远高于该门槛。

---

## 6. 实务影响提示（基于上述事实的推论，非新增查证）

由于两个清单的 `NSPrivacyAccessedAPITypes` 均为空 / 缺失，`file_selector` 本身**不为宿主 App 贡献任何 Required Reason API 声明**。若 App 上架时被 Apple 提示缺少 `NSPrivacyAccessedAPICategoryFileTimestamp`（C617.1 等）声明，来源应是**其他依赖或 App 自身代码**，而非 file_selector。这一点与 PR #5846 中「only shared_preferences has a non-empty manifest」的说明一致。

---

## 7. 证据 URL 清单（含抓取状态）

### 抓取成功（HTTP 200）

| # | URL | 用途 |
|---|---|---|
| 1 | https://pub.dev/packages/file_selector | 平台支持矩阵、依赖列表 |
| 2 | https://pub.dev/api/packages/file_selector | 1.0.3 完整 pubspec 与依赖约束 |
| 3 | https://pub.dev/packages/file_selector_ios/changelog | 0.5.1+8 "Adds privacy manifest" |
| 4 | https://pub.dev/packages/file_selector_macos/changelog | 0.9.4+1 "Adds privacy manifest" |
| 5 | https://pub.dev/packages/file_selector_ios/versions | iOS 各版本发布时间 |
| 6 | https://pub.dev/api/packages/file_selector_ios | iOS 各版本 pubspec 与精确发布时间戳 |
| 7 | https://pub.dev/api/packages/file_selector_macos/versions/0.9.4%2B1 | macOS 0.9.4+1 发布时间与 SDK 约束 |
| 8 | https://raw.githubusercontent.com/flutter/packages/main/packages/file_selector/file_selector_ios/ios/file_selector_ios/Sources/file_selector_ios/Resources/PrivacyInfo.xcprivacy | **iOS 清单逐字内容（main）** |
| 9 | https://raw.githubusercontent.com/flutter/packages/file_selector_ios-v0.5.1%2B8/packages/file_selector/file_selector_ios/ios/Resources/PrivacyInfo.xcprivacy | **iOS 清单逐字内容（首发版本 tag）** |
| 10 | https://raw.githubusercontent.com/flutter/packages/main/packages/file_selector/file_selector_macos/macos/file_selector_macos/Sources/file_selector_macos/Resources/PrivacyInfo.xcprivacy | **macOS 清单逐字内容（main）** |
| 11 | https://raw.githubusercontent.com/flutter/packages/file_selector_macos-v0.9.4%2B1/packages/file_selector/file_selector_macos/macos/file_selector_macos/Sources/file_selector_macos/Resources/PrivacyInfo.xcprivacy | **macOS 清单逐字内容（首发版本 tag）** |
| 12 | https://raw.githubusercontent.com/flutter/packages/main/packages/file_selector/file_selector_ios/ios/file_selector_ios.podspec | iOS resource_bundles 打包确认 |
| 13 | https://raw.githubusercontent.com/flutter/packages/main/packages/file_selector/file_selector_macos/macos/file_selector_macos.podspec | macOS resource_bundles 打包确认 |
| 14 | https://api.github.com/repos/flutter/packages/commits?path=packages/file_selector/file_selector_ios/ios/Resources/PrivacyInfo.xcprivacy | 定位 PR #5846 与 #6672 |
| 15 | https://api.github.com/repos/flutter/packages/commits?path=packages/file_selector/file_selector_macos/macos/file_selector_macos/Sources/file_selector_macos/Resources/PrivacyInfo.xcprivacy | 定位 PR #7687 |
| 22 | https://raw.githubusercontent.com/flutter/packages/file_selector_ios-v0.5.3%2B6/packages/file_selector/file_selector_ios/ios/file_selector_ios/Sources/file_selector_ios/Resources/PrivacyInfo.xcprivacy | **锁定版本 0.5.3+6 的清单逐字内容** |
| 23 | https://raw.githubusercontent.com/flutter/packages/file_selector_macos-v0.9.5%2B1/packages/file_selector/file_selector_macos/macos/file_selector_macos/Sources/file_selector_macos/Resources/PrivacyInfo.xcprivacy | **锁定版本 0.9.5+1 的清单逐字内容** |
| 24 | https://raw.githubusercontent.com/flutter/packages/file_selector_ios-v0.5.3%2B6/packages/file_selector/file_selector_ios/ios/file_selector_ios.podspec | 0.5.3+6 CocoaPods 打包确认 |
| 25 | https://raw.githubusercontent.com/flutter/packages/file_selector_macos-v0.9.5%2B1/packages/file_selector/file_selector_macos/macos/file_selector_macos.podspec | 0.9.5+1 CocoaPods 打包确认 |
| 26 | https://raw.githubusercontent.com/flutter/packages/file_selector_ios-v0.5.3%2B6/packages/file_selector/file_selector_ios/ios/file_selector_ios/Package.swift | 0.5.3+6 SPM 资源打包确认 |
| 27 | https://raw.githubusercontent.com/flutter/packages/file_selector_macos-v0.9.5%2B1/packages/file_selector/file_selector_macos/macos/file_selector_macos/Package.swift | 0.9.5+1 SPM 资源打包确认 |

### 抓取返回 404（该事实本身即证据：对应路径下文件不存在）

| # | URL | 结论 |
|---|---|---|
| 16 | https://raw.githubusercontent.com/flutter/packages/main/packages/file_selector/file_selector_ios/ios/Classes/Resources/PrivacyInfo.xcprivacy | **404** — main 分支该路径无此文件 |
| 17 | https://raw.githubusercontent.com/flutter/packages/file_selector_ios-v0.5.1%2B8/packages/file_selector/file_selector_ios/ios/Classes/Resources/PrivacyInfo.xcprivacy | **404** — v0.5.1+8 该路径无此文件 |
| 18 | https://raw.githubusercontent.com/flutter/packages/main/packages/file_selector/file_selector_macos/macos/Classes/Resources/PrivacyInfo.xcprivacy | **404** — main 分支该路径无此文件 |
| 19 | https://raw.githubusercontent.com/flutter/packages/file_selector_macos-v0.9.4%2B1/packages/file_selector/file_selector_macos/macos/Classes/Resources/PrivacyInfo.xcprivacy | **404** — v0.9.4+1 该路径无此文件 |
| 20 | https://raw.githubusercontent.com/flutter/packages/file_selector_macos-v0.9.4%2B1/packages/file_selector/file_selector_macos/macos/Resources/PrivacyInfo.xcprivacy | **404** — 该路径无此文件 |
| 21 | https://api.github.com/repos/flutter/packages/commits?path=packages/file_selector/file_selector_macos/macos/Resources/PrivacyInfo.xcprivacy | 返回空数组 `[]` — 确认该路径从无提交历史 |

---

## 8. 明确标注「未查证到」的项

| 项 | 状态 |
|---|---|
| 具体 reason code（C617.1 / CA92.1 / DDA9.1 / 0A2A.1 / 3B52.1 等） | **不适用** —— 两个清单均无 `NSPrivacyAccessedAPIType` 条目，因此不存在任何 reason code。这是确证的「无」，不是「查不到」。 |
| flutter/flutter issue **#143624** 与 file_selector 隐私清单的关联 | **未查证到，需人工确认**。#5846 与 #7687 的 commit message 所列 issue 中不含该编号。 |
| 项目实际 `pubspec.lock` 中解析到的子包版本 | **已确证**（由调用方提供 lockfile 事实）：file_selector 1.1.0 / file_selector_ios 0.5.3+6 / file_selector_macos 0.9.5+1 / file_selector_platform_interface 2.7.0。本报告已据此在对应 git tag 上完成清单验证。 |
| GitHub 代码搜索页面 `github.com/search?q=...&type=code` | **未使用** —— 该页面需登录且对非交互抓取不友好；改用 GitHub Commits API + raw 文件穷举，证据强度更高。 |
