import 'package:livekit_client/livekit_client.dart' show lkPlatformSupportsE2EE;

/// 本平台是否支持 E2EE 的探针。
///
/// **唯一权威来源是 LiveKit SDK 自己的 `lkPlatformSupportsE2EE()`** ——
/// 因为真正会因为它抛异常的是 `room.connect()`(livekit_client 2.12.0,
/// `lib/src/core/room.dart:289-292`:不支持就 `throw LiveKitE2EEException`)。
/// 我们自己另写一套平台白名单必然会与它漂移,漂移的那一天就是
/// 「UI 说加密了、连接却直接失败」或者更糟的反过来。
///
/// 实测过的 SDK 实现(2.12.0):
/// - 原生端 `lib/src/support/platform/io.dart`:
///   `[windows, linux, macOS, iOS, android].contains(lkPlatformImplementation())`
///   —— 本项目的五端里,iOS/Android/Windows/macOS **全部返回 true**。
/// - Web 端 `lib/src/support/platform/web.dart`:
///   `isInsertableStreamSupported() || isScriptTransformSupported()`
///   —— 运行期探测浏览器能力,**不是**静态平台判断。Chrome/Edge 有
///   insertable streams,Safari/Firefox 走 RTCRtpScriptTransform;
///   老浏览器两样都没有时返回 false。所以 Web 是**唯一可能为 false** 的那一端,
///   且必须在运行期问、不能在编译期猜。
///
/// 做成 typedef + 可注入,是为了让降级逻辑能在 `flutter test` 里被两个分支
/// 都跑到 —— 注意 `lkPlatformSupportsE2EE()` **不看** `lkPlatformIsTest()`,
/// 在 Windows 上跑 `flutter test` 它返回 true,不注入就永远测不到 false 分支。
typedef E2EEPlatformProbe = bool Function();

/// 默认探针:直接问 SDK。
bool defaultE2EEPlatformProbe() => lkPlatformSupportsE2EE();
