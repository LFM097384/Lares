// 不具名圈两档概念稿出图脚本:守则时段(严格按 Chatham House 官方 FAQ)\n// 与隐名之约(受规则启发 · 非官方)。
//
// 不是回归测试:默认 skip,只有 LARES_SHOTS=1 才跑。
//   $env:LARES_SHOTS='1'; flutter test test/chatham_concept_screenshots_test.dart
// 输出:spike_out/chatham/<screen>_<dark|light360>.png
//
// 出图技巧沿用 test/ui_room_screenshots_test.dart:手动加载中文字体与
// MaterialIcons、toImage 包在 runAsync 里、RepaintBoundary 截图。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/chatham_preview/chatham_kit.dart';
import 'package:lares_app/src/chatham_preview/convene_sheet.dart';
import 'package:lares_app/src/chatham_preview/gate_review.dart';
import 'package:lares_app/src/chatham_preview/release_and_end.dart';
import 'package:lares_app/src/chatham_preview/room_under_rule.dart';
import 'package:lares_app/src/theme/theme.dart';

final bool _skip = Platform.environment['LARES_SHOTS'] != '1';
const String _outDir = 'spike_out/chatham';
const String _font = 'Msyh';
const String _emoji = 'SegoeEmoji';

Future<void> _load(String family, String path) async {
  final File f = File(path);
  if (!f.existsSync()) return;
  final Uint8List bytes = await f.readAsBytes();
  final FontLoader loader = FontLoader(family)
    ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
  await loader.load();
}

Future<void> _loadFonts() async {
  await _load(_font, r'C:\Windows\Fonts\msyh.ttc');
  await _load('Roboto', r'C:\Windows\Fonts\msyh.ttc');
  await _load(_emoji, r'C:\Windows\Fonts\seguiemj.ttf');
  // 衬线:拉丁用 Georgia(正/斜各一),中文用华文中宋
  final FontLoader serif = FontLoader(ChathamType.serifLatin);
  for (final String p in <String>[r'C:\Windows\Fonts\georgia.ttf', r'C:\Windows\Fonts\georgiai.ttf']) {
    final File f = File(p);
    if (f.existsSync()) {
      serif.addFont(f.readAsBytes().then((Uint8List b) => ByteData.sublistView(b)));
    }
  }
  await serif.load();
  await _load(ChathamType.serifCjk, r'C:\Windows\Fonts\STZHONGS.TTF');
  await _load(ChathamType.mono, r'C:\Windows\Fonts\consola.ttf');
  final List<String> icons = <String>[
    r'D:\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
    if (Platform.environment['FLUTTER_ROOT'] != null)
      '${Platform.environment['FLUTTER_ROOT']}\\bin\\cache\\artifacts\\material_fonts\\materialicons-regular.otf',
  ];
  for (final String p in icons) {
    if (File(p).existsSync()) {
      await _load('MaterialIcons', p);
      break;
    }
  }
}

ThemeData _withFont(ThemeData t) {
  const List<String> fb = <String>[_emoji];
  TextStyle? f(TextStyle? s) => s?.copyWith(fontFamily: _font, fontFamilyFallback: fb);
  final ButtonStyle? filled = t.filledButtonTheme.style;
  return t.copyWith(
    textTheme: t.textTheme.apply(fontFamily: _font, fontFamilyFallback: fb),
    primaryTextTheme: t.primaryTextTheme.apply(fontFamily: _font, fontFamilyFallback: fb),
    appBarTheme: t.appBarTheme.copyWith(titleTextStyle: f(t.appBarTheme.titleTextStyle)),
    filledButtonTheme: FilledButtonThemeData(
      style: filled?.copyWith(
        textStyle: WidgetStatePropertyAll<TextStyle?>(f(filled.textStyle?.resolve(<WidgetState>{}))),
      ),
    ),
  );
}

class _Shot {
  const _Shot(this.name, this.build);
  final String name;
  final Widget Function() build;
}

final List<_Shot> _shots = <_Shot>[
  _Shot('1_convene', () => const ConveneSheetPreview()),
  _Shot('1b_convene_strict', () => const ConveneSheetPreview(tier: Tier.strict)),
  _Shot('2_room', () => const RoomUnderRulePreview()),
  _Shot('3_ai', () => const InRoomAiPreview()),
  _Shot('4_gate', () => const GateReviewPreview()),
  _Shot('5_consensus', () => const ReleaseConsensusPreview()),
  _Shot('6_end', () => const SessionEndPreview()),
  _Shot('7_strict_room', () => const StrictRoomPreview()),
];

/// 亮色 360 宽只出两张。
const Set<String> _lightToo = <String>{'1_convene', '4_gate'};

final List<String> _errors = <String>[];

Future<void> _render(WidgetTester tester, _Shot s, {required bool light}) async {
  final Size size = light ? const Size(360, 780) : const Size(390, 844);
  const double dpr = 2;
  tester.view.physicalSize = size * dpr;
  tester.view.devicePixelRatio = dpr;
  tester.view.padding = const FakeViewPadding(top: 47 * dpr, bottom: 34 * dpr);
  addTearDown(tester.view.reset);

  final GlobalKey key = GlobalKey();
  final ThemeData theme = _withFont(light ? LaresTheme.light() : LaresTheme.dark());
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: s.build(),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  Object? e;
  while ((e = tester.takeException()) != null) {
    _errors.add('[${s.name}${light ? ' light' : ''}] $e');
  }
  final String path = '$_outDir/${s.name}_${light ? 'light360' : 'dark'}.png';
  final RenderRepaintBoundary boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage(pixelRatio: dpr);
    final ByteData? bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final File file = File(path)..parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes!.buffer.asUint8List());
  });
  await tester.pumpWidget(const SizedBox.shrink());
}

void main() {
  setUpAll(() async {
    if (_skip) return;
    await _loadFonts();
  });

  tearDownAll(() {
    if (_skip) return;
    File('$_outDir/exceptions.txt')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(_errors.isEmpty ? 'none\n' : '${_errors.join('\n')}\n');
  });

  for (final _Shot s in _shots) {
    testWidgets('chatham shot ${s.name}', (WidgetTester tester) async {
      await _render(tester, s, light: false);
      if (_lightToo.contains(s.name)) await _render(tester, s, light: true);
    }, skip: _skip);
  }
}
