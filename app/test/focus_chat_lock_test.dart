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
    expect(find.byKey(const ValueKey('focus-chat-hint')), findsNothing);
    expect(find.byKey(const ValueKey('focus-start')), findsOneWidget);
    expect(find.text('开始专注'), findsOneWidget);
    // 专注插件开着时控件排右侧固定是「排行榜 + 聊天」,便签让位
    expect(tester.takeException(), isNull);
    await room.close(tester);
  });

  testWidgets('专注期:聊天收起,显示安静提示;分心入口隐藏', (tester) async {
    final room = await FocusRoom.pump(tester);
    room.focus.status('c1', phase: 'focus', endsAt: kFocusNow + 600000, round: 1);
    await tester.pump();

    expect(find.byType(ChatPanel), findsNothing);
    expect(find.byType(ChatToggleButton), findsNothing);
    expect(find.text('专注中,文字聊天已收起 · 休息时再聊'), findsOneWidget);
    // 语音便签收起,离开 / 麦克风还在
    expect(find.byIcon(Icons.voicemail_rounded), findsNothing);
    expect(find.byIcon(Icons.call_end_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
    await room.close(tester);
  });

  testWidgets('休息期(chatInBreak):聊天回来', (tester) async {
    final room = await FocusRoom.pump(tester);
    room.focus.status(
      'c1',
      phase: 'break',
      endsAt: kFocusNow + 300000,
      round: 1,
    );
    await tester.pump();

    expect(find.byType(ChatPanel), findsOneWidget);
    expect(find.text('专注中,文字聊天已收起 · 休息时再聊'), findsNothing);
    expect(find.byType(ChatToggleButton), findsOneWidget);
    await room.close(tester);
  });

  testWidgets('休息期但圈主关了 chatInBreak:聊天仍收起', (tester) async {
    final room = await FocusRoom.pump(tester);
    room.focus.status(
      'c1',
      phase: 'break',
      endsAt: kFocusNow + 300000,
      round: 1,
      config: {'chatInBreak': false},
    );
    await tester.pump();
    expect(find.byType(ChatPanel), findsNothing);
    expect(find.byKey(const ValueKey('focus-chat-hint')), findsOneWidget);
    await room.close(tester);
  });

  testWidgets('圈主停用专注:一切恢复', (tester) async {
    final room = await FocusRoom.pump(tester);
    room.focus.status('c1', phase: 'focus', endsAt: kFocusNow + 600000, round: 1);
    await tester.pump();
    expect(find.byType(ChatPanel), findsNothing);

    room.focus.inject({
      't': 'focus_notice',
      'circleId': 'c1',
      'kind': 'ended_by_owner',
    });
    await tester.pump();
    expect(find.byType(ChatPanel), findsOneWidget);
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
    await expectMicCentred(tester, 400);
    await room.close(tester);
  });

  testWidgets('不能锁的平台、专注期:麦克风仍正中', (tester) async {
    final room = await FocusRoom.pump(tester, size: const Size(400, 800));
    room.focus.status('c1', phase: 'focus', endsAt: kFocusNow + 600000, round: 1);
    await tester.pump();
    expect(find.byKey(const ValueKey('focus-board')), findsOneWidget);
    expect(find.byKey(const ValueKey('focus-lock')), findsNothing);
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