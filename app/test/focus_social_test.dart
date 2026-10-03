// 专注社交(§10)+ 活动推送客户端(§9):出勤卡、🔥 徽标、周报卡、叫大家来、设置界面。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/focus/activity_push.dart';
import 'package:lares_app/src/net/secret_vault.dart';
import 'package:lares_app/src/state/settings_store.dart';
import 'package:lares_app/src/theme/theme.dart';
import 'package:lares_app/src/ui/push_settings_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/focus_fixtures.dart';
import 'helpers/focus_room.dart';
import 'helpers/localized_app.dart';

Map<String, dynamic> _round({
  List<Map<String, dynamic>>? members,
  int round = 2,
}) => {
  't': 'focus_round',
  'circleId': 'c1',
  'round': round,
  'rounds': 4,
  'endedAt': kFocusNow,
  'lenMs': 25 * 60000,
  'members':
      members ??
      [
        {'userId': 'u_me', 'name': '我', 'awayMs': 0, 'full': true},
        {'userId': 'u2', 'name': '大橘', 'awayMs': 0, 'full': true},
        {'userId': 'u3', 'name': '阿青', 'awayMs': 0, 'full': true},
        {'userId': 'u1', 'name': '小鹿', 'awayMs': 125000, 'full': false},
      ],
};

Map<String, dynamic> _pushCfg({int readyAt = 0, bool custom = false}) => {
  't': 'push_cfg',
  'circleId': 'c1',
  'cfg': {
    'triggers': {'focus': true, 'crowd': false, 'arrive': false},
    'crowdN': 3,
  },
  'custom': custom,
  'defaults': {
    'triggers': {'focus': true, 'crowd': false, 'arrive': false},
    'crowdN': 3,
  },
  'summonReadyAt': readyAt,
  'now': kFocusNow,
  'limits': {'cooldownMin': 30, 'dailyCap': 8, 'summonMin': 10},
};

void main() {
  group('FocusSocial 状态', () {
    test('进开着专注的房间拉 focus_social_get;没开不拉', () async {
      final h = FocusHarness();
      h.service.setRoom('c1');
      expect(h.sent.where((m) => m['t'] == 'focus_social_get'), isEmpty);
      h.enable('c1');
      expect(h.sent.where((m) => m['t'] == 'focus_social_get'), hasLength(1));
      await h.dispose();
    });

    test('出勤 / 连续打卡 / 周报解析;排除 u_ai_*;下一轮开始收起出勤卡', () async {
      final h = FocusHarness();
      h.enable('c1');
      h.service.setRoom('c1');
      h.inject(
        _round(
          members: [
            {'userId': 'u_me', 'name': '我', 'awayMs': 0, 'full': true},
            {'userId': 'u_ai_x', 'name': 'AI', 'awayMs': 0, 'full': true},
          ],
        ),
      );
      final r = h.service.social.lastRound!;
      expect(r.total, 1);
      expect(r.allIn, isTrue);

      h.inject({
        't': 'focus_streaks',
        'circleId': 'c1',
        'streaks': {'u1': 5, 'u_ai_x': 9, 'u2': 0},
      });
      expect(h.service.social.streakOf('u1'), 5);
      expect(h.service.social.streakOf('u_ai_x'), 0);
      expect(h.service.social.streakOf('u2'), 0);

      h.inject({
        't': 'focus_weekly',
        'circleId': 'c1',
        'card': {
          'week': '2026-09-07',
          'focusMs': 3 * 3600000,
          'rank': 2,
          'of': 4,
          'streak': 5,
          'circleTotalMs': 9 * 3600000,
        },
      });
      expect(h.service.social.weekly!.rank, 2);
      h.sent.clear();
      h.service.social.dismissWeekly();
      expect(h.sent.single, {
        't': 'focus_weekly_seen',
        'circleId': 'c1',
        'week': '2026-09-07',
      });
      expect(h.service.social.weekly, isNull);

      // 别的圈的周报不收
      h.inject({
        't': 'focus_weekly',
        'circleId': 'other',
        'card': {'week': '2026-09-07'},
      });
      expect(h.service.social.weekly, isNull);

      h.status('c1', phase: 'focus', round: 3, endsAt: kFocusNow + 60000);
      expect(h.service.social.lastRound, isNull);
      await h.dispose();
    });
  });

  group('ActivityPush', () {
    test('叫人:带 ownerKey;成功记下冷却;冷却回执', () async {
      final h = FocusHarness(ownerKey: 'ok_1');
      h.service.setRoom('c1');
      expect(h.sent.last, {'t': 'push_cfg_get', 'circleId': 'c1'});
      final a = h.service.activity;
      final f = a.summon('c1');
      expect(h.sent.last, {
        't': 'push_summon',
        'circleId': 'c1',
        'ownerKey': 'ok_1',
      });
      h.inject({
        't': 'push_summon_ok',
        'circleId': 'c1',
        'sent': 3,
        'nextAt': kFocusNow + 600000,
      });
      final r = await f;
      expect((r as SummonSent).count, 3);
      expect(a.summonWait('c1'), const Duration(minutes: 10));

      final f2 = a.summon('c1');
      h.inject({
        't': 'owner_error',
        'op': 'push_summon',
        'circleId': 'c1',
        'reason': 'cooldown',
        'retryAt': kFocusNow + 300000,
      });
      expect(await f2, isA<SummonCooldown>());
      expect(a.summonWait('c1'), const Duration(minutes: 5));
      await h.dispose();
    });

    test('不是圈主:不拉配置,叫人直接失败', () async {
      final h = FocusHarness();
      h.service.setRoom('c1');
      expect(h.sent.where((m) => m['t'] == 'push_cfg_get'), isEmpty);
      expect(await h.service.activity.summon('c1'), isA<SummonFailed>());
      await h.dispose();
    });

    test('保存配置:push_cfg_set + owner_ok;null 恢复默认', () async {
      final h = FocusHarness(ownerKey: 'k');
      final a = h.service.activity;
      final f = a.save(
        'c1',
        PushTriggerConfig.fallback.copyWith(crowdN: 5),
      );
      expect(h.sent.last['t'], 'push_cfg_set');
      expect((h.sent.last['cfg'] as Map)['crowdN'], 5);
      h.inject({'t': 'owner_ok', 'op': 'push_cfg_set', 'circleId': 'c1'});
      expect(await f, isTrue);
      final f2 = a.save('c1', null);
      expect(h.sent.last['cfg'], isNull);
      h.inject({
        't': 'owner_error',
        'op': 'push_cfg_set',
        'circleId': 'c1',
        'reason': 'bad_config',
      });
      expect(await f2, isFalse);
      await h.dispose();
    });
  });

  group('房间页', () {
    testWidgets('出勤卡:部分全勤写出谁离开多久;全勤一句话;可收起', (tester) async {
      final room = await FocusRoom.pump(tester);
      room.focus.inject(_round());
      await tester.pump();
      expect(find.byKey(const ValueKey('focus-round-card')), findsOneWidget);
      expect(find.text('3/4 全勤 · 小鹿离开 2 分钟'), findsOneWidget);

      room.focus.inject(
        _round(
          members: [
            for (final id in ['u_me', 'u1', 'u2', 'u3'])
              {'userId': id, 'name': id, 'awayMs': 0, 'full': true},
          ],
        ),
      );
      await tester.pump();
      expect(find.text('本轮 4 人全勤 🎉'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('focus-round-dismiss')));
      await tester.pump();
      expect(find.byKey(const ValueKey('focus-round-card')), findsNothing);
      await room.close(tester);
    });

    testWidgets('🔥 徽标:座位上有,idle 也有;0 天没有;排行榜行也有', (tester) async {
      final room = await FocusRoom.pump(tester);
      room.focus.status('c1'); // idle
      room.focus.inject({
        't': 'focus_streaks',
        'circleId': 'c1',
        'streaks': {'u1': 5},
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('focus-streak-u1')), findsOneWidget);
      expect(find.byKey(const ValueKey('focus-streak-u2')), findsNothing);
      expect(find.text('🔥5'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('focus-board')).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      room.focus.inject({
        't': 'focus_board',
        'circleId': 'c1',
        'today': [
          {'userId': 'u1', 'name': '小鹿', 'ms': 3600000},
          {'userId': 'u2', 'name': '大橘', 'ms': 600000},
        ],
        'week': <Object>[],
        'all': <Object>[],
      });
      await tester.pump();
      expect(
        find.byKey(const ValueKey('focus-board-streak-u1')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('focus-board-streak-u2')), findsNothing);
      await room.close(tester);
    });

    testWidgets('周报卡:显示时长 / 名次 / 连续,点「知道了」回执并收起', (tester) async {
      final room = await FocusRoom.pump(tester);
      room.focus.inject({
        't': 'focus_weekly',
        'circleId': 'c1',
        'card': {
          'week': '2026-09-07',
          'focusMs': 3 * 3600000 + 20 * 60000,
          'rank': 2,
          'of': 4,
          'streak': 5,
          'circleTotalMs': 9 * 3600000,
        },
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('focus-weekly-card')), findsOneWidget);
      expect(find.text('上周专注小结'), findsOneWidget);
      expect(find.textContaining('圈里第 2 名 · 共 4 人'), findsOneWidget);
      expect(find.textContaining('连续 5 天'), findsOneWidget);
      room.focus.sent.clear();
      await tester.tap(find.byKey(const ValueKey('focus-weekly-dismiss')));
      await tester.pump();
      expect(room.focus.sent.single['t'], 'focus_weekly_seen');
      expect(find.byKey(const ValueKey('focus-weekly-card')), findsNothing);
      await room.close(tester);
    });

    testWidgets('叫大家来:非圈主看不到', (tester) async {
      final room = await FocusRoom.pump(tester);
      expect(find.byKey(const ValueKey('room-summon')), findsNothing);
      await room.close(tester);
    });

    testWidgets('叫大家来:圈主确认后发出;冷却中显示分钟并禁用', (tester) async {
      final room = await FocusRoom.pump(tester, ownerKey: 'ok_1');
      room.focus.inject(_pushCfg());
      await tester.pump();
      expect(find.byKey(const ValueKey('room-summon')), findsOneWidget);
      expect(find.text('叫大家来'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('room-summon')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('叫大家来?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('summon-confirm')));
      await tester.pump();
      expect(room.focus.sent.last, {
        't': 'push_summon',
        'circleId': 'c1',
        'ownerKey': 'ok_1',
      });
      room.focus.inject({
        't': 'push_summon_ok',
        'circleId': 'c1',
        'sent': 2,
        'nextAt': kFocusNow + 10 * 60000,
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('已经叫了 2 个人'), findsOneWidget);
      expect(find.text('10 分'), findsOneWidget);
      final btn = tester.widget<TextButton>(
        find.byKey(const ValueKey('room-summon')),
      );
      expect(btn.onPressed, isNull);
      await room.close(tester);
    });
  });

  group('设置界面', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    testWidgets('通知我:三档,选「只要被叫」写进设置', (tester) async {
      final s = await tester.runAsync(
        () => SettingsStore.load(vault: InMemorySecretVault()),
      );
      await tester.pumpWidget(
        localizedApp(
          Scaffold(body: CirclePushLevelTile(settings: s!, circleId: 'c1')),
          theme: LaresTheme.dark(),
        ),
      );
      expect(find.text('通知我:全部'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('circle-push-level')));
      await tester.pumpAndSettle();
      expect(find.text('只要被叫'), findsOneWidget);
      expect(find.text('关'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('push-level-called')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(s.circlePushLevel('c1'), 'called');
      expect(find.text('通知我:只要被叫'), findsOneWidget);
    });

    testWidgets('推送免打扰:默认 23:00–08:00,可关', (tester) async {
      final s = await tester.runAsync(
        () => SettingsStore.load(vault: InMemorySecretVault()),
      );
      await tester.pumpWidget(
        localizedApp(
          Scaffold(body: PushQuietTile(settings: s!)),
          theme: LaresTheme.dark(),
        ),
      );
      expect(find.text('23:00–08:00 不推送圈里的动静'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('push-quiet-tile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('push-quiet-switch')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(s.pushQuietOn, isFalse);
      await tester.tap(find.text('好'));
      await tester.pumpAndSettle();
      expect(find.text('关 —— 任何时间都可能收到圈里的动静'), findsOneWidget);
    });

    testWidgets('圈主活动提醒:开关、人数加减、恢复默认', (tester) async {
      final h = FocusHarness(ownerKey: 'k');
      h.inject(_pushCfg(custom: true));
      await tester.pumpWidget(
        localizedApp(
          Scaffold(
            body: PushTriggersSheet(activity: h.service.activity, circleId: 'c1'),
          ),
          theme: LaresTheme.dark(),
        ),
      );
      await tester.pump();
      expect(find.text('有人开始专注'), findsOneWidget);
      expect(find.byKey(const ValueKey('push-crowd-n')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('push-trigger-crowd')));
      await tester.pump();
      var sent = h.sent.last;
      expect(sent['t'], 'push_cfg_set');
      expect((sent['cfg'] as Map)['triggers'], {
        'focus': true,
        'crowd': true,
        'arrive': false,
      });
      // 乐观更新:人数行立刻出现
      expect(find.text('3 人'), findsOneWidget);
      h.inject({'t': 'owner_ok', 'op': 'push_cfg_set', 'circleId': 'c1'});
      final cfg = Map<String, dynamic>.from(_pushCfg(custom: true));
      cfg['cfg'] = sent['cfg'];
      h.inject(cfg);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('push-crowd-plus')));
      await tester.pump();
      sent = h.sent.last;
      expect((sent['cfg'] as Map)['crowdN'], 4);
      h.inject({'t': 'owner_ok', 'op': 'push_cfg_set', 'circleId': 'c1'});
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('push-triggers-reset')));
      await tester.pump();
      expect(h.sent.last['cfg'], isNull);
      h.inject({'t': 'owner_ok', 'op': 'push_cfg_set', 'circleId': 'c1'});
      await tester.pump();
      await h.dispose();
    });
  });
}
