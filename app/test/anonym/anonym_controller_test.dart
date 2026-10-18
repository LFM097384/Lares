import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/anonym/anonym_controller.dart';
import 'package:lares_app/src/anonym/anonym_crypto.dart';
import 'package:lares_app/src/anonym/anonym_seal.dart';

import 'anonym_crypto_test.dart' show kVectorPub;
import 'anonym_seal_test.dart' show kSealAgentPub, kSealAgentSeed;

const String kCid = 'c1';

/// 本圈 agent 身份:u_ai_anon_ + sha256('c1')[:8]。
final String kAgent = anonAgentIdentityFor(kCid);

/// agent 广播的 `state`(data 帧,不带 circleId)。
Map<String, dynamic> state({
  bool active = true,
  String sid = 'S1',
  int k = 2,
  bool meAcked = false,
  String convener = 'u-owner',
}) => {
  't': 'state',
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
  't': 'draft',
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

List<int> frame(Map<String, dynamic> m) => utf8.encode(jsonEncode(m));

void main() {
  late List<Map<String, Object?>> sent; // 信令 WS
  late List<(Map<String, Object?>, String)> data; // LiveKit data → 目标身份
  late AnonymController c;

  AnonymController make({
    AnonymMediaKeyFor? mediaKeyFor,
    AnonymSealer? sealer,
  }) => AnonymController(
    send: sent.add,
    sendData: (m, to) => data.add((m, to)),
    mediaKeyFor: mediaKeyFor,
    sealer: sealer,
    keyFactory: () => AnonymKeys.fromSeed(List<int>.generate(32, (i) => i)),
    nonceFactory: () => 'AAECAwQFBgcICQoLDA0ODw',
  );

  /// agent 发来一帧。
  void agent(Map<String, dynamic> m) => c.handleData(kAgent, frame(m));

  Map<String, Object?> lastData() => data.last.$1;

  setUp(() {
    sent = [];
    data = [];
    c = make()..bindRoom(circleId: kCid, inRoom: true, myUserId: 'me');
  });

  group('agent identity', () {
    test('u_ai_anon_ + first 8 hex of sha256(circleId)', () {
      // sha256("c1") = 7b8e…(与服务器 aiUserIdFor 同法,前缀不同)
      expect(kAgent, matches(RegExp(r'^u_ai_anon_[0-9a-f]{8}$')));
      expect(anonAgentIdentityFor('c1'), kAgent);
      expect(anonAgentIdentityFor('c2'), isNot(kAgent));
      expect(c.agentIdentity, kAgent);
      expect(c.isAgentIdentity(kAgent), isTrue);
      expect(c.isAgentIdentity('u_ai_anon_00000000'), isFalse);
    });

    test('anon_agent_state.identity overrides the derived one', () {
      c.handle({'t': 'anon_agent_state', 'circleId': kCid, 'present': true, 'active': false, 'identity': 'u_ai_anon_custom'});
      expect(c.agentPresent, isTrue);
      expect(c.agentIdentity, 'u_ai_anon_custom');
      expect(c.isAgentIdentity(kAgent), isFalse);
      // 不是 u_ai_ 开头的 identity 不认
      c.handle({'t': 'anon_agent_state', 'circleId': kCid, 'present': false});
      c.handle({'t': 'anon_agent_state', 'circleId': kCid, 'present': true, 'identity': 'u_evil'});
      expect(c.agentIdentity, kAgent);
    });
  });

  group('data topic parsing', () {
    test('frames from anyone but the agent are dropped', () {
      c.handleData('me', frame(state()));
      c.handleData('u-owner', frame(state()));
      c.handleData('u_ai_deadbeef', frame(state())); // 语音 AI 也不行
      c.handleData('', frame(state()));
      expect(c.active, isFalse);
      agent(state());
      expect(c.active, isTrue);
      expect(c.agentPresent, isTrue);
    });

    test('malformed frames are ignored', () {
      expect(AnonymController.decodeFrame(utf8.encode('not json')), isNull);
      expect(AnonymController.decodeFrame(utf8.encode('[1,2]')), isNull);
      expect(AnonymController.decodeFrame(utf8.encode('{"x":1}')), isNull);
      expect(AnonymController.decodeFrame(const [0xff, 0xfe]), isNull);
      expect(AnonymController.decodeFrame(const []), isNull);
      expect(AnonymController.decodeFrame(frame({'t': 'state'})), {'t': 'state'});
      c.handleData(kAgent, utf8.encode('{"t":'));
      expect(c.active, isFalse);
    });

    test('not in the room → frames ignored', () {
      c.bindRoom(circleId: kCid, inRoom: false, myUserId: 'me');
      agent(state());
      expect(c.active, isFalse);
    });

    test('v1 anon_* session messages over signaling are ignored now', () {
      c.handle({'t': 'anon_state', 'circleId': kCid, ...state()..remove('t')});
      expect(c.active, isFalse);
    });

    test('state parses members, convener and asks for consent', () {
      agent(state());
      expect(c.active, isTrue);
      expect(c.sid, 'S1');
      expect(c.k, 2);
      expect(c.members.map((m) => m.acked), [true, false, false]);
      expect(c.convenerName, '圈主');
      expect(c.needsConsent, isTrue);
      expect(c.iAmConvener, isFalse);
      expect(c.sessionActive, isTrue);
    });
  });

  test('accept sends ack{pubKey} to the agent only; decline sends nothing', () {
    agent(state());
    c.decline();
    expect(c.declined, isTrue);
    expect(c.needsConsent, isFalse);
    expect(data, isEmpty);
    c.accept();
    expect(data.single.$1, {'t': 'ack', 'pubKey': kVectorPub});
    expect(data.single.$2, kAgent);
    expect(sent, isEmpty); // 不走信令
    expect(c.acked, isTrue);
  });

  test('ask / answer{qid,q,a}, minutes skill, draft, review, approve with verifiable sig', () {
    agent(state());
    c.accept();
    data.clear();
    c.ask('  总结一下? ');
    expect(c.askPending, isTrue);
    expect(lastData(), {'t': 'ask', 'q': '总结一下?'});
    agent({'t': 'answer', 'qid': 'q1', 'q': '总结一下?', 'a': '三点'});
    expect(c.askPending, isFalse);
    expect(c.answers.single.answer, '三点');
    expect(c.answers.single.question, '总结一下?');
    expect(c.answers.single.askerName, '');

    c.requestMinutes();
    expect(c.draftPending, isTrue);
    expect(lastData(), {'t': 'skill', 'name': 'minutes'});
    agent(draftMsg());
    expect(c.draftPending, isFalse);
    final d = c.draft!;
    expect(d.items.map((i) => i.roleRisk), [false, true, false]);
    // topic kept verbatim (it's inside draftHash)
    expect(d.items.map((i) => i.topic), ['预算', '预算', ' Hiring  plan ']);
    expect(d.items[1].reason, '职位');
    expect(d.metrics, {'k_anon': 3, 'note': 'ok'});

    c.review('i2', AnonymReviewAction.generalise);
    expect(lastData(), {'t': 'review', 'draftId': 'd1', 'itemId': 'i2', 'action': 'generalise'});

    c.approve();
    final m = lastData();
    expect(m['t'], 'approve');
    expect(m.keys.toSet(), {'t', 'draftId', 'draftHash', 'nonce', 'sig'}); // sid 不发
    expect(m['nonce'], 'AAECAwQFBgcICQoLDA0ODw');
    final msg = approvalMessage(sid: 'S1', draftId: 'd1', draftHash: 'h', nonce: m['nonce']! as String);
    expect(verifyApproval(kVectorPub, msg, m['sig']! as String), isTrue);
    expect(c.approvedCurrent, isTrue);
    final n = data.length;
    c.approve(); // de-duped
    expect(data.length, n);

    // 改过的稿子 hash 变了 → 可以再签
    agent(draftMsg(hash: 'h2'));
    expect(c.approvedCurrent, isFalse);

    agent({'t': 'approvals', 'draftId': 'd1', 'count': 1, 'k': 2});
    expect(c.approvals, 1);
    expect(c.approvalsK, 2);
    agent({'t': 'released', 'draftId': 'd1', 'text': '# 纪要\n- 放出去的'});
    expect(c.releasedText, '# 纪要\n- 放出去的');
    expect(data.every((e) => e.$2 == kAgent), isTrue);
    expect(sent, isEmpty);
  });

  test('skill with args; not acked → nothing sent', () {
    agent(state());
    c.runSkill('topics', args: {'max': 3});
    expect(data, isEmpty);
    c.accept();
    c.runSkill('topics', args: {'max': 3});
    expect(lastData(), {'t': 'skill', 'name': 'topics', 'args': {'max': 3}});
    expect(c.draftPending, isFalse); // 只有 minutes 走出门稿
  });

  test('no data channel / agent → session messages are not sent', () {
    c = AnonymController(send: sent.add)
      ..bindRoom(circleId: kCid, inRoom: true, myUserId: 'me');
    c.handleData(kAgent, frame(state()));
    c.accept();
    expect(sent, isEmpty);
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

  test('ended wipes keys/answers/draft, keeps receipt + released until dismissed', () {
    agent(state());
    c.accept();
    final keys = c.keys!;
    c.ask('q');
    agent({'t': 'answer', 'qid': '1', 'q': 'q', 'a': 'a'});
    agent(draftMsg());
    agent({'t': 'released', 'draftId': 'd1', 'text': 'T'});
    agent({
      't': 'ended',
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
    // agent 随后再报一次 inactive:卡片还开着,原文不丢
    agent(state(active: false));
    expect(c.releasedText, 'T');
    c.dismissEnded();
    expect(c.receipt, isNull);
    expect(c.releasedText, isNull);
  });

  test('ended: a member who never acked gets no end card', () {
    agent(state());
    c.decline();
    agent({'t': 'ended', 'receipt': {'counts': {'utterances': 3}, 'sha256': 'ab' * 32}});
    expect(c.active, isFalse);
    expect(c.receipt, isNull);
    expect(c.releasedText, isNull);
  });

  test('leaving the room or switching circle wipes everything', () {
    agent(state());
    c.accept();
    final keys = c.keys!;
    c.bindRoom(circleId: kCid, inRoom: false, myUserId: 'me');
    expect(c.active, isFalse);
    expect(c.agentPresent, isFalse);
    expect(keys.wiped, isTrue);

    c.bindRoom(circleId: kCid, inRoom: true, myUserId: 'me');
    agent(state());
    c.accept();
    final k2 = c.keys!;
    c.bindRoom(circleId: 'c2', inRoom: true, myUserId: 'me');
    expect(c.active, isFalse);
    expect(k2.wiped, isTrue);
    // 换圈后,旧圈 agent 的帧不再认
    agent(state());
    expect(c.active, isFalse);
  });

  test('agent restart: same sid unacked re-sends same ack; inactive wipes', () {
    agent(state());
    c.accept();
    data.clear();
    c.handle({'t': '_disconnected'});
    expect(c.active, isTrue);
    agent(state(meAcked: false));
    expect(data.single.$1, {'t': 'ack', 'pubKey': kVectorPub});
    data.clear();
    agent(state(meAcked: true));
    expect(data, isEmpty);
    final keys = c.keys!;
    agent(state(active: false));
    expect(c.active, isFalse);
    expect(keys.wiped, isTrue);
  });

  test('a new sid wipes the previous session and asks consent again', () {
    agent(state());
    c.accept();
    final keys = c.keys!;
    agent(state(sid: 'S2'));
    expect(keys.wiped, isTrue);
    expect(c.acked, isFalse);
    expect(c.needsConsent, isTrue);
  });

  group('owner controls over signaling', () {
    test('invite / dismiss / end; k defaults and clamps', () {
      c.invite(3);
      expect(sent.last, {'t': 'anon_agent_invite', 'circleId': kCid, 'k': 3});
      expect(c.invitePending, isTrue);
      c.handle({'t': 'anon_agent_state', 'circleId': kCid, 'present': true, 'active': false});
      expect(c.invitePending, isFalse);
      expect(c.agentPresent, isTrue);

      c.end(); // not active → nothing
      expect(data, isEmpty);
      agent(state(convener: 'me'));
      expect(c.iAmConvener, isTrue);
      c.end();
      expect(lastData(), {'t': 'end'});
      expect(data.last.$2, kAgent);

      c.dismiss();
      expect(sent.last, {'t': 'anon_agent_dismiss', 'circleId': kCid});

      expect(AnonymController.defaultK(2), 2);
      expect(AnonymController.defaultK(3), 3);
      expect(AnonymController.defaultK(4), 3);
      expect(AnonymController.defaultK(5), 4);
      expect(AnonymController.defaultK(10), 6);
      expect(AnonymController.clampK(1, 5), 2);
      expect(AnonymController.clampK(9, 5), 5);
    });

    test('anon_agent_state for another circle is ignored', () {
      c.handle({'t': 'anon_agent_state', 'circleId': 'other', 'present': true, 'active': true});
      expect(c.agentPresent, isFalse);
      expect(c.sessionActive, isFalse);
    });

    test('transcript suppression: anon_agent_state.active OR data state.active', () {
      expect(c.sessionActive, isFalse);
      c.handle({'t': 'anon_agent_state', 'circleId': kCid, 'present': true, 'active': true});
      expect(c.sessionActive, isTrue);
      expect(c.active, isFalse); // 会话细节还没到
      c.handle({'t': 'anon_agent_state', 'circleId': kCid, 'present': true, 'active': false});
      expect(c.sessionActive, isFalse);
      agent(state());
      expect(c.sessionActive, isTrue);
    });

    test('agent leaving (present:false) ends the session locally', () {
      agent(state());
      c.accept();
      final keys = c.keys!;
      c.handle({'t': 'anon_agent_state', 'circleId': kCid, 'present': false, 'active': false});
      expect(c.active, isFalse);
      expect(c.sessionActive, isFalse);
      expect(keys.wiped, isTrue);
    });
  });

  group('E2EE keyreq', () {
    final String pubB64 = base64.encode(kSealAgentPub);

    test('keyreq → accept seals media key hex and sends anon_agent_key', () async {
      String? askedFor;
      c = make(mediaKeyFor: (cid) async {
        askedFor = cid;
        return 'ab' * 32;
      })..bindRoom(circleId: kCid, inRoom: true, myUserId: 'u-owner');
      c.handle({'t': 'anon_agent_keyreq', 'circleId': kCid, 'x25519Pub': pubB64});
      expect(c.keyRequest, isNotNull);
      expect(c.keyRequest!.x25519Pub, kSealAgentPub);
      await c.acceptKeyRequest();
      expect(askedFor, kCid);
      expect(c.keyRequest, isNull);
      final m = sent.single;
      expect(m['t'], 'anon_agent_key');
      expect(m['circleId'], kCid);
      expect(m['x25519Pub'], pubB64);
      // agent 能用自己的私钥解开,得到的正是媒体密钥 hex
      final String clear = await anonUnseal(agentSeed: kSealAgentSeed, sealed: m['sealed']! as String, circleId: kCid);
      expect(clear, 'ab' * 32);
    });

    test('decline sends nothing', () {
      c.handle({'t': 'anon_agent_keyreq', 'circleId': kCid, 'x25519Pub': pubB64});
      c.declineKeyRequest();
      expect(c.keyRequest, isNull);
      expect(sent, isEmpty);
    });

    test('no media key on this device → error, nothing sent', () async {
      c = make(mediaKeyFor: (_) async => null)
        ..bindRoom(circleId: kCid, inRoom: true, myUserId: 'u-owner');
      c.handle({'t': 'anon_agent_keyreq', 'circleId': kCid, 'x25519Pub': pubB64});
      await c.acceptKeyRequest();
      expect(sent, isEmpty);
      expect(c.lastError, 'no_media_key');
    });

    test('bad pubkey / other circle / not in room → ignored', () {
      c.handle({'t': 'anon_agent_keyreq', 'circleId': kCid, 'x25519Pub': 'short'});
      c.handle({'t': 'anon_agent_keyreq', 'circleId': 'other', 'x25519Pub': pubB64});
      expect(c.keyRequest, isNull);
      c.bindRoom(circleId: kCid, inRoom: false);
      c.handle({'t': 'anon_agent_keyreq', 'circleId': kCid, 'x25519Pub': pubB64});
      expect(c.keyRequest, isNull);
    });

    test('leaving while sealing drops the request', () async {
      c = make(mediaKeyFor: (_) async => 'ab' * 32)
        ..bindRoom(circleId: kCid, inRoom: true, myUserId: 'u-owner');
      c.handle({'t': 'anon_agent_keyreq', 'circleId': kCid, 'x25519Pub': pubB64});
      final f = c.acceptKeyRequest();
      c.bindRoom(circleId: kCid, inRoom: false);
      await f;
      expect(sent, isEmpty);
    });
  });

  group('errors', () {
    test('anon_error over signaling is recorded without circleId', () {
      c.handle({'t': 'anon_error', 'code': 'not_owner'});
      expect(c.lastError, 'not_owner');
      c.clearError();
      expect(c.lastError, isNull);
    });

    test('anon_error for another circle is ignored', () {
      c.handle({'t': 'anon_error', 'circleId': 'other', 'op': 'anon_agent_invite', 'code': 'x'});
      expect(c.lastError, isNull);
      c.invite(2);
      c.handle({'t': 'anon_error', 'circleId': kCid, 'op': 'anon_agent_invite', 'code': 'not_registered'});
      expect(c.lastError, 'not_registered');
      expect(c.invitePending, isFalse);
      expect(c.memoryError, isNull);
    });

    test('agent error{op,code}: a rejected approve can be signed again', () {
      agent(state());
      c.accept();
      agent(draftMsg());
      c.approve();
      expect(c.approvedCurrent, isTrue);
      agent({'t': 'error', 'op': 'approve', 'code': 'bad_sig'});
      expect(c.lastError, 'bad_sig');
      expect(c.approvedCurrent, isFalse);
      final n = data.length;
      c.approve();
      expect(data.length, n + 1);
      expect(lastData()['t'], 'approve');
    });

    test('agent error for ask clears the pending flag', () {
      agent(state());
      c.accept();
      c.ask('q');
      agent({'t': 'error', 'op': 'ask', 'code': 'rate_limited'});
      expect(c.askPending, isFalse);
      expect(c.lastError, 'rate_limited');
    });
  });
}
