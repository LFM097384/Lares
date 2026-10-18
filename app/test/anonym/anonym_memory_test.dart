import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/anonym/anonym_controller.dart';
import 'package:lares_app/src/anonym/anonym_crypto.dart';
import 'package:lares_app/src/anonym/anonym_memory.dart';
import 'package:lares_app/src/anonym/anonym_sheets.dart';

import '../helpers/localized_app.dart';
import 'anonym_controller_test.dart' show kCid, state;

const String kMemDisclosure = '只有大家同意放行的去名内容会被记住；原话散会即焚';

Map<String, dynamic> memMsg(List<Object?> items, {String cid = kCid}) => {
  't': 'anon_mem',
  'circleId': cid,
  'items': items,
};

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
  late AnonymController c;

  setUp(() {
    sent = [];
    c = AnonymController(
      send: sent.add,
      keyFactory: () => AnonymKeys.fromSeed(List<int>.generate(32, (i) => i)),
      nonceFactory: () => 'AAECAwQFBgcICQoLDA0ODw',
    )..bindRoom(circleId: kCid, inRoom: true, myUserId: 'me');
  });

  group('controller', () {
    test('loadMemory sends anon_mem_list and parses the reply', () {
      c.loadMemory();
      expect(sent.single, {'t': 'anon_mem_list', 'circleId': kCid});
      expect(c.memoryLoading, isTrue);
      expect(c.memoryItems, isNull);
      c.handle(memMsg(kItems));
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

    test('anon_mem for another circle, or without items list, is ignored', () {
      c.loadMemory();
      c.handle(memMsg(kItems, cid: 'other'));
      expect(c.memoryItems, isNull);
      c.handle({'t': 'anon_mem', 'circleId': kCid, 'items': 'x'});
      expect(c.memoryItems, isNull);
      expect(c.memoryLoading, isTrue);
    });

    test('anon_mem with no prior load is ignored (no circle requested)', () {
      c.handle(memMsg(kItems));
      expect(c.memoryItems, isNull);
    });

    test('retract permission: owner or canRetract only (approverIds ignored)', () {
      c.loadMemory();
      c.handle(memMsg(kItems));
      final items = c.memoryItems!;
      // m1: server says canRetract
      expect(c.mayRetract(items[0], isOwner: false), isTrue);
      // m2: canRetract false, even though approverIds lists me
      expect(c.mayRetract(items[1], isOwner: false), isFalse);
      expect(c.mayRetract(items[1], isOwner: true), isTrue);
      // m3: tombstone — never
      expect(c.mayRetract(items[2], isOwner: true), isFalse);
      // m4: server says canRetract
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

    test('retract sends anon_mem_retract and keeps the item until the server confirms', () {
      c.loadMemory();
      c.handle(memMsg(kItems));
      sent.clear();
      c.retractMemory('m1');
      expect(sent.single, {'t': 'anon_mem_retract', 'circleId': kCid, 'itemId': 'm1'});
      expect(c.memoryItems!.first.retracted, isFalse);
      expect(c.memoryItems!.first.text, '下季度预算先砍一成');
      expect(c.memoryRetracting('m1'), isTrue);
      // a second tap while pending doesn't resend; tombstones / unknown ids don't send
      c.retractMemory('m1');
      c.retractMemory('m3');
      c.retractMemory('nope');
      expect(sent, hasLength(1));
      c.handle({'t': 'anon_mem_retracted', 'circleId': kCid, 'itemId': 'm1'});
      expect(c.memoryItems!.first.retracted, isTrue);
      expect(c.memoryItems!.first.text, isNull);
      expect(c.memoryRetracting('m1'), isFalse);
    });

    test('a re-sent anon_mem list also confirms a retract', () {
      c.loadMemory();
      c.handle(memMsg(kItems));
      c.retractMemory('m2');
      c.handle(memMsg([
        kItems[0],
        {'id': 'm2', 'retracted': true},
        kItems[2],
        kItems[3],
      ]));
      expect(c.memoryRetracting('m2'), isFalse);
      expect(c.memoryItems![1].retracted, isTrue);
    });

    test('anon_error while retracting is attributed to memory and the item stays', () {
      c.loadMemory();
      c.handle(memMsg(kItems));
      c.retractMemory('m1');
      c.handle({'t': 'anon_error', 'circleId': kCid, 'op': 'anon_mem_retract', 'code': 'not_approver'});
      expect(c.memoryError, 'not_approver');
      expect(c.memoryRetracting('m1'), isFalse);
      expect(c.memoryItems!.first.retracted, isFalse);
      expect(c.lastError, isNull, reason: 'session banner is not hijacked');
    });

    test('anon_error while loading becomes the memory error', () {
      c.loadMemory();
      c.handle({'t': 'anon_error', 'circleId': kCid, 'op': 'anon_mem_list', 'code': 'not_registered'});
      expect(c.memoryLoading, isFalse);
      expect(c.memoryError, 'not_registered');
      expect(c.memoryItems, isNull);
      expect(c.lastError, isNull);
    });

    test('anon_error is routed by op: non-memory ops never touch the memory panel', () {
      c.handle(state());
      c.accept();
      c.loadMemory();
      c.requestDraft();
      // a draft failure while memory is loading goes to the session panel only
      c.handle({'t': 'anon_error', 'circleId': kCid, 'op': 'anon_draft', 'code': 'busy'});
      expect(c.lastError, 'busy');
      expect(c.draftPending, isFalse);
      expect(c.memoryError, isNull);
      expect(c.memoryLoading, isTrue);
      c.clearError();
      // a memory failure while the draft is pending goes to memory only
      c.requestDraft();
      c.handle({'t': 'anon_error', 'circleId': kCid, 'op': 'anon_mem_list', 'code': 'rate_limited'});
      expect(c.memoryError, 'rate_limited');
      expect(c.lastError, isNull);
      expect(c.draftPending, isTrue);
    });

    test('memory anon_error for the home-opened circle is accepted outside the room', () {
      c.bindRoom(circleId: null, inRoom: false, myUserId: 'me');
      c.loadMemory(circleId: 'c9');
      c.handle({'t': 'anon_error', 'circleId': 'c8', 'op': 'anon_mem_list', 'code': 'x'});
      expect(c.memoryError, isNull);
      c.handle({'t': 'anon_error', 'circleId': 'c9', 'op': 'anon_mem_list', 'code': 'not_member'});
      expect(c.memoryError, 'not_member');
      expect(c.lastError, isNull);
    });

    test('memory survives anon_ended and anon_state{active:false}', () {
      c.handle(state());
      c.loadMemory();
      c.handle(memMsg(kItems));
      c.handle({
        't': 'anon_ended',
        'circleId': kCid,
        'receipt': <String, Object?>{'counts': <String, num>{}, 'sha256': 'x'},
      });
      expect(c.memoryItems, hasLength(4));
      c.handle({...state(active: false)});
      expect(c.memoryItems, hasLength(4));
      expect(c.memoryCircleId, kCid);
    });

    test('memory is cleared when leaving the room / switching circle', () {
      c.loadMemory();
      c.handle(memMsg(kItems));
      c.bindRoom(circleId: kCid, inRoom: false, myUserId: 'me');
      expect(c.memoryItems, isNull);
      expect(c.memoryCircleId, isNull);

      c.bindRoom(circleId: kCid, inRoom: true, myUserId: 'me');
      c.loadMemory();
      c.handle(memMsg(kItems));
      c.bindRoom(circleId: 'c2', inRoom: true, myUserId: 'me');
      expect(c.memoryItems, isNull);
    });

    test('memory of another circle opened from home is kept while idle', () {
      c.bindRoom(circleId: null, inRoom: false, myUserId: 'me');
      c.loadMemory(circleId: 'c9');
      expect(sent.last, {'t': 'anon_mem_list', 'circleId': 'c9'});
      c.handle(memMsg(kItems, cid: 'c9'));
      c.bindRoom(circleId: null, inRoom: false, myUserId: 'me');
      expect(c.memoryItems, hasLength(4));
      c.retractMemory('m1');
      expect(sent.last, {'t': 'anon_mem_retract', 'circleId': 'c9', 'itemId': 'm1'});
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

    testWidgets('opening sends anon_mem_list and shows loading', (tester) async {
      await tall(tester);
      await tester.pumpWidget(screen());
      expect(sent.single, {'t': 'anon_mem_list', 'circleId': kCid});
      expect(find.byKey(const ValueKey('anon-mem-loading')), findsOneWidget);
    });

    testWidgets('lists items with kind chip, date, provenance and a tombstone', (tester) async {
      await tall(tester);
      await tester.pumpWidget(screen());
      c.handle(memMsg(kItems));
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
      c.handle(memMsg(kItems));
      await tester.pump();
      expect(find.byKey(const ValueKey('anon-mem-retract-m2')), findsOneWidget);
    });

    testWidgets('retract goes through a confirmation dialog; cancel sends nothing', (tester) async {
      await tall(tester);
      await tester.pumpWidget(screen());
      c.handle(memMsg(kItems));
      await tester.pump();
      sent.clear();

      await tester.tap(find.byKey(const ValueKey('anon-mem-retract-m1')));
      await tester.pumpAndSettle();
      expect(find.text('撤回这条记忆?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('anon-mem-retract-cancel')));
      await tester.pumpAndSettle();
      expect(sent, isEmpty);

      await tester.tap(find.byKey(const ValueKey('anon-mem-retract-m1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('anon-mem-retract-confirm')));
      // 撤回中的小转圈是无限动画:不能 pumpAndSettle
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(sent.single, {'t': 'anon_mem_retract', 'circleId': kCid, 'itemId': 'm1'});
      // not deleted yet: still visible, showing pending
      expect(find.text('下季度预算先砍一成'), findsOneWidget);
      expect(find.byKey(const ValueKey('anon-mem-pending-m1')), findsOneWidget);

      c.handle({'t': 'anon_mem_retracted', 'circleId': kCid, 'itemId': 'm1'});
      await tester.pump();
      expect(find.text('下季度预算先砍一成'), findsNothing);
      expect(find.byKey(const ValueKey('anon-mem-tombstone-m1')), findsOneWidget);
      // anon_mem_retracted carries no retractedAt: no date shown
      expect(find.byKey(const ValueKey('anon-mem-retracted-date-m1')), findsNothing);
    });

    testWidgets('empty state', (tester) async {
      await tall(tester);
      await tester.pumpWidget(screen());
      c.handle(memMsg(const []));
      await tester.pump();
      expect(find.byKey(const ValueKey('anon-mem-empty')), findsOneWidget);
      expect(find.text('还没有记忆'), findsOneWidget);
    });

    testWidgets('error state offers retry, which resends anon_mem_list', (tester) async {
      await tall(tester);
      await tester.pumpWidget(screen());
      c.handle({'t': 'anon_error', 'circleId': kCid, 'op': 'anon_mem_list', 'code': 'not_registered'});
      await tester.pump();
      expect(find.byKey(const ValueKey('anon-mem-error')), findsOneWidget);
      expect(find.textContaining('not_registered'), findsOneWidget);
      sent.clear();
      await tester.tap(find.byKey(const ValueKey('anon-mem-retry')));
      await tester.pump();
      expect(sent.single, {'t': 'anon_mem_list', 'circleId': kCid});
    });

    testWidgets('English locale: kinds, plural provenance, no Chinese leaking', (tester) async {
      await tall(tester);
      await tester.pumpWidget(screen(locale: const Locale('en')));
      c.handle(memMsg(kItems));
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
