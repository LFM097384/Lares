import 'dart:async';

import '../audio/audio_tuning.dart';

/// 降噪相关的值类型随本接口一起导出:调用方一次 import 即可拿到
/// [AudioTuning] / [NoiseSuppressionMode] / [ResolvedAudioTuning]。
export '../audio/audio_tuning.dart';

/// RTC 抽象层(设计.md §8.1):业务只依赖本接口,
/// LiveKit 与 Agora 的切换成本被限制在本文件实现内。
abstract interface class RtcService {
  /// 连接并进入房间。返回耗时(用于 1.5s 进房目标监控)。
  /// [highQuality] 控制发布音质(opus 48k 音乐级 / 24k 语音级,§2.2 流量透明度)。
  /// [tuning] 控制采集端降噪档位;平台能力不足时会自动回落,
  /// 实际生效结果见 [activeTuning]。
  Future<Duration> join({
    required String url,
    required String token,
    required bool startMuted,
    bool highQuality = true,
    AudioTuning tuning = AudioTuning.standard,
  });

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
