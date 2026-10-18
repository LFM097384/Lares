import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/anonym/anonym_controller.dart';
import 'package:lares_app/src/anonym/anonym_crypto.dart';
import 'package:lares_app/src/anonym/anonym_gate.dart';
import 'package:lares_app/src/anonym/anonym_room.dart';
import 'package:lares_app/src/anonym/anonym_sheets.dart';

import '../helpers/localized_app.dart';
import 'anonym_controller_test.dart' show draftMsg, frame, kAgent, kCid, state;

const String kDisclosure =
    'AI 作为成员加入，只转写已同意成员的声音；原话在 AI 内部先脱敏，再交给大模型';

const String kKeyReqNote =
    '托管 AI 运行期间会在内存里持有本圈媒体密钥；如需完全排除运营方，可在自己的设备上运行独立模式';

void main() {
  late List<Map<String, Object?>> sent;
  late List<Map<String, Object?>> data;
  late AnonymController anon;

  /// agent 发来一帧(LiveKit data,topic lares.anon)。
  void agent(Map<String, dynamic> m) => anon.handleData(kAgent, frame(m));

  setUp(() {
    sent = [];
    data = [];
    anon = AnonymController(
      send: sent.add,
      sendData: (m, to) {
        if (to != kAgent) throw StateError('sent to $to');
        data.add(m);
      },
      keyFactory: () => AnonymKeys.fromSeed(List<int>.generate(32, (i) => i)),
      nonceFactory: () => 'AAECAwQFBgcICQoLDA0ODw',
    )..bindRoom(circleId: kCid, inRoom: true, myUserId: 'me');
  });

  Future<void> tall(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  testWidgets('convene sheet: rule, labels, disclosure verbatim, k picker 2..n, no strict tier',
      (tester) async {
    await tall(tester);
    await tester.pumpWidget(localizedScaffold(
        AnonymConveneSheet(anonym: anon, presentCount: 5)));
    expect(find.text('邀请炉灵'), findsOneWidget);
    // 出处只留邀请面板底部一行小字脚注
    expect(find.text('受 Chatham House 规则启发 · 非官方 · 与 Chatham House 无隶属'), findsOneWidget);
    expect(find.textContaining('隐名之约'), findsNothing);
    expect(find.text(kDisclosure), findsOneWidget);
    expect(find.textContaining('严格'), findsNothing);
    expect(find.textContaining('依规则'), findsNothing);
    // 默认 ceil(5/2)+1 = 4
    expect(find.text('4 / 5 人同意才放行'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('anon-k-plus')));
    await tester.pump();
    expect(find.text('5 / 5 人同意才放行'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('anon-k-plus'))); // capped
    await tester.pump();
    expect(find.text('5 / 5 人同意才放行'), findsOneWidget);
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.byKey(const ValueKey('anon-k-minus')));
      await tester.pump();
    }
    expect(find.text('2 / 5 人同意才放行'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('anon-convene-start')));
    await tester.pump();
    expect(sent.single, {'t': 'anon_agent_invite', 'circleId': kCid, 'k': 2});
    expect(anon.invitePending, isTrue);
  });

  testWidgets('convene sheet with fewer than two people cannot start', (tester) async {
    await tall(tester);
    await tester.pumpWidget(localizedScaffold(
        AnonymConveneSheet(anonym: anon, presentCount: 1)));
    expect(find.byKey(const ValueKey('anon-need-two')), findsOneWidget);
    final btn = tester.widget<FilledButton>(find.byKey(const ValueKey('anon-convene-start')));
    expect(btn.onPressed, isNull);
  });

  testWidgets('host shows consent on anon_state; accept sends ack', (tester) async {
    await tall(tester);
    await tester.pumpWidget(localizedApp(
        AnonymRoomHost(anonym: anon, child: const Scaffold(body: SizedBox()))));
    agent(state());
    await tester.pumpAndSettle();
    expect(find.text('圈主 邀请了炉灵'), findsOneWidget);
    expect(find.textContaining('Chatham'), findsNothing);
    expect(find.text(kDisclosure), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('anon-consent-accept')));
    await tester.pumpAndSettle();
    expect(data.single['t'], 'ack');
    expect(anon.acked, isTrue);
    // 同一场不再弹第二次
    agent(state(meAcked: true));
    await tester.pumpAndSettle();
    expect(find.byType(AnonymConsentSheet), findsNothing);
  });

  testWidgets('consent decline keeps me in room as 未加入, no ack', (tester) async {
    await tall(tester);
    await tester.pumpWidget(localizedApp(AnonymRoomHost(
        anonym: anon,
        child: Scaffold(body: AnonymRoomBand(anonym: anon)))));
    agent(state());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('anon-consent-decline')));
    await tester.pumpAndSettle();
    expect(data, isEmpty);
    expect(anon.declined, isTrue);
    expect(find.byKey(const ValueKey('anon-declined-note')), findsOneWidget);
    expect(find.text('我 · 未加入'), findsOneWidget);
    expect(find.byKey(const ValueKey('anon-ask')), findsNothing);
  });

  testWidgets('band shows label, ack status, ask AI panel marked 不留痕', (tester) async {
    await tall(tester);
    await tester.pumpWidget(localizedScaffold(AnonymRoomBand(anonym: anon)));
    expect(find.byKey(const ValueKey('anon-band')), findsNothing);
    agent(state());
    anon.accept();
    agent(state(meAcked: true));
    await tester.pump();
    expect(find.textContaining('EMBER', findRichText: true), findsOneWidget);
    expect(find.textContaining('炉灵在场 · 不署名', findRichText: true), findsOneWidget);
    expect(find.text('2/3 已加入'), findsOneWidget);
    expect(find.text('圈主 · 已加入'), findsOneWidget);
    expect(find.text('小三 · 未加入'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('anon-ask')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('anon-ask-sheet')), findsOneWidget);
    expect(find.text('不留痕'), findsWidgets);
    await tester.enterText(find.byKey(const ValueKey('anon-ask-field')), '大家主要分歧?');
    await tester.tap(find.byKey(const ValueKey('anon-ask-send')));
    await tester.pump();
    expect(data.last, {'t': 'ask', 'q': '大家主要分歧?'});
    expect(find.byKey(const ValueKey('anon-thinking')), findsOneWidget);
    agent({'t': 'answer', 'qid': 'q1', 'q': '大家主要分歧?', 'a': '在预算节奏上'});
    await tester.pump();
    expect(find.text('在预算节奏上'), findsWidgets);
    // 散会 → 面板自己关
    agent({'t': 'ended', 'receipt': {'sha256': 'x'}});
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('anon-ask-sheet')), findsNothing);
    expect(find.byKey(const ValueKey('anon-band')), findsNothing);
  });

  testWidgets('gate review: roleRisk tag + actions, metrics only if given, approve, release copy',
      (tester) async {
    await tall(tester);
    agent(state());
    anon.accept();
    agent(draftMsg());
    data.clear();
    String? clip;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
        (call) async {
      if (call.method == 'Clipboard.setData') {
        clip = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    await tester.pumpWidget(localizedApp(AnonymGateScreen(anonym: anon)));
    // topics shown verbatim as section headings, one per topic, in first-seen order
    expect(find.byKey(const ValueKey('anon-topic-0')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('anon-topic-0'))).data, '预算');
    expect(tester.widget<Text>(find.byKey(const ValueKey('anon-topic-1'))).data, ' Hiring  plan ');
    expect(find.byKey(const ValueKey('anon-topic-2')), findsNothing);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('anon-topic-0'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('anon-item-i1'))).dy),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('anon-item-i2'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('anon-topic-1'))).dy),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('anon-topic-1'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('anon-item-i3'))).dy),
    );
    expect(find.byKey(const ValueKey('anon-role-risk-i2')), findsOneWidget);
    expect(find.byKey(const ValueKey('anon-role-risk-i1')), findsNothing);
    expect(find.text('暴露角色'), findsOneWidget);
    expect(find.byKey(const ValueKey('anon-metrics')), findsOneWidget);
    expect(find.text('k_anon'), findsOneWidget);
    expect(find.textContaining('随机'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('anon-review-i2-cut')));
    await tester.pump();
    expect(data.last, {'t': 'review', 'draftId': 'd1', 'itemId': 'i2', 'action': 'cut'});
    expect(find.text('0 / 2 已同意放行'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('anon-approve')));
    await tester.pump();
    expect(data.last['t'], 'approve');
    expect(find.text('你已同意,等其他人'), findsOneWidget);
    agent({'t': 'approvals', 'draftId': 'd1', 'count': 2, 'k': 2});
    agent({'t': 'released', 'draftId': 'd1', 'text': '预算该砍。'});
    await tester.pump();
    expect(find.byKey(const ValueKey('anon-released')), findsOneWidget);
    expect(find.byKey(const ValueKey('anon-approve')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('anon-copy-released')));
    await tester.pump();
    expect(clip, '预算该砍。');
  });

  testWidgets('gate without metrics hides the metrics block', (tester) async {
    await tall(tester);
    agent(state());
    anon.accept();
    agent({
      't': 'draft',
      'draft': {'draftId': 'd', 'draftHash': 'h', 'items': [{'id': 'a', 'text': 'x'}]},
    });
    await tester.pumpWidget(localizedApp(AnonymGateScreen(anonym: anon)));
    expect(find.byKey(const ValueKey('anon-metrics')), findsNothing);
    // no topic from the server → no heading
    expect(find.byKey(const ValueKey('anon-topic-0')), findsNothing);
  });

  testWidgets('end card via host: counts + sha256; dismiss wipes released text', (tester) async {
    await tall(tester);
    await tester.pumpWidget(localizedApp(
        AnonymRoomHost(anonym: anon, child: const Scaffold(body: SizedBox()))));
    agent(state());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('anon-consent-accept')));
    await tester.pumpAndSettle();
    agent({'t': 'released', 'draftId': 'd1', 'text': '出门的话'});
    final sha = 'ab12' * 16;
    agent({
      't': 'ended',
      'receipt': {'counts': {'utterances': 9}, 'sha256': sha},
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('anon-end-card')), findsOneWidget);
    expect(find.text('散会'), findsOneWidget);
    expect(find.text(sha), findsOneWidget);
    expect(find.text('utterances  9'), findsOneWidget);
    expect(find.text('出门的话'), findsOneWidget);
    expect(anon.keys, isNull);
    await tester.tap(find.byKey(const ValueKey('anon-end-ok')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('anon-end-card')), findsNothing);
    expect(anon.releasedText, isNull);
    expect(anon.receipt, isNull);
  });

  testWidgets('end card is not shown to a member who did not ack', (tester) async {
    await tall(tester);
    await tester.pumpWidget(localizedApp(AnonymRoomHost(
        anonym: anon,
        child: Scaffold(body: AnonymRoomBand(anonym: anon)))));
    agent(state());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('anon-consent-decline')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('anon-band')), findsOneWidget);
    agent({
      't': 'ended',
      'receipt': {'counts': {'utterances': 9}, 'sha256': 'ab12' * 16},
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('anon-end-card')), findsNothing);
    expect(find.byKey(const ValueKey('anon-band')), findsNothing);
    expect(anon.active, isFalse);
  });

  testWidgets('end confirm dialog sends end over data', (tester) async {
    await tall(tester);
    agent(state(convener: 'me'));
    await tester.pumpWidget(localizedApp(Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => confirmAnonymEnd(context, anon),
          child: const Text('go'),
        ),
      ),
    )));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('anon-end-confirm')));
    await tester.pumpAndSettle();
    expect(data.last, {'t': 'end'});
    expect(sent, isEmpty);
  });

  testWidgets('English locale renders without the Chinese labels leaking', (tester) async {
    await tall(tester);
    await tester.pumpWidget(localizedScaffold(
        AnonymConveneSheet(anonym: anon, presentCount: 3),
        locale: const Locale('en')));
    expect(find.text('Invite Ember'), findsOneWidget);
    expect(find.text('Inspired by the Chatham House Rule · Unofficial · Not affiliated with Chatham House'),
        findsOneWidget);
    expect(find.textContaining('under the Rule'), findsNothing);
  });
  testWidgets('band: 导出会议纪要 sends skill minutes and opens the gate', (tester) async {
    await tall(tester);
    await tester.pumpWidget(localizedApp(Scaffold(body: AnonymRoomBand(anonym: anon))));
    agent(state());
    anon.accept();
    agent(state(meAcked: true));
    await tester.pump();
    data.clear();
    expect(find.text('导出会议纪要'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('anon-minutes')));
    await tester.pump();
    expect(data.single, {'t': 'skill', 'name': 'minutes'});
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(AnonymGateScreen), findsOneWidget);
    agent(draftMsg());
    agent({'t': 'released', 'draftId': 'd1', 'text': '# 会议纪要\n- 预算该砍'});
    await tester.pump();
    expect(find.byKey(const ValueKey('anon-released')), findsOneWidget);
    expect(find.textContaining('会议纪要'), findsWidgets);
  });

  testWidgets('keyreq sheet: honest note verbatim; accept seals and sends anon_agent_key',
      (tester) async {
    await tall(tester);
    anon.mediaKeyFor = (_) async => 'cd' * 32;
    await tester.pumpWidget(localizedApp(
        AnonymRoomHost(anonym: anon, child: const Scaffold(body: SizedBox()))));
    anon.handle({
      't': 'anon_agent_keyreq', 'circleId': kCid,
      'x25519Pub': 'NYBy1jZYgNGu6jKa35EhODhR7SGijjt16WXQ0s0WYlQ=',
    });
    await tester.pumpAndSettle();
    expect(find.byType(AnonymKeyRequestSheet), findsOneWidget);
    expect(find.text(kKeyReqNote), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('anon-keyreq-accept')));
    await tester.pumpAndSettle();
    // 密封是纯 Dart 异步运算:放到真实事件循环里跑完
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && sent.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(sent.single['t'], 'anon_agent_key');
    expect(sent.single['circleId'], kCid);
    expect(sent.single['x25519Pub'], 'NYBy1jZYgNGu6jKa35EhODhR7SGijjt16WXQ0s0WYlQ=');
    expect(sent.single['sealed'], isA<String>());
    expect(find.byType(AnonymKeyRequestSheet), findsNothing);
    expect(anon.keyRequest, isNull);
  });

  testWidgets('keyreq sheet: decline sends nothing', (tester) async {
    await tall(tester);
    anon.mediaKeyFor = (_) async => 'cd' * 32;
    await tester.pumpWidget(localizedApp(
        AnonymRoomHost(anonym: anon, child: const Scaffold(body: SizedBox()))));
    anon.handle({
      't': 'anon_agent_keyreq', 'circleId': kCid,
      'x25519Pub': 'NYBy1jZYgNGu6jKa35EhODhR7SGijjt16WXQ0s0WYlQ=',
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('anon-keyreq-decline')));
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
    expect(anon.keyRequest, isNull);
    expect(find.byType(AnonymKeyRequestSheet), findsNothing);
  });

  testWidgets('dismiss confirm sends anon_agent_dismiss', (tester) async {
    await tall(tester);
    await tester.pumpWidget(localizedApp(Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => confirmAnonymDismiss(context, anon),
          child: const Text('go'),
        ),
      ),
    )));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('请炉灵离开?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('anon-dismiss-confirm')));
    await tester.pumpAndSettle();
    expect(sent.single, {'t': 'anon_agent_dismiss', 'circleId': kCid});
  });

  testWidgets('no copy says the server processes what is said', (tester) async {
    await tall(tester);
    await tester.pumpWidget(localizedScaffold(
        AnonymConveneSheet(anonym: anon, presentCount: 3)));
    expect(find.textContaining('服务器内存'), findsNothing);
    await tester.pumpWidget(localizedScaffold(
        AnonymConveneSheet(anonym: anon, presentCount: 3), locale: const Locale('en')));
    expect(find.textContaining('server memory'), findsNothing);
    expect(find.textContaining('The AI joins as a member'), findsOneWidget);
  });
}
