import 'platform/platform_info.dart'
    if (dart.library.io) 'platform/platform_info_io.dart';

/// 全局配置:可用 --dart-define 覆盖,例:
/// flutter run --dart-define=LARES_SIGNALING=ws://192.168.1.10:8787
class LaresConfig {
  LaresConfig._();

  /// presence 信令服务地址
  static const String signalingUrl = String.fromEnvironment(
    'LARES_SIGNALING',
    defaultValue: 'ws://127.0.0.1:8787',
  );

  /// 默认圈子(MVP 单一圈子)
  static const String defaultCircleId = String.fromEnvironment(
    'LARES_CIRCLE',
    defaultValue: 'home',
  );

  static const String defaultCircleName = String.fromEnvironment(
    'LARES_CIRCLE_NAME',
    defaultValue: '我们的圈',
  );

  /// 仅主机 ICE 候选(局域网联调加速:跳过 STUN 收集,秒连;
  /// 公网/生产必须为 false)
  static const bool hostOnlyIce = bool.fromEnvironment('LARES_HOST_ONLY_ICE');

  /// 启动即自动进默认圈(常驻挂机端/浸泡测试:开机自启 → 自动在圈)
  static const bool autoJoin = bool.fromEnvironment('LARES_AUTO_JOIN');

  /// 录音与转写(需求⑧)。**默认关闭,入口完全不出现。**
  ///
  /// 为什么用开关而不是删代码:功能本身已完成并有 218 项测试,
  /// 删掉等于丢弃;但它有两处尚未解决的问题,不宜对外开放 ——
  ///  1. VAD 门限是在合成信号上调出来的,**从未见过真实麦克风**;
  ///  2. 录音的伦理面还没定稿(断连宽限期内被录方可能已看不到指示器;
  ///     「只保存在本地设备」这句对 App 为真、对世界为假)。
  /// 想开启:`--dart-define=LARES_RECORDING=true`。
  static const bool recordingEnabled =
      bool.fromEnvironment('LARES_RECORDING');

  static bool get isDesktop => PlatformInfo.isDesktop;

  static String get platformName => PlatformInfo.current;
}
