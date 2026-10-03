import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/ui/chat_panel.dart';

import 'helpers/focus_fixtures.dart';
import 'helpers/focus_room.dart';

void main() {
  testWidgets('开了专注但没开番茄钟:聊天照常,卡上有醒目的开始键', (tester) async {
    final room = await FocusRoom.pump(tester, ownerKey: 'ok');
    room.focus.status('c1');
    await tester.pump();

    expect(find.byType(ChatPanel), findsOneWidget);
    expect(find.byKey(const ValueKey('focus-start')), findsOneWidget);
    expect(find.text('开始专注'), findsOneWidget);
    // 专注插件开着时控件排右侧固定是「排行榜 + 聊天」,便签让位
    expect(tester.takeException(), isNull);
    await room.close(tester);
  });

  testWidgets('专注期:文字聊天与发图照常;只收地图 / 便签 / 小程序', (tester) async {
    final room = await FocusRoom.pump(tester);
    room.focus.status('c1', phase: 'focus', endsAt: kFocusNow + 600000, round: 1);
    await tester.pump();

    expect(find.byType(ChatPanel), findsOneWidget);
    expect(find.byType(ChatToggleButton), findsOneWidget);
    // 发图入口在输入栏里,专注期也在
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    expect(find.textContaining('文字聊天已收起'), findsNothing);
    // 语音便签收起,离开 / 麦克风还在
    expect(find.byIcon(Icons.voicemail_rounded), findsNothing);
    expect(find.byIcon(Icons.call_end_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
    await room.close(tester);
  });

  testWidgets('专注期:能打字发消息', (tester) async {
    final room = await FocusRoom.pump(tester);
    room.focus.status('c1', phase: 'focus', endsAt: kFocusNow + 600000, round: 1);
    await tester.pump();

    final field = find.descendant(
      of: find.byType(ChatPanel),
      matching: find.byType(TextField),
    );
    expect(field, findsOneWidget);
    await tester.enterText(field, '专注中也能说一句');
    await tester.pump();
    expect(find.text('专注中也能说一句'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await room.close(tester);
  });

  testWidgets('休息期:聊天照常', (tester) async {
    final room = await FocusRoom.pump(tester);
    room.focus.status(
      'c1',
      phase: 'break',
      endsAt: kFocusNow + 300000,
      round: 1,
    );
    await tester.pump();

    expect(find.byType(ChatPanel), findsOneWidget);
    expect(find.byType(ChatToggleButton), findsOneWidget);
    await room.close(tester);
  });

  testWidgets('老配置里带 chatInBreak:false:休息期 / 专注期聊天都不收', (tester) async {
    final room = await FocusRoom.pump(tester);
    room.focus.status(
      'c1',
      phase: 'break',
      endsAt: kFocusNow + 300000,
      round: 1,
      config: {'chatInBreak': false},
    );
    await tester.pump();
    expect(find.byType(ChatPanel), findsOneWidget);

    room.focus.status(
      'c1',
      phase: 'focus',
      endsAt: kFocusNow + 600000,
      round: 2,
      config: {'chatInBreak': false},
    );
    await tester.pump();
    expect(find.byType(ChatPanel), findsOneWidget);
    expect(tester.takeException(), isNull);
    await room.close(tester);
  });

  testWidgets('从休息进入专注段:展开着的聊天不被收起', (tester) async {
    final room = await FocusRoom.pump(tester);
    room.focus.status(
      'c1',
      phase: 'break',
      endsAt: kFocusNow + 300000,
      round: 1,
    );
    await tester.pump();
    final collapsedHeight = tester.getSize(find.byType(ChatPanel)).height;
    await tester.tap(find.byType(ChatToggleButton));
    // 背景呼吸 / 计时卡一直在动,不能 pumpAndSettle
    await tester.pump(const Duration(milliseconds: 600));
    final expandedHeight = tester.getSize(find.byType(ChatPanel)).height;
    expect(expandedHeight, greaterThan(collapsedHeight));

    room.focus.status('c1', phase: 'focus', endsAt: kFocusNow + 600000, round: 2);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(ChatPanel), findsOneWidget);
    expect(tester.getSize(find.byType(ChatPanel)).height, expandedHeight);
    await room.close(tester);
  });
  testWidgets('圈主停用专注:一切恢复', (tester) async {
    final room = await FocusRoom.pump(tester);
    room.focus.status('c1', phase: 'focus', endsAt: kFocusNow + 600000, round: 1);
    await tester.pump();
    expect(find.byType(ChatPanel), findsOneWidget);
    expect(find.byIcon(Icons.voicemail_rounded), findsNothing);

    room.focus.inject({
      't': 'focus_notice',
      'circleId': 'c1',
      'kind': 'ended_by_owner',
    });
    await tester.pump();
    expect(find.byType(ChatPanel), findsOneWidget);
    // 专注那一套收起:排行榜键不在了,控件排回到「离开 · 麦 · 聊天」
    expect(find.byKey(const ValueKey('focus-board')), findsNothing);
    expect(find.byType(ChatToggleButton), findsOneWidget);
    expect(find.byKey(const ValueKey('focus-timer-card')), findsNothing);
    // snackbar 告知
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('圈主结束了专注'), findsOneWidget);
    await room.close(tester);
  });

  testWidgets('360 宽不溢出', (tester) async {
    final room = await FocusRoom.pump(
      tester,
      size: const Size(360, 640),
      ownerKey: 'ok',
      lockSupported: true,
      people: const ['u_me', 'u1', 'u2', 'u3'],
    );
    room.focus.status(
      'c1',
      phase: 'focus',
      endsAt: kFocusNow + 1000000,
      round: 2,
      members: [
        focusMember('u_me', '我', 'focus'),
        focusMember('u1', '小鹿', 'away', awaySince: kFocusNow - 4000000),
        focusMember('u2', '大橘', 'focus'),
        focusMember('u3', '阿青', 'focus'),
      ],
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await room.close(tester);
  });

  /// 控件排里麦克风的水平中心 == 屏幕中心(专注时右侧换成排行榜 / 锁)。
  Future<void> expectMicCentred(WidgetTester tester, double width) async {
    final mic = find.byIcon(Icons.mic_rounded).evaluate().isNotEmpty
        ? find.byIcon(Icons.mic_rounded)
        : find.byIcon(Icons.mic_off_rounded);
    final dx = tester.getCenter(mic.last).dx;
    expect(dx, moreOrLessEquals(width / 2, epsilon: 0.5));
  }

  testWidgets('专注期控件排:麦克风正中,右侧排行榜 + 锁定', (tester) async {
    final room = await FocusRoom.pump(
      tester,
      size: const Size(400, 800),
      lockSupported: true,
    );
    room.focus.status('c1', phase: 'focus', endsAt: kFocusNow + 600000, round: 1);
    await tester.pump();
    expect(find.byKey(const ValueKey('focus-board')), findsOneWidget);
    expect(find.byKey(const ValueKey('focus-lock')), findsOneWidget);
    // 锁占了右侧第二格:聊天展开/收起键回到输入栏,聊天照样能展开
    expect(find.byType(ChatToggleButton), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ChatPanel),
        matching: find.byType(ChatToggleButton),
      ),
      findsOneWidget,
    );
    await expectMicCentred(tester, 400);
    await room.close(tester);
  });

  testWidgets('不能锁的平台、专注期:右侧排行榜 + 聊天开关,麦克风正中', (tester) async {
    final room = await FocusRoom.pump(tester, size: const Size(400, 800));
    room.focus.status('c1', phase: 'focus', endsAt: kFocusNow + 600000, round: 1);
    await tester.pump();
    expect(find.byKey(const ValueKey('focus-board')), findsOneWidget);
    expect(find.byKey(const ValueKey('focus-lock')), findsNothing);
    // 聊天开关在控件排(不在输入栏里),且在麦克风右侧
    final toggle = find.byType(ChatToggleButton);
    expect(toggle, findsOneWidget);
    expect(
      find.descendant(of: find.byType(ChatPanel), matching: toggle),
      findsNothing,
    );
    expect(tester.getCenter(toggle).dx, greaterThan(200));
    await expectMicCentred(tester, 400);
    await room.close(tester);
  });

  testWidgets('没开番茄钟:控件排是排行榜 + 聊天开关,麦克风正中', (tester) async {
    final room = await FocusRoom.pump(tester, size: const Size(400, 800));
    room.focus.status('c1');
    await tester.pump();
    expect(find.byKey(const ValueKey('focus-board')), findsOneWidget);
    expect(find.byType(ChatToggleButton), findsOneWidget);
    await expectMicCentred(tester, 400);
    await room.close(tester);
  });

  testWidgets('360×640 开着字幕:座位名字完整可见', (tester) async {
    final room = await FocusRoom.pump(
      tester,
      size: const Size(360, 640),
      people: const ['u_me', 'u1', 'u2', 'u3'],
    );
    room.focus.status('c1', phase: 'focus', endsAt: kFocusNow + 600000, round: 1);
    await tester.pump();
    final view = tester.getRect(find.byType(GridView));
    for (final name in ['小鹿', '大橘']) {
      final f = find.descendant(of: find.byType(GridView), matching: find.text(name));
      if (f.evaluate().isEmpty) continue; // 第二排可以滚动出视野
      final r = tester.getRect(f.first);
      if (r.top >= view.bottom) continue;
      expect(r.bottom, lessThanOrEqualTo(view.bottom + 0.5), reason: name);
    }
    expect(tester.takeException(), isNull);
    await room.close(tester);
  });
}