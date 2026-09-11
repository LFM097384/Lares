/// Web 端实现(无 dart:io)。io 端见 platform_info_io.dart。
class PlatformInfo {
  static bool get isDesktop => false;
  static String get current => 'web';
}
