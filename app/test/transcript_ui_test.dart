import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/transcript/transcript_history_screen.dart';
import 'package:lares_app/src/transcript/transcript_models.dart';
import 'package:lares_app/src/transcript/transcript_owner_section.dart';
import 'package:lares_app/src/transcript/transcript_service.dart';

import 'helpers/localized_app.dart';

class _FakeHistory extends ChangeNotifier implements TranscriptHistory {
  _FakeHistory(this.all, {this.fail = false});
  final List<TranscriptEntry> all;
  bool fail;
  int calls = 0;

  @override
  Future<TranscriptPage> page({Object? cursor, int limit = 50}) async {
    calls++;
    if (fail) throw TranscriptOpException('boom');
    final start = cursor as int? ?? 0;
    final end = (start + limit).clamp(0, all.length);
    return TranscriptPage(
        items: all.sublist(start, end), more: end < all.length, cursor: end);
  }

  void clear() {
    all.clear();
    notifyListeners();
  }
}

List<TranscriptEntry> _entries(int n) => [
      for (var i = 0; i < n; i++)
        TranscriptEntry(
            userId: 'u$i',
            name: '说话人$i',
            id: '$i',
            text: '第$i句',
            startedAt: DateTime(2026, 1, 1, 10, i).millisecondsSinceEpoch,
            ts: 0),
    ];

class _FakeBots implements BotTokenApi {
  final items = <BotTokenInfo>[];
  @override
  Future<BotTokenCreated> create(String name) async {
    final info = BotTokenInfo(id: 'b${items.length}', name: name, createdAt: 0);
    items.add(info);
    return BotTokenCreated(info: info, token: 'lrb_SECRET_$name');
  }

  @override
  Future<List<BotTokenInfo>> list() async => List.of(items);

  final revoked = <String>[];
  @override
  Future<void> revoke(String id) async => revoked.add(id);
}

void main() {
  group('TranscriptHistoryScreen', () {
    testWidgets('renders rows and loads more', (tester) async {
      final h = _FakeHistory(_entries(5));
      await tester.pumpWidget(localizedApp(TranscriptHistoryScreen(
          history: h, circleName: 'c', pageSize: 3)));
      await tester.pumpAndSettle();
      expect(find.text('第0句'), findsOneWidget);
      expect(find.text('第2句'), findsOneWidget);
      expect(find.text('第3句'), findsNothing);
      expect(find.textContaining('说话人0 · '), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('transcript-load-more')));
      await tester.pumpAndSettle();
      expect(find.text('第4句'), findsOneWidget);
      expect(find.byKey(const ValueKey('transcript-load-more')), findsNothing);
    });

    testWidgets('empty and error states', (tester) async {
      final h = _FakeHistory([]);
      await tester.pumpWidget(
          localizedApp(TranscriptHistoryScreen(history: h, circleName: 'c')));
      await tester.pumpAndSettle();
      expect(find.textContaining('还没有记录'), findsOneWidget);

      final bad = _FakeHistory([], fail: true);
      await tester.pumpWidget(localizedApp(
          TranscriptHistoryScreen(key: UniqueKey(), history: bad, circleName: 'c')));
      await tester.pumpAndSettle();
      expect(find.text('没能读到记录,稍后再试'), findsOneWidget);
      bad.fail = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.textContaining('还没有记录'), findsOneWidget);
    });

    testWidgets('owner sees 清空记录; 算了 cancels; 清空 clears', (tester) async {
      final h = _FakeHistory(_entries(2));
      var cleared = 0;
      await tester.pumpWidget(localizedApp(TranscriptHistoryScreen(
        history: h,
        circleName: 'c',
        onClear: () async {
          cleared++;
          h.clear();
        },
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('transcript-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空记录'));
      await tester.pumpAndSettle();
      expect(find.text('算了'), findsOneWidget);
      await tester.tap(find.text('算了'));
      await tester.pumpAndSettle();
      expect(cleared, 0);
      expect(find.text('第0句'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('transcript-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('transcript-clear-confirm')));
      await tester.pumpAndSettle();
      expect(cleared, 1);
      expect(find.text('第0句'), findsNothing);
    });

    testWidgets('non-owner has no clear action', (tester) async {
      await tester.pumpWidget(localizedApp(TranscriptHistoryScreen(
          history: _FakeHistory(_entries(1)), circleName: 'c')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('transcript-menu')), findsNothing);
      expect(find.text('清空记录'), findsNothing);
    });
  });

  group('TranscriptOwnerSwitch', () {
    testWidgets('E2EE circle: turning on warns first; 算了 sends nothing',
        (tester) async {
      final sent = <bool>[];
      await pumpLocalized(
          tester,
          TranscriptOwnerSwitch(
              on: false, e2ee: true, onSet: (v) async => sent.add(v)));
      await tester.tap(find.byKey(const ValueKey('owner-transcript-switch')));
      await tester.pumpAndSettle();
      expect(find.textContaining('阿里云'), findsWidgets);
      expect(find.textContaining('密文'), findsWidgets);
      await tester.tap(find.text('算了'));
      await tester.pumpAndSettle();
      expect(sent, isEmpty);

      await tester.tap(find.byKey(const ValueKey('owner-transcript-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('transcript-e2ee-confirm')));
      await tester.pumpAndSettle();
      expect(sent, [true]);
    });

    testWidgets('plain circle: no warning', (tester) async {
      final sent = <bool>[];
      await pumpLocalized(
          tester,
          TranscriptOwnerSwitch(
              on: false, e2ee: false, onSet: (v) async => sent.add(v)));
      await tester.tap(find.byKey(const ValueKey('owner-transcript-switch')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(sent, [true]);
    });
  });

  group('BotTokensScreen', () {
    testWidgets('create shows the token once; revoke confirm with 算了',
        (tester) async {
      final api = _FakeBots();
      await tester.pumpWidget(localizedApp(BotTokensScreen(api: api)));
      await tester.pumpAndSettle();
      expect(find.text('还没有机器人'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('bot-token-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('bot-token-name')), '纪要');
      await tester.tap(find.byKey(const ValueKey('bot-token-create-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('lrb_SECRET_纪要'), findsOneWidget);
      expect(find.textContaining('只显示这一次'), findsOneWidget);
      expect(find.byKey(const ValueKey('bot-token-copy')), findsOneWidget);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      // 关掉之后,令牌再也不出现
      expect(find.text('lrb_SECRET_纪要'), findsNothing);
      expect(find.text('纪要'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('算了'));
      await tester.pumpAndSettle();
      expect(api.revoked, isEmpty);
      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bot-token-revoke-confirm')));
      await tester.pumpAndSettle();
      expect(api.revoked, ['b0']);
      expect(find.text('纪要'), findsNothing);
    });
  });
}
