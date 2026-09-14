// 临时探针:二分定位 ChatScene 里哪一块卡住。用完即删。
// 进度写进文件,因为管道会缓冲 stdout,卡住时什么也看不到。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/theme/tokens.dart';

import 'fonts.dart';
import 'palette_theme.dart';
import 'palettes.dart';

const Size _canvas = Size(390, 844);
const double _dpr = 2.0;

final File _mark = File('tool/palette/_probe_progress.txt');
void mark(String s) {
  _mark.writeAsStringSync('$s\n', mode: FileMode.append, flush: true);
}

Future<void> _cap(GlobalKey key, String path) async {
  final RenderRepaintBoundary b =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final ui.Image img = await b.toImage(pixelRatio: _dpr);
  final ByteData? d = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  File(path).writeAsBytesSync(d!.buffer.asUint8List());
}

Future<void> run(WidgetTester tester, String name, Widget child) async {
  mark('START $name');
  tester.view.physicalSize = Size(_canvas.width * _dpr, _canvas.height * _dpr);
  tester.view.devicePixelRatio = _dpr;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final GlobalKey k = GlobalKey();
  await tester.pumpWidget(RepaintBoundary(
    key: k,
    child: MediaQuery(
      data: const MediaQueryData(
          size: _canvas,
          devicePixelRatio: _dpr,
          padding: EdgeInsets.only(top: 44, bottom: 24)),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: themeFor(baseline),
        home: Scaffold(body: SafeArea(child: child)),
      ),
    ),
  ));
  mark('  pumped $name');
  await tester.pump(const Duration(milliseconds: 300));
  mark('  pumped300 $name');
  await _cap(k, 'tool/palette/_probe_$name.png');
  mark('OK $name');
}

Color _c(int v) => Color(v);

void main() {
  setUpAll(() async {
    if (_mark.existsSync()) _mark.deleteSync();
    mark('fonts loading');
    await loadRenderFonts();
    mark('fonts ok cjk=$loadedCjkPath icons=$iconsLoaded');
  });

  // A:纯文本 Column,无 emoji
  testWidgets('a_plain', (WidgetTester t) async {
    await run(
        t,
        'a_plain',
        Column(
          children: const <Widget>[
            Text('我把汤热上了,你们慢慢聊'),
            Text('今天那首歌叫什么来着'),
          ],
        ));
  });

  // B:带 emoji 的文本 —— 怀疑点一
  testWidgets('b_emoji', (WidgetTester t) async {
    await run(
        t,
        'b_emoji',
        Column(
          children: const <Widget>[
            Text('别聊了,我这边还在改 bug 😵'),
          ],
        ));
  });

  // C:Spacer + mainAxisSize.min 面板 —— 怀疑点二
  testWidgets('c_spacer', (WidgetTester t) async {
    await run(
        t,
        'c_spacer',
        Column(
          children: <Widget>[
            const Text('顶部'),
            const Spacer(),
            DecoratedBox(
              decoration: BoxDecoration(
                color: _c(baseline.surface),
                borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(LaresRadii.lg)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const <Widget>[Text('面板'), Text('第二行')],
              ),
            ),
          ],
        ));
  });
}
