/// 按圈 E2EE 的粘合层:开关 + 口令 -> 密钥 -> 交给 LiveKit。
///
/// **为什么拿具体的 [LiveKitRtcService] 而不是 `RtcService`**:
/// 沿用 `chat/session_chat_transport.dart` 与 `moderation/block_audio_enforcer.dart`
/// 已经验证过的做法。`RtcService` 是刻意保持厂商无关的抽象层(设计.md §8.1),
/// 里面不能出现 `E2EEOptions`;而且它有四个测试 fake 实现
/// (`FakeRtcService implements RtcService`),往接口上加成员会直接弄坏它们。
/// 所以把**具体实现**作为独立的可选协作者传进来,抽象层一个字都不用改。
library;

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart' show E2EEOptions;

import '../rtc/livekit_rtc_service.dart';
import '../state/settings_store.dart';
import 'e2ee_key.dart';
import 'e2ee_platform.dart';
import 'e2ee_status.dart';
import 'e2ee_store.dart';

/// 把派生好的 hex 密钥装进将要进房的 [LiveKitRtcService]。
///
/// 做成可注入的种子,理由与 `moderation/block_audio_enforcer.dart` 里的
/// `RoomGetter` 完全一样:默认实现 `E2EEOptions.sharedKey` 会穿透到
/// flutter_webrtc 的 `FlutterWebRTC.Method` 平台通道去建 frame cryptor,
/// 而 `flutter test` 里根本没有那个通道(MissingPluginException)。
/// 不留这个缝,「密钥装好了」这条**成功路径**在 CI 里就一行都跑不到,
/// 而那正是「用户以为加密了」最需要被守住的地方。
typedef E2EEKeyInstaller = Future<void> Function(
  LiveKitRtcService? rtc,
  String key,
);

/// 默认安装器:真的去建 frame cryptor 并写进 `pendingEncryption`。
Future<void> defaultE2EEKeyInstaller(
  LiveKitRtcService? rtc,
  String key,
) async {
  // 用新的 `encryption:` 参数(而非废弃的 `e2eeOptions:`)才会一并加密
  // 数据通道 —— 文字/图片消息走的正是那条通道。
  final E2EEOptions options = await E2EEOptions.sharedKey(key);
  rtc?.pendingEncryption = options;
}

/// 密钥派生函数。默认是 Argon2id(在 isolate 里跑),测试可注入快实现。
typedef E2EEKeyDeriver = Future<String> Function({
  required String passcode,
  required String circleId,
});

/// 圈子 E2EE 的应用级控制器。UI 只读它,`RoomController` 只在进房前调
/// [prepareFor] 一次。
class E2EEController extends ChangeNotifier {
  E2EEController({
    required E2EEStore store,
    required SettingsStore settings,
    LiveKitRtcService? rtc,
    E2EEPlatformProbe? platformProbe,
    E2EEKeyInstaller? keyInstaller,
    E2EEKeyDeriver? keyDeriver,
  })  : _store = store,
        _settings = settings,
        _rtc = rtc,
        _probe = platformProbe ?? defaultE2EEPlatformProbe,
        _install = keyInstaller ?? defaultE2EEKeyInstaller,
        _deriveKey = keyDeriver ?? deriveCircleE2EEKeyAsync {
    _store.addListener(notifyListeners);
    _settings.addListener(notifyListeners);
  }

  final E2EEStore _store;
  final SettingsStore _settings;
  final LiveKitRtcService? _rtc;
  final E2EEPlatformProbe _probe;
  final E2EEKeyInstaller _install;

  /// 派生器做成可注入的,不只是为了测试跑得快 ——
  /// Argon2id 真算一次要 250ms,几十个用例串起来就是十几秒;
  /// 更重要的是 `compute()` 在 `flutter test` 的单 isolate 环境里
  /// 行为与真机不同,不注入就等于在测一个跟线上不一样的东西。
  final E2EEKeyDeriver _deriveKey;

  /// 本平台是否支持 E2EE(运行期探测,Web 上取决于浏览器能力)
  bool get platformSupported => _probe();

  /// 最近一次 [prepareFor] 得出的事实状态;没准备过(没进过房)时为 null。
  E2EEStatus? _activeStatus;
  E2EEStatus? get activeStatus => _activeStatus;

  /// [_activeStatus] 对应的圈子 id,防止跨圈读到上一个圈的结论。
  String? _activeCircleId;
  String? get activeCircleId => _activeCircleId;

  /// 当前房间的真实状态;圈子对不上或没准备过一律返回 null,
  /// UI 据此不显示任何加密相关字样(宁可不说,不可说错)。
  E2EEStatus? statusForActiveCircle(String? circleId) =>
      (circleId != null && circleId == _activeCircleId) ? _activeStatus : null;

  /// 圈主定的圈级规定:circleId -> true/false。没有条目 = 圈子没统一规定(老圈 / env 圈),
  /// 沿用本机开关。
  ///
  /// 为什么圈级规定压过本机开关:E2EE 是全圈同一把钥匙,一半人加密一半人不加密,
  /// 结果是彼此都听不见。注册圈由圈主拍板,服务器在 welcome / circle_settings 里推下来,
  /// 必须在 Room 构造之前(也就是 [prepareFor] 之前)就位。
  final Map<String, bool> _circlePolicy = <String, bool>{};

  /// 服务器推来的圈级规定。null = 撤销规定(回落本机开关)。
  void setCirclePolicy(String circleId, bool? enabled) {
    final before = _circlePolicy[circleId];
    if (enabled == null) {
      _circlePolicy.remove(circleId);
    } else {
      _circlePolicy[circleId] = enabled;
    }
    if (before != enabled) notifyListeners();
  }

  /// 这个圈子的加密是不是圈主统一定的(是 → 本机开关不该让人拨)。
  bool isCircleManaged(String circleId) => _circlePolicy.containsKey(circleId);

  bool isEnabled(String circleId) =>
      _circlePolicy[circleId] ?? _store.isEnabled(circleId);

  /// 这个圈子有没有可用于派生的口令(鉴权模式为 circle 且填了口令)。
  bool hasPasscode(String circleId) =>
      canDeriveCircleKey(_settings.credentialFor(circleId).passcode);

  /// **预测**某个圈子在本设备上开了 E2EE 会是什么结果 ——
  /// 供设置页在用户按下开关**之前**如实展示,不承诺平台做不到的事。
  /// 权威结论仍然是进房后的 [activeStatus]。
  E2EEStatus previewStatusFor(String circleId) => resolveE2EEStatus(
        enabled: isEnabled(circleId),
        platformSupported: platformSupported,
        hasPasscode: hasPasscode(circleId),
      );

  Future<void> setEnabled(String circleId, bool enabled) =>
      _store.setEnabled(circleId, enabled);

  Future<void> forget(String circleId) => _store.forget(circleId);

  /// 进房**之前**必须调用一次:算出这次该不该加密、能不能加密,
  /// 并把结果(或 null)写进 `LiveKitRtcService.pendingEncryption`。
  ///
  /// 纪律:**无论如何都要写一次**,包括写 null。
  /// 只在「要加密」时写、不在「不加密」时清,就会让上一个圈子的密钥
  /// 跟着用户漂到下一个圈子里 —— 那既连不上也查不出来。
  Future<E2EEStatus> prepareFor(String? circleId) async {
    final rtc = _rtc;
    final id = circleId ?? '';

    if (id.isEmpty) {
      rtc?.pendingEncryption = null;
      _publish(null, E2EEStatus.disabled);
      return E2EEStatus.disabled;
    }

    E2EEStatus status = resolveE2EEStatus(
      enabled: isEnabled(id),
      platformSupported: platformSupported,
      hasPasscode: hasPasscode(id),
    );

    if (!status.isEncrypted) {
      // 平台不支持时**尤其**不能硬开:LiveKit 会让 room.connect() 直接抛
      // LiveKitE2EEException,用户连房间都进不去。照常进房,但状态如实报降级。
      rtc?.pendingEncryption = null;
      _publish(id, status);
      return status;
    }

    try {
      // Argon2id 是**刻意慢**的(实测桌面约 250ms),必须在 isolate 里算,
      // 否则进房那一刻 UI 线程会卡掉十几帧。
      // 派生也放进这个 try:低内存设备上 Argon2 要 64 MiB,可能抛 OOM,
      // 那种情况必须落到 failed 而不是让异常冒出去把进房整个打断。
      final String key = await _deriveKey(
        passcode: _settings.credentialFor(id).passcode,
        circleId: id,
      );
      await _install(rtc, key);
    } catch (e) {
      // 底层 frame cryptor 没起来。绝不静默当作加密成功。
      debugPrint('[lares] E2EE 密钥装载失败,本次通话不加密: $e');
      rtc?.pendingEncryption = null;
      status = E2EEStatus.failed;
    }
    _publish(id, status);
    return status;
  }

  void _publish(String? circleId, E2EEStatus status) {
    if (_activeCircleId == circleId && _activeStatus == status) return;
    _activeCircleId = circleId;
    _activeStatus = status;
    notifyListeners();
  }

  @override
  void dispose() {
    _store.removeListener(notifyListeners);
    _settings.removeListener(notifyListeners);
    super.dispose();
  }
}
