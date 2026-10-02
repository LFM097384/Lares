import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/transcript/local_transcript_store.dart';
import 'package:lares_app/src/transcript/transcript_backend_io.dart';
import 'package:lares_app/src/transcript/transcript_crypto.dart';
import 'package:lares_app/src/transcript/transcript_models.dart';
import 'package:lares_app/src/transcript/transcript_service.dart';

const _key = '9b1c5e7a2d4f6081a3c5e7f90b2d4f6182a4c6e8fa1c3e5f7092b4d6f8a1c3e5';

TranscriptEntry _e(String uid, String id, int at) => TranscriptEntry(
    userId: uid, name: uid, id: id, text: 't$id', startedAt: at, ts: at);

class _FakeSignaling {
  final sent = <Map<String, dynamic>>[];
  final ctrl = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  void inject(Map<String, dynamic> m) => ctrl.add(m);
}

TranscriptService _service(_FakeSignaling sig,
        {LocalTranscriptStore? store,
        String? Function(String)? keyFor,
        bool e2ee = true,
        String? ownerKey = 'ok-1'}) =>
    TranscriptService(
      send: sig.sent.add,
      messages: sig.ctrl.stream,
      ownerKeyFor: (_) => ownerKey,
      circleKeyFor: (id) async => keyFor == null ? _key : keyFor(id),
      isE2EE: (_) => e2ee,
      myUserId: () => 'me',
      myName: () => '我',
      store: store ?? LocalTranscriptStore(backend: MemoryTranscriptBackend()),
      timeout: const Duration(milliseconds: 200),
    );

void main() {
  group('LocalTranscriptStore', () {
    test('dedupe by (uid,id), newest-first paging, clear', () async {
      final s = LocalTranscriptStore(backend: MemoryTranscriptBackend());
      expect(await s.addAll('c', [for (var i = 0; i < 5; i++) _e('a', '$i', i)]),
          5);
      expect(await s.addAll('c', [_e('a', '1', 1), _e('b', '1', 9)]), 1);
      final p1 = await s.page('c', limit: 4);
      expect(p1.items.map((e) => e.startedAt), [9, 4, 3, 2]);
      expect(p1.more, isTrue);
      final p2 = await s.page('c', offset: p1.cursor! as int, limit: 4);
      expect(p2.items.map((e) => e.startedAt), [1, 0]);
      expect(p2.more, isFalse);
      expect(await s.count('other'), 0);
      await s.clear('c');
      expect((await s.page('c')).items, isEmpty);
    });

    test('persists to an injected directory and survives reload', () async {
      final dir = await Directory.systemTemp.createTemp('lares_tx_');
      addTearDown(() => dir.delete(recursive: true));
      final backend = DirectoryTranscriptBackend(() async => dir);
      final s1 = LocalTranscriptStore(backend: backend);
      await s1.addAll('c/1', [_e('a', '1', 1), _e('a', '2', 2)]);
      final s2 = LocalTranscriptStore(backend: backend);
      await s2.add('c/1', _e('a', '2', 2)); // 重复,不追加
      expect((await s2.page('c/1')).items.map((e) => e.id), ['2', '1']);
      await s2.clear('c/1');
      final s3 = LocalTranscriptStore(backend: backend);
      expect(await s3.count('c/1'), 0);
    });
  });

  group('relay', () {
    test('receive → decrypt → store → ack; bad blobs acked and counted',
        () async {
      final sig = _FakeSignaling();
      final svc = _service(sig);
      final good = encryptTranscriptLine(
        circleKeyHex: _key,
        circleId: 'c1',
        line: const TranscriptPlain(
            id: 'x1', uid: 'alice', name: '阿丽', text: '你好', startedAt: 5, ts: 6),
      );
      final wrongKey = encryptTranscriptLine(
        circleKeyHex: 'ab' * 32,
        circleId: 'c1',
        line: const TranscriptPlain(
            id: 'x2', uid: 'bob', name: 'B', text: 'no', startedAt: 7, ts: 8),
      );
      sig.inject({
        't': 'transcript_relay',
        'circleId': 'c1',
        'items': [
          {'rid': 'r1', 'blob': good, 'ts': 1},
          {'rid': 'r2', 'blob': wrongKey, 'ts': 2},
          {'rid': 'r3', 'blob': 'garbage', 'ts': 3},
        ],
      });
      await svc.idle;
      final page = await svc.store.page('c1');
      expect(page.items.single.text, '你好');
      expect(page.items.single.name, '阿丽');
      expect(svc.undecryptableCount, 2);
      expect(sig.sent.single, {
        't': 'transcript_relay_ack',
        'circleId': 'c1',
        'rids': ['r1', 'r2', 'r3'],
      });
    });

    test('no passcode → no ack (server keeps it)', () async {
      final sig = _FakeSignaling();
      final svc = _service(sig, keyFor: (_) => null);
      sig.inject({
        't': 'transcript_relay',
        'circleId': 'c1',
        'items': [
          {'rid': 'r1', 'blob': 'x', 'ts': 1}
        ],
      });
      await svc.idle;
      expect(sig.sent, isEmpty);
    });

    test('transcript_cleared wipes the local store', () async {
      final sig = _FakeSignaling();
      final svc = _service(sig);
      await svc.store.add('c1', _e('a', '1', 1));
      sig.inject({'t': 'transcript_cleared', 'circleId': 'c1'});
      await Future<void>.delayed(Duration.zero);
      expect(await svc.store.count('c1'), 0);
      expect(svc.epochOf('c1'), 1);
    });
  });

  test('EncryptedTranscriptSink sends a decryptable relay and stores own line',
      () async {
    final sig = _FakeSignaling();
    final svc = _service(sig);
    svc.encryptedSink.appendFinal(
        circleId: 'c1',
        id: 'me-1',
        text: '今晚见',
        startedAt: DateTime.fromMillisecondsSinceEpoch(1000));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final msg = sig.sent.single;
    expect(msg['t'], 'transcript_relay');
    expect(msg['circleId'], 'c1');
    final line = decryptTranscriptLine(
        circleKeyHex: _key, circleId: 'c1', blob: msg['blob'] as String);
    expect(line.text, '今晚见');
    expect(line.uid, 'me');
    expect(line.name, '我');
    expect(line.startedAt, 1000);
    expect((await svc.store.page('c1')).items.single.id, 'me-1');
  });

  test('server history paging via transcript_get', () async {
    final sig = _FakeSignaling();
    final svc = _service(sig, e2ee: false);
    final h = svc.historyFor('c1');
    expect(h, isA<ServerTranscriptHistory>());
    final f = h.page(limit: 2);
    expect(sig.sent.last, {'t': 'transcript_get', 'circleId': 'c1', 'limit': 2});
    sig.inject({
      't': 'transcript_page',
      'circleId': 'c1',
      'more': true,
      'items': [
        {'seq': 9, 'ts': 9, 'userId': 'a', 'name': 'A', 'id': '9', 'text': 'n', 'startedAt': 9},
        {'seq': 8, 'ts': 8, 'userId': 'a', 'name': 'A', 'id': '8', 'text': 'm', 'startedAt': 8},
      ],
    });
    final p = await f;
    expect(p.items.length, 2);
    expect(p.more, isTrue);
    final f2 = h.page(cursor: p.cursor, limit: 2);
    expect(sig.sent.last['before'], 8);
    sig.inject({
      't': 'transcript_error',
      'op': 'get',
      'circleId': 'c1',
      'reason': 'off',
    });
    await expectLater(f2, throwsA(isA<TranscriptOpException>()));
  });

  test('owner ops: set / clear / bot tokens / errors', () async {
    final sig = _FakeSignaling();
    final svc = _service(sig);
    final set = svc.setTranscriptOn('c1', true);
    expect(sig.sent.last, {
      't': 'circle_transcript_set',
      'circleId': 'c1',
      'on': true,
      'ownerKey': 'ok-1'
    });
    sig.inject({'t': 'owner_ok', 'op': 'circle_transcript_set', 'circleId': 'c1'});
    await set;

    final create = svc.createBotToken('c1', '纪要');
    expect(sig.sent.last['t'], 'bot_token_create');
    expect(sig.sent.last['name'], '纪要');
    sig.inject({
      't': 'bot_token',
      'circleId': 'c1',
      'id': 'b1',
      'name': '纪要',
      'token': 'lrb_secret',
      'createdAt': 1
    });
    final c = await create;
    expect(c.token, 'lrb_secret');

    final list = svc.listBotTokens('c1');
    sig.inject({
      't': 'bot_tokens',
      'circleId': 'c1',
      'items': [
        {'id': 'b1', 'name': '纪要', 'createdAt': 1}
      ]
    });
    expect((await list).single.id, 'b1');

    final revoke = svc.revokeBotToken('c1', 'b1');
    expect(sig.sent.last['id'], 'b1');
    sig.inject({
      't': 'owner_error',
      'op': 'bot_token_revoke',
      'circleId': 'c1',
      'reason': 'not_found'
    });
    await expectLater(revoke,
        throwsA(isA<TranscriptOpException>().having((e) => e.reason, 'reason', 'not_found')));

    await svc.store.add('c1', _e('a', '1', 1));
    final clear = svc.clearAsOwner('c1');
    expect(sig.sent.last['t'], 'transcript_clear');
    sig.inject({'t': 'owner_ok', 'op': 'transcript_clear', 'circleId': 'c1'});
    await clear;
    expect(await svc.store.count('c1'), 0);

    await expectLater(svc.setTranscriptOn('c1', false),
        throwsA(isA<TranscriptOpException>().having((e) => e.reason, 'r', 'timeout')));
  });

  test('no owner key → no_key without sending', () async {
    final sig = _FakeSignaling();
    final svc = _service(sig, ownerKey: null);
    await expectLater(svc.setTranscriptOn('c1', true),
        throwsA(isA<TranscriptOpException>()));
    expect(sig.sent, isEmpty);
  });
}
