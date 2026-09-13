import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/chat/chat_envelope.dart';
import 'package:lares_app/src/chat/chat_limits.dart';
import 'package:lares_app/src/chat/chat_message.dart';
import 'package:lares_app/src/chat/chat_service.dart';
import 'package:lares_app/src/chat/chat_transport.dart';

/// 假传输:记录发出的帧,可控地在第 N 次发送起失败;入站用 broadcast 流手工投递。
class FakeTransport implements ChatTransport {
  final List<Uint8List> sent = <Uint8List>[];
  final StreamController<ChatInboundFrame> _c =
      StreamController<ChatInboundFrame>.broadcast();

  /// 从第几次 send 开始失败;null 表示永不失败
  int? failFromIndex;

  @override
  Future<void> send(Uint8List frame) async {
    final int? limit = failFromIndex;
    if (limit != null && sent.length >= limit) {
      throw StateError('未进房');
    }
    sent.add(frame);
  }

  @override
  Stream<ChatInboundFrame> get inbound => _c.stream;

  @override
  Future<void> dispose() async {
    if (!_c.isClosed) await _c.close();
  }

  void deliver(String identity, Uint8List bytes) {
    if (!_c.isClosed) {
      _c.add(ChatInboundFrame(senderIdentity: identity, bytes: bytes));
    }
  }
}

/// 入站流是异步的,断言前必须把微任务/事件队列抽干
Future<void> pump([int times = 8]) async {
  for (int i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// 确定性 id 生成器
String Function() seqIds(String prefix) {
  int i = 0;
  return () => '$prefix-${i++}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final DateTime ts = DateTime.fromMillisecondsSinceEpoch(1700000000000);

  /// 建一个服务并登记清理(ChatService 内部的 ImageAssembler 会起真实 Timer,
  /// 必须 dispose,否则测试结束时定时器泄漏)
  ChatService buildService(
    FakeTransport t, {
    String userId = 'ua',
    String userName = '甲',
    String circleId = 'home',
    String idPrefix = 'm',
  }) {
    final ChatService s = ChatService(
      transport: t,
      userId: userId,
      userName: userName,
      circleIdGetter: () => circleId,
      idGenerator: seqIds(idPrefix),
      now: () => ts,
    );
    addTearDown(() async {
      s.dispose();
      await t.dispose();
    });
    return s;
  }

  group('发送', () {
    test('超限拒发:抛 ChatImageTooLargeError 且一个包都不发', () async {
      final FakeTransport t = FakeTransport();
      final ChatService s = buildService(t);

      final Uint8List big = Uint8List(maxImageBytes + 1);
      await expectLater(
        s.sendImage(big),
        throwsA(isA<ChatImageTooLargeError>()),
      );

      expect(t.sent, isEmpty); // 零发送
      expect(s.messages, isEmpty); // 不留下消息

      // 错误对象带上真实数值,便于 UI 提示
      try {
        await s.sendImage(big);
        fail('应当抛出');
      } on ChatImageTooLargeError catch (e) {
        expect(e.bytes, maxImageBytes + 1);
        expect(e.limit, maxImageBytes);
      }

      // 恰好等于上限则放行
      await s.sendImage(Uint8List(maxImageBytes));
      expect(t.sent, isNotEmpty);
    });

    test('空消息拒发:空串与纯空白既不入列也不发包', () async {
      final FakeTransport t = FakeTransport();
      final ChatService s = buildService(t);

      await s.sendText('');
      await s.sendText('   ');
      await s.sendText('\n\t ');

      expect(s.messages, isEmpty);
      expect(t.sent, isEmpty);
    });

    test('发送成功态:乐观回显后翻为 sent', () async {
      final FakeTransport t = FakeTransport();
      final ChatService s = buildService(t);

      await s.sendText('  你好  '); // 顺带验证 trim

      expect(s.messages.length, 1);
      final ChatMessage m = s.messages.single;
      expect(m.kind, ChatMessageKind.text);
      expect(m.text, '你好');
      expect(m.isMine, isTrue);
      expect(m.senderId, 'ua');
      expect(m.state, ChatDeliveryState.sent);
      expect(t.sent.length, 1);
      expect(s.unreadCount, 0); // 自己发的不计未读
    });

    test('发送失败态:不抛异常,消息标记 failed', () async {
      final FakeTransport t = FakeTransport()..failFromIndex = 0;
      final ChatService s = buildService(t);

      await s.sendText('发不出去'); // 不应抛

      expect(s.messages.length, 1);
      expect(s.messages.single.state, ChatDeliveryState.failed);
      expect(t.sent, isEmpty);
    });

    test('图片中途失败:标记 failed 并中止余下分片', () async {
      final FakeTransport t = FakeTransport()..failFromIndex = 2;
      final ChatService s = buildService(t);

      // 30 KB -> 3 片,第 3 片(下标 2)开始失败
      final Uint8List bytes =
          Uint8List.fromList(List<int>.generate(30 * 1024, (int i) => i % 251));
      await s.sendImage(bytes); // 不应抛

      expect(t.sent.length, 2); // 只发出前两片,余下中止
      expect(s.messages.length, 1);
      expect(s.messages.single.state, ChatDeliveryState.failed);
      expect(s.messages.single.kind, ChatMessageKind.image);
    });
  });

  group('接收', () {
    test('端到端:文字+图片跨端送达、未读计数、自己的消息不重复', () async {
      final FakeTransport ta = FakeTransport();
      final FakeTransport tb = FakeTransport();
      final ChatService a =
          buildService(ta, userId: 'ua', userName: '甲', idPrefix: 'a');
      final ChatService b =
          buildService(tb, userId: 'ub', userName: '乙', idPrefix: 'b');

      const String body = '晚上一起吃饭吗';
      final Uint8List image =
          Uint8List.fromList(List<int>.generate(30 * 1024, (int i) => (i * 7) % 251));

      await a.sendText(body);
      await a.sendImage(image, width: 120, height: 90);

      // A 的出站全部转投到 B 的入站
      for (final Uint8List frame in ta.sent) {
        tb.deliver('ua', frame);
      }
      await pump();

      // B 两条都收到,发送者昵称正确
      expect(b.messages.length, 2);
      final ChatMessage bText = b.messages
          .firstWhere((ChatMessage m) => m.kind == ChatMessageKind.text);
      expect(bText.text, body);
      expect(bText.senderName, '甲');
      expect(bText.senderId, 'ua');
      expect(bText.isMine, isFalse);

      final ChatMessage bImage = b.messages
          .firstWhere((ChatMessage m) => m.kind == ChatMessageKind.image);
      expect(bImage.senderName, '甲');
      expect(bImage.imageBytes, equals(image)); // 逐字节一致
      expect(bImage.imageWidth, 120);
      expect(bImage.imageHeight, 90);
      expect(bImage.state, ChatDeliveryState.sent);

      // 未读:入站两条计 2,markRead 归零
      expect(b.unreadCount, 2);
      b.markRead();
      expect(b.unreadCount, 0);

      // A 自己只各留一份,没有被回显重复计数
      expect(a.messages.length, 2);
      expect(a.unreadCount, 0);

      // 把 A 自己的帧回灌给 A:sid == 自己,应被忽略
      for (final Uint8List frame in ta.sent) {
        ta.deliver('ua', frame);
      }
      await pump();
      expect(a.messages.length, 2); // 仍是两条
      expect(a.unreadCount, 0);
    });

    test('未知版本与未知类型的入站帧被静默忽略', () async {
      final FakeTransport t = FakeTransport();
      final ChatService s = buildService(t, userId: 'ub', userName: '乙');

      t.deliver(
        'ua',
        encodeFrame(<String, dynamic>{
          'v': 99,
          't': 'text',
          'id': 'z',
          'sid': 'ua',
          'body': 'x',
        }),
      );
      t.deliver(
        'ua',
        encodeFrame(<String, dynamic>{
          'v': 1,
          't': 'video',
          'id': 'z2',
          'sid': 'ua',
        }),
      );
      // 结构坏帧
      t.deliver('ua', Uint8List.fromList(<int>[1, 2]));
      await pump();

      expect(s.messages, isEmpty);
      expect(s.unreadCount, 0);
    });

    test('入站文字重复 id 去重', () async {
      final FakeTransport t = FakeTransport();
      final ChatService s = buildService(t, userId: 'ub', userName: '乙');

      final Uint8List frame = encodeFrame(buildTextHeader(
        id: 'dup-1',
        senderId: 'ua',
        senderName: '甲',
        circleId: 'home',
        timestamp: ts,
        body: '只该出现一次',
      ));
      t.deliver('ua', frame);
      t.deliver('ua', frame);
      await pump();

      expect(s.messages.length, 1);
      expect(s.unreadCount, 1);
    });
  });
}
