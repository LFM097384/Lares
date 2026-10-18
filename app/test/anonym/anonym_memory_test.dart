import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/anonym/anonym_controller.dart';
import 'package:lares_app/src/anonym/anonym_crypto.dart';
import 'package:lares_app/src/anonym/anonym_memory.dart';
import 'package:lares_app/src/anonym/anonym_sheets.dart';

import '../helpers/localized_app.dart';
import 'anonym_controller_test.dart' show draftMsg, frame, kAgent, kCid, state;

const String kMemDisclosure = '只有大家同意放行的去名内容会被记住；原话散会即焚';

/// agent 回的记忆列表(data `mem`,不带 circleId)。
Map<String, dynamic> memMsg(List<Object?> items) => {'t': 'mem', 'items': items};

final List<Map<String, Object?>> kItems = [
  {
    'id': 'm1',
    'circleId': kCid,
    'text': '下季度预算先砍一成',
    'kind': 'decision',
    'sid': 'S1',
    'releasedAt': DateTime.utc(2026, 10, 18, 9).millisecondsSinceEpoch,
    'approvals': 3,
    'canRetract': true,
  },
  {
    'id': 'm2',
    'circleId': kCid,
    'text': '有与会者建议引入外部评审',
    'kind': 'idea',
    'sid': 'S1',
    'releasedAt': '2026-10-17T08:00:00.000Z',
    'approvals': 2,
    'canRetract': false,
    'approverIds': ['me'], // ignored: not a retract fallback
  },
  {'id': 'm3', 'retracted': true, 'retractedAt': DateTime.utc(2026, 10, 19, 9).millisecondsSinceEpoch},
  {
    'id': 'm4',
    'text': '下周前整理需求清单',
    'kind': 'todo',
    'releasedAt': '2026-10-16T08:00:00Z',
    'approvals': 4,
    'canRetract': true,
  },
];

void main() {
  late List<Map<String, Object?>> sent;
  late List<Map<String, Object?>> data;
  late AnonymController c;

  void agent(Map<String, dynamic> m) => c.handleData(kAgent, frame(m));
  Map<String, Object?> lastData() => data.last;

  setUp(() {
    sent = [];
    data = [];
    c = AnonymController(
      send: sent.add,
      sendData: (m, to) {
        if (to != kAgent) throw StateError('sent to $to');
        data.add(m);
      },
      keyFactory: () => AnonymKeys.fromSeed(List<int>.generate(32, (i) => i)),
      nonceFactory: () => 'AAECAwQFBgcICQoLDA0ODw',
    )..bindRoom(circleId: kCid, inRoom: true, myUserId: 'me');
    // agent 在场(记忆由它保管)
    c.handle({'t': 'anon_agent_state', 'circleId': kCid, 'present': true, 'active': false});
  });

  group('controller', () {
    test('loadMemory sends mem_list to the agent and parses the mem reply', () {
      c.loadMemory();
      expect(data.single, {'t': 'mem_list'});
      expect(sent, isEmpty);
      expect(c.memoryLoading, isTrue);
      expect(c.memoryItems, isNull);
      agent(memMsg(kItems));
      expect(c.memoryLoading, isFalse);
      final items = c.memoryItems!;
      expect(items.map((e) => e.id), ['m1', 'm2', 'm3', 'm4']);
      expect(items[0].kind, AnonymMemoryKind.decision);
      expect(items[0].approvals, 3);
      expect(items[0].sid, 'S1');
      expect(items[1].kind, AnonymMemoryKind.idea);
      expect(items[3].kind, AnonymMemoryKind.todo);
      expect(items[3].canRetract, isTrue);
    });
    test('releasedAt accepts ms epoch, seconds, numeric string, and ISO', () {
      final DateTime want = DateTime.utc(2026, 10, 18, 9);
      final int ms = want.millisecondsSinceEpoch;
      expect(AnonymController.parseReleasedAt(ms)!.toUtc(), want);
      expect(AnonymController.parseReleasedAt(ms ~/ 1000)!.toUtc(), want);
      expect(AnonymController.parseReleasedAt('$ms')!.toUtc(), want);
      expect(
        AnonymController.parseReleasedAt('2026-10-18T09:00:00.000Z')!.toUtc(),
        want,
      );
      expect(AnonymController.parseReleasedAt(null), isNull);
      expect(AnonymController.parseReleasedAt('garbage'), isNull);
      expect(AnonymController.parseReleasedAt(-1), isNull);
    });

    test('tombstones keep only the id (+ retractedAt), even if the server leaks text', () {
      final items = AnonymController.parseMemoryItems([
        {'id': 't1', 'retracted': true, 'text': 'should be dropped', 'retractedAt': 1760778000000},
        {'id': 't2', 'retracted': true, 'retractedAt': null},
      ]);
      expect(items.first.retracted, isTrue);
      expect(items.first.text, isNull);
      expect(items.first.retractedAt!.toUtc(),
          DateTime.fromMillisecondsSinceEpoch(1760778000000, isUtc: true));
      expect(items.last.retractedAt, isNull);
    });

    test('malformed entries are skipped; unknown kind becomes other; dup ids dropped', () {
      final items = AnonymController.parseMemoryItems([
        'nope',
        {'text': 'no id'},
        {'id': 'x'}, // no text, not a tombstone
        {'id': 'k', 'text': 'hi', 'kind': 'rumour', 'speaker': 'u1'},
        {'id': 'k', 'text': 'dup'},
        {'id': 7, 'text': 'numeric id'},
      ]);
      expect(items.map((e) => e.id), ['k', '7']);
      expect(items.first.kind, AnonymMemoryKind.other);
      expect(items.first.text, 'hi');
    });

    test('mem from a non-agent sender, or without items list, is ignored', () {
      c.loadMemory();
      c.handleData('u3', frame(memMsg(kItems)));
      expect(c.memoryItems, isNull);
      agent({'t': 'mem', 'items': 'x'});
      expect(c.memoryItems, isNull);
      expect(c.memoryLoading, isTrue);
    });

    test('mem with no prior load is ignored (no circle requested)', () {
      agent(memMsg(kItems));
      expect(c.memoryItems, isNull);
    });

    test('agent absent → agent_absent error, nothing sent', () {
      c.handle({'t': 'anon_agent_state', 'circleId': kCid, 'present': false});
      c.loadMemory();
      expect(data, isEmpty);
      expect(c.memoryLoading, isFalse);
      expect(c.memoryError, 'agent_absent');
    });

    test('another circle opened from home → agent_absent (memory lives with that circle\'s agent)', () {
      c.bindRoom(circleId: null, inRoom: false, myUserId: 'me');
      c.loadMemory(circleId: 'c9');
      expect(data, isEmpty);
      expect(c.memoryCircleId, 'c9');
      expect(c.memoryError, 'agent_absent');
    });

    test('retract permission: owner or canRetract only (approverIds ignored)', () {
      c.loadMemory();
      agent(memMsg(kItems));
      final items = c.memoryItems!;
      expect(c.mayRetract(items[0], isOwner: false), isTrue);
      expect(c.mayRetract(items[1], isOwner: false), isFalse);
      expect(c.mayRetract(items[1], isOwner: true), isTrue);
      expect(c.mayRetract(items[2], isOwner: true), isFalse);
      expect(c.mayRetract(items[3], isOwner: false), isTrue);
      final AnonymMemoryItem denied = AnonymController.parseMemoryItems([
        {'id': 'z', 'text': 't', 'canRetract': false, 'approverIds': ['u9']},
      ]).single;
      expect(c.mayRetract(denied, isOwner: false), isFalse);
      final AnonymMemoryItem silent = AnonymController.parseMemoryItems([
        {'id': 'y', 'text': 't', 'approverIds': ['me']},
      ]).single;
      expect(c.mayRetract(silent, isOwner: false), isFalse);
    });

    test('retract sends mem_retract and keeps the item until the agent confirms', () {
      c.loadMemory();
      agent(memMsg(kItems));
      data.clear();
      c.retractMemory('m1');
      expect(data.single, {'t': 'mem_retract', 'itemId': 'm1'});
      expect(c.memoryItems!.first.retracted, isFalse);
      expect(c.memoryItems!.first.text, '下季度预算先砍一成');
      expect(c.memoryRetracting('m1'), isTrue);
      c.retractMemory('m1');
      c.retractMemory('m3');
      c.retractMemory('nope');
      expect(data, hasLength(1));
      agent({'t': 'mem_retracted', 'itemId': 'm1'});
      expect(c.memoryItems!.first.retracted, isTrue);
      expect(c.memoryItems!.first.text, isNull);
      expect(c.memoryRetracting('m1'), isFalse);
    });

    test('a re-sent mem list also confirms a retract', () {
      c.loadMemory();
      agent(memMsg(kItems));
      c.retractMemory('m2');
      agent(memMsg([
        kItems[0],
        {'id': 'm2', 'retracted': true},
        kItems[2],
        kItems[3],
      ]));
      expect(c.memoryRetracting('m2'), isFalse);
      expect(c.memoryItems![1].retracted, isTrue);
    });

    test('error while retracting is attributed to memory and the item stays', () {
      c.loadMemory();
      agent(memMsg(kItems));
      c.retractMemory('m1');
      agent({'t': 'error', 'op': 'mem_retract', 'code': 'not_approver'});
      expect(c.memoryError, 'not_approver');
      expect(c.memoryRetracting('m1'), isFalse);
      expect(c.memoryItems!.first.retracted, isFalse);
      expect(c.lastError, isNull, reason: 'session banner is not hijacked');
    });

    test('error while loading becomes the memory error', () {
      c.loadMemory();
      agent({'t': 'error', 'op': 'mem_list', 'code': 'not_registered'});
      expect(c.memoryLoading, isFalse);
      expect(c.memoryError, 'not_registered');
      expect(c.memoryItems, isNull);
      expect(c.lastError, isNull);
    });

    test('errors are routed by op: non-memory ops never touch the memory panel', () {
      agent(state());
      c.accept();
      c.loadMemory();
      c.requestMinutes();
      agent({'t': 'error', 'op': 'skill', 'code': 'busy'});
      expect(c.lastError, 'busy');
      expect(c.draftPending, isFalse);
      expect(c.memoryError, isNull);
      expect(c.memoryLoading, isTrue);
      c.clearError();
      c.requestMinutes();
      agent({'t': 'error', 'op': 'mem_list', 'code': 'rate_limited'});
      expect(c.memoryError, 'rate_limited');
      expect(c.lastError, isNull);
      expect(c.draftPending, isTrue);
    });

    test('memory survives ended and state{active:false}', () {
      agent(state());
      c.loadMemory();
      agent(memMsg(kItems));
      agent(draftMsg());
      agent({
        't': 'ended',
        'receipt': <String, Object?>{'counts': <String, num>{}, 'sha256': 'x'},
      });
      expect(c.memoryItems, hasLength(4));
      agent(state(active: false));
      expect(c.memoryItems, hasLength(4));
      expect(c.memoryCircleId, kCid);
    });

    test('memory is cleared when leaving the room / switching circle', () {
      c.loadMemory();
      agent(memMsg(kItems));
      c.bindRoom(circleId: kCid, inRoom: false, myUserId: 'me');
      expect(c.memoryItems, isNull);
      expect(c.memoryCircleId, isNull);

      c.bindRoom(circleId: kCid, inRoom: true, myUserId: 'me');
      c.handle({'t': 'anon_agent_state', 'circleId': kCid, 'present': true});
      c.loadMemory();
      agent(memMsg(kItems));
      expect(c.memoryItems, hasLength(4));
      c.bindRoom(circleId: 'c2', inRoom: true, myUserId: 'me');
      expect(c.memoryItems, isNull);
    });
  });
  group('screen', () {
    Future<void> tall(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
    }

    Widget screen({bool owner = false, Locale locale = const Locale('zh')}) =>
        localizedApp(
          AnonymMemoryScreen(
            anonym: c,
            circleId: kCid,
            circleName: '读书会',
            isOwner: owner,
          ),
          locale: locale,
        );

    testWidgets('opening sends mem_list and shows loading', (tester) async {
      await tall(tester);
      await tester.pumpWidget(screen());
      expect(lastData(), {'t': 'mem_list'});
      expect(find.byKey(const ValueKey('anon-mem-loading')), findsOneWidget);
    });

    testWidgets('lists items with kind chip, date, provenance and a tombstone', (tester) async {
      await tall(tester);
      await tester.pumpWidget(screen());
      agent(memMsg(kItems));
      await tester.pump();
      expect(find.text('下季度预算先砍一成'), findsOneWidget);
      expect(find.text('决定'), findsOneWidget);
      expect(find.text('想法'), findsOneWidget);
      expect(find.text('待办'), findsOneWidget);
      expect(find.text('去名 · 经 3 人放行'), findsOneWidget);
      expect(find.text('去名 · 经 2 人放行'), findsOneWidget);
      expect(find.byKey(const ValueKey('anon-mem-date-m1')), findsOneWidget);
      expect(find.byKey(const ValueKey('anon-mem-date-m2')), findsOneWidget);
      expect(find.byKey(const ValueKey('anon-mem-tombstone-m3')), findsOneWidget);
      expect(find.text('已撤回'), findsOneWidget);
      expect(find.byKey(const ValueKey('anon-mem-retracted-date-m3')), findsOneWidget);
      // retract shown for m1 and m4 (canRetract), not m2 (canRetract false)
      expect(find.byKey(const ValueKey('anon-mem-retract-m1')), findsOneWidget);
      expect(find.byKey(const ValueKey('anon-mem-retract-m2')), findsNothing);
      expect(find.byKey(const ValueKey('anon-mem-retract-m4')), findsOneWidget);
      expect(find.textContaining('依规则'), findsNothing);
    });

    testWidgets('owner can retract anything that is not a tombstone', (tester) async {
      await tall(tester);
      await tester.pumpWidget(screen(owner: true));
      agent(memMsg(kItems));
      await tester.pump();
      expect(find.byKey(const ValueKey('anon-mem-retract-m2')), findsOneWidget);
    });

    testWidgets('retract goes through a confirmation dialog; cancel sends nothing', (tester) async {
      await tall(tester);
      await tester.pumpWidget(screen());
      agent(memMsg(kItems));
      await tester.pump();
      data.clear();

      await tester.tap(find.byKey(const ValueKey('anon-mem-retract-m1')));
      await tester.pumpAndSettle();
      expect(find.text('撤回这条记忆?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('anon-mem-retract-cancel')));
      await tester.pumpAndSettle();
      expect(data, isEmpty);

      await tester.tap(find.byKey(const ValueKey('anon-mem-retract-m1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('anon-mem-retract-confirm')));
      // 撤回中的小转圈是无限动画:不能 pumpAndSettle
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(lastData(), {'t': 'mem_retract', 'itemId': 'm1'});
      // not deleted yet: still visible, showing pending
      expect(find.text('下季度预算先砍一成'), findsOneWidget);
      expect(find.byKey(const ValueKey('anon-mem-pending-m1')), findsOneWidget);

      agent({'t': 'mem_retracted', 'itemId': 'm1'});
      await tester.pump();
      expect(find.text('下季度预算先砍一成'), findsNothing);
      expect(find.byKey(const ValueKey('anon-mem-tombstone-m1')), findsOneWidget);
      // anon_mem_retracted carries no retractedAt: no date shown
      expect(find.byKey(const ValueKey('anon-mem-retracted-date-m1')), findsNothing);
    });

    testWidgets('empty state', (tester) async {
      await tall(tester);
      await tester.pumpWidget(screen());
      agent(memMsg(const []));
      await tester.pump();
      expect(find.byKey(const ValueKey('anon-mem-empty')), findsOneWidget);
      expect(find.text('还没有记忆'), findsOneWidget);
    });

    testWidgets('error state offers retry, which resends mem_list', (tester) async {
      await tall(tester);
      await tester.pumpWidget(screen());
      agent({'t': 'error', 'op': 'mem_list', 'code': 'not_registered'});
      await tester.pump();
      expect(find.byKey(const ValueKey('anon-mem-error')), findsOneWidget);
      expect(find.textContaining('not_registered'), findsOneWidget);
      data.clear();
      await tester.tap(find.byKey(const ValueKey('anon-mem-retry')));
      await tester.pump();
      expect(lastData(), {'t': 'mem_list'});
    });

        testWidgets('agent absent: explains instead of a raw code', (tester) async {
      await tall(tester);
      c.handle({'t': 'anon_agent_state', 'circleId': kCid, 'present': false});
      await tester.pumpWidget(screen());
      await tester.pump();
      expect(find.byKey(const ValueKey('anon-mem-error')), findsOneWidget);
      expect(find.textContaining('邀请炉灵入房'), findsOneWidget);
      expect(find.textContaining('agent_absent'), findsNothing);
    });

    testWidgets('English locale: kinds, plural provenance, no Chinese leaking', (tester) async {
      await tall(tester);
      await tester.pumpWidget(screen(locale: const Locale('en')));
      agent(memMsg(kItems));
      await tester.pump();
      expect(find.text('Decision'), findsOneWidget);
      expect(find.text('Unattributed · released by 3 people'), findsOneWidget);
      expect(find.text('Retracted'), findsOneWidget);
      expect(find.textContaining('under the Rule'), findsNothing);
      expect(find.text('决定'), findsNothing);
    });
  });

  group('disclosure', () {
    testWidgets('convene sheet carries the memory disclosure line', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(localizedScaffold(
        AnonymConveneSheet(anonym: c, presentCount: 3),
      ));
      expect(find.text(kMemDisclosure), findsOneWidget);
    });

    testWidgets('consent sheet carries the memory disclosure line', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        localizedScaffold(const AnonymConsentSheet(convenerName: '林岚')),
      );
      expect(find.text(kMemDisclosure), findsOneWidget);
    });
  });
}
