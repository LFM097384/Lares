import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/focus/focus_models.dart';
import 'package:lares_app/src/focus/focus_service.dart';
import 'package:lares_app/src/focus/focus_widgets.dart';
import 'package:lares_app/src/theme/theme.dart';

import 'helpers/focus_fixtures.dart';
import 'helpers/focus_room.dart';
import 'helpers/localized_app.dart';

void main() {
  test('formatAway / formatClock', () {
    expect(formatAway(const Duration(seconds: 133)), '2:13');
    expect(formatAway(const Duration(seconds: 5)), '0:05');
    expect(formatAway(const Duration(hours: 1, seconds: 7)), '1:00:07');
    expect(formatClock(const Duration(minutes: 24, seconds: 9)), '24:09');
    expect(formatClock(const Duration(seconds: -3)), '00:00');
  });

  testWidgets('座位徽标:专注中 / 离开 m:ss / 休息', (tester) async {
    final room = await FocusRoom.pump(tester);
    room.focus.status(
      'c1',
      members: [
        focusMember('u_me', '我', 'focus'),
        focusMember('u1', '小鹿', 'away', awaySince: kFocusNow - 133000),
        focusMember('u2', '大橘', 'break'),
      ],
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('focus-badge-u_me')), findsOneWidget);
    expect(find.text('专注中'), findsWidgets);
    expect(find.text('离开 2:13'), findsOneWidget);
    expect(find.text('休息'), findsOneWidget);
    await room.close(tester);
  });

  testWidgets('离开徽标每秒走', (tester) async {
    var now = DateTime.fromMillisecondsSinceEpoch(kFocusNow);
    final sent = <Map<String, dynamic>>[];
    final focus = FocusService(
      send: sent.add,
      messages: const Stream.empty(),
      clockOffsetMs: () => 0,
      now: () => now,
    );
    addTearDown(focus.dispose);
    focus.debugInject({
      't': 'plugins',
      'circleId': 'c1',
      'items': [
        {'id': kFocusPluginId, 'enabled': true, 'config': <String, dynamic>{}},
      ],
    });
    focus.setRoom('c1');
    focus.debugInject({
      't': 'focus_status',
      'circleId': 'c1',
      'enabled': true,
      'config': <String, dynamic>{},
      'pomodoro': {'phase': 'idle', 'endsAt': null, 'round': 0, 'rounds': 4},
      'members': [focusMember('u1', '小鹿', 'away', awaySince: kFocusNow - 5000)],
    });

    await tester.pumpWidget(
      localizedApp(
        Center(child: FocusSeatBadge(focus: focus, userId: 'u1')),
        theme: LaresTheme.dark(),
      ),
    );
    expect(find.text('离开 0:05'), findsOneWidget);
    now = now.add(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('离开 0:07'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('收起的语音条里也有徽标(compact)', (tester) async {
    final room = await FocusRoom.pump(tester);
    room.focus.status(
      'c1',
      phase: 'break',
      endsAt: kFocusNow + 300000,
      round: 1,
      members: [focusMember('u1', '小鹿', 'break')],
    );
    await tester.pump();
    // 休息期聊天回来 → 展开消息,语音区收成一条
    final expand = find.byTooltip('展开消息');
    expect(expand, findsOneWidget);
    await tester.tap(expand);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('focus-badge-u1')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await room.close(tester);
  });

  testWidgets('不在专注名单里的人没有徽标', (tester) async {
    final room = await FocusRoom.pump(tester);
    room.focus.status('c1', members: [focusMember('u1', '小鹿', 'focus')]);
    await tester.pump();
    expect(find.byKey(const ValueKey('focus-badge-u1')), findsOneWidget);
    expect(find.byKey(const ValueKey('focus-badge-u2')), findsNothing);
    await room.close(tester);
  });
}
