// 机器人聊天帧(契约 §2):只认服务器发出的(无 participant)+ bot:true + sid 以 bot: 开头;
// 成员冒充一律丢弃。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/chat/chat_envelope.dart';
import 'package:lares_app/src/chat/chat_message.dart';
import 'package:lares_app/src/chat/chat_service.dart';
import 'package:lares_app/src/chat/chat_transport.dart';
import 'package:lares_app/src/chat/livekit_chat_transport.dart';
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

Map<String, dynamic> botHeader(
        {String id = 'b1', String sid = 'bot:tok1', Object? bot = true}) =>
    <String, dynamic>{
      'v': 1,
      't': 'text',
      'id': id,
      'sid': sid,
      'sn': '小助手',
      'cid': 'home',
      'ts': 1700000000000,
      'body': '会议纪要已生成',
      'bot': ?bot,
    };

void main() {
  group('纯函数 chatSenderVerdict / acceptChatFrame', () {
    test('无 participant:必须 bot:true 且 sid 以 bot: 开头', () {
      expect(chatSenderVerdict(senderIdentity: '', header: botHeader()),
          ChatSenderVerdict.bot);
      expect(chatSenderVerdict(senderIdentity: '', header: botHeader(bot: null)),
          ChatSenderVerdict.drop);
      expect(chatSenderVerdict(senderIdentity: '', header: botHeader(sid: 'u1')),
          ChatSenderVerdict.drop);
      expect(chatSenderVerdict(senderIdentity: '', header: botHeader(sid: 'bot:')),
          ChatSenderVerdict.drop);
      expect(chatSenderVerdict(senderIdentity: '', header: botHeader(bot: 'true')),
          ChatSenderVerdict.drop);
      expect(acceptChatFrame('', encodeFrame(botHeader())), isTrue);
      expect(acceptChatFrame('', encodeFrame(botHeader(bot: null))), isFalse);
      expect(acceptChatFrame('', Uint8List.fromList([1, 2])), isFalse);
    });

    test('有 participant 却自称机器人 → 丢弃;普通帧放行', () {
      expect(chatSenderVerdict(senderIdentity: 'u1', header: botHeader()),
          ChatSenderVerdict.drop);
      expect(
          chatSenderVerdict(senderIdentity: 'u1', header: botHeader(bot: null)),
          ChatSenderVerdict.drop,
          reason: 'sid 以 bot: 开头');
      expect(
          chatSenderVerdict(senderIdentity: 'u1', header: botHeader(sid: 'u1')),
          ChatSenderVerdict.drop,
          reason: 'bot:true');
      expect(
          chatSenderVerdict(
              senderIdentity: 'u1', header: botHeader(sid: 'u1', bot: null)),
          ChatSenderVerdict.peer);
    });
  });

  group('ChatService', () {
    Future<(ChatService, _T)> build() async {
      final t = _T();
      final s = ChatService(
        transport: t,
        userId: 'me',
        userNameGetter: () => '我',
        circleIdGetter: () => 'home',
      );
      addTearDown(() async {
        s.dispose();
        await t.dispose();
      });
      return (s, t);
    }

    Future<void> pump() async {
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('服务器发的机器人消息显示为机器人;成员冒充被丢', () async {
      final (s, t) = await build();
      t.c.add(ChatInboundFrame(senderIdentity: '', bytes: encodeFrame(botHeader())));
      t.c.add(ChatInboundFrame(
          senderIdentity: 'u1', bytes: encodeFrame(botHeader(id: 'spoof1'))));
      t.c.add(ChatInboundFrame(
          senderIdentity: 'u1',
          bytes: encodeFrame(botHeader(id: 'spoof2', bot: null))));
      t.c.add(ChatInboundFrame(
          senderIdentity: '', bytes: encodeFrame(botHeader(id: 'x', bot: null))));
      await pump();
      expect(s.messages.length, 1);
      final ChatMessage m = s.messages.single;
      expect(m.isBot, isTrue);
      expect(m.senderName, '小助手');
      expect(m.senderId, 'bot:tok1');
      expect(m.text, '会议纪要已生成');
      expect(s.unreadCount, 1);
    });

    testWidgets('聊天面板:机器人名字旁有「机器人」徽标', (tester) async {
      final t = _T();
      final s = ChatService(
        transport: t,
        userId: 'me',
        userNameGetter: () => '我',
        circleIdGetter: () => 'home',
      );
      await tester.pumpWidget(localizedScaffold(
          ChatPanel(chat: s, initiallyExpanded: true)));
      t.c.add(ChatInboundFrame(senderIdentity: '', bytes: encodeFrame(botHeader())));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('chat-bot-badge')), findsOneWidget);
      expect(find.text('机器人'), findsOneWidget);
      expect(find.text('小助手'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      s.dispose();
      await t.dispose();
    });
  });
}
