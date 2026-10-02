import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 「锁定专注」:Android 屏幕固定(startLockTask / stopLockTask)。
///
/// 原生侧在 MainActivity.kt,通道 `lares/focus_lock`,方法:
/// - `start` → bool:立即返回 true,但系统的「固定屏幕」确认框可能还没点,
///   所以真正锁没锁要随后用 `isLocked` 轮询确认;
/// - `stop` → bool(没锁也安全);
/// - `isLocked` → bool。
/// 出错是 PlatformException(code `focus_lock`);别的平台没有实现 → MissingPluginException。
/// 两种异常这里一律吞掉并当作「不可用 / 没锁」。
class FocusLock extends ChangeNotifier {
  FocusLock({
    MethodChannel? channel,
    bool? supported,
    this.pollEvery = const Duration(seconds: 3),
  }) : _channel = channel ?? const MethodChannel('lares/focus_lock'),
       supported = supported ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  final MethodChannel _channel;
  final Duration pollEvery;

  /// 本平台是否提供锁定(只有 Android)。
  final bool supported;

  bool _locked = false;
  bool _requested = false;
  Timer? _poll;

  /// 系统确认已处于屏幕固定。
  bool get locked => _locked;

  /// 用户请求过锁定(系统确认框可能还没点)。
  bool get requested => _requested;

  Future<bool> _call(String method) async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> start() async {
    if (!supported) return false;
    final ok = await _call('start');
    if (!ok) return false;
    _requested = true;
    _poll?.cancel();
    _poll = Timer.periodic(pollEvery, (_) => unawaited(refresh()));
    notifyListeners();
    unawaited(refresh());
    return true;
  }

  Future<void> stop() async {
    _poll?.cancel();
    _poll = null;
    final wasOn = _requested || _locked;
    _requested = false;
    _locked = false;
    if (wasOn) {
      await _call('stop');
      notifyListeners();
    }
  }

  /// 查一次原生状态。用户用系统手势(返回 + 概览)退出固定后,
  /// 这里把界面状态拉回「没锁」。回到前台时也调一次。
  Future<void> refresh() async {
    if (!_requested) return;
    final now = await _call('isLocked');
    if (now == _locked) return;
    final wasLocked = _locked;
    _locked = now;
    if (wasLocked && !now) {
      // 曾经锁上、现在没了 = 用户自己退出了固定
      _requested = false;
      _poll?.cancel();
      _poll = null;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }
}

/// iOS Family Controls 存根(`lares/family_controls`)。原生侧默认不编译 →
/// MissingPluginException → 视为不可用。
class FamilyControls {
  const FamilyControls([
    this._channel = const MethodChannel('lares/family_controls'),
  ]);

  final MethodChannel _channel;

  Future<bool> _call(String m) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return false;
    try {
      return await _channel.invokeMethod<bool>(m) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> available() => _call('available');
  Future<bool> authorize() => _call('authorize');
  Future<bool> shield() => _call('shield');
  Future<bool> unshield() => _call('unshield');
}
