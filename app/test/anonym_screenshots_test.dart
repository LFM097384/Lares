// 隐名之约(受 Chatham House 规则启发 · 非官方)正式界面出图脚本。
//
// 不是回归测试:默认 skip,只有 LARES_SHOTS=1 才跑。
//   $env:LARES_SHOTS='1'; flutter test test/anonym_screenshots_test.dart
// 输出:spike_out/chatham/prod_<screen>_dark.png
//
// 出图技巧沿用 test/chatham_concept_screenshots_test.dart。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/l10n/gen/app_localizations.dart';
import 'package:lares_app/src/anonym/anonym_controller.dart';
import 'package:lares_app/src/anonym/anonym_crypto.dart';
import 'package:lares_app/src/anonym/anonym_gate.dart';
import 'package:lares_app/src/anonym/anonym_kit.dart';
import 'package:lares_app/src/anonym/anonym_memory.dart';
import 'package:lares_app/src/anonym/anonym_room.dart';
import 'package:lares_app/src/anonym/anonym_sheets.dart';
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

AnonymController _session({bool acked = true}) {
  final c = AnonymController(
    send: (_) {},
    keyFactory: () => AnonymKeys.fromSeed(List<int>.generate(32, (i) => i)),
  )..bindRoom(circleId: 'c1', inRoom: true, myUserId: 'me');
  c.handle({
    't': 'anon_state', 'circleId': 'c1', 'active': true, 'sid': 'S1', 'k': 3,
    'convenerId': 'u1',
    'members': [
      {'id': 'u1', 'name': '林岚', 'acked': true},
      {'id': 'me', 'name': '我', 'acked': acked},
      {'id': 'u3', 'name': '周屿', 'acked': true},
      {'id': 'u4', 'name': '阿青', 'acked': false},
    ],
  });
  if (acked) c.accept();
  return c;
}

/// 底部面板在真机里是浮在房间上的;出图时放在一块深色底上,模拟面板外观。
Widget _sheetLike(BuildContext context, Widget sheet) {
  final cs = Theme.of(context).colorScheme;
  return Scaffold(
    backgroundColor: Colors.black,
    body: Align(
      alignment: Alignment.bottomCenter,
      child: Material(
        color: cs.surfaceContainerLow,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.only(top: 24),
          child: sheet,
        ),
      ),
    ),
  );
}

class _Shot {
  const _Shot(this.name, this.build);
  final String name;
  final Widget Function(BuildContext) build;
}

final List<_Shot> _shots = <_Shot>[
  _Shot('prod_1_convene', (ctx) => _sheetLike(ctx,
      AnonymConveneSheet(anonym: _session(acked: false), presentCount: 4))),
  _Shot('prod_2_consent', (ctx) => _sheetLike(ctx,
      const AnonymConsentSheet(convenerName: '林岚'))),
  _Shot('prod_3_band', (ctx) {
    final c = _session();
    c.handle({'t': 'anon_answer', 'circleId': 'c1', 'askerName': '周屿',
        'question': '我们分歧主要在哪?', 'answer': '分歧集中在节奏:一方主张本季度先砍外包预算,另一方担心交付会断档。'});
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const SizedBox(height: 56),
          AnonymRoomBand(anonym: c),
          const Spacer(),
        ]),
      ),
    );
  }),
  _Shot('prod_3b_band_declined', (ctx) {
    final c = _session(acked: false)..decline();
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const SizedBox(height: 56),
          AnonymRoomBand(anonym: c),
          const Spacer(),
        ]),
      ),
    );
  }),
  _Shot('prod_4_ask', (ctx) {
    final c = _session();
    c.handle({'t': 'anon_answer', 'circleId': 'c1', 'askerName': '周屿',
        'question': '我们分歧主要在哪?', 'answer': '分歧集中在节奏:一方主张本季度先砍外包预算,另一方担心交付会断档。双方都同意需要一份过渡计划。'});
    return _sheetLike(ctx, AnonymAskSheet(anonym: c));
  }),
  _Shot('prod_5_gate', (ctx) {
    final c = _session();
    c.handle({
      't': 'anon_draft', 'circleId': 'c1',
      'draft': {
        'draftId': 'd1', 'draftHash': 'h1',
        'items': [
          {'id': 'a', 'text': '有人认为本季度应先压缩外包预算,把节省下来的部分留作过渡。'},
          {'id': 'b', 'text': '作为负责交付的人,我担心砍外包会让三月的上线断档。', 'roleRisk': true,
            'reason': '「负责交付」可能指向具体的人', 'flags': ['role-revealing']},
          {'id': 'c', 'text': '与会者普遍同意:需要一份两个月的过渡计划。'},
        ],
        'metrics': {'items': 3, 'roleRisk': 1, 'kAnonymity': 3},
      },
    });
    c.handle({'t': 'anon_approvals', 'circleId': 'c1', 'draftId': 'd1', 'count': 1, 'k': 3});
    return AnonymGateScreen(anonym: c);
  }),
  _Shot('prod_5b_released', (ctx) {
    final c = _session();
    c.handle({
      't': 'anon_draft', 'circleId': 'c1',
      'draft': {'draftId': 'd1', 'draftHash': 'h1', 'items': [
        {'id': 'a', 'text': '有人认为本季度应先压缩外包预算,把节省下来的部分留作过渡。'},
      ]},
    });
    c.handle({'t': 'anon_released', 'circleId': 'c1', 'draftId': 'd1',
        'text': '· 有人认为本季度应先压缩外包预算,把节省下来的部分留作过渡。\n· 与会者普遍同意:需要一份两个月的过渡计划。'});
    return AnonymGateScreen(anonym: c);
  }),
  _Shot('prod_6_end', (ctx) => AnonymEndCard(
        receipt: const AnonymReceipt(
          counts: {'utterances': 42, 'drafts': 2, 'released': 1},
          sha256: '9f3ac41e07bde2a8b55c1f0e6d2a7c3e4b9a0f1d2c3e4f5a6b7c8d9e0f1a2b3c',
        ),
        releasedText: '· 有人认为本季度应先压缩外包预算,把节省下来的部分留作过渡。\n· 与会者普遍同意:需要一份两个月的过渡计划。',
      )),
  _Shot('prod_7_memory', (ctx) {
    final c = _session()..loadMemory();
    c.handle({
      't': 'anon_mem', 'circleId': 'c1',
      'items': [
        {'id': 'm1', 'text': '本季度先压缩外包预算,节省部分留作过渡。', 'kind': 'decision',
          'sid': 'S2', 'releasedAt': '2026-10-18T09:00:00Z', 'approvals': 3, 'canRetract': true},
        {'id': 'm2', 'text': '在三月上线前整理一份两个月的过渡计划。', 'kind': 'todo',
          'sid': 'S2', 'releasedAt': DateTime.utc(2026, 10, 18, 9).millisecondsSinceEpoch, 'approvals': 3},
        {'id': 'm3', 'retracted': true},
        {'id': 'm4', 'text': '有与会者建议引入外部评审,以免团队内部视角单一。', 'kind': 'idea',
          'sid': 'S1', 'releasedAt': '2026-10-11T09:00:00Z', 'approvals': 4, 'canRetract': true},
        {'id': 'm5', 'text': '《三体》是刘慈欣写的。', 'kind': 'fact',
          'sid': 'S1', 'releasedAt': '2026-10-11T09:00:00Z', 'approvals': 4},
      ],
    });
    c.retractMemory('m4');
    return AnonymMemoryScreen(anonym: c, circleId: 'c1', circleName: '周末读书会', isOwner: false);
  }),
];

final List<String> _errors = <String>[];

Future<void> _render(WidgetTester tester, _Shot s) async {
  const Size size = Size(390, 844);
  const double dpr = 2;
  tester.view.physicalSize = size * dpr;
  tester.view.devicePixelRatio = dpr;
  tester.view.padding = const FakeViewPadding(top: 47 * dpr, bottom: 34 * dpr);
  addTearDown(tester.view.reset);

  final GlobalKey key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _withFont(LaresTheme.dark()),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(builder: s.build),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  Object? e;
  while ((e = tester.takeException()) != null) {
    _errors.add('[${s.name}] $e');
  }
  final String path = '$_outDir/${s.name}_dark.png';
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
    File('$_outDir/prod_exceptions.txt')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(_errors.isEmpty ? 'none\n' : '${_errors.join('\n')}\n');
  });

  for (final _Shot s in _shots) {
    testWidgets('anonym shot ${s.name}', (WidgetTester tester) async {
      await _render(tester, s);
    }, skip: _skip);
  }
}
