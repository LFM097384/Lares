// 聊天:AI 助手(u_ai_*)发的消息名字旁有「AI」;以「…」结尾(被打断)跟淡色「(被打断)」。
// 真人消息以「…」结尾不加;机器人(bot:)仍是「机器人」徽标。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/chat/chat_envelope.dart';
import 'package:lares_app/src/chat/chat_service.dart';
import 'package:lares_app/src/chat/chat_transport.dart';
import 'package:lares_app/src/theme/theme.dart';
import 'package:lares_app/src/ui/chat_panel.dart';

import 'helpers/localized_app.dart';

class _T implements ChatTransport {
  final StreamController<ChatInboundFrame> c =
      StreamController<ChatInboundFrame>.broadcast();
  @override
  Future<void> send(Uint8List frame) async {}
  @override
  Stream<ChatInboundFrame> get inbound => c.stream;
  @override
  Future<void> dispose() async => c.close();
}

Map<String, dynamic> _text(String id, String sid, String sn, String body) =>
    <String, dynamic>{
      'v': 1,
      't': 'text',
      'id': id,
      'sid': sid,
      'sn': sn,
      'cid': 'home',
      'ts': 1700000000000,
      'body': body,
    };

void main() {
  Future<(ChatService, _T)> pump(WidgetTester tester,
      List<(String, Map<String, dynamic>)> frames, {ThemeData? theme}) async {
    final t = _T();
    final s = ChatService(
      transport: t,
      userId: 'me',
      userNameGetter: () => '我',
      circleIdGetter: () => 'home',
    );
    await tester.pumpWidget(localizedApp(
        Scaffold(body: ChatPanel(chat: s, initiallyExpanded: true)),
        theme: theme));
    for (final (who, h) in frames) {
      t.c.add(ChatInboundFrame(senderIdentity: who, bytes: encodeFrame(h)));
    }
    await tester.pump();
    await tester.pump();
    return (s, t);
  }

  Future<void> done(WidgetTester tester, (ChatService, _T) r) async {
    await tester.pumpWidget(const SizedBox());
    r.$1.dispose();
    await r.$2.dispose();
  }

  testWidgets('AI 的消息有「AI」标签;完整回答不带「(被打断)」', (tester) async {
    final r = await pump(tester, [
      ('u_ai_c1', _text('m1', 'u_ai_c1', '小助手', '明天下午三点。')),
    ]);
    expect(find.byKey(const ValueKey('chat-ai-badge')), findsOneWidget);
    expect(find.text('AI'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-bot-badge')), findsNothing);
    expect(find.byKey(const ValueKey('chat-ai-interrupted')), findsNothing);
    expect(find.textContaining('(被打断)', findRichText: true), findsNothing);
    await done(tester, r);
  });

  testWidgets('AI 被打断(以「…」结尾):跟「(被打断)」', (tester) async {
    final r = await pump(tester, [
      ('u_ai_c1', _text('m1', 'u_ai_c1', '小助手', '明天下午三点,我们先…')),
    ], theme: LaresTheme.light());
    expect(find.byKey(const ValueKey('chat-ai-interrupted')), findsOneWidget);
    expect(find.textContaining('明天下午三点,我们先… (被打断)', findRichText: true),
        findsOneWidget);
    await done(tester, r);
  });

  testWidgets('真人以「…」结尾:不加标签、不加「(被打断)」', (tester) async {
    final r = await pump(tester, [
      ('u1', _text('m1', 'u1', '小鹿', '我想想…')),
    ]);
    expect(find.byKey(const ValueKey('chat-ai-badge')), findsNothing);
    expect(find.byKey(const ValueKey('chat-ai-interrupted')), findsNothing);
    expect(find.text('我想想…'), findsOneWidget);
    await done(tester, r);
  });
}
