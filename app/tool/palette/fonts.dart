// 在 flutter_test 环境里加载真实字体。
//
// 必要性:flutter_test 默认只有一个叫 "Ahem" 的测试字体,所有字形都是实心方块。
// 不加载真字体,截出来的图会是一屏黑方块 —— 那等于没渲染。
//
// 需要两类字体:
//   1. 中文 UI 字体(界面里全是中文)
//   2. Material Icons(麦克风、发送、图片等图标)
//
// 中文字体从 Windows 系统目录找,Material Icons 从 Flutter SDK 的
// material_fonts 缓存里找 —— 两者都不新增任何 pub 依赖。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'palette_theme.dart';

/// 候选中文字体,按优先级。等宽/装饰体排后面。
const List<String> _cjkCandidates = <String>[
  r'C:\Windows\Fonts\msyh.ttc', // 微软雅黑(最像产品字体)
  r'C:\Windows\Fonts\msyhl.ttc',
  r'C:\Windows\Fonts\Deng.ttf', // 等线
  r'C:\Windows\Fonts\Dengl.ttf',
  r'C:\Windows\Fonts\simhei.ttf', // 黑体
  r'C:\Windows\Fonts\simkai.ttf',
];

/// 找到的中文字体路径,供报告里说明「这张图用的什么字」。
String? loadedCjkPath;

/// 是否成功加载了图标字体。
bool iconsLoaded = false;

/// 加载渲染所需的全部字体。必须在任何 pumpWidget 之前调用。
Future<void> loadRenderFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── 中文正文字体 ──
  for (final String path in _cjkCandidates) {
    final File f = File(path);
    if (!f.existsSync()) continue;
    try {
      final Uint8List bytes = await f.readAsBytes();
      final FontLoader loader = FontLoader(kUiFontFamily)
        ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
      await loader.load();
      loadedCjkPath = path;
      break;
    } catch (_) {
      // 某些 .ttc 集合字体可能加载失败,继续试下一个
      continue;
    }
  }

  // ── Material Icons ──
  // 图标字体族名必须正好是 'MaterialIcons',否则 Icon widget 找不到它。
  final String? iconPath = _findMaterialIcons();
  if (iconPath != null) {
    try {
      final Uint8List bytes = await File(iconPath).readAsBytes();
      final FontLoader loader = FontLoader('MaterialIcons')
        ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
      await loader.load();
      iconsLoaded = true;
    } catch (_) {
      iconsLoaded = false;
    }
  }
}

/// 定位 Flutter SDK 里的 Material Icons 字体。
/// 从 Dart 可执行文件路径反推 SDK 根目录,不硬编码盘符。
String? _findMaterialIcons() {
  final List<String> roots = <String>[];

  final String? envRoot = Platform.environment['FLUTTER_ROOT'];
  if (envRoot != null && envRoot.isNotEmpty) roots.add(envRoot);

  // dart 可执行文件通常在 <flutter>/bin/cache/dart-sdk/bin/dart.exe
  final String exe = Platform.resolvedExecutable;
  final List<String> parts = exe.split(Platform.pathSeparator);
  for (int i = parts.length - 1; i >= 0; i--) {
    if (parts[i] == 'bin' && i >= 1) {
      roots.add(parts.sublist(0, i).join(Platform.pathSeparator));
    }
    if (parts[i] == 'cache' && i >= 2) {
      roots.add(parts.sublist(0, i - 1).join(Platform.pathSeparator));
    }
  }

  for (final String root in roots) {
    for (final String rel in <String>[
      'bin/cache/artifacts/material_fonts/materialicons-regular.otf',
      'artifacts/material_fonts/materialicons-regular.otf',
    ]) {
      final String path =
          '$root${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}';
      if (File(path).existsSync()) return path;
    }
  }
  return null;
}
