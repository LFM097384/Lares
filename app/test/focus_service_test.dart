import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/focus/focus_models.dart';
import 'package:lares_app/src/focus/focus_service.dart';

import 'helpers/focus_fixtures.dart';

List<Map<String, dynamic>> _of(FocusHarness h, String t) =>
    h.sent.where((m) => m['t'] == t).toList();

void main() {
  group('FocusService 离开上报', () {
    void run(
      FocusHostKind host,
      void Function(FakeAsync async, FocusHarness h) body,
    ) {
      fakeAsync((async) {
        final h = FocusHarness(
          host: host,
          now: () => DateTime.fromMillisecondsSinceEpoch(
            kFocusNow,
          ).add(async.elapsed),
        );
        h.enable('c1', config: {'graceSec': 10});
        h.service.setRoom('c1');
        // 离开只在番茄钟专注段上报(没开钟时房间照常)
        h.status(
          'c1',
          phase: 'focus',
          endsAt: kFocusNow + 3600000,
          round: 1,
          config: {'graceSec': 10},
        );
        h.sent.clear();
        body(async, h);
        h.service.dispose();
      });
    }

    test('宽限期内回来:什么都不发', () {
      run(FocusHostKind.mobile, (async, h) {
        h.service.onAppLifecycle(AppLifecycleState.paused);
        async.elapse(const Duration(seconds: 9));
        h.service.onAppLifecycle(AppLifecycleState.resumed);
        async.elapse(const Duration(seconds: 30));
        expect(h.sent, isEmpty);
      });
    });

    test('超过宽限:发 focus_away,since = 真正离开的时刻;回来补 focus_back', () {
      run(FocusHostKind.mobile, (async, h) {
        async.elapse(const Duration(seconds: 3));
        h.service.onAppLifecycle(AppLifecycleState.paused);
        async.elapse(const Duration(seconds: 10));
        final away = _of(h, 'focus_away');
        expect(away, hasLength(1));
        expect(away.single['circleId'], 'c1');
        expect(away.single['since'], kFocusNow + 3000);
        h.service.onAppLifecycle(AppLifecycleState.resumed);
        expect(_of(h, 'focus_back'), [
          {'t': 'focus_back', 'circleId': 'c1'},
        ]);
      });
    });

    test('since 换算成服务器时间(pong 偏移)', () {
      fakeAsync((async) {
        final sent = <Map<String, dynamic>>[];
        final s = FocusService(
          send: sent.add,
          messages: const Stream.empty(),
          clockOffsetMs: () => 5000,
          now: () =>
              DateTime.fromMillisecondsSinceEpoch(kFocusNow).add(async.elapsed),
        );
        s.debugInject({
          't': 'plugins',
          'circleId': 'c1',
          'items': [
            {'id': kFocusPluginId, 'enabled': true, 'config': {'graceSec': 0}},
          ],
        });
        s.setRoom('c1');
        s.debugInject({
          't': 'focus_status',
          'circleId': 'c1',
          'now': kFocusNow,
          'enabled': true,
          'config': {'graceSec': 0},
          'pomodoro': {
            'phase': 'focus',
            'endsAt': kFocusNow + 3600000,
            'round': 1,
            'rounds': 4,
          },
          'members': <Object>[],
        });
        s.onAppLifecycle(AppLifecycleState.paused);
        async.flushMicrotasks();
        final away = sent.where((m) => m['t'] == 'focus_away').single;
        expect(away['since'], kFocusNow + 5000);
        s.dispose();
      });
    });

    test('休息期离开不上报;回到专注期仍不在 → 从那一刻重新计宽限', () {
      run(FocusHostKind.mobile, (async, h) {
        h.status('c1', phase: 'break', endsAt: kFocusNow + 300000, round: 1);
        h.service.onAppLifecycle(AppLifecycleState.paused);
        async.elapse(const Duration(seconds: 60));
        expect(_of(h, 'focus_away'), isEmpty);

        h.status('c1', phase: 'focus', endsAt: kFocusNow + 1500000, round: 2);
        async.elapse(const Duration(seconds: 9));
        expect(_of(h, 'focus_away'), isEmpty);
        async.elapse(const Duration(seconds: 2));
        final away = _of(h, 'focus_away');
        expect(away, hasLength(1));
        expect(away.single['since'], kFocusNow + 60000);
      });
    });

    test('移动端 inactive(下拉通知栏)不算离开', () {
      run(FocusHostKind.mobile, (async, h) {
        h.service.onAppLifecycle(AppLifecycleState.inactive);
        async.elapse(const Duration(minutes: 2));
        expect(h.sent, isEmpty);
        expect(h.service.locallyAway, isFalse);
      });
    });

    test('Web 的 inactive(标签页失焦)算离开', () {
      run(FocusHostKind.web, (async, h) {
        h.service.onAppLifecycle(AppLifecycleState.inactive);
        async.elapse(const Duration(seconds: 11));
        expect(_of(h, 'focus_away'), hasLength(1));
      });
    });

    test('桌面:窗口失焦算离开,聚焦回来补 back;移动端忽略窗口焦点', () {
      run(FocusHostKind.desktop, (async, h) {
        h.service.onWindowFocus(false);
        async.elapse(const Duration(seconds: 11));
        expect(_of(h, 'focus_away'), hasLength(1));
        h.service.onWindowFocus(true);
        expect(_of(h, 'focus_back'), hasLength(1));
      });
      run(FocusHostKind.mobile, (async, h) {
        h.service.onWindowFocus(false);
        async.elapse(const Duration(minutes: 1));
        expect(h.sent, isEmpty);
      });
    });

    test('开着专注插件但没开番茄钟(idle):离开不上报', () {
      run(FocusHostKind.mobile, (async, h) {
        h.status('c1', config: {'graceSec': 10});
        h.sent.clear();
        h.service.onAppLifecycle(AppLifecycleState.paused);
        async.elapse(const Duration(minutes: 1));
        expect(_of(h, 'focus_away'), isEmpty);
      });
    });

    test('没开专注 / 不在房:不上报', () {
      fakeAsync((async) {
        final h = FocusHarness();
        h.service.setRoom('c2'); // 没启用
        h.service.onAppLifecycle(AppLifecycleState.paused);
        async.elapse(const Duration(minutes: 1));
        expect(h.sent, isEmpty);
        h.service.dispose();
      });
    });

    test('离开期间出房:不补 back,计时器作废', () {
      run(FocusHostKind.mobile, (async, h) {
        h.service.onAppLifecycle(AppLifecycleState.paused);
        async.elapse(const Duration(seconds: 5));
        h.service.setRoom(null);
        async.elapse(const Duration(minutes: 1));
        expect(h.sent, isEmpty);
      });
    });
  });

  group('FocusService 状态', () {
    test('进启用的房间发 focus_get;圈主结束 → 关闭专注', () async {
      final h = FocusHarness();
      h.enable('c1');
      h.service.setRoom('c1');
      expect(h.sent.last, {'t': 'focus_get', 'circleId': 'c1'});
      expect(h.service.active, isTrue);
      // 没开番茄钟:房间照常,聊天开着、不收分心入口
      expect(h.service.chatLocked, isFalse);
      expect(h.service.focusing, isFalse);
      h.status('c1', phase: 'focus', endsAt: kFocusNow + 60000, round: 1);
      expect(h.service.chatLocked, isTrue);
      expect(h.service.focusing, isTrue);

      final notices = <FocusNotice>[];
      h.service.notices.listen(notices.add);
      h.inject({
        't': 'focus_notice',
        'circleId': 'c1',
        'kind': 'ended_by_owner',
      });
      await Future<void>.delayed(Duration.zero);
      expect(h.service.active, isFalse);
      expect(h.service.chatLocked, isFalse);
      expect(notices.single.kind, FocusNoticeKind.endedByOwner);
      await h.dispose();
    });

    test('circle_summary 的小视图能启停', () async {
      final h = FocusHarness();
      h.service.setRoom('c1');
      h.inject({
        't': 'circle_summary',
        'circleId': 'c1',
        'plugins': [
          {'id': kFocusPluginId, 'enabled': true},
        ],
      });
      expect(h.service.active, isTrue);
      expect(h.sent.last['t'], 'focus_get');
      h.inject({'t': 'circle_summary', 'circleId': 'c1', 'plugins': <Object>[]});
      expect(h.service.active, isFalse);
      await h.dispose();
    });

    test('成员离开时长按服务器时间走', () async {
      final h = FocusHarness();
      h.enable('c1');
      h.service.setRoom('c1');
      h.status(
        'c1',
        members: [
          focusMember('u1', '小鹿', 'away', awaySince: kFocusNow - 133000),
          focusMember('u2', '大橘', 'focus'),
        ],
      );
      expect(h.service.awayFor('u1'), const Duration(seconds: 133));
      expect(h.service.awayFor('u2'), isNull);
      expect(h.service.memberState('u2')!.state, FocusMemberMode.focus);
      await h.dispose();
    });

    test('focus_error → error notice', () async {
      final h = FocusHarness();
      h.enable('c1');
      h.service.setRoom('c1');
      final notices = <FocusNotice>[];
      h.service.notices.listen(notices.add);
      h.inject({
        't': 'focus_error',
        'op': 'focus_start',
        'circleId': 'c1',
        'reason': 'forbidden',
      });
      await Future<void>.delayed(Duration.zero);
      expect(notices.single.kind, FocusNoticeKind.error);
      expect(notices.single.reason, 'forbidden');
      await h.dispose();
    });
  });
}
