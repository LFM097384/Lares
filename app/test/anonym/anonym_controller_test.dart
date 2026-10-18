import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/anonym/anonym_controller.dart';
import 'package:lares_app/src/anonym/anonym_crypto.dart';

import 'anonym_crypto_test.dart' show kVectorPub;

const String kCid = 'c1';

Map<String, dynamic> state({
  bool active = true,
  String sid = 'S1',
  int k = 2,
  bool meAcked = false,
  String convener = 'u-owner',
}) => {
  't': 'anon_state',
  'circleId': kCid,
  'active': active,
  'sid': sid,
  'k': k,
  'convenerId': convener,
  'members': [
    {'id': 'u-owner', 'name': '圈主', 'acked': true},
    {'id': 'me', 'name': '我', 'acked': meAcked},
    {'id': 'u3', 'name': '小三', 'acked': false},
  ],
};

Map<String, dynamic> draftMsg({String id = 'd1', String hash = 'h'}) => {
  't': 'anon_draft',
  'circleId': kCid,
  'draft': {
    'draftId': id,
    'draftHash': hash,
    'items': [
      {'id': 'i1', 'topic': '预算', 'text': '预算该砍', 'roleRisk': false, 'flags': <String>[]},
      {'id': 'i2', 'topic': '预算', 'text': '作为财务我认为…', 'roleRisk': true, 'reason': '职位', 'flags': ['role-revealing']},
      {'id': 'i3', 'topic': ' Hiring  plan ', 'text': '先招两个人', 'roleRisk': false, 'flags': <String>[]},
    ],
    'metrics': {'k_anon': 3, 'note': 'ok', 'nested': {'x': 1}},
  },
};

void main() {
  late List<Map<String, Object?>> sent;
  late AnonymController c;

  AnonymController make() => AnonymController(
    send: sent.add,
    keyFactory: () => AnonymKeys.fromSeed(List<int>.generate(32, (i) => i)),
    nonceFactory: () => 'AAECAwQFBgcICQoLDA0ODw',
  );

  setUp(() {
    sent = [];
    c = make()..bindRoom(circleId: kCid, inRoom: true, myUserId: 'me');
  });

  test('ignores non-anon and other-circle messages', () {
    c.handle({'t': 'chat', 'circleId': kCid});
    c.handle({...state(), 'circleId': 'other'});
    expect(c.active, isFalse);
  });

  test('anon_state parses members, convener and asks for consent', () {
    c.handle(state());
    expect(c.active, isTrue);
    expect(c.sid, 'S1');
    expect(c.k, 2);
    expect(c.members.map((m) => m.acked), [true, false, false]);
    expect(c.convenerName, '圈主');
    expect(c.needsConsent, isTrue);
    expect(c.iAmConvener, isFalse);
    expect(c.feeding, isFalse);
  });

  test('accept generates key and sends anon_ack; decline does not', () {
    c.handle(state());
    c.decline();
    expect(c.declined, isTrue);
    expect(c.needsConsent, isFalse);
    expect(sent, isEmpty);
    c.accept();
    expect(sent.single, {'t': 'anon_ack', 'circleId': kCid, 'pubKey': kVectorPub});
    expect(c.acked, isTrue);
    expect(c.feeding, isTrue);
  });

  test('ownFinal only feeds when acked', () {
    c.handle(state());
    c.ownFinal('你好', DateTime.fromMillisecondsSinceEpoch(1000));
    expect(sent, isEmpty);
    c.accept();
    sent.clear();
    c.ownFinal('  你好 ', DateTime.fromMillisecondsSinceEpoch(1000));
    c.ownFinal('   ', DateTime.fromMillisecondsSinceEpoch(1000));
    expect(sent.single,
        {'t': 'anon_utt', 'circleId': kCid, 'text': '你好', 'ts': 1000, 'final': true});
  });

  test('ask / answer, draft parse, review, approve with verifiable sig', () {
    c.handle(state());
    c.accept();
    sent.clear();
    c.ask('总结一下?');
    expect(c.askPending, isTrue);
    expect(sent.last, {'t': 'anon_ask', 'circleId': kCid, 'question': '总结一下?'});
    c.handle({'t': 'anon_answer', 'circleId': kCid, 'askerName': '我', 'question': '总结一下?', 'answer': '三点'});
    expect(c.askPending, isFalse);
    expect(c.answers.single.answer, '三点');

    c.requestDraft();
    expect(c.draftPending, isTrue);
    expect(sent.last, {'t': 'anon_draft', 'circleId': kCid});
    c.handle(draftMsg());
    final d = c.draft!;
    expect(d.items.map((i) => i.roleRisk), [false, true, false]);
    // topic kept verbatim (it's inside draftHash)
    expect(d.items.map((i) => i.topic), ['预算', '预算', ' Hiring  plan ']);
    expect(d.items[1].reason, '职位');
    expect(d.metrics, {'k_anon': 3, 'note': 'ok'});

    c.review('i2', AnonymReviewAction.generalise);
    expect(sent.last, {
      't': 'anon_review', 'circleId': kCid, 'draftId': 'd1', 'itemId': 'i2', 'action': 'generalise',
    });

    c.approve();
    final m = sent.last;
    expect(m['t'], 'anon_approve');
    expect(m['nonce'], 'AAECAwQFBgcICQoLDA0ODw');
    final msg = approvalMessage(sid: 'S1', draftId: 'd1', draftHash: 'h', nonce: m['nonce']! as String);
    expect(verifyApproval(kVectorPub, msg, m['sig']! as String), isTrue);
    expect(c.approvedCurrent, isTrue);
    final n = sent.length;
    c.approve(); // de-duped
    expect(sent.length, n);

    // 改过的稿子 hash 变了 → 可以再签
    c.handle(draftMsg(hash: 'h2'));
    expect(c.approvedCurrent, isFalse);

    c.handle({'t': 'anon_approvals', 'circleId': kCid, 'draftId': 'd1', 'count': 1, 'k': 2});
    expect(c.approvals, 1);
    expect(c.approvalsK, 2);
    c.handle({'t': 'anon_released', 'circleId': kCid, 'draftId': 'd1', 'text': '放出去的'});
    expect(c.releasedText, '放出去的');
  });

  test('roleRisk: score ≥ 0.5 or role-revealing flag', () {
    final d = AnonymController.parseDraft({
      'draftId': 'd', 'draftHash': 'h',
      'items': [
        {'id': 1, 'text': 'a', 'roleRisk': 0.7},
        {'id': 'b', 'text': 'b', 'roleRisk': 0.2},
        {'id': 'c', 'text': 'c', 'flags': ['role-revealing']},
        {'id': 'x'}, // no text → dropped
      ],
    })!;
    expect(d.items.map((i) => '${i.id}:${i.roleRisk}'), ['1:true', 'b:false', 'c:true']);
    expect(d.items.map((i) => i.topic), everyElement(isNull));
    expect(d.metrics, isEmpty);
    expect(AnonymController.parseDraft({'draftId': 'd'}), isNull);
  });

  test('anon_ended wipes keys/answers/draft, keeps receipt + released until dismissed', () {
    c.handle(state());
    c.accept();
    final keys = c.keys!;
    c.ask('q');
    c.handle({'t': 'anon_answer', 'circleId': kCid, 'askerName': '我', 'question': 'q', 'answer': 'a'});
    c.handle(draftMsg());
    c.handle({'t': 'anon_released', 'circleId': kCid, 'draftId': 'd1', 'text': 'T'});
    c.handle({
      't': 'anon_ended', 'circleId': kCid,
      'receipt': {'counts': {'utterances': 12, 'released': 1, 'bad': 'x'}, 'sha256': 'ab' * 32},
    });
    expect(c.active, isFalse);
    expect(keys.wiped, isTrue);
    expect(c.keys, isNull);
    expect(c.answers, isEmpty);
    expect(c.draft, isNull);
    expect(c.receipt!.counts, {'utterances': 12, 'released': 1});
    expect(c.receipt!.sha256, 'ab' * 32);
    expect(c.releasedText, 'T');
    // 服务器随后再报一次 inactive:卡片还开着,原文不丢
    c.handle(state(active: false));
    expect(c.releasedText, 'T');
    c.dismissEnded();
    expect(c.receipt, isNull);
    expect(c.releasedText, isNull);
  });

  test('anon_ended: a member who never acked gets no end card, just the ended state', () {
    c.handle(state());
    c.decline();
    c.handle({
      't': 'anon_ended', 'circleId': kCid,
      'receipt': {'counts': {'utterances': 3}, 'sha256': 'ab' * 32},
    });
    expect(c.active, isFalse);
    expect(c.receipt, isNull);
    expect(c.releasedText, isNull);

    // nor someone who saw the session but never answered the consent
    c.handle(state(sid: 'S2'));
    c.handle({'t': 'anon_ended', 'circleId': kCid, 'receipt': {'sha256': 'x'}});
    expect(c.active, isFalse);
    expect(c.receipt, isNull);
  });

  test('leaving the room or switching circle wipes everything', () {
    c.handle(state());
    c.accept();
    final keys = c.keys!;
    c.bindRoom(circleId: kCid, inRoom: false, myUserId: 'me');
    expect(c.active, isFalse);
    expect(keys.wiped, isTrue);

    c.bindRoom(circleId: kCid, inRoom: true, myUserId: 'me');
    c.handle(state());
    c.accept();
    final k2 = c.keys!;
    c.bindRoom(circleId: 'c2', inRoom: true, myUserId: 'me');
    expect(c.active, isFalse);
    expect(k2.wiped, isTrue);
  });

  test('reconnect: inactive state wipes; same sid unacked re-sends same ack', () {
    c.handle(state());
    c.accept();
    sent.clear();
    c.handle({'t': '_disconnected'});
    expect(c.active, isTrue);
    c.handle(state(meAcked: false));
    expect(sent.single, {'t': 'anon_ack', 'circleId': kCid, 'pubKey': kVectorPub});
    sent.clear();
    c.handle(state(meAcked: true));
    expect(sent, isEmpty);
    final keys = c.keys!;
    c.handle(state(active: false));
    expect(c.active, isFalse);
    expect(keys.wiped, isTrue);
  });

  test('a new sid wipes the previous session and asks consent again', () {
    c.handle(state());
    c.accept();
    final keys = c.keys!;
    c.handle(state(sid: 'S2'));
    expect(keys.wiped, isTrue);
    expect(c.acked, isFalse);
    expect(c.needsConsent, isTrue);
  });

  test('owner start / end; k defaults and clamps', () {
    c.start(3);
    expect(sent.last, {'t': 'anon_start', 'circleId': kCid, 'k': 3});
    c.end(); // not active → nothing
    expect(sent.length, 1);
    c.handle(state(convener: 'me'));
    expect(c.iAmConvener, isTrue);
    c.end();
    expect(sent.last, {'t': 'anon_end', 'circleId': kCid});

    expect(AnonymController.defaultK(2), 2);
    expect(AnonymController.defaultK(3), 3);
    expect(AnonymController.defaultK(4), 3);
    expect(AnonymController.defaultK(5), 4);
    expect(AnonymController.defaultK(10), 6);
    expect(AnonymController.clampK(1, 5), 2);
    expect(AnonymController.clampK(9, 5), 5);
  });

  test('anon_error is recorded without circleId', () {
    c.handle({'t': 'anon_error', 'code': 'not_owner'});
    expect(c.lastError, 'not_owner');
    c.clearError();
    expect(c.lastError, isNull);
  });

  test('anon_error for a non-memory op on another circle is ignored', () {
    c.handle({'t': 'anon_error', 'circleId': 'other', 'op': 'anon_ask', 'code': 'x'});
    expect(c.lastError, isNull);
    c.handle({'t': 'anon_error', 'circleId': kCid, 'op': 'anon_ask', 'code': 'bad_question'});
    expect(c.lastError, 'bad_question');
    expect(c.memoryError, isNull);
  });

  test('a rejected anon_approve can be signed again', () {
    c.handle(state());
    c.accept();
    c.handle(draftMsg());
    c.approve();
    expect(c.approvedCurrent, isTrue);
    c.handle({'t': 'anon_error', 'circleId': kCid, 'op': 'anon_approve', 'code': 'bad_sig'});
    expect(c.approvedCurrent, isFalse);
    final n = sent.length;
    c.approve();
    expect(sent.length, n + 1);
    expect(sent.last['t'], 'anon_approve');
  });
}
