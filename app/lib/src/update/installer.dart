/// 安装器的 **Web 侧实现**(不含 dart:io)。
///
/// 与 `location_share.dart` / `tray_service.dart` 同一套条件导入写法:
/// 调用方写
/// ```dart
/// import 'installer.dart' if (dart.library.io) 'installer_io.dart';
/// ```
/// 即可在 Web 上拿到这里的实现、在原生端拿到 installer_io.dart 的实现。
library;

import 'installer_api.dart';
import 'update_models.dart';

export 'installer_api.dart';

/// 条件导入的工厂入口。Web 上任何平台都只能「告知」。
UpdateInstaller createInstaller(UpdatePlatform platform) => const WebInstaller();

/// Web 端没有 ABI 概念。
Future<List<String>> readDeviceAbis() async => const [];

/// Web 端无法落盘(也不需要)。
Future<DownloadTarget> openDownloadTarget(String fileName) async =>
    throw UnsupportedError('Web 端不支持下载安装包');
