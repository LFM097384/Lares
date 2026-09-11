import 'dart:async';

/// RTC 抽象层(设计.md §8.1):业务只依赖本接口,
/// LiveKit 与 Agora 的切换成本被限制在本文件实现内。
abstract interface class RtcService {
  /// 连接并进入房间。返回耗时(用于 1.5s 进房目标监控)。
  /// [highQuality] 控制发布音质(opus 48k 音乐级 / 24k 语音级,§2.2 流量透明度)。
  Future<Duration> join({
    required String url,
    required String token,
    required bool startMuted,
    bool highQuality = true,
  });

  Future<void> setMuted(bool muted);

  Future<void> leave();

  /// 正在说话的成员 identity 集合(LiveKit active-speaker 事件驱动)
  Stream<Set<String>> get speakingIdentities;

  /// 远端成员掉线/服务断开时触发
  Stream<void> get onDisconnected;

  bool get inRoom;
}
