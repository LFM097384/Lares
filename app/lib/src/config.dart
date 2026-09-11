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

  static bool get isDesktop => PlatformInfo.isDesktop;

  static String get platformName => PlatformInfo.current;
}
