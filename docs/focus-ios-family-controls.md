# 专注学习(lares.focus):iOS Family Controls 与各平台约束矩阵

专注学习插件要回答一个问题:**这个人现在还在 Lares 里专注吗?** 能做到多强的约束,
完全取决于平台给了什么 API。Android 可以「屏幕固定」;iOS 真正的屏蔽能力
(FamilyControls / ManagedSettings)需要 Apple 单独批准的权限,目前**只写好了代码、
藏在编译开关后面,没有启用**。本文记录:怎么申请、批下来以后改哪些地方、
以及现在每个平台实际是怎么判定「离开」的。

## 现状:各平台约束矩阵

| 平台 | 约束手段 | 「离开」如何判定 | 局限 |
|---|---|---|---|
| Android | 屏幕固定(lock task / screen pinning),通道 `lares/focus_lock` | 生命周期:App 退到后台超过宽限期 → 上报 away | 系统会弹确认框,用户必须同意;用户可以用「返回 + 概览」手势随时退出固定 |
| iOS | 仅生命周期 | App 进后台超过宽限期 → away | 锁屏、来电也会被算作 away —— 生命周期分不清「锁屏」和「切走」;FamilyControls 屏蔽在编译开关 `LARES_FAMILY_CONTROLS` 后面,**未启用** |
| Windows / macOS / Linux 桌面 | 窗口失焦/聚焦(`window_manager`) | 窗口失焦超过宽限期 → away | 无法阻止切换窗口,只能记录 |
| Web | 页面可见性 / 生命周期 | 页面 hidden → away | 同上,只能记录 |

Dart 侧约定:调用 `lares/family_controls` 抛 `MissingPluginException`(未编译该通道,即当前所有正式构建)
即视为**不可用**,回落到纯生命周期判定。

## 原生通道契约

### `lares/focus_lock`(Android,`MainActivity.kt`)

| 方法 | 返回 | 说明 |
|---|---|---|
| `start` | `bool`(`true`) | `startLockTask()`;非设备所有者时系统弹确认框,`true` 只表示请求已发出,不代表用户已同意 |
| `stop` | `bool`(`true`) | `stopLockTask()`;未处于固定状态时调用也安全 |
| `isLocked` | `bool` | `ActivityManager.lockTaskModeState != LOCK_TASK_MODE_NONE`(API 23+;更老的系统用 `isInLockTaskMode`) |

任何异常 → `PlatformException(code: "focus_lock", message: e.message)`。

因为 `start` 返回时用户可能还没点确认,Dart 侧应在稍后用 `isLocked` 轮询确认真实状态。

### `lares/family_controls`(iOS,`AppDelegate.swift`,仅在 `LARES_FAMILY_CONTROLS` 下编译)

| 方法 | 返回 | 说明 |
|---|---|---|
| `available` | `bool` | iOS 16+ 为 `true` |
| `authorize` | `bool`(`true`)或 `FlutterError` | `AuthorizationCenter.shared.requestAuthorization(for: .individual)`;用户拒绝 → `family_controls` 错误 |
| `shield` | `bool`(`true`) | `ManagedSettingsStore().shield.applicationCategories = .all(except: Set())` |
| `unshield` | `bool`(`true`) | 清除所有 shield 设置 |

## 申请 Family Controls (Distribution) 权限

开发阶段在 Xcode 里加 Family Controls capability 就能在真机调试(Development 权限自动发放),
但**上架 / TestFlight 必须拿到 Distribution 权限**,需要人工申请:

1. 以**账号持有人(Account Holder)**身份登录 Apple Developer —— Admin 也不行。
2. 打开申请表:<https://developer.apple.com/contact/request/family-controls-distribution>
3. **每个 bundle id 单独申请**:主 App(`Runner` 的 bundle id)要申请;如果以后加了
   ShieldConfiguration / ShieldAction / DeviceActivityMonitor 扩展,每个扩展的 bundle id 也要各申请一次。
4. 用途说明里写清楚:个人自愿使用(`.individual` 授权,不是家长管控),仅在用户主动开始专注时屏蔽,
   结束即解除;不收集、不上传任何应用使用数据。
5. 等 Apple 邮件回复(通常数天到数周)。批准后在 Certificates, Identifiers & Profiles 的 App ID
   页面能看到 Family Controls 已可用于 Distribution。

## 批准以后要改的地方

1. **权限文件**:把 `app/ios/Runner/Runner.familycontrols.entitlements.example` 的内容合并进
   `app/ios/Runner/Runner.entitlements`(即在现有条目基础上加
   `com.apple.developer.family-controls = true`)。
2. **Xcode / App ID**:在 Runner target → Signing & Capabilities 里添加 *Family Controls* capability;
   在开发者后台对应 App ID 勾选 Family Controls。
3. **重新生成描述文件(provisioning profiles)**:Development 和 App Store 两套都要重新生成并下载;
   **CI 里存的描述文件 / 签名 secrets 也要同步更新**,否则 CI 签名会因权限不匹配失败。
4. **打开编译开关**:Runner target 的 Build Settings 里设置
   `SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) LARES_FAMILY_CONTROLS`
   (Debug 和 Release 都要;或写进 xcconfig)。然后按 `AppDelegate.swift` 中
   `LaresFamilyControlsChannel` 注释里的示例,在 `didInitializeImplicitFlutterEngine` 里注册通道
   —— 调用处同样包在 `#if LARES_FAMILY_CONTROLS` 里。
5. **把 Lares 自己排除在屏蔽之外**:`ApplicationToken` 无法凭 bundle id 构造,只能让用户在
   `FamilyActivityPicker` 里选。需要加一个选择界面(SwiftUI,经 `UIHostingController` 弹出),
   让用户选出 Lares(以及想保留的其它应用,如词典),把选出的 token 持久化,
   `shield` 时改成 `.all(except: tokens)` / 相应设置 `shield.applications`。
   不做这一步,`shield` 会把 Lares 本身也挡住。
6. **(可选)自定义屏蔽界面**:加一个 ShieldConfiguration 扩展,把系统屏蔽页换成
   「正在专注学习 · Lares」之类的文案;记得这个扩展的 bundle id 也要申请 Distribution 权限(见上)。
7. **最低系统版本**:`.individual` 授权要求 iOS 16。App 整体部署目标不必提高 ——
   代码里已用 `#available(iOS 16.0, *)` 守护,低版本 `available` 返回 `false`,Dart 侧回落到生命周期判定。

## App Review 备注示例

> Lares uses the Family Controls framework with **individual** authorization only (the user authorizes for
> themselves; this is not a parental-control feature). When the user explicitly starts a "Focus Study"
> session, Lares applies a temporary shield to other app categories via ManagedSettings so the user can
> study without distractions; the shield is removed as soon as the session ends or the user stops it.
> The user chooses which apps remain available through FamilyActivityPicker. Lares does not collect,
> store, or transmit any app-usage or Screen Time data.
>
> To test: open a circle → Plugins → Focus Study → Start. Grant the Screen Time permission when prompted.
> Other apps are shielded; tap Stop to remove the shield.
