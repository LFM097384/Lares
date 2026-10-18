import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/anonym/anonym_controller.dart';
import 'package:lares_app/src/anonym/anonym_crypto.dart';
import 'package:lares_app/src/anonym/anonym_gate.dart';
import 'package:lares_app/src/anonym/anonym_kit.dart';
import 'package:lares_app/src/anonym/anonym_room.dart';
import 'package:lares_app/src/anonym/anonym_sheets.dart';

import '../helpers/localized_app.dart';
import 'anonym_controller_test.dart' show draftMsg, kCid, state;

const String kDisclosure =
    '本阶段：原话经 Lares 服务器内存与云端识别/大模型（阿里云、DeepSeek）处理，不存储、不写日志、散会即焚；运营方无法被技术性排除';

void main() {
  late List<Map<String, Object?>> sent;
  late AnonymController anon;

  setUp(() {
    sent = [];
    anon = AnonymController(
      send: sent.add,
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
    expect(find.text(kRuleEn), findsOneWidget);
    expect(find.text(kRuleZh), findsOneWidget);
    expect(find.text('受 Chatham House 规则启发 · 非官方'), findsOneWidget);
    expect(find.text('与 Chatham House 无隶属'), findsOneWidget);
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
    expect(sent.single, {'t': 'anon_start', 'circleId': kCid, 'k': 2});
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
    anon.handle(state());
    await tester.pumpAndSettle();
    expect(find.text('圈主 发起了隐名之约'), findsOneWidget);
    expect(find.text(kDisclosure), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('anon-consent-accept')));
    await tester.pumpAndSettle();
    expect(sent.single['t'], 'anon_ack');
    expect(anon.acked, isTrue);
    // 同一场不再弹第二次
    anon.handle(state(meAcked: true));
    await tester.pumpAndSettle();
    expect(find.byType(AnonymConsentSheet), findsNothing);
  });

  testWidgets('consent decline keeps me in room as 未加入, no ack', (tester) async {
    await tall(tester);
    await tester.pumpWidget(localizedApp(AnonymRoomHost(
        anonym: anon,
        child: Scaffold(body: AnonymRoomBand(anonym: anon)))));
    anon.handle(state());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('anon-consent-decline')));
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
    expect(anon.declined, isTrue);
    expect(find.byKey(const ValueKey('anon-declined-note')), findsOneWidget);
    expect(find.text('我 · 未加入'), findsOneWidget);
    expect(find.byKey(const ValueKey('anon-ask')), findsNothing);
  });

  testWidgets('band shows label, ack status, ask AI panel marked 不留痕', (tester) async {
    await tall(tester);
    await tester.pumpWidget(localizedScaffold(AnonymRoomBand(anonym: anon)));
    expect(find.byKey(const ValueKey('anon-band')), findsNothing);
    anon.handle(state());
    anon.accept();
    anon.handle(state(meAcked: true));
    await tester.pump();
    expect(find.textContaining('RULE-INSPIRED', findRichText: true), findsOneWidget);
    expect(find.textContaining('隐名之约 · 非官方', findRichText: true), findsOneWidget);
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
    expect(sent.last, {'t': 'anon_ask', 'circleId': kCid, 'question': '大家主要分歧?'});
    expect(find.byKey(const ValueKey('anon-thinking')), findsOneWidget);
    anon.handle({'t': 'anon_answer', 'circleId': kCid, 'askerName': '我', 'question': '大家主要分歧?', 'answer': '在预算节奏上'});
    await tester.pump();
    expect(find.text('在预算节奏上'), findsWidgets);
    // 散会 → 面板自己关
    anon.handle({'t': 'anon_ended', 'circleId': kCid, 'receipt': {'sha256': 'x'}});
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('anon-ask-sheet')), findsNothing);
    expect(find.byKey(const ValueKey('anon-band')), findsNothing);
  });

  testWidgets('gate review: roleRisk tag + actions, metrics only if given, approve, release copy',
      (tester) async {
    await tall(tester);
    anon.handle(state());
    anon.accept();
    anon.handle(draftMsg());
    sent.clear();
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
    expect(sent.last['action'], 'cut');
    expect(find.text('0 / 2 已同意放行'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('anon-approve')));
    await tester.pump();
    expect(sent.last['t'], 'anon_approve');
    expect(find.text('你已同意,等其他人'), findsOneWidget);
    anon.handle({'t': 'anon_approvals', 'circleId': kCid, 'draftId': 'd1', 'count': 2, 'k': 2});
    anon.handle({'t': 'anon_released', 'circleId': kCid, 'draftId': 'd1', 'text': '预算该砍。'});
    await tester.pump();
    expect(find.byKey(const ValueKey('anon-released')), findsOneWidget);
    expect(find.byKey(const ValueKey('anon-approve')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('anon-copy-released')));
    await tester.pump();
    expect(clip, '预算该砍。');
  });

  testWidgets('gate without metrics hides the metrics block', (tester) async {
    await tall(tester);
    anon.handle(state());
    anon.accept();
    anon.handle({
      't': 'anon_draft', 'circleId': kCid,
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
    anon.handle(state());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('anon-consent-accept')));
    await tester.pumpAndSettle();
    anon.handle({'t': 'anon_released', 'circleId': kCid, 'draftId': 'd1', 'text': '出门的话'});
    final sha = 'ab12' * 16;
    anon.handle({
      't': 'anon_ended', 'circleId': kCid,
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
    anon.handle(state());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('anon-consent-decline')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('anon-band')), findsOneWidget);
    anon.handle({
      't': 'anon_ended', 'circleId': kCid,
      'receipt': {'counts': {'utterances': 9}, 'sha256': 'ab12' * 16},
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('anon-end-card')), findsNothing);
    expect(find.byKey(const ValueKey('anon-band')), findsNothing);
    expect(anon.active, isFalse);
  });

  testWidgets('end confirm dialog sends anon_end', (tester) async {
    await tall(tester);
    anon.handle(state(convener: 'me'));
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
    expect(sent.last, {'t': 'anon_end', 'circleId': kCid});
  });

  testWidgets('English locale renders without the Chinese labels leaking', (tester) async {
    await tall(tester);
    await tester.pumpWidget(localizedScaffold(
        AnonymConveneSheet(anonym: anon, presentCount: 3),
        locale: const Locale('en')));
    expect(find.text('Inspired by the Chatham House Rule · Unofficial'), findsOneWidget);
    expect(find.text('Not affiliated with Chatham House'), findsOneWidget);
    expect(find.textContaining('under the Rule'), findsNothing);
  });
}
