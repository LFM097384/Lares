import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/update/update_models.dart';

/// 构造一个形似 GitHub `releases/latest` 的负载。
String _release({
  String tag = 'v0.2.0',
  List<Map<String, Object?>> assets = const [],
  String body = '',
}) =>
    jsonEncode({
      'tag_name': tag,
      'name': 'Lares $tag',
      'body': body,
      'html_url': 'https://github.com/LFM097384/Lares/releases/tag/$tag',
      'published_at': '2026-09-11T15:34:15Z',
      'assets': assets,
    });

Map<String, Object?> _asset(String name, {int size = 1024}) => {
      'name': name,
      'browser_download_url': 'https://example.invalid/$name',
      'size': size,
    };

/// 依据 .github/workflows/ios-build.yml 的真实打包名
const _windowsAsset = 'lares-windows.zip';
const _macosAsset = 'lares-macos.zip';
const _iosAsset = 'lares_app.ipa';
const _arm64Apk = 'app-arm64-v8a-release.apk';
const _arm32Apk = 'app-armeabi-v7a-release.apk';
const _x64Apk = 'app-x86_64-release.apk';

void main() {
  group('Release JSON 解析', () {
    test('正常负载:字段齐全', () {
      final r = ReleaseInfo.fromJsonString(_release(
        assets: [_asset(_windowsAsset, size: 4096)],
        body: '修了一堆 bug',
      ))!;

      expect(r.tagName, 'v0.2.0');
      expect(r.version.display, '0.2.0');
      expect(r.body, '修了一堆 bug');
      expect(r.assets.single.name, _windowsAsset);
      expect(r.assets.single.size, 4096);
      expect(r.publishedAt, isNotNull);
    });

    test('真实的 v0.1.0:assets 为空数组也能正常解析', () {
      // 这正是当前仓库的实际状态:CI 只上传 Actions artifact,不挂 release asset
      final r = ReleaseInfo.fromJsonString(_release(tag: 'v0.1.0'))!;
      expect(r.version.display, '0.1.0');
      expect(r.assets, isEmpty);
    });

    test('畸形负载一律返回 null,不抛异常', () {
      for (final bad in [
        '',
        'not json at all',
        '{',
        '[]',
        '{"foo":"bar"}', // 没有 tag_name
        '{"tag_name":""}', // 空 tag
        '{"tag_name":"完全不是版本号"}', // tag 无法解析成版本
        '{"tag_name":123}', // 类型不对
      ]) {
        expect(() => ReleaseInfo.fromJsonString(bad), returnsNormally);
        expect(ReleaseInfo.fromJsonString(bad), isNull, reason: '负载: $bad');
      }
    });

    test('assets 里混入畸形条目时跳过该条,不影响其余', () {
      final r = ReleaseInfo.fromJsonString(jsonEncode({
        'tag_name': 'v0.2.0',
        'assets': [
          {'name': 'no-url.zip'}, // 缺 url
          'a string', // 类型不对
          _asset(_windowsAsset),
          {'browser_download_url': 'https://x/y'}, // 缺 name
        ],
      }))!;
      expect(r.assets.length, 1);
      expect(r.assets.single.name, _windowsAsset);
    });

    test('size 缺失时降级为 0(后续据此跳过大小校验)', () {
      final r = ReleaseInfo.fromJsonString(jsonEncode({
        'tag_name': 'v0.2.0',
        'assets': [
          {'name': 'x.zip', 'browser_download_url': 'https://x/y.zip'},
        ],
      }))!;
      expect(r.assets.single.size, 0);
    });
  });

  group('资产选择:桌面与 iOS', () {
    final assets = [
      UpdateAsset(name: _windowsAsset, downloadUrl: 'u', size: 1),
      UpdateAsset(name: _macosAsset, downloadUrl: 'u', size: 2),
      UpdateAsset(name: _iosAsset, downloadUrl: 'u', size: 3),
      UpdateAsset(name: _arm64Apk, downloadUrl: 'u', size: 4),
    ];

    test('Windows 选 zip', () {
      expect(
        AssetSelector.select(assets, UpdatePlatform.windows)!.name,
        _windowsAsset,
      );
    });

    test('macOS 选 macos zip(不会错选 windows zip)', () {
      expect(
        AssetSelector.select(assets, UpdatePlatform.macos)!.name,
        _macosAsset,
      );
    });

    test('iOS 选 ipa(仅用于展示)', () {
      expect(AssetSelector.select(assets, UpdatePlatform.ios)!.name, _iosAsset);
    });

    test('Web / unknown 永远没有可下载资产', () {
      expect(AssetSelector.select(assets, UpdatePlatform.web), isNull);
      expect(AssetSelector.select(assets, UpdatePlatform.unknown), isNull);
    });

    test('带版本号后缀的文件名也能匹配', () {
      final versioned = [
        UpdateAsset(
          name: 'lares-windows-v0.2.0.zip',
          downloadUrl: 'u',
          size: 1,
        ),
      ];
      expect(
        AssetSelector.select(versioned, UpdatePlatform.windows)!.name,
        'lares-windows-v0.2.0.zip',
      );
    });

    test('本平台没有对应资产时返回 null', () {
      final onlyApk = [
        UpdateAsset(name: _arm64Apk, downloadUrl: 'u', size: 1),
      ];
      expect(AssetSelector.select(onlyApk, UpdatePlatform.windows), isNull);
      expect(AssetSelector.select(onlyApk, UpdatePlatform.macos), isNull);
      expect(AssetSelector.select(const [], UpdatePlatform.windows), isNull);
    });
  });

  group('资产选择:Android ABI', () {
    final apks = [
      UpdateAsset(name: _arm32Apk, downloadUrl: 'u', size: 1),
      UpdateAsset(name: _arm64Apk, downloadUrl: 'u', size: 2),
      UpdateAsset(name: _x64Apk, downloadUrl: 'u', size: 3),
    ];

    UpdateAsset? pick(List<String> abis) => AssetSelector.select(
          apks,
          UpdatePlatform.android,
          deviceAbis: abis,
        );

    test('arm64 设备选 arm64-v8a', () {
      expect(pick(['arm64-v8a', 'armeabi-v7a', 'armeabi'])!.name, _arm64Apk);
    });

    test('32 位 arm 设备选 armeabi-v7a(绝不给 arm64)', () {
      expect(pick(['armeabi-v7a', 'armeabi'])!.name, _arm32Apk);
    });

    test('模拟器 x86_64 选 x86_64', () {
      expect(pick(['x86_64', 'arm64-v8a'])!.name, _x64Apk);
    });

    test('按设备 ABI 优先级取第一顺位,而非列表里的第一个包', () {
      // 设备首选 x86_64,即便 arm64 包排在资产列表更前面
      expect(pick(['x86_64'])!.name, _x64Apk);
    });

    test('设备 ABI 未知时才回退猜测 arm64', () {
      expect(pick(const [])!.name, _arm64Apk);
    });

    test('设备 ABI 已知但无匹配包时返回 null(不塞装不上的包)', () {
      final onlyArm64 = [
        UpdateAsset(name: _arm64Apk, downloadUrl: 'u', size: 1),
      ];
      final got = AssetSelector.select(
        onlyArm64,
        UpdatePlatform.android,
        deviceAbis: ['armeabi-v7a'],
      );
      expect(got, isNull);
    });

    test('存在通用 APK 时优先选它', () {
      final withUniversal = [
        UpdateAsset(name: _arm64Apk, downloadUrl: 'u', size: 1),
        UpdateAsset(name: 'app-release.apk', downloadUrl: 'u', size: 2),
      ];
      final got = AssetSelector.select(
        withUniversal,
        UpdatePlatform.android,
        deviceAbis: ['armeabi-v7a'],
      );
      expect(got!.name, 'app-release.apk');
    });

    test('大小写不敏感', () {
      final upper = [
        UpdateAsset(name: 'App-ARM64-V8A-release.APK', downloadUrl: 'u', size: 1),
      ];
      final got = AssetSelector.select(
        upper,
        UpdatePlatform.android,
        deviceAbis: ['arm64-v8a'],
      );
      expect(got, isNotNull);
    });
  });

  group('从 release 正文提取 SHA-256', () {
    const hash =
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

    test('「文件名 空格 哈希」格式', () {
      expect(
        extractSha256ForAsset('$_windowsAsset  $hash', _windowsAsset),
        hash,
      );
    });

    test('sha256sum 标准输出格式(哈希在前)', () {
      expect(
        extractSha256ForAsset('$hash  $_windowsAsset', _windowsAsset),
        hash,
      );
    });

    test('markdown 列表 + 反引号 + 大写哈希', () {
      final body = '## 校验和\n- `$_windowsAsset`: `${hash.toUpperCase()}`\n';
      expect(extractSha256ForAsset(body, _windowsAsset), hash);
    });

    test('多文件时各取各的', () {
      const other =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final body = '$_windowsAsset $hash\n$_macosAsset $other';
      expect(extractSha256ForAsset(body, _windowsAsset), hash);
      expect(extractSha256ForAsset(body, _macosAsset), other);
    });

    test('正文没写校验和时返回 null(这是常态,不是错误)', () {
      expect(extractSha256ForAsset('没有任何校验和', _windowsAsset), isNull);
      expect(extractSha256ForAsset('', _windowsAsset), isNull);
      // 长度不是 64 的 hex 不算
      expect(extractSha256ForAsset('$_windowsAsset abc123', _windowsAsset),
          isNull);
    });
  });
}
