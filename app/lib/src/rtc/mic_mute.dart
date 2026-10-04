import 'dart:async';

import 'package:flutter/foundation.dart';

import 'rtc_service.dart';

/// 麦克风开关在 SDK 那一侧的最小接口,只为让 [MicMuteDriver] 能脱离
/// LiveKit 单测。LiveKit 适配见 `livekit_rtc_service.dart` 的 `_LiveKitMicPort`。
abstract interface class MicPort {
  /// 让 SDK 打开 / 关闭麦克风(LiveKit:`setMicrophoneEnabled`)。
  ///
  /// 轨道还没发布时 `enabled: true` 会创建并发布;发布进行中再调用,
  /// SDK 会排队到发布完成之后执行(LiveKit 的 `_publishRunner`)。
  Future<void> setEnabled(bool enabled);

  /// 此刻麦克风是否**真的**在采集并发布。
  ///
  /// ⚠️ 必须是同步更新的真值。LiveKit 的 `isMicrophoneEnabled()` 读的是
  /// `publication.muted`,它靠一个异步广播事件才更新 —— `await mute()`
  /// 返回时它还是旧值。这正是「第一次静音总失败」的根因(见 [MicMuteDriver])。
  bool get live;
}

/// 静音状态机:把「想要的状态」可靠地落到 SDK 上,并**按真值**回报。
///
/// 规则:
/// 1. 调 [MicPort.setEnabled];抛异常且不是权限问题 -> 等 [retryDelay] 再试一次。
/// 2. 不管有没有抛,最后都以 [MicPort.live] 为准:达到目标就算成功
///    (哪怕中途抛过);没达到就抛 [MicException],带上真实的 `micOnNow`。
/// 3. 原始异常一律 debugPrint,免得以后的报告只剩一句「静音失败」。
///
/// 同一时刻只跑一个请求;请求在途时又来新意图,只保留**最后一个**,
/// 当前请求结束后补做(界面连点不会丢意图,也不会交错调用 SDK)。
class MicMuteDriver {
  MicMuteDriver(
    this._port, {
    this.retryDelay = const Duration(milliseconds: 250),
    MicFailure Function(Object e)? classify,
  }) : _classify = classify ?? _defaultClassify;

  final MicPort _port;
  final Duration retryDelay;
  final MicFailure Function(Object e) _classify;

  Future<void>? _inFlight;
  bool? _queued;
  Completer<void>? _queuedDone;

  static MicFailure _defaultClassify(Object e) => MicFailure.unavailable;

  /// 把麦克风切到 `muted`。成功返回;失败抛 [MicException](真实状态在里面)。
  Future<void> setMuted(bool muted) {
    final running = _inFlight;
    if (running == null) return _start(muted);
    // 有请求在途:覆盖排队意图,所有排队者等同一个结果。
    _queued = muted;
    final done = _queuedDone ??= Completer<void>();
    return done.future;
  }

  Future<void> _start(bool muted) {
    final f = _apply(muted);
    _inFlight = f;
    f.whenComplete(_drain).ignore();
    return f;
  }

  void _drain() {
    _inFlight = null;
    final next = _queued;
    final done = _queuedDone;
    _queued = null;
    _queuedDone = null;
    if (next == null || done == null) return;
    _start(next).then(done.complete, onError: done.completeError);
  }

  Future<void> _apply(bool muted) async {
    final target = !muted; // 想要的 live 值
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        await _port.setEnabled(target);
        lastError = null;
      } catch (e, st) {
        lastError = e;
        lastStack = st;
        debugPrint(
          '[lares] 麦克风切换异常 attempt=$attempt target=${target ? 'on' : 'off'} '
          'live=${_port.live} (${e.runtimeType}): $e\n$st',
        );
      }
      if (_port.live == target) {
        if (lastError != null) {
          debugPrint('[lares] 麦克风切换虽抛异常,但真实状态已达成,按成功处理');
        }
        return;
      }
      // 权限问题重试也没用;没抛异常却没达成也不再重试(不是瞬时错误)。
      if (lastError == null || _classify(lastError) == MicFailure.permissionDenied) {
        break;
      }
      if (attempt == 1 && retryDelay > Duration.zero) {
        await Future<void>.delayed(retryDelay);
      }
    }
    final nowOn = _port.live;
    debugPrint(
      '[lares] 麦克风切换失败 target=${target ? 'on' : 'off'} live=$nowOn '
      'cause=$lastError${lastStack != null ? '\n$lastStack' : ''}',
    );
    throw MicException(
      lastError == null ? MicFailure.unavailable : _classify(lastError),
      micOnNow: nowOn,
      cause: lastError,
    );
  }
}
