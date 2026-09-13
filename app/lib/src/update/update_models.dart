/// 更新检查的数据模型:GitHub Release JSON -> 领域对象,以及按平台/ABI 选包。
///
/// 设计要点:**纯 Dart,零 IO,零 Flutter 依赖**,因此可以在单元测试里
/// 直接喂 JSON 字符串验证,不需要真机也不需要真实 release。
library;

import 'dart:convert';

import 'version.dart';

/// 目标平台(与 GitHub Release 资产命名一一对应)。
/// 注意 iOS/Web 也在列:它们能**检测**新版本,只是不能自我更新。
enum UpdatePlatform { windows, android, macos, ios, web, unknown }

/// 本平台能采取的动作。UI 据此决定按钮文案与可用性。
enum UpdateCapability {
  /// 可下载 + 可直接安装(Windows 替换重启 / Android 拉起系统安装器)
  downloadAndInstall,

  /// 可下载,但需要用户手动完成最后一步(macOS 引导替换)
  downloadAndGuide,

  /// 仅告知,无法自助更新(iOS 侧载/TestFlight、Web 刷新页面)
  notifyOnly,
}

/// Release 里的一个资产(下载目标)。
class UpdateAsset {
  const UpdateAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
  });

  final String name;
  final String downloadUrl;

  /// 字节数。GitHub 提供此字段,是我们唯一能**事先**拿到的完整性凭据。
  final int size;

  static UpdateAsset? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final url = json['browser_download_url'];
    if (name is! String || name.isEmpty) return null;
    if (url is! String || url.isEmpty) return null;
    final rawSize = json['size'];
    final size = rawSize is int
        ? rawSize
        : (rawSize is num ? rawSize.toInt() : 0);
    return UpdateAsset(name: name, downloadUrl: url, size: size);
  }

  @override
  String toString() => 'UpdateAsset($name, $size B)';
}

/// 一次成功解析出来的 Release。
class ReleaseInfo {
  const ReleaseInfo({
    required this.tagName,
    required this.version,
    required this.name,
    required this.body,
    required this.htmlUrl,
    required this.assets,
    required this.publishedAt,
  });

  final String tagName;

  /// 解析后的版本(tag 去掉 v 前缀)。
  final LaresVersion version;

  final String name;

  /// Release 正文。UI 以**纯文本**渲染(不引入 markdown 依赖)。
  final String body;

  final String htmlUrl;
  final List<UpdateAsset> assets;
  final DateTime? publishedAt;

  /// 解析 GitHub `releases/latest` 响应体。
  ///
  /// 畸形负载一律返回 null(不抛):字段缺失、类型不对、tag 无法解析成版本号。
  static ReleaseInfo? fromJsonString(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } catch (_) {
      return null;
    }
    return fromJson(decoded);
  }

  static ReleaseInfo? fromJson(Object? json) {
    if (json is! Map) return null;

    final tag = json['tag_name'];
    if (tag is! String || tag.isEmpty) return null;

    final version = LaresVersion.tryParse(tag);
    if (version == null) return null; // 无法比较的 tag 视为不可用

    final rawAssets = json['assets'];
    final assets = <UpdateAsset>[];
    if (rawAssets is List) {
      for (final a in rawAssets) {
        final parsed = UpdateAsset.fromJson(a);
        if (parsed != null) assets.add(parsed);
      }
    }

    DateTime? published;
    final rawPublished = json['published_at'];
    if (rawPublished is String) published = DateTime.tryParse(rawPublished);

    return ReleaseInfo(
      tagName: tag,
      version: version,
      name: json['name'] is String ? json['name'] as String : tag,
      body: json['body'] is String ? json['body'] as String : '',
      htmlUrl: json['html_url'] is String
          ? json['html_url'] as String
          : 'https://github.com/LFM097384/Lares/releases',
      assets: List.unmodifiable(assets),
      publishedAt: published,
    );
  }
}

/// 「有新版本」时交给 UI 的完整信息。
class UpdateInfo {
  const UpdateInfo({
    required this.release,
    required this.currentVersion,
    required this.platform,
    required this.capability,
    required this.asset,
    required this.expectedSha256,
  });

  final ReleaseInfo release;
  final LaresVersion currentVersion;
  final UpdatePlatform platform;
  final UpdateCapability capability;

  /// 本平台对应的下载资产。**可能为 null**:release 没有为本平台传包
  /// (本项目 CI 目前只产出 Actions artifact,不挂 release asset,详见 README/报告)。
  final UpdateAsset? asset;

  /// 从 release 正文里解析到的该资产 SHA-256(如果作者写了的话)。
  final String? expectedSha256;

  bool get hasDownloadableAsset => asset != null;

  /// 真正能自助更新 = 平台支持 且 确实有包可下。
  bool get canSelfUpdate =>
      asset != null && capability != UpdateCapability.notifyOnly;

  String get latestDisplay => release.version.display;
  String get currentDisplay => currentVersion.display;
}

/// 按平台 + ABI 选包。
///
/// 资产名依据 `.github/workflows/ios-build.yml` 的真实打包步骤:
/// - Windows:`Compress-Archive ... -DestinationPath build\dist\lares-windows.zip`
/// - macOS:`zip -qry lares-macos.zip lares_app.app`
/// - Android:`flutter build apk --split-per-abi` -> `app-<abi>-release.apk`
/// - iOS:`zip -qry lares_app.ipa Payload`
///
/// 匹配策略刻意宽松(大小写无关 + 关键词),这样即使将来发布时给文件名加了
/// 版本号后缀(如 `lares-windows-v0.2.0.zip`)也仍然能选中。
abstract final class AssetSelector {
  /// Android split-per-abi 产物名里出现的 ABI 关键字,按优先级排列。
  static const List<String> knownAbis = [
    'arm64-v8a',
    'armeabi-v7a',
    'x86_64',
  ];

  /// [deviceAbis] 传设备 `Build.SUPPORTED_ABIS`(优先级从高到低)。
  static UpdateAsset? select(
    List<UpdateAsset> assets,
    UpdatePlatform platform, {
    List<String> deviceAbis = const [],
  }) {
    if (assets.isEmpty) return null;
    switch (platform) {
      case UpdatePlatform.windows:
        return _firstWhere(
          assets,
          (n) => n.endsWith('.zip') && n.contains('windows'),
        );
      case UpdatePlatform.macos:
        return _firstWhere(
          assets,
          (n) =>
              (n.endsWith('.zip') || n.endsWith('.dmg')) && n.contains('macos'),
        );
      case UpdatePlatform.android:
        return _selectApk(assets, deviceAbis);
      case UpdatePlatform.ios:
        // 仅用于展示;iOS 无法自助安装(未签名 .ipa 需要侧载工具)。
        return _firstWhere(assets, (n) => n.endsWith('.ipa'));
      case UpdatePlatform.web:
      case UpdatePlatform.unknown:
        return null;
    }
  }

  static UpdateAsset? _selectApk(
    List<UpdateAsset> assets,
    List<String> deviceAbis,
  ) {
    final apks = assets
        .where((a) => a.name.toLowerCase().endsWith('.apk'))
        .toList(growable: false);
    if (apks.isEmpty) return null;

    // 1) 严格按设备 ABI 优先级挑(设备第一顺位 ABI 最优)
    for (final abi in deviceAbis) {
      final want = abi.toLowerCase().trim();
      if (want.isEmpty) continue;
      for (final a in apks) {
        if (a.name.toLowerCase().contains(want)) return a;
      }
    }

    // 2) 设备 ABI 拿不到时的兜底:优先 arm64(现代机绝大多数),
    //    但只在资产里确实没有「通用包」时才这么猜。
    final universal = _firstWhere(
      apks,
      (n) => !knownAbis.any((abi) => n.contains(abi)),
    );
    if (universal != null) return universal;

    if (deviceAbis.isEmpty) {
      for (final abi in knownAbis) {
        final hit = _firstWhere(apks, (n) => n.contains(abi));
        if (hit != null) return hit;
      }
    }

    // 3) 设备 ABI 已知但没有任何一个包匹配 -> 明确返回 null,
    //    绝不乱塞一个装不上的 APK 给用户。
    return null;
  }

  static UpdateAsset? _firstWhere(
    List<UpdateAsset> assets,
    bool Function(String lowerName) test,
  ) {
    for (final a in assets) {
      if (test(a.name.toLowerCase())) return a;
    }
    return null;
  }
}

/// 从 release 正文里尽力抠出某个文件对应的 SHA-256。
///
/// 支持常见写法(顺序无关、大小写无关):
/// ```
/// lares-windows.zip  a1b2...64hex
/// a1b2...64hex  lares-windows.zip      <- sha256sum 标准输出
/// - `lares-windows.zip`: `A1B2...`
/// ```
/// 找不到就返回 null —— 这是**常态**,不是错误。
String? extractSha256ForAsset(String body, String assetName) {
  if (body.isEmpty || assetName.isEmpty) return null;
  final lowerAsset = assetName.toLowerCase();
  final hex = RegExp(r'\b([a-fA-F0-9]{64})\b');

  for (final rawLine in body.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (!line.toLowerCase().contains(lowerAsset)) continue;
    final m = hex.firstMatch(line);
    if (m != null) return m.group(1)!.toLowerCase();
  }
  return null;
}
