# 隐私清单(PrivacyInfo.xcprivacy)编写依据与判断记录

配套文件:`app/ios/Runner/PrivacyInfo.xcprivacy`

本文件记录该清单**每一项的依据、证据 URL 和推理链**,以及哪些地方是判断、
哪些地方待验证。目的是让下一个人(或半年后的你)不必重跑一遍调研,
就能判断某次依赖升级或功能改动是否需要动清单。

> **调研日期**:2026-10。Apple 文档页会改版,下面的 URL 若失效请按标题重新检索。
> 本文所有 Apple 原文均为逐字引用,常量与 reason code 均经实际抓取核对,
> 未使用记忆填补;无法证实的项目一律显式标注「待验证」。

---

## 0. 结论速览

| 项 | 结论 |
|---|---|
| `NSPrivacyTracking` | `false` |
| `NSPrivacyTrackingDomains` | 空数组 |
| `NSPrivacyCollectedDataTypes` | 声明 3 项:`AudioData`、`Name`、`UserID`(均 Linked=true、Tracking=false、AppFunctionality) |
| `NSPrivacyAccessedAPITypes` | 只声明 `NSPrivacyAccessedAPICategoryUserDefaults` + `CA92.1`、`1C8F.1` |
| 位置数据 | **判定为不算 collected**,未声明 —— 这是全篇最需要复核的判断,见 §3.1 |
| File timestamp | 当前不声明(死代码),启用录音落盘后必须补 `C617.1`,见 §4.2 |

**上架前必做的三件事**(与清单本身无关但会一起被打回):
1. `PRODUCT_BUNDLE_IDENTIFIER` 目前是 Flutter 默认占位 `com.example.laresApp`,必须改。
2. `Info.plist` 缺 `ITSAppUsesNonExemptEncryption`,提交时会被追问。
3. 把 `PrivacyInfo.xcprivacy` 加入 Runner target 的 **Copy Bundle Resources**
   (本项目走 SPM 而非 CocoaPods,没有 pod post_install hook 可用,必须在
   Xcode 里手动加,或改 `project.pbxproj`)。目前 pbxproj 中尚无该文件的引用。

---

## 1. 规则基础:三套容易混淆的责任划分

这三条规则方向不同,混淆会导致多写或漏写。均为官方原文逐字引用。

**(a) Required Reason API —— 谁的代码用,谁声明,不能互相替代**

> "If you use the API in your app's code, then you need to report the API in your
> app's privacy manifest file. If you use the API in your third-party SDK's code,
> then you need to report the API in your third-party SDK's privacy manifest file.
> Your third-party SDK can't rely on the privacy manifest files for apps that link
> the third-party SDK, or those of other third-party SDKs the app links, to report
> your third-party SDK's use of required reasons API."

> "For each executable or dynamic library in an app that uses a required reason API,
> the bundle that includes the executable or dynamic library needs to include a
> privacy manifest file that reports the API."

来源:<https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api>

**这直接回答了任务里的第 4 问**:插件自带清单**不能**替 app 声明 app 自己代码用的 API;
反过来 app 也不需要替插件声明插件用的 API。

**(b) 数据收集 —— 方向相反,app 清单不必覆盖 SDK 收集的数据**

> "Third-party SDKs need to provide their own privacy manifest files that record the
> types of data they collect. Your app's privacy manifest file doesn't need to cover
> data collected by third-party SDKs that your app links to."

来源:<https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests>

**(c) App Store Connect 营养标签 —— 又不一样,必须涵盖第三方**

营养标签要求 "identify all of the data you or your third-party partners collect",
且 "Developers are responsible for all code included in their apps."
来源:<https://developer.apple.com/app-store/app-privacy-details/>

> ⚠️ 本文只处理 (a) 和 (b),即 `PrivacyInfo.xcprivacy` 文件本身。
> 在 App Store Connect 网页上填营养标签时规则是 (c),**不要直接照抄本清单**。

**合规时间线**(逐字):
- "Starting May 1, 2024, apps that don't describe their use of required reason API
  in their privacy manifest file aren't accepted by App Store Connect."
- "Starting November 12, 2024, apps you submit for review in App Store Connect must
  contain a valid privacy manifest file."(TN3181)
- "Starting February 12, 2025, apps you submit for review in App Store Connect must
  contain a valid privacy manifest file for a certain number of commonly used
  third-party SDKs."

---

## 2. Apple 对 "collect" 的官方定义(判断的基准)

这是本文所有数据类型判断的依据,两处措辞略有不同,**都要看**。

**主定义**(Data collection 章节,逐字):

> "'Collect' refers to transmitting data off the device in a way that allows you
> and/or your third-party partners to access it for a period longer than what is
> necessary to service the transmitted request in real time."

**第二处定义**(Additional guidance,条目 "You collect data to service a request but
do not retain it after servicing the request.",逐字):

> "'Collect' refers to transmitting data off the device and storing it in a readable
> form for longer than the time it takes you and/or your third-party partners to
> service the request. For example, if an authentication token or IP address is sent
> on a server call and not retained, or if data is sent to your servers then
> immediately discarded after servicing the request, you do not need to disclose this
> in your answers in App Store Connect."

**仅设备内处理的官方豁免**(逐字):

> "Data that is processed only on device is not 'collected' and does not need to be
> disclosed in your answers. If you derive anything from that data and send it off
> device, the resulting data should be considered separately."

来源(以上三条同页):<https://developer.apple.com/app-store/app-privacy-details/>

**提炼出的两条件判据**:数据要算 collected,必须同时满足
1. 离开设备(transmitting off the device),且
2. 留存时间超过实时服务该请求所需(longer than necessary to service in real time)。

---

## 3. 逐项数据判定

### 3.1 位置数据 —— 判定为**不算 collected**,不声明 ⚠️ 本篇最关键的判断

**代码事实**(已逐行核实):

- 客户端 `app/lib/src/state/location_share.dart`:用户显式开启后,
  `Geolocator.getPositionStream(LocationSettings(accuracy: LocationAccuracy.medium,
  distanceFilter: 50))`,经 `reportLocation()` 通过 WebSocket 发 `{'t':'loc', lat, lng}`。
  出房自动停止(`_onRoomChanged`)。
- 服务端 `server/src/index.js:444-462`(`case 'loc'`):
  ```js
  member.loc = { lat, lng, ts: Date.now() };   // 内存 Map,非数据库
  broadcast(session.circleId, { t:'member_loc', ... });  // 立即转发同圈成员
  ```
  `loc_off`(:464-471)与断连时 `delete member.loc`。
  **全文件无任何位置持久化代码** —— 服务端唯一的落盘逻辑是 `saveNote()`(语音便签),
  位置不经过它。已 grep 确认无位置相关的 `writeFile` / 数据库调用。

**推理链**:

1. 条件一(离开设备)**成立** —— 数据确实发到了服务器。
2. 条件二(留存超过实时服务所需)**不成立** —— 服务端把它放在内存 Map 里的唯一目的,
   是支撑两件实时的事:立刻 broadcast 给同圈成员,以及让**后进房的人**通过
   `roomSnapshot()`(:269, :275)拿到当前在线成员的位置。这两者都是「服务该请求」
   的一部分:位置的生命周期严格绑定于「该用户此刻正在共享且在线」,
   关闭共享或断连即刻消失,不写磁盘、无数据库、进程重启全部丢失。
3. 因此按 Apple 的两条件判据,**不构成 collect**。
   最直接对应的官方原文是第二处定义中的 "if data is sent to your servers then
   immediately discarded after servicing the request, you do not need to disclose this"。

**⚠️ 反方意见(必须一并记录,不要当作已经解决)**:

Apple 在同一页有一条针对 app 内私信的条目:

> 条目:"You offer in-app private messaging between users that are not SMS text messages."
> 答复:"Declare emails or text messages on your label. Text messages refer to both
> SMS and non-SMS messages."

这条**没有给出「不留存则豁免」的例外**。它与上面的通用 collect 定义存在张力:
如果 Apple 对「实时转发但不留存」的私信仍要求声明,那么同样架构的位置转发
是否也该声明,官方文档**没有直接给出答案**。我已检索,Apple 官方页面上
**不存在**针对「传输给其他用户但开发者服务器不存储」这一情形的专门条目。

**当前的选择与理由**:采用「不声明」。因为
(a) 通用 collect 定义是明文的、可逐字引用的,而私信那条针对的是消息内容不是位置;
(b) 位置在服务端确实一秒都没有写入过任何持久化介质。

**但这属于判断而非事实。** 如果希望零风险,保守做法是声明
`NSPrivacyCollectedDataTypeCoarseLocation`(注意用 Coarse 而非 Precise:
`LocationAccuracy.medium` 在 iOS 上约对应百米级,不满足 Precise 定义中
"same or greater resolution as a latitude and longitude with three or more
decimal places" —— 不过这个映射关系本身**待验证**,见 §6)。
多声明不会被拒,只会让产品页的隐私标签多一项。**建议在首次提交前
通过 App Store Connect 的 Contact Us 就这一点向 Apple 确认。**

参考:官方另有一条 "You collect precise location, but immediately de-identify and
coarsen it before storing." → "Disclose that you collect Coarse Location" ——
可见 Apple 认为「存储」是判定的关键动作,这一条侧面支持了本文的判断。

### 3.2 语音便签音频 —— **算 collected**,已声明 `NSPrivacyCollectedDataTypeAudioData`

**代码事实**:

- 客户端 `app/lib/src/state/voice_notes.dart:141-170`(`stopAndSend`):
  用 `record` 包录 ≤15s AAC,`base64Encode(bytes)` 后 `http.post` 到 `/notes`。
- 服务端 `server/src/index.js:779-806`(`POST /notes`)→ `saveNote()`(:705-708):
  ```js
  await writeFile(path.join(dir, `${note.id}.json`), JSON.stringify(note));
  ```
  **明确写入磁盘**,记录含 `{id, circleId, userId, name, audio, mime, durationSec, createdAt}`。
- 删除时机:其他成员播放完毕后客户端发 `DELETE /notes/:id`(`playAll`,:195-196)。
  也就是说**如果没人听,便签会一直留在服务器磁盘上**。

**推理**:两个条件都成立 —— 离开设备 ✓,留存时间远超实时服务(要等到别人来听)✓。
**这是本 app 唯一明确构成 collect 的数据流。**

**字段选择依据**:官方 Additional guidance 逐字:
> "Mark 'Other User Content' to represent generic free form text fields and
> **'Audio Data' for voice recordings**."

- `Linked = true`:便签 JSON 里 audio 与 `userId`、`name` 同处一条记录,
  未做任何去标识化。按官方 "Data collected from an app is often linked to the
  user's identity, unless specific privacy protections are put in place before
  collection to de-identify or anonymize it" —— 本项目没有这类保护,故为 true。
- `Tracking = false`:不与任何第三方数据关联,不用于广告。
- `Purpose = AppFunctionality`:官方定义涵盖 "enable features"。这是产品功能本身。

**注意**:这一项与任务简报里「服务器不落盘」的描述**不符**。简报只提到了
位置不落盘,但语音便签这条路径是真实落盘的。这是本次调研中最重要的事实修正。

### 3.3 昵称 —— **算 collected**,已声明 `NSPrivacyCollectedDataTypeName`

昵称本地存 shared_preferences(`identity.dart:37` 的 `lares.name`,默认「我」),
本身不构成 collect(仅设备内)。但它**随语音便签一起落盘**
(`index.js:793`: `name: String(name ?? '圈友').slice(0, 24)`),
因此与音频同样满足两个条件。

选 `Name`(Contact Info 类)的依据:官方定义 "Name, such as first or last name"。
用户自填的显示名属此类。

### 3.4 userId —— **算 collected**,已声明 `NSPrivacyCollectedDataTypeUserID`

`identity.dart:40-43`:`'u_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'`。
本机生成的随机串,随便签落盘。

官方 User ID 定义涵盖 "assigned user ID, customer number, or other user- or
account-level ID that can be used to identify a particular user or account" ——
虽无账号体系,但它确实用于识别特定用户,如实声明。

**为什么不声明 `DeviceID`**:官方 Device ID 定义是 "the device's advertising
identifier, or other device-level ID"。本 app 的 `deviceId` 同样是本地时间戳
自生成的,**不是** IDFA、也不是 `identifierForVendor`(全仓库零命中)。
它不是从系统设备标识 API 取得的,不落入该类别。

### 3.5 实时通话音频、文字与图片消息 —— **不算 collected**,不声明

- **通话音频**:LiveKit 实时媒体流,经 SFU 转发,不落盘。属实时服务。
- **文字与图片消息**:走 **LiveKit data channel** 直接送达同圈成员,
  **完全不经过本项目的信令服务器**。已 grep 服务端确认:`index.js` 中
  **没有任何**聊天消息的存储或转发代码(搜 `case 'chat'` / `saveMessage` 均零命中)。
  连「传输到开发者服务器」这一步都不存在,更谈不上留存。

  > 这里同样受 §3.1 提到的「in-app private messaging」条目的张力影响。
  > 但与位置不同的是,消息**根本没有经过开发者的服务器**,
  > 连 collect 的第一个条件(transmitting to *your* servers)都不满足,
  > 因此不声明的理由比位置更充分。

- **图片来源**:`image_source_io.dart` 用 `file_selector` 的 `openFile()`
  系统文档选择器。全仓库**无** `image_picker`、无 `PHPhotoLibrary`、
  Info.plist 无相册权限描述。故**不涉及**
  `NSPrivacyCollectedDataTypePhotosorVideos`。

  > ⚠️ 常量拼写陷阱:是 `PhotosorVideos`(中间 `or` **小写**),
  > 不是 `PhotosOrVideos`。写错会触发 ITMS-91056。本清单未用到该常量,
  > 此处记下以防将来加相册功能时踩坑。

---

## 4. Required Reason API 逐项判定

### 4.1 五个类别的核查结果

app 自身代码的核查范围:`app/lib` 全部 Dart 文件 + `app/ios/Runner/AppDelegate.swift`
+ `app/ios/Runner/SceneDelegate.swift`。

| 类别 | 结论 | 依据 |
|---|---|---|
| `...CategorySystemBootTime` | 不声明 | grep `systemUptime` / `mach_absolute_time` / `bootTime` 全仓库零命中 |
| `...CategoryDiskSpace` | 不声明 | grep `statfs` / `statvfs` / `volumeAvailableCapacity` / `systemFreeSize` / `freeSpace` 零命中 |
| `...CategoryActiveKeyboards` | 不声明 | grep `activeInputModes` / `UITextInputMode` 零命中 |
| `...CategoryFileTimestamp` | **当前不声明**,见 §4.2 | 唯一触及处是死代码 |
| `...CategoryUserDefaults` | **声明 `CA92.1` + `1C8F.1`**,见 §4.3 | `1C8F.1` 是必需(home_widget 写 App Group 且无自带清单) |

**关于 DiskSpace 的一个易错点**:`disk_guard.dart` 名字里有 "disk",但它
**不触发** DiskSpace 类别 —— 它只是把自家目录下文件的 `size` 累加起来
执行自设的 2 GiB 配额,从未查询过文件系统的真实剩余空间。
Apple 该类别针对的是 `statfs` / `volumeAvailableCapacityKey` 这类
**查询卷可用容量**的 API。

**AppDelegate.swift / SceneDelegate.swift 已逐行读完**:只做 Flutter 引擎注册
和 `lares://` 深链解析(MethodChannel `lares/deeplink`),
未触碰任何 required reason API。

### 4.2 File timestamp:为什么当前不声明 ⚠️ 升级功能时必查

**事实**:`app/lib/src/recording/disk_guard.dart:306` 确实调用了
`e.statSync()`,`:312` 读 `st.modified` —— 这落在 Apple 的 File timestamp
类别内(该类别涵盖 `stat`、`FileAttributeKey.modificationDate` 等 13 个 API)。

**但整条录音落盘管线是未接线的死代码**,四路验证:

1. `LaresConfig.recordingEnabled`(`config.dart:41-42`)默认 `false`,
   源码注释明写「**默认关闭,入口完全不出现**」。
2. `app/lib` 下**没有任何文件** import `disk_guard.dart`
   (唯一 import 者是 `app/test/recording_disk_guard_test.dart`)。
3. `DiskGuard` 在生产代码中零构造点;`recording_service.dart:61` 预留的
   `wouldExceedDisk` 注入接缝从未被接上。
4. 整个 `recording/` 子系统只有 `recording_consent.dart`(同意状态机)与
   `recording_indicator.dart`(指示灯)被 main.dart 和 UI 引用;
   `disk_guard` / `capture_session` / `transcript_store` / `stt_*` / `vad`
   构成一片无人引用的孤岛。

Dart AOT 在 release 构建时做 tree-shaking,未被引用的库代码不进入二进制;
测试代码更不会被编译进 app。故当前**不声明**。

**⚠️ 触发重新评估的条件(任一成立就必须补声明)**:
- 有人用 `--dart-define=LARES_RECORDING=true` 出正式包;
- 有人把 `DiskGuard` / `RecordingService` / `TranscriptStore` 接进生产代码
  (接缝已经预留好了,`wouldExceedDisk` 参数就在 `recording_service.dart:61` 等着)。

届时应声明:

```xml
<dict>
    <key>NSPrivacyAccessedAPIType</key>
    <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
    <key>NSPrivacyAccessedAPITypeReasons</key>
    <array>
        <string>C617.1</string>
    </array>
</dict>
```

`C617.1` 官方原文:
> "Declare this reason to access the timestamps, size, or other metadata of files
> inside the app container, app group container, or the app's CloudKit container."

**适用性确认**:DiskGuard 枚举的是 app 自己容器内的录音/转写目录,
读 mtime 与 size 用于配额清理 —— 与 C617.1 的措辞逐字吻合(它明确涵盖
"timestamps, size, or other metadata" 且限定在 "inside the app container")。
**不要**用 `0A2A.1`:官方明确 "This reason may only be declared by third-party SDKs"。

**保守替代方案**:如果不想依赖 tree-shaking 的推断,现在就把
`FileTimestamp` + `C617.1` 声明上。Apple 对「声明了但实际未调用」的类别
不作处罚(清单是声明使用**理由**,不是使用**证明**),
而漏声明会被自动化检查退回。这是一个**风险不对称**的选择:
多声明的代价是产品页多一行,漏声明的代价是一轮审核往返。
**当前选择了「不声明」是因为 §4.1 的核查足够确定;
若你倾向零风险,直接加上也是完全正当的。**

### 4.3 User defaults:声明了 `CA92.1` + `1C8F.1`,两条都有确切来源

两个 reason code 的官方定义:

| Code | 官方原文(节选) |
|---|---|
| `CA92.1` | "Declare this reason to access user defaults to read and write information that is only accessible to the app itself." |
| `1C8F.1` | "...information that is only accessible to the apps, app extensions, and App Clips that are **members of the same App Group** as the app itself." |

**`CA92.1` —— 属于「从严」声明,但理由充分**

app 经 shared_preferences 持久化昵称、圈子列表、服务器档案等
(`identity.dart` / `settings_store.dart` / `circle_store.dart` /
`update_service.dart`),存在自身沙盒内 → 对应 `CA92.1`。

严格按规则 §1(a),实际调用发生在 `shared_preferences_foundation` 插件内部,
而该插件自带清单(声明的是 `1C8F.1`),照字面 app 可以不写。仍然写上是因为:
Runner 主 target 与插件同处一个可执行文件(SPM 静态链接),边界不像动态
framework 那样清晰;且风险不对称 —— 多声明无罚,漏声明被退回。

另外,`flutter_foreground_task` 11.0.3 的 iOS 代码有 **17 处
`UserDefaults.standard`** 调用,而该插件**不自带清单**。虽然本项目的
`ForegroundRoomService.init()` 在非 Android 平台直接 return
(`foreground_service.dart:13`),但插件的 iOS 原生代码仍被链接进二进制。
`CA92.1` 一并覆盖了这个情形。

**`1C8F.1` —— ⚠️ 这一条是必须的,不是从严**

这是本次调研中容易漏掉、但确实构成缺口的一项:

1. `main.dart:126` **无条件**调用 `WidgetService().init(...)`。
2. `widget_service.dart:53` 判定 `hasHomeWidget = platform == 'android' ||
   platform == 'ios'`,`:59-61` 在 iOS 上执行
   `HomeWidget.setAppGroupId('group.com.lfm097384.lares')`。
3. `:159-163` 经 `HomeWidget.saveWidgetData()` 写入
   `circle_name` / `presence_text` / `primary_circle_id` / `has_primary`。
   这些写入落到 **App Group 的 NSUserDefaults**。
4. `app/ios/Runner/Runner.entitlements` 确已配置
   `com.apple.security.application-groups` = `group.com.lfm097384.lares`,
   说明这条路径在真机上是通的,不是死代码。
5. **`home_widget` 0.7.0+1 不自带隐私清单** —— 已核实其全部 37 个已发布
   版本均无该文件,且其插件内部有 5 处 `UserDefaults(suiteName:)` 调用
   (`SwiftHomeWidgetPlugin.swift:77,106,154`、
   `HomeWidgetBackgroundWorker.swift:40,89`)。**升级到最新版也解决不了。**

按规则 §1(a),插件没声明的部分不会自动被覆盖;而这条路径由 app 的代码
主动发起、写的是 app 自己的 App Group —— 因此必须由 app 侧清单申报。

> ⚠️ **`ios/LaresWidget/` 的额外注意事项**
> `LaresWidget.swift:29-33` 直接调用
> `UserDefaults(suiteName: "group.com.example.lares_app")` 读取共享数据。
> 该 target **目前尚未加入 Xcode 工程**(`project.pbxproj` 中 grep
> `LaresWidget` 零命中,需先在 macOS 上跑 `ios/add_widget_target.rb`)。
> 一旦接入,**widget extension 作为独立 bundle 需要它自己的一份
> `PrivacyInfo.xcprivacy`**(同样声明 UserDefaults + `1C8F.1`)。
> Apple 原文:"For each executable or dynamic library in an app that uses a
> required reason API, the bundle that includes the executable or dynamic
> library needs to include a privacy manifest file that reports the API."
>
> 另注:该文件里的 App Group 写作 `group.com.example.lares_app`,
> 而 `Runner.entitlements` 与 `widget_service.dart` 用的是
> `group.com.lfm097384.lares` —— **两者不一致**,接入前需统一,
> 否则 widget 读不到数据。(此为顺带发现,不属清单问题。)

---

## 5. 第三方插件清单核查结果

**结论**:6 个高风险插件全部自带清单且锁定版本达标;但完整核查 19 个包后发现
**`home_widget` 与 `flutter_foreground_task` 无清单却调用 UserDefaults** ——
这个缺口已由 app 侧清单的 `1C8F.1` / `CA92.1` 覆盖(见 §4.3)。

### 5.1 六个高风险插件(全部达标)

版本号取自 `app/pubspec.lock`(实际锁定版本,非 pubspec.yaml 的声明范围)。

| 插件 | 锁定版本 | 自带清单 | 首次加入版本 | 达标 | 清单内容 |
|---|---|---|---|---|---|
| shared_preferences | `2.5.5` | 是 | `shared_preferences_foundation` **2.3.5** | ✅ | `UserDefaults` + **`1C8F.1`** |
| └ shared_preferences_foundation | `2.5.7` | | | | |
| path_provider | `2.1.6` | 是 | `path_provider_foundation` **2.3.2** | ✅ | **API 数组为空** |
| └ path_provider_foundation | `2.6.0` | | | | |
| device_info_plus | `13.2.0` | 是 | **10.0.1** | ✅ | 空 |
| package_info_plus | `10.2.1` | 是 | **6.0.0** | ✅ | 空 |
| connectivity_plus | `7.3.1` | 是 | **6.0.1** | ✅ | 空 |
| geolocator | `14.0.3` | 是 | `geolocator_apple` **2.3.7** | ✅ | 空 |
| └ geolocator_apple | `2.3.14` | | | | |

**两个需要纠正的常见误解**(任务简报里也这么假设了,但实测不成立):

1. **shared_preferences 用的是 `1C8F.1`,不是 `CA92.1`。** 逐字实测内容:
   ```xml
   <key>NSPrivacyAccessedAPIType</key>
   <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
   <key>NSPrivacyAccessedAPITypeReasons</key>
   <array>
       <string>1C8F.1</string>
   </array>
   ```
2. **path_provider 没有声明 `C617.1`,它的 `NSPrivacyAccessedAPITypes` 是空数组。**
   已在 v2.3.2 / v2.4.0 / v2.4.4 三个 tag 逐一 fetch 确认,内容一致且始终为空。

**证据 URL**:
- shared_preferences_foundation 清单(HTTP 200 实测):
  <https://raw.githubusercontent.com/flutter/packages/main/packages/shared_preferences/shared_preferences_foundation/darwin/shared_preferences_foundation/Sources/shared_preferences_foundation/Resources/PrivacyInfo.xcprivacy>
  首版 2.3.5:<https://pub.dev/packages/shared_preferences_foundation/versions/2.3.5/changelog>
  (负向对照:2.3.4 tag 下同路径 404)
- path_provider_foundation 清单:
  <https://raw.githubusercontent.com/flutter/packages/path_provider_foundation-v2.4.4/packages/path_provider/path_provider_foundation/darwin/path_provider_foundation/Sources/path_provider_foundation/Resources/PrivacyInfo.xcprivacy>
  (负向对照:2.3.1 tag 下 404)
- plus 系列三个插件同日批量加入(作者 Miguel Beltran,2024-02-12),
  三份清单文件字节完全相同(同一 git blob SHA `a34b7e2e`):
  - device_info_plus PR [#2582](https://github.com/fluttercommunity/plus_plugins/issues/2582),commit `34fe31eb` → 10.0.1(10.0.0 已撤回)
  - package_info_plus PR [#2584](https://github.com/fluttercommunity/plus_plugins/issues/2584),commit `895fe1a2` → 6.0.0
  - connectivity_plus PR [#2581](https://github.com/fluttercommunity/plus_plugins/issues/2581),commit `707fab70` → 6.0.1(6.0.0 发布有误)
  - 当前路径示例:<https://raw.githubusercontent.com/fluttercommunity/plus_plugins/main/packages/connectivity_plus/connectivity_plus/ios/connectivity_plus/Sources/connectivity_plus/PrivacyInfo.xcprivacy>
- geolocator_apple 清单(注意在 `darwin/` 而非 `ios/`):
  <https://raw.githubusercontent.com/Baseflow/flutter-geolocator/main/geolocator_apple/darwin/geolocator_apple/Sources/geolocator_apple/PrivacyInfo.xcprivacy>
  版本依据:<https://pub.dev/packages/geolocator_apple/versions/2.3.7/changelog>

### 5.2 其余依赖的核查结果

经 pub.dev 发布 tarball 全量文件枚举 + 按锁定版本 git tag 抓文件本体 +
本机 pub cache 解包 + 二进制 xcframework 下载解包实测,**非 changelog 推断**:

| 插件 | 锁定版本 | 自带清单 | 首次加入 | 清单内容 |
|---|---|---|---|---|
| file_selector_ios | `0.5.3+6` | **是** | **0.5.1+8** | 空数组 |
| record_ios | `1.2.1` | **是** | **1.0.0** | 空数组 |
| WebRTC-SDK(二进制) | `150.7871.01` | **是** | 未查证到 | `SystemBootTime` → `35F9.1`,`8FFB.1`;`FileTimestamp` → `C617.1` |
| livekit_client | `2.12.0` | **否** | — | — |
| flutter_webrtc | `1.6.0` | **否** | — | — |
| flutter_foreground_task | `11.0.3` | **否**(103 个版本全无) | — | 但有 17 处 `UserDefaults.standard` 调用 |
| home_widget | `0.7.0+1` | **否**(37 个版本全无) | — | 但有 5 处 `UserDefaults(suiteName:)` 调用 |
| sherpa_onnx_ios | `1.13.8` | **否** | — | — |
| media_kit_libs_ios_audio | `1.1.4` | **否** | 预计 1.1.5(**未发布**) | — |
| media_kit | `1.2.6` | 不适用 | — | 无 iOS 原生代码 |
| flutter_map | `8.3.2` | 不适用 | — | 纯 Dart |
| web_socket_channel / http / crypto / latlong2 | `3.0.3` / `1.6.0` / `3.0.7` / `0.9.1` | 不适用 | — | 纯 Dart |
| tray_manager / window_manager | `0.5.3` / `0.5.2` | 不适用 | — | 仅桌面平台,不参与 iOS 编译 |

**三个会导致误判的坑**(记下来,免得下次重踩):

1. **`media_kit_libs_ios_audio`:GitHub 有 ≠ pub.dev 有。** 仓库 main 分支已
   合入清单(PR #1412,2026-05),但**从未发布**;pub.dev 最新仍是 1.1.4。
   只查 GitHub 会误判为已满足。其 xcframework 由 podspec 在安装时下载
   (libmpv),该构建期产物解包后同样 0 命中。
2. **livekit CHANGELOG 2.1.4 的措辞是陷阱。** 逐字写着
   `bump version of flutter-webrtc with privacy manifest files`,字面像是
   flutter_webrtc 加了清单,但该包任何版本任何路径都无此文件。更硬的反证:
   两插件 iOS/macOS 共 8 份 podspec 全无 `resource_bundles` 声明,
   SPM target 亦无 `resources:` —— 没有资源声明,即便有文件也进不了产物。
3. **`record` 6.x 已把 `record_darwin` 拆成 `record_ios` + `record_macos`。**
   `record_darwin` 在当前 lock 中**不存在**。且 record_ios 的 CHANGELOG
   从未提及 privacy manifest(文件随拆分静默继承)—— 只查 changelog 会
   误判为「无」。反过来 `window_manager` 0.5.1 的 changelog 命中 "privacy",
   实际却是把指向不存在文件的 podspec 声明注释掉,方向相反。

**阴性结论的可信度**:对 `flutter_foreground_task`(103 版)与 `home_widget`
(37 版)做了全部已发布版本穷举,0 命中;并用已知带清单的
`path_provider_foundation` / `shared_preferences_foundation` 跑同一流程做
对照(均正常出阳性),确认工具能检出阳性,阴性结论才成立。

**这些「无清单」项是否阻塞上架?**

- 按规则 §1(a)(b),第三方 SDK 的清单是 **SDK 作者的责任**,app 侧无法也无需
  替它们声明。上述插件均**不在** Apple 那份「commonly used third-party SDKs」
  强制名单上(该名单主要是 Firebase、Google 系、Facebook SDK 等),
  因此**不构成 2025-02-12 那条规则的阻塞**。
- **但有一个例外已被处理**:`home_widget` 的 App Group UserDefaults 写入是由
  **app 自己的代码**主动发起的(见 §4.3),这部分由本清单的 `1C8F.1` 覆盖。
  `flutter_foreground_task` 的 `UserDefaults.standard` 由 `CA92.1` 覆盖。
- 仍建议首次归档后用 Xcode 的 **Product > Archive > Generate Privacy Report**
  自动汇总所有链接进来的清单,一次性核对全貌。

---

## 6. 待验证事项(明确列出,不含糊带过)

1. **位置是否真的不用声明** —— §3.1 的判断依据的是通用 collect 定义,
   但 Apple 对「实时转发不留存」这一情形**没有专门条目**,且 in-app private
   messaging 那条存在张力。**建议向 Apple 官方确认**(App Store Connect →
   Contact Us → App Review)。保守做法是声明 `CoarseLocation`。

2. **`LocationAccuracy.medium` 对应 Coarse 还是 Precise** —— 若最终决定声明位置,
   需要确认这个映射。Apple 的分界是「纬经度小数点后三位或更高精度」
   (约 111 米)。geolocator 的 `medium` 在 iOS 上映射到
   `kCLLocationAccuracyHundredMeters`(约 100 米),**刚好在分界线附近**,
   未实测确认。且需注意:iOS 的 accuracy 是「期望精度」,系统**可能返回
   更精确的结果**;若实际返回精度更高,应按 Precise 声明。**待验证**。

3. **`WebRTC-SDK` 首次加入清单的版本** —— 仅确证当前锁定的 150.7871.01
   自带(SHA256 与 SPM binaryTarget checksum 逐字节一致)。
   CocoaPods Specs 仓库各 sharded 路径均 404,未能回溯首个版本。
   影响:若将来**降级** livekit_client 导致 WebRTC 二进制降级,需重查。

4. **空 `NSPrivacyAccessedAPITypes` 能否消除 ITMS-91053** —— 若
   `media_kit_libs_ios_audio` 打包的 libmpv/ffmpeg 二进制实际调用了
   required reason API,其缺失清单可能触发告警。需对二进制做符号分析,
   超出本次可验证范围。首次上传时留意 App Store Connect 的邮件反馈。

4. **tree-shaking 是否真的剔除了 `disk_guard.dart`** —— §4.2 的结论基于静态
   引用分析(import / 构造点 / barrel / 条件导入四路验证),
   未在真机 release 二进制上用 `nm` / `strings` 验证。
   若要彻底消除疑虑,要么实测,要么直接声明 `C617.1`。

5. **"Data Not Collected" 这个短语查无实据** —— 在 Apple 开发者文档
   与 App Store Connect 帮助页的渲染全文中均检索不到。
   官方等价措辞是 App Store Connect 里的
   `"No, we do not collect data from this app"`。
   (本项目有 collected 数据,不适用该选项,此条仅备忘。)

6. **macOS 端也缺清单** —— `app/macos/` 是完整的 Flutter macOS runner
   (`MACOSX_DEPLOYMENT_TARGET = 12.0`),同样没有 `PrivacyInfo.xcprivacy`。
   若要上 Mac App Store,需在 `app/macos/Runner/` 放一份
   (位置是 `MacSample.app/Contents/Resources/PrivacyInfo.xcprivacy`,与 iOS 不同)。
   内容可与 iOS 基本一致。另注意 macOS 端 `Info.plist` 只有麦克风描述、
   **无位置权限描述**,`Release.entitlements` 也**未开**
   `com.apple.security.personal-information.location` ——
   沙盒下 geolocator 在 macOS 会直接失败。本次未处理(超出任务范围)。

---

## 7. 后续维护检查点

**每次改动下列任一项时,回来重读本文并更新清单:**

| 触发条件 | 需要做什么 |
|---|---|
| 启用录音落盘(`LARES_RECORDING=true` 出正式包,或接线 `DiskGuard`/`TranscriptStore`) | 增补 `FileTimestamp` + `C617.1`(§4.2)。若还接了云端 STT(`stt_cloud.dart` 会把音频上传给 Groq),则音频流向第三方,需重新评估 collected 声明并在营养标签里申报第三方 |
| `LaresWidget` target 接入 Xcode 工程 | 给 widget extension **单独建一份清单**(声明 UserDefaults + `1C8F.1`),它是独立 bundle;并统一两处不一致的 App Group 名(§4.3) |
| 移除 `home_widget` 依赖或停用主屏 Widget | 可考虑从清单中移除 `1C8F.1`(但保留也无害) |
| 加相册/相机入口(引入 `image_picker` 等) | 声明 `NSPrivacyCollectedDataTypePhotosorVideos`(注意 `or` 小写),并补 Info.plist 权限描述 |
| 服务器开始持久化位置或聊天记录 | 位置改为 collected,增补 `CoarseLocation`/`PreciseLocation`;消息则需声明 `EmailsOrTextMessages` 或 `OtherUserContent` |
| 引入任何分析/崩溃上报/广告 SDK | `NSPrivacyTracking` 与 `NSPrivacyTrackingDomains` 需重新评估;新增 `Diagnostics`/`CrashData` 等类型 |
| 加账号体系 | `UserID` 的 Linked 语义变化,可能需要加 `EmailAddress` 等 Contact Info |
| 升级 §5 表格中的插件 | 原则上只会变好(清单只增不减),但**降级**或换插件时必须重查。用 Generate Privacy Report 复核 |
| Flutter SDK 大版本升级 | 引擎自身可能改变 required reason API 的使用。复核 Generate Privacy Report |

**每次提交前的机械检查**:
```bash
plutil -lint app/ios/Runner/PrivacyInfo.xcprivacy   # 需在 macOS 上
```
成功输出 `... : OK`。格式错误会以 `ITMS-91056: Invalid privacy manifest` 被退回。

并确认文件已在 Runner target 的 Copy Bundle Resources 中
(最终应位于 `Runner.app/PrivacyInfo.xcprivacy`,即 bundle 根目录)。

---

## 8. 主要参考来源

- Required Reason API 及全部 reason code:
  <https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api>
- 数据使用描述:
  <https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests>
- 清单文件总览与放置位置:
  <https://developer.apple.com/documentation/bundleresources/privacy-manifest-files>
- 常量枚举(Apple 已把枚举从文章页迁到符号页,文章页本身不含常量值):
  <https://developer.apple.com/documentation/bundleresources/app-privacy-configuration>
- "collect" 定义、Additional guidance、Optional disclosure:
  <https://developer.apple.com/app-store/app-privacy-details/>
- TN3181 调试无效清单(含 `plutil -lint` 与 ITMS-91056 原文):
  <https://developer.apple.com/documentation/technotes/tn3181-debugging-invalid-privacy-manifest>
- TN3183 Required Reason API 条目写法(含官方 XML 示例):
  <https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest>
- TN3184 数据收集条目写法:
  <https://developer.apple.com/documentation/technotes/tn3184-adding-data-collection-details-to-your-privacy-manifest>

> 注:Apple 文档页为 JS 渲染,直接抓 HTML 只能拿到标题。
> 调研时通过官方 DocC JSON 端点
> `https://developer.apple.com/tutorials/data/documentation/<path>.json`
> 获取结构化原文。若将来需要复核,用同样方法。
