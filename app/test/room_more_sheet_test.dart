// 功能收纳:默认房间只有语音 + 文字聊天,其余可选功能收在「更多」后面;
// 「更多」里只列本圈开着的功能(关掉的整格不出现)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/captions/caption_controller.dart';
import 'package:lares_app/src/plugins/plugin_service.dart';
import 'package:lares_app/src/state/location_share_stub.dart'
    if (dart.library.io) 'package:lares_app/src/state/location_share.dart';
import 'package:lares_app/src/state/room_controller.dart';
import 'package:lares_app/src/theme/theme.dart';
import 'package:lares_app/src/ui/room_screen.dart';

import 'helpers/caption_fakes.dart';
import 'helpers/chat_fakes.dart';
import 'helpers/focus_room.dart';
import 'helpers/localized_app.dart';
import 'room_screen_test.dart' show FakeRtcService, FakeSignalingClient;

class _Room {
  _Room(this.signaling, this.controller, this.captions, this.location,
      this.plugins, this.pluginMsgs, this.chat);

  final FakeSignalingClient signaling;
  final RoomController controller;
  final CaptionController captions;
  final LocationShareService location;
  final PluginService plugins;
  final StreamController<Map<String, dynamic>> pluginMsgs;
  final ShotsChatService? chat;

  /// 圈主改了功能开关(或 welcome 带来的圈信息)。
  void features(Map<String, bool> f, {bool transcript = false}) =>
      signaling.testInject({
        't': 'circle_settings',
        'circle': {
          'id': 'c1',
          'registered': true,
          'features': f,
          'transcript': transcript,
        },
      });

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    chat?.dispose();
    await location.dispose();
    plugins.dispose();
    await pluginMsgs.close();
    captions.dispose();
    controller.dispose();
    await tester.pump(const Duration(minutes: 6));
  }
}

const _allOff = {
  'captions': false,
  'transcript': false,
  'voiceNotes': false,
  'map': false,
  'recording': false,
  'plugins': false,
  'focus': false,
  'p2p': false,
  'devTools': false,
};

Future<_Room> _pump(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  bool withChat = true,
  bool thirdPartyPlugin = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final signaling = FakeSignalingClient();
  final controller = RoomController(
    signaling: signaling,
    rtc: FakeRtcService(),
    userId: 'u_me',
    deviceId: 'd_1',
    userName: '我',
  );
  unawaited(controller.join('c1').catchError((Object _) {}));
  signaling.testInject({
    't': 'room',
    'circleId': 'c1',
    'members': [
      {'userId': 'u_me', 'name': '我', 'status': 'free'},
      {'userId': 'u1', 'name': '小鹿', 'status': 'free'},
    ],
  });
  await controller.testInjectToken('wss://fake', 'tok');
  // 服务器配了字幕(welcome.captions = true)
  controller.captionsAvailable = true;

  final captions = CaptionController(
    transcriberFactory: ({
      required onPartial,
      required onFinal,
      required onFatal,
    }) =>
        FakeTranscriber(onPartial, onFinal, onFatal),
  );
  final location = LocationShareService(room: controller);
  final pluginMsgs = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  final plugins = PluginService(
    send: (_) {},
    messages: pluginMsgs.stream,
    ownerKeyFor: (_) => null,
  );
  pluginMsgs.add({
    't': 'plugins',
    'circleId': 'c1',
    'items': [
      if (thirdPartyPlugin)
        {
          'id': 'acme.board',
          'name': '白板',
          'enabled': true,
          'entry': {'url': 'https://example.com/board'},
        },
    ],
  });
  final chat = withChat ? ShotsChatService() : null;

  await tester.pumpWidget(
    localizedApp(
      RoomScreen(
        controller: controller,
        circleName: '我们的圈',
        chat: chat,
        captions: captions,
        locationShare: location,
        plugins: plugins,
      ),
      theme: LaresTheme.dark(),
    ),
  );
  await tester.pump();
  return _Room(
      signaling, controller, captions, location, plugins, pluginMsgs, chat);
}

Future<void> _openMore(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('room-more')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void _expectMicCentred(WidgetTester tester, double width) {
  final mic = find.byIcon(Icons.mic_rounded).evaluate().isNotEmpty
      ? find.byIcon(Icons.mic_rounded)
      : find.byIcon(Icons.mic_off_rounded);
  final dx = tester.getCenter(mic.last).dx;
  expect(dx, moreOrLessEquals(width / 2, epsilon: 0.5));
}

void main() {
  testWidgets('默认房间:可选功能都不在外面,只有「更多」', (tester) async {
    final room = await _pump(tester, thirdPartyPlugin: true);
    expect(find.byKey(const ValueKey('room-more')), findsOneWidget);
    expect(find.byKey(const ValueKey('captions-toggle')), findsNothing);
    expect(find.byIcon(Icons.voicemail_rounded), findsNothing);
    expect(find.byIcon(Icons.map_outlined), findsNothing);
    expect(find.byKey(const ValueKey('room-transcript-history')), findsNothing);
    expect(find.byKey(const ValueKey('room-plugins')), findsNothing);

    await _openMore(tester);
    expect(find.byKey(const ValueKey('more-captions')), findsOneWidget);
    expect(find.byKey(const ValueKey('more-map')), findsOneWidget);
    expect(find.byKey(const ValueKey('more-plugins')), findsOneWidget);
    // 没开转写、没配便签:不出格子
    expect(find.byKey(const ValueKey('more-transcript')), findsNothing);
    expect(find.byKey(const ValueKey('more-voiceNotes')), findsNothing);
    await room.close(tester);
  });

  testWidgets('字幕格:点一下开 / 关', (tester) async {
    final room = await _pump(tester);
    await _openMore(tester);
    expect(room.captions.wantCaptions, isFalse);
    await tester.tap(find.byKey(const ValueKey('captions-toggle')));
    await tester.pump();
    expect(room.captions.wantCaptions, isTrue);
    expect(find.text('开着'), findsOneWidget);
    await room.close(tester);
  });

  testWidgets('只列开着的功能:字幕关 + 地图开', (tester) async {
    final room = await _pump(tester);
    room.features({..._allOff, 'map': true});
    await tester.pump();
    await _openMore(tester);
    expect(find.byKey(const ValueKey('more-map')), findsOneWidget);
    expect(find.byKey(const ValueKey('more-captions')), findsNothing);
    expect(find.byKey(const ValueKey('more-plugins')), findsNothing);
    await room.close(tester);
  });

  testWidgets('全关(普通成员):没有「更多」,也不剩任何可选键', (tester) async {
    final room = await _pump(tester, thirdPartyPlugin: true);
    room.features(_allOff);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('room-more')), findsNothing);
    expect(find.byKey(const ValueKey('captions-toggle')), findsNothing);
    expect(find.byIcon(Icons.map_outlined), findsNothing);
    expect(find.byKey(const ValueKey('room-plugins')), findsNothing);
    await room.close(tester);
  });

  testWidgets('插件关:第三方入口不列', (tester) async {
    final room = await _pump(tester, thirdPartyPlugin: true);
    room.features({..._allOff, 'map': true, 'plugins': false});
    await tester.pump();
    await _openMore(tester);
    expect(find.byKey(const ValueKey('more-plugins')), findsNothing);
    await room.close(tester);
  });

  testWidgets('地图铺着时圈主关掉地图:退回房间', (tester) async {
    final room = await _pump(tester);
    await _openMore(tester);
    await tester.tap(find.byKey(const ValueKey('more-map')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('room-map-close')), findsOneWidget);
    room.features({..._allOff, 'captions': true});
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('room-map-close')), findsNothing);
    await room.close(tester);
  });

  testWidgets('圈主关掉字幕:本机不再看字幕', (tester) async {
    final room = await _pump(tester);
    room.captions.setWantCaptions(true);
    await tester.pump();
    room.features({..._allOff, 'map': true});
    await tester.pump();
    await tester.pump();
    expect(room.captions.wantCaptions, isFalse);
    await room.close(tester);
  });

  testWidgets('转写开着:常驻一行提示,「更多」里有转写格', (tester) async {
    final room = await _pump(tester);
    room.features({
      'captions': true,
      'transcript': true,
      'map': true,
    }, transcript: true);
    await tester.pump();
    expect(find.text('本圈开着转写记录'), findsOneWidget);
    await room.close(tester);
  });

  testWidgets('用途名牌:头部一行淡字', (tester) async {
    final room = await _pump(tester);
    room.signaling.testInject({
      't': 'circle_settings',
      'circle': {
        'id': 'c1',
        'registered': true,
        'purpose': {'id': 'study', 'name': '自习', 'icon': '📚'},
      },
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('room-purpose')), findsOneWidget);
    expect(find.text('📚 自习'), findsOneWidget);
    await room.close(tester);
  });

  group('麦克风正中', () {
    for (final width in [360.0, 400.0]) {
      testWidgets('有聊天 · $width', (tester) async {
        final room = await _pump(tester, size: Size(width, 800));
        expect(find.byKey(const ValueKey('room-more')), findsOneWidget);
        _expectMicCentred(tester, width);
        expect(tester.takeException(), isNull);
        await room.close(tester);
      });

      testWidgets('无聊天 · $width', (tester) async {
        final room = await _pump(
          tester,
          size: Size(width, 800),
          withChat: false,
        );
        final more = find.byKey(const ValueKey('room-more'));
        expect(more, findsOneWidget);
        // 没有聊天时「更多」在右侧
        expect(tester.getCenter(more).dx, greaterThan(width / 2));
        _expectMicCentred(tester, width);
        await room.close(tester);
      });

      testWidgets('无聊天 + 全关 · $width', (tester) async {
        final room = await _pump(
          tester,
          size: Size(width, 800),
          withChat: false,
        );
        room.features(_allOff);
        await tester.pump();
        expect(find.byKey(const ValueKey('room-more')), findsNothing);
        _expectMicCentred(tester, width);
        await room.close(tester);
      });

      testWidgets('专注模式 · $width', (tester) async {
        final room = await FocusRoom.pump(tester, size: Size(width, 800));
        room.focus.status('c1');
        await tester.pump();
        expect(find.byKey(const ValueKey('focus-board')), findsOneWidget);
        _expectMicCentred(tester, width);
        expect(tester.takeException(), isNull);
        await room.close(tester);
      });
    }
  });
}
