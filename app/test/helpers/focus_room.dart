/// 把一个装了专注插件的房间页 pump 起来。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/focus/focus_lock.dart';
import 'package:lares_app/src/state/room_controller.dart';
import 'package:lares_app/src/theme/theme.dart';
import 'package:lares_app/src/ui/room_screen.dart';

import '../room_screen_test.dart' show FakeRtcService, FakeSignalingClient;
import 'chat_fakes.dart';
import 'focus_fixtures.dart';
import 'localized_app.dart';

class FocusRoom {
  FocusRoom._(this.signaling, this.controller, this.focus, this.chat, this.lock);

  final FakeSignalingClient signaling;
  final RoomController controller;
  final FocusHarness focus;
  final ShotsChatService chat;
  final FocusLock lock;

  static Future<FocusRoom> pump(
    WidgetTester tester, {
    String? ownerKey,
    Size size = const Size(390, 844),
    bool lockSupported = false,
    List<String> people = const ['u_me', 'u1', 'u2'],
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
    final names = {'u_me': '我', 'u1': '小鹿', 'u2': '大橘', 'u3': '阿青'};
    signaling.testInject({
      't': 'room',
      'circleId': 'c1',
      'members': [
        for (final id in people)
          {'userId': id, 'name': names[id] ?? id, 'status': 'free'},
      ],
    });
    await controller.testInjectToken('wss://fake', 'tok');
    final focus = FocusHarness(ownerKey: ownerKey);
    final chat = ShotsChatService();
    final lock = FocusLock(supported: lockSupported);
    focus.enable('c1');
    focus.service.setRoom('c1');

    await tester.pumpWidget(
      localizedApp(
        RoomScreen(
          controller: controller,
          circleName: '自习室',
          chat: chat,
          focus: focus.service,
          focusLock: lock,
        ),
        theme: LaresTheme.dark(),
      ),
    );
    await tester.pump();
    final room = FocusRoom._(signaling, controller, focus, chat, lock);
    return room;
  }

  /// 拆树(房间页有无限动画,不能 pumpAndSettle)并收掉控制器与残余计时器。
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    lock.dispose();
    chat.dispose();
    controller.dispose();
    await focus.dispose();
    await tester.pump(const Duration(minutes: 6));
  }
}
