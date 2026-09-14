// 渲染器:把每套配色的两个场景截成 PNG。
//
// 跑法(app/ 目录下):
//   flutter test tool/palette/render_test.dart
//
// 为什么放在 *_test.dart 里用 flutter test 跑:
// 截图需要一个能光栅化的 Flutter 引擎。flutter test 自带 headless 引擎
// (Skia/Impeller 的 CPU 后端),RepaintBoundary.toImage() 能拿到真实像素,
// 不需要显示器、不需要装 Chrome、不需要起模拟器 —— 这是本机唯一稳的路子。
//
// 输出:app/tool/palette/<id>_room.png 与 <id>_chat.png
//
// 注意:本文件虽以 _test.dart 结尾,但它**不是**回归测试,
// 而是一个借测试运行器执行的离线渲染脚本。它不在 test/ 目录下,
// 所以 `flutter test`(默认只跑 test/)不会捡到它,441 项测试不受影响。

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fonts.dart';
import 'palette_theme.dart';
import 'palettes.dart';
import 'scenes.dart';

/// 输出目录(相对 app/ 工作目录)。
const String _outDir = 'tool/palette';

/// 渲染逻辑尺寸。取常见手机竖屏比例。
const Size _canvas = Size(390, 844);

/// 像素密度。2.0 让文字边缘足够干净,又不会让文件大到没法看。
const double _dpr = 2.0;

void main() {
  setUpAll(() async {
    await loadRenderFonts();
  });

  testWidgets('渲染全部配色方案的界面对比图', (WidgetTester tester) async {
    tester.view.physicalSize = Size(_canvas.width * _dpr, _canvas.height * _dpr);
    tester.view.devicePixelRatio = _dpr;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final List<String> written = <String>[];

    for (final Palette p in allPalettes) {
      for (final MapEntry<String, Widget> scene in <String, Widget>{
        'room': RoomScene(palette: p),
        'chat': ChatScene(palette: p),
      }.entries) {
        final GlobalKey boundaryKey = GlobalKey();

        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: MediaQuery(
              data: const MediaQueryData(
                size: _canvas,
                devicePixelRatio: _dpr,
                padding: EdgeInsets.only(top: 44, bottom: 24),
              ),
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: themeFor(p),
                home: scene.value,
              ),
            ),
          ),
        );

        // 让波纹动画停在一个好看的相位上(它是 repeat 的,不能等它结束)
        await tester.pump(const Duration(milliseconds: 700));

        final String path = '$_outDir/${p.id}_${scene.key}.png';
        await _capture(boundaryKey, path);
        written.add(path);
      }
    }

    // 再出一张总览大图,把 5 套 × 2 场景拼在一起 —— 产品负责人要的是「对比」
    await _renderContactSheet(tester);
    written.add('$_outDir/_overview.png');

    stdout.writeln('\n已生成 ${written.length} 张图:');
    for (final String w in written) {
      final File f = File(w);
      final String size =
          f.existsSync() ? '${(f.lengthSync() / 1024).round()} KB' : '缺失!';
      stdout.writeln('  $w  ($size)');
    }
    if (loadedCjkPath != null) {
      stdout.writeln('中文字体: $loadedCjkPath');
    } else {
      stdout.writeln('警告:未能加载中文字体,图上中文可能是方框!');
    }
    stdout.writeln('图标字体: ${iconsLoaded ? "已加载" : "未加载(图标会是方框)"}');
  });
}

/// 把一个 RepaintBoundary 的像素写成 PNG。
Future<void> _capture(GlobalKey key, String path) async {
  final RenderRepaintBoundary boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final ui.Image image = await boundary.toImage(pixelRatio: _dpr);
  final ByteData? bytes =
      await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  if (bytes == null) {
    throw StateError('toByteData 返回 null:$path');
  }
  final File file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes.buffer.asUint8List());
}

/// 总览拼版:每套方案一列(房间 + 聊天),带方案名与关键 token 色块。
Future<void> _renderContactSheet(WidgetTester tester) async {
  // 拼版画布比单张宽得多,先把 view 放大,否则布局会溢出
  const double tileW = 300;
  const double tileH = 650;
  const double headerH = 96;
  final double sheetW = tileW * allPalettes.length + 16 * (allPalettes.length + 1);
  const double sheetH = headerH + tileH * 2 + 16 * 3;

  tester.view.physicalSize = Size(sheetW * 1.5, sheetH * 1.5);
  tester.view.devicePixelRatio = 1.5;

  final GlobalKey key = GlobalKey();

  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MediaQuery(
        data: MediaQueryData(size: Size(sheetW, sheetH), devicePixelRatio: 1.5),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Container(
            width: sheetW,
            height: sheetH,
            color: const Color(0xFF08070A),
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: allPalettes.map((Palette p) {
                return Container(
                  width: tileW,
                  margin: const EdgeInsets.only(right: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SizedBox(
                        height: headerH,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              p.name,
                              style: const TextStyle(
                                fontFamily: kUiFontFamily,
                                color: Color(0xFFFFFFFF),
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              p.source,
                              maxLines: 2,
                              style: const TextStyle(
                                fontFamily: kUiFontFamily,
                                color: Color(0xFF9A93A3),
                                fontSize: 11,
                                height: 1.3,
                              ),
                            ),
                            const SizedBox(height: 8),
                            // token 色块条
                            Row(
                              children: <int>[
                                p.bg,
                                p.surface,
                                p.surfaceHigh,
                                p.brand,
                                p.statusFree,
                                p.statusBusy,
                                p.statusEars,
                                p.statusAway,
                              ].map((int c) {
                                return Container(
                                  width: 26,
                                  height: 18,
                                  margin: const EdgeInsets.only(right: 4),
                                  decoration: BoxDecoration(
                                    color: Color(c),
                                    borderRadius: BorderRadius.circular(3),
                                    border: Border.all(
                                      color: const Color(0x22FFFFFF),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                      ),
                      _SheetTile(
                        width: tileW,
                        height: tileH,
                        child: MaterialApp(
                          debugShowCheckedModeBanner: false,
                          theme: themeFor(p),
                          home: RoomScene(palette: p),
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 700));
  await _captureAt(key, '$_outDir/_overview.png', 1.5);
}

Future<void> _captureAt(GlobalKey key, String path, double ratio) async {
  final RenderRepaintBoundary boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final ui.Image image = await boundary.toImage(pixelRatio: ratio);
  final ByteData? bytes =
      await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  if (bytes == null) throw StateError('toByteData 返回 null:$path');
  final File file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes.buffer.asUint8List());
}

/// 拼版里的一格:把手机尺寸的场景缩放塞进格子。
class _SheetTile extends StatelessWidget {
  const _SheetTile({
    required this.width,
    required this.height,
    required this.child,
  });

  final double width;
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: width,
        height: height,
        child: FittedBox(
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: _canvas.width,
            height: _canvas.height,
            child: MediaQuery(
              data: const MediaQueryData(
                size: _canvas,
                devicePixelRatio: _dpr,
                padding: EdgeInsets.only(top: 44, bottom: 24),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
