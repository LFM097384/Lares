import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/focus/focus_models.dart';

import 'helpers/focus_fixtures.dart';
import 'helpers/focus_room.dart';

void main() {
  testWidgets('等待开始:圈主能开番茄钟(带 ownerKey)', (tester) async {
    final room = await FocusRoom.pump(tester, ownerKey: 'ok_1');
    room.focus.status('c1');
    await tester.pump();

    expect(find.text('等待开始'), findsOneWidget);
    expect(find.text('一起安静地做事 · 番茄钟可选'), findsOneWidget);
    room.focus.sent.clear();
    await tester.tap(find.byKey(const ValueKey('focus-start')));
    await tester.pump();
    expect(room.focus.sent.single, {
      't': 'focus_start',
      'circleId': 'c1',
      'ownerKey': 'ok_1',
    });
    await room.close(tester);
  });

  testWidgets('普通成员:默认没有开始按钮;membersCanStart 时有,且不带 ownerKey', (
    tester,
  ) async {
    final room = await FocusRoom.pump(tester);
    room.focus.status('c1');
    await tester.pump();
    expect(find.byKey(const ValueKey('focus-start')), findsNothing);
    expect(find.byKey(const ValueKey('focus-board')), findsOneWidget);

    room.focus.status('c1', config: {'membersCanStart': true});
    await tester.pump();
    room.focus.sent.clear();
    await tester.tap(find.byKey(const ValueKey('focus-start')));
    await tester.pump();
    expect(room.focus.sent.single, {'t': 'focus_start', 'circleId': 'c1'});
    await room.close(tester);
  });

  testWidgets('专注期:倒计时 + 轮次 + 结束按钮', (tester) async {
    final room = await FocusRoom.pump(tester, ownerKey: 'ok_1');
    room.focus.status(
      'c1',
      phase: 'focus',
      endsAt: kFocusNow + (24 * 60 + 9) * 1000,
      round: 2,
      rounds: 4,
    );
    await tester.pump();
    expect(find.text('专注中'), findsWidgets);
    expect(find.text('24:09'), findsOneWidget);
    expect(find.text('第 2/4 轮'), findsOneWidget);
    room.focus.sent.clear();
    await tester.tap(find.byKey(const ValueKey('focus-stop')));
    await tester.pump();
    expect(room.focus.sent.single['t'], 'focus_stop');
    await room.close(tester);
  });

  testWidgets('plugin_state 推进阶段:进休息,提示 snackbar', (tester) async {
    final room = await FocusRoom.pump(tester);
    room.focus.status('c1', phase: 'focus', endsAt: kFocusNow + 1000, round: 1);
    await tester.pump();

    room.focus.inject({
      't': 'plugin_state',
      'circleId': 'c1',
      'pluginId': kFocusPluginId,
      'rev': 3,
      'state': {
        'pomodoro': {
          'phase': 'break',
          'endsAt': kFocusNow + 300000,
          'round': 1,
          'rounds': 4,
        },
      },
    });
    room.focus.inject({
      't': 'focus_notice',
      'circleId': 'c1',
      'kind': 'phase',
      'phase': 'break',
      'round': 1,
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('休息一下'), findsOneWidget);
    expect(find.text('05:00'), findsOneWidget);
    expect(find.text('休息一下,聊两句吧'), findsOneWidget);
    await room.close(tester);
  });

  testWidgets('排行榜:三个页签,自己高亮', (tester) async {
    final room = await FocusRoom.pump(tester);
    room.focus.status('c1');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('focus-board')));
    await tester.pump();
    expect(room.focus.sent.last, {'t': 'focus_get', 'circleId': 'c1'});

    room.focus.inject({
      't': 'focus_board',
      'circleId': 'c1',
      'today': [
        {'userId': 'u1', 'name': '小鹿', 'ms': 95 * 60000},
        {'userId': 'u_me', 'name': '我', 'ms': 50 * 60000},
      ],
      'week': [
        {'userId': 'u_me', 'name': '我', 'ms': 300 * 60000},
      ],
      'all': <Map<String, dynamic>>[],
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const ValueKey('focus-leaderboard')), findsOneWidget);
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('本周'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('1 小时 35 分'), findsOneWidget);
    final board = find.byKey(const ValueKey('focus-leaderboard'));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('focus-board-row-u_me')),
        matching: find.text('我'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: board, matching: find.textContaining('你')),
      findsNothing,
    );

    await tester.tap(find.text('本周'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('5 小时 0 分'), findsOneWidget);

    await tester.tap(find.text('全部'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('还没有人上榜,开始专注吧'), findsOneWidget);
    await room.close(tester);
  });

  testWidgets('锁定按钮:仅支持的平台、仅专注期;确认框的取消是「算了」', (tester) async {
    final room = await FocusRoom.pump(tester, lockSupported: true);
    room.focus.status('c1', phase: 'focus', endsAt: kFocusNow + 60000, round: 1);
    await tester.pump();
    expect(find.byKey(const ValueKey('focus-lock')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('focus-lock')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('锁定专注?'), findsOneWidget);
    expect(find.text('算了'), findsOneWidget);
    expect(find.text('取消'), findsNothing);
    await tester.tap(find.text('算了'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    room.focus.status('c1', phase: 'break', endsAt: kFocusNow + 60000, round: 1);
    await tester.pump();
    expect(find.byKey(const ValueKey('focus-lock')), findsNothing);
    await room.close(tester);
  });

  testWidgets('不支持锁定的平台没有锁定按钮', (tester) async {
    final room = await FocusRoom.pump(tester);
    room.focus.status('c1', phase: 'focus', endsAt: kFocusNow + 60000, round: 1);
    await tester.pump();
    expect(find.byKey(const ValueKey('focus-lock')), findsNothing);
    await room.close(tester);
  });
}
