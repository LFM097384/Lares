// 房间页截图脚手架:用假实现 pump 真正的 RoomScreen,把若干状态截成 PNG。
//
// 这不是回归测试,而是借测试运行器执行的出图脚本。默认全部 skip;
// 只有设置 LARES_SHOTS=1 才会真的跑。
//
// 跑法(app/ 目录下,PowerShell):
//   $env:LARES_SHOTS='1'; $env:LARES_SHOTS_TAG='before'; flutter test test/ui_room_screenshots_test.dart
//
// 输出:spike_out/room_shots/<tag>_<state>.png 与 <tag>_exceptions.txt
//
// 注意(沿用 tool/palette/render_test.dart 的经验):
//  - flutter_test 默认字体是方块,必须手动加载中文字体与 MaterialIcons;
//  - toImage 必须包在 runAsync 里,否则假时钟下永远不返回;
//  - 房间页有无限循环动画:不能 pumpAndSettle,每个场景后要 pumpWidget(SizedBox.shrink())。

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/captions/caption_controller.dart';
import 'package:lares_app/src/chat/chat_message.dart';
import 'package:lares_app/src/focus/focus_lock.dart';
import 'package:lares_app/src/net/signaling_client.dart';
import 'package:lares_app/src/rtc/rtc_service.dart';
import 'package:lares_app/src/state/room_controller.dart';
import 'package:lares_app/src/theme/theme.dart';
import 'package:lares_app/src/ui/room_screen.dart';

import 'helpers/caption_fakes.dart';
import 'helpers/chat_fakes.dart';
import 'helpers/focus_fixtures.dart';
import 'helpers/localized_app.dart';

final bool _skip = Platform.environment['LARES_SHOTS'] != '1';
final String _tag = Platform.environment['LARES_SHOTS_TAG'] ?? 'after';
const String _outDir = 'spike_out/room_shots';
const String _font = 'Msyh';

final List<String> _exceptions = <String>[];

// ─────────────────────────── 字体 ───────────────────────────

const List<String> _cjkCandidates = <String>[
  r'C:\Windows\Fonts\msyh.ttc',
  r'C:\Windows\Fonts\simhei.ttf',
];

Future<void> _loadFontFamily(String family, Uint8List bytes) async {
  final FontLoader loader = FontLoader(family)
    ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
  await loader.load();
}

Future<void> _loadFonts() async {
  for (final String path in _cjkCandidates) {
    final File f = File(path);
    if (!f.existsSync()) continue;
    try {
      final Uint8List bytes = await f.readAsBytes();
      // 同时注册成 Roboto:主题没设 fontFamily 时 Typography 默认就找它。
      await _loadFontFamily(_font, bytes);
      await _loadFontFamily('Roboto', bytes);
      break;
    } catch (_) {
      continue;
    }
  }
  final List<String> iconCandidates = <String>[
    r'D:\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
    if (Platform.environment['FLUTTER_ROOT'] != null)
      '${Platform.environment['FLUTTER_ROOT']}\\bin\\cache\\artifacts\\material_fonts\\materialicons-regular.otf',
  ];
  for (final String path in iconCandidates) {
    final File f = File(path);
    if (!f.existsSync()) continue;
    await _loadFontFamily('MaterialIcons', await f.readAsBytes());
    break;
  }
}

ThemeData _withFont(ThemeData t) => t.copyWith(
      textTheme: t.textTheme.apply(fontFamily: _font),
      primaryTextTheme: t.primaryTextTheme.apply(fontFamily: _font),
    );

// ─────────────────────────── 假实现 ───────────────────────────

class _FakeSignalingClient extends SignalingClient {
  _FakeSignalingClient() : super(url: 'ws://fake');

  @override
  void connect() {}

  @override
  void send(Map<String, dynamic> msg) {}

  @override
  Future<void> dispose() async {}
}

class _FakeRtcService implements RtcService {
  final StreamController<Set<String>> speaking =
      StreamController<Set<String>>.broadcast();
  final StreamController<void> _dropped = StreamController<void>.broadcast();
  bool _inRoom = false;
  bool muted = true;

  @override
  bool get inRoom => _inRoom;

  @override
  Future<RtcJoinResult> join({
    required String url,
    required String token,
    required bool startMuted,
    bool highQuality = true,
    AudioTuning tuning = AudioTuning.standard,
  }) async {
    _inRoom = true;
    muted = startMuted;
    return RtcJoinResult(
        elapsed: const Duration(milliseconds: 120), micOn: !startMuted);
  }

  @override
  ResolvedAudioTuning? get activeTuning =>
      _inRoom ? previewTuning(AudioTuning.standard) : null;

  @override
  ResolvedAudioTuning previewTuning(AudioTuning tuning) => resolveAudioTuning(
        tuning,
        const AudioPlatformCapabilities(
          platform: 'windows',
          supportsAudioSession: false,
          supportsEnhanced: false,
        ),
      );

  @override
  Future<void> leave() async {
    _inRoom = false;
  }

  @override
  Future<void> setMuted(bool m) async {
    muted = m;
  }

  @override
  Stream<Set<String>> get speakingIdentities => speaking.stream;

  @override
  Stream<void> get onDisconnected => _dropped.stream;
}

// ─────────────────────────── 场景数据 ───────────────────────────

const Map<String, String> _names = <String, String>{
  'u_me': '我',
  'u1': '阿蛮',
  'u2': '小鹿',
  'u3': '大橘',
};

List<ChatMessage> _chatMessages() {
  ChatMessage text(String id, String sender, String body, int min,
          {bool mine = false}) =>
      ChatMessage.text(
        id: id,
        senderId: sender,
        senderName: _names[sender]!,
        circleId: 'home',
        timestamp: DateTime(2026, 1, 1, 21, min),
        body: body,
        isMine: mine,
      );
  return <ChatMessage>[
    text('c1', 'u1', '今晚谁还在?', 1),
    text('c2', 'u2', '我在,刚下班,边做饭边挂着', 2),
    text('c3', 'u_me', '在的~ 我在写代码', 3, mine: true),
    // 图片字节尚未到齐:渲染占位
    ChatMessage(
      id: 'c4',
      senderId: 'u1',
      senderName: '阿蛮',
      circleId: 'home',
      timestamp: DateTime(2026, 1, 1, 21, 5),
      kind: ChatMessageKind.image,
      imageWidth: 800,
      imageHeight: 600,
    ),
    text('c5', 'u3', '这张照片是哪里拍的?看起来好舒服,周末一起去吧', 6),
    text('c6', 'u_me', '好呀', 7, mine: true),
  ];
}

class _Scene {
  _Scene({
    required this.name,
    this.people = 4,
    this.speaking = const <String>{},
    this.chatMessages = false,
    this.captions = false,
    this.keyboard = false,
    this.size = const Size(390, 844),
    this.dpr = 2.0,
    this.padTop = 47,
    this.padBottom = 34,
    this.light = false,
    this.focus,
  });

  final String name;
  final int people;
  final Set<String> speaking;
  final bool chatMessages;
  final bool captions;
  final bool keyboard;
  final Size size;
  final double dpr;
  final double padTop;
  final double padBottom;
  final bool light;

  /// 专注学习场景:'focus' / 'break' / 'board';null = 不装专注插件。
  final String? focus;
}

final List<_Scene> _scenes = <_Scene>[
  _Scene(name: 'a_empty', people: 2),
  _Scene(name: 'b_chat', speaking: <String>{'u1'}, chatMessages: true),
  _Scene(
      name: 'c_captions',
      speaking: <String>{'u1'},
      chatMessages: true,
      captions: true),
  _Scene(
      name: 'd_keyboard',
      speaking: <String>{'u1'},
      chatMessages: true,
      keyboard: true),
  _Scene(
      name: 'e_small',
      speaking: <String>{'u1'},
      chatMessages: true,
      captions: true,
      size: const Size(375, 667),
      padTop: 20,
      padBottom: 0),
  _Scene(
      name: 'f_desktop',
      speaking: <String>{'u1'},
      chatMessages: true,
      captions: true,
      size: const Size(1100, 750),
      dpr: 1.0,
      padTop: 0,
      padBottom: 0),
  _Scene(
      name: 'g_light',
      speaking: <String>{'u1'},
      chatMessages: true,
      light: true),
  _Scene(name: 'focus_phase', speaking: <String>{'u1'}, focus: 'focus'),
  _Scene(
      name: 'focus_break',
      speaking: <String>{'u1'},
      chatMessages: true,
      focus: 'break'),
  _Scene(name: 'focus_leaderboard', focus: 'board'),
  _Scene(
      name: 'focus_idle',
      speaking: <String>{'u1'},
      chatMessages: true,
      focus: 'idle'),
  _Scene(
      name: 'focus_phase_360',
      speaking: <String>{'u1'},
      captions: true,
      focus: 'focus',
      size: const Size(360, 640),
      padTop: 24,
      padBottom: 0),
];

// ─────────────────────────── 出图 ───────────────────────────

/// 当前场景/步骤,供 FlutterError 钩子给异常打标签
String _where = '';

void _drainExceptions(WidgetTester tester, String scene, String step) {
  // 详细内容已由 FlutterError 钩子逐条记下;这里只把框架的待报异常清掉,
  // 免得它把整个用例判失败(这是出图脚本,不是断言)。
  while (tester.takeException() != null) {}
  _where = '$scene/after-$step';
}

void _recordError(FlutterErrorDetails d) {
  final List<String> lines = d
      .exceptionAsString()
      .split('\n')
      .where((String l) => l.trim().isNotEmpty)
      .take(2)
      .toList();
  final String ctx = d.context?.toDescription() ?? '';
  final RegExpMatch? m =
      RegExp(r'lib/src/[^\s:]+\.dart:\d+:\d+').firstMatch(d.toString());
  final String creator = m?.group(0) ?? '';
  final String entry =
      '[$_where] ${lines.join(' / ')}  ($ctx${creator.isEmpty ? '' : ' @ $creator'})';
  if (!_exceptions.contains(entry)) _exceptions.add(entry);
}

Future<void> _capture(
    WidgetTester tester, GlobalKey key, String path, double dpr) async {
  final RenderRepaintBoundary boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage(pixelRatio: dpr);
    final ByteData? bytes =
        await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) throw StateError('toByteData 返回 null:$path');
    final File file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes.buffer.asUint8List());
  });
}

Future<void> _runScene(WidgetTester tester, _Scene s) async {
  // 视口:改 tester.view,让真实 MediaQuery 看到尺寸/安全区/键盘
  tester.view.physicalSize = Size(s.size.width * s.dpr, s.size.height * s.dpr);
  tester.view.devicePixelRatio = s.dpr;
  tester.view.padding =
      FakeViewPadding(top: s.padTop * s.dpr, bottom: s.padBottom * s.dpr);
  tester.view.viewInsets = FakeViewPadding.zero;

  final _FakeSignalingClient signaling = _FakeSignalingClient();
  final _FakeRtcService rtc = _FakeRtcService();
  final RoomController controller = RoomController(
    signaling: signaling,
    rtc: rtc,
    userId: 'u_me',
    deviceId: 'd_1',
    userName: '我',
  );
  controller.captionsAvailable = true;
  unawaited(controller.join('home').catchError((Object _) {}));

  final List<String> ids = <String>['u_me', 'u1', 'u2', 'u3'].take(s.people).toList();
  const Map<String, String> statuses = <String, String>{
    'u_me': 'free',
    'u1': 'free',
    'u2': 'busy',
    'u3': 'ears',
  };
  signaling.testInject(<String, dynamic>{
    't': 'room',
    'circleId': 'home',
    'members': <Map<String, dynamic>>[
      for (final String id in ids)
        <String, dynamic>{
          'userId': id,
          'name': _names[id],
          'status': statuses[id],
        },
    ],
  });
  await controller.testInjectToken('wss://fake', 'tok');

  final ShotsChatService chat = ShotsChatService();
  if (s.chatMessages) chat.seed(_chatMessages());

  final FakeChannel ch = FakeChannel(localIdentity: 'u_me');
  final FakeTap tap = FakeTap();
  final CaptionController captions = CaptionController(
    transcriberFactory: ({
      required onPartial,
      required onFinal,
      required onFatal,
    }) =>
        FakeTranscriber(onPartial, onFinal, onFatal),
    nameOf: (String id) => _names[id] ?? id,
  );
  captions.bindSession(ch, tap);
  captions.updateConditions(const CaptionConditions(
      available: true, inRoom: true, muted: false, provide: true));

  FocusHarness? focus;
  if (s.focus != null) {
    focus = FocusHarness(ownerKey: 'ok_home');
    focus.enable('home');
    focus.service.setRoom('home');
    final bool brk = s.focus == 'break';
    final bool idle = s.focus == 'idle';
    focus.status(
      'home',
      phase: idle ? 'idle' : brk ? 'break' : 'focus',
      endsAt: idle
          ? null
          : kFocusNow + (brk ? 3 * 60 + 42 : 18 * 60 + 27) * 1000,
      round: idle ? 0 : 2,
      rounds: 4,
      members: <Map<String, dynamic>>[
        focusMember('u_me', '我', idle ? 'idle' : brk ? 'break' : 'focus'),
        focusMember('u1', _names['u1']!, idle ? 'idle' : brk ? 'break' : 'focus'),
        focusMember('u2', _names['u2']!, idle ? 'idle' : brk ? 'break' : 'away',
            awaySince: brk || idle ? null : kFocusNow - 133000),
        focusMember('u3', _names['u3']!, idle ? 'idle' : brk ? 'break' : 'focus'),
      ],
    );
  }

  final GlobalKey key = GlobalKey();
  final ThemeData theme =
      _withFont(s.light ? LaresTheme.light() : LaresTheme.dark());

  await tester.pumpWidget(RepaintBoundary(
    key: key,
    child: localizedApp(
      RoomScreen(
        controller: controller,
        circleName: '我们的圈',
        chat: chat,
        captions: captions,
        focus: focus?.service,
        focusLock: focus == null ? null : FocusLock(supported: true),
      ),
      theme: theme,
    ),
  ));
  await tester.pump();
  _drainExceptions(tester, s.name, 'mount');

  if (s.speaking.isNotEmpty) {
    rtc.speaking.add(s.speaking);
    await tester.pump();
  }

  if (s.captions) {
    ch.join('u1', mic: true);
    ch.join('u3', mic: true); // 开着麦但没表态 → 「大橘 未开启字幕」
    await tester.runAsync(() => captions.setWantCaptions(true));
    await tester.pump();
    ch.receive('u1', <String, dynamic>{'t': 'capack', 'on': true});
    ch.receive('u1', <String, dynamic>{
      't': 'cap', 'id': 'a', 'seq': 1, 'text': '今天晚饭吃的什么呀?', 'final': true,
    });
    ch.receive('u1', <String, dynamic>{
      't': 'cap', 'id': 'b', 'seq': 2, 'text': '我煮了一锅番茄牛腩,还剩好多。', 'final': true,
    });
    ch.receive('u1', <String, dynamic>{
      't': 'cap', 'id': 'c', 'seq': 3, 'text': '要不明天带点给', 'final': false,
    });
    // 有人向本机请求字幕 → 「正在为 小鹿 生成字幕」横幅
    ch.remotes.add('u2');
    ch.receive('u2', <String, dynamic>{'t': 'capreq', 'on': true});
    await tester.pump();
  }
  _drainExceptions(tester, s.name, 'setup');

  if (s.chatMessages || s.keyboard) {
    final Finder expand = find.byTooltip('展开消息');
    if (expand.evaluate().isNotEmpty) {
      await tester.tap(expand.first, warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
    _drainExceptions(tester, s.name, 'expand');
  }

  if (s.keyboard) {
    tester.view.viewInsets = FakeViewPadding(bottom: 336 * s.dpr);
    final Finder field = find.byType(TextField);
    if (field.evaluate().isNotEmpty) {
      await tester.tap(field.first, warnIfMissed: false);
      await tester.pump();
    }
    _drainExceptions(tester, s.name, 'keyboard');
  }

  if (s.focus == 'board' && focus != null) {
    await tester.tap(find.byKey(const ValueKey<String>('focus-board')).first,
        warnIfMissed: false);
    await tester.pump();
    focus.inject(<String, dynamic>{
      't': 'focus_board',
      'circleId': 'home',
      'today': <Map<String, dynamic>>[
        <String, dynamic>{'userId': 'u1', 'name': _names['u1'], 'ms': 142 * 60000},
        <String, dynamic>{'userId': 'u_me', 'name': '我', 'ms': 96 * 60000},
        <String, dynamic>{'userId': 'u3', 'name': _names['u3'], 'ms': 75 * 60000},
        <String, dynamic>{'userId': 'u2', 'name': _names['u2'], 'ms': 31 * 60000},
      ],
      'week': <Map<String, dynamic>>[],
      'all': <Map<String, dynamic>>[],
    });
    await tester.pump();
    _drainExceptions(tester, s.name, 'board');
  }

  for (int i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 700));
  }
  _drainExceptions(tester, s.name, 'settle');

  await _capture(tester, key, '$_outDir/${_tag}_${s.name}.png', s.dpr);

  // 拆树:停掉无限动画,再收控制器
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  _drainExceptions(tester, s.name, 'unmount');
  captions.dispose();
  chat.dispose();
  controller.dispose();
  await focus?.dispose();
  await tester.pump(const Duration(seconds: 30)); // 放掉残余计时器
  _drainExceptions(tester, s.name, 'dispose');
}

void main() {
  setUpAll(() async {
    if (_skip) return;
    TestWidgetsFlutterBinding.ensureInitialized();
    Directory(_outDir).createSync(recursive: true);
    await _loadFonts();
  });

  tearDownAll(() {
    if (_skip) return;
    File('$_outDir/${_tag}_exceptions.txt').writeAsStringSync(
        _exceptions.isEmpty ? '(none)\n' : '${_exceptions.join('\n\n')}\n');
  });

  for (final _Scene s in _scenes) {
    testWidgets('room shot ${s.name}', (WidgetTester tester) async {
      addTearDown(tester.view.reset);
      final bool oldBanner = WidgetsApp.debugAllowBannerOverride;
      WidgetsApp.debugAllowBannerOverride = false;
      final void Function(FlutterErrorDetails)? oldOnError = FlutterError.onError;
      _where = '${s.name}/mount';
      FlutterError.onError = (FlutterErrorDetails d) {
        _recordError(d);
        oldOnError?.call(d);
      };
      try {
        await _runScene(tester, s);
      } finally {
        FlutterError.onError = oldOnError;
        WidgetsApp.debugAllowBannerOverride = oldBanner;
      }
    }, skip: _skip, timeout: const Timeout(Duration(minutes: 5)));
  }
}
