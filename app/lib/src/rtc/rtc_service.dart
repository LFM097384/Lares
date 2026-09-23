import 'dart:async';

import '../audio/audio_tuning.dart';

/// 降噪相关的值类型随本接口一起导出:调用方一次 import 即可拿到
/// [AudioTuning] / [NoiseSuppressionMode] / [ResolvedAudioTuning]。
export '../audio/audio_tuning.dart';

/// 麦克风没开成(或没关成)的原因。
///
/// 只分两类,因为用户能做的事只有两种:权限被拒 -> 去系统设置;
/// 其它(设备被占用、采集启动失败、后台不允许启动录音……)-> 再试一次。
/// 再细分对用户没有意义,对日志才有意义,原始异常放在 [MicException.cause]。
enum MicFailure { permissionDenied, unavailable }

/// 麦克风开/关失败。
///
/// 带上 [micOnNow] 是这个类型存在的全部理由:开麦状态是隐私相关的显示,
/// 失败之后界面必须显示**真实**状态,而不是「我猜它应该还是原来那样」。
/// 实现方在抛出前向底层问一次真实状态填进来。
class MicException implements Exception {
  MicException(this.kind, {required this.micOnNow, this.cause});

  final MicFailure kind;

  /// 失败之后麦克风此刻是否真的在采集并发布。
  final bool micOnNow;
  final Object? cause;

  @override
  String toString() => 'MicException($kind, micOnNow=$micOnNow, cause=$cause)';
}

/// 一次 join 的结果。
///
/// 以前 join 只返回耗时,调用方只能**假设**麦克风是按 startMuted 要求的状态 ——
/// 而「进圈即开麦」时开麦是连上房间之后才做的第二步,它可能单独失败
/// (最常见:没给麦克风权限)。那一步失败不该让整个进房失败(人照样能听),
/// 但也绝不能让界面显示「麦克风开着」。所以把真实结果一起带回来。
class RtcJoinResult {
  const RtcJoinResult({
    required this.elapsed,
    required this.micOn,
    this.micFailure,
  });

  final Duration elapsed;

  /// 进房之后麦克风是否真的开着。
  final bool micOn;

  /// 要求开麦却没开成时的原因;没要求开麦或开成了则为 null。
  final MicFailure? micFailure;
}

/// RTC 抽象层(设计.md §8.1):业务只依赖本接口,
/// LiveKit 与 Agora 的切换成本被限制在本文件实现内。
abstract interface class RtcService {
  /// 连接并进入房间。返回耗时(用于 1.5s 进房目标监控)与麦克风真实状态。
  /// [highQuality] 控制发布音质(opus 48k 音乐级 / 24k 语音级,§2.2 流量透明度)。
  /// [tuning] 控制采集端降噪档位;平台能力不足时会自动回落,
  /// 实际生效结果见 [activeTuning]。
  ///
  /// `startMuted: false` 时开麦失败**不得**抛出:房间已经连上,
  /// 应返回 `micOn: false` 并在 [RtcJoinResult.micFailure] 里说明原因。
  Future<RtcJoinResult> join({
    required String url,
    required String token,
    required bool startMuted,
    bool highQuality = true,
    AudioTuning tuning = AudioTuning.standard,
  });

  /// 失败时抛 [MicException](带失败后的真实状态);调用方据此回滚显示。
  Future<void> setMuted(bool muted);

  Future<void> leave();

  /// 正在说话的成员 identity 集合(LiveKit active-speaker 事件驱动)
  Stream<Set<String>> get speakingIdentities;

  /// 远端成员掉线/服务断开时触发
  Stream<void> get onDisconnected;

  bool get inRoom;

  /// 当前(或上次 join 解析出的)实际生效的降噪状态;未进房时为 null。
  ResolvedAudioTuning? get activeTuning;

  /// 不进房也能查询本平台能力,供设置页如实显示(不承诺平台做不到的事)。
  ResolvedAudioTuning previewTuning(AudioTuning tuning);
}
