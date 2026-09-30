// 截图脚手架用的假聊天服务(与 chat_panel_test.dart 里的 FakeChatService 同款,
// 另加 visibleMessages / userId)。不碰 LiveKit、不碰传输层。
import 'package:flutter/foundation.dart';
import 'package:lares_app/src/chat/chat_message.dart';
import 'package:lares_app/src/chat/chat_service.dart';

class ShotsChatService extends ChangeNotifier implements ChatService {
  ShotsChatService({this.userId = 'u_me'});

  @override
  final String userId;

  final List<ChatMessage> _messages = <ChatMessage>[];
  int _unread = 0;

  @override
  List<ChatMessage> get messages => List<ChatMessage>.unmodifiable(_messages);

  @override
  List<ChatMessage> get visibleMessages => messages;

  @override
  int get unreadCount => _unread;

  @override
  void markRead() {
    if (_unread == 0) return;
    _unread = 0;
    notifyListeners();
  }

  @override
  Future<void> sendText(String raw) async {
    _messages.add(ChatMessage.text(
      id: 'm${_messages.length}',
      senderId: userId,
      senderName: '我',
      circleId: 'home',
      timestamp: DateTime(2026, 1, 1, 9, 5),
      body: raw,
      isMine: true,
    ));
    notifyListeners();
  }

  @override
  Future<void> sendImage(
    Uint8List bytes, {
    int? width,
    int? height,
    String mime = 'image/png',
  }) async {
    _messages.add(ChatMessage.image(
      id: 'm${_messages.length}',
      senderId: userId,
      senderName: '我',
      circleId: 'home',
      timestamp: DateTime(2026, 1, 1, 9, 6),
      bytes: bytes,
      imageWidth: width,
      imageHeight: height,
      isMine: true,
    ));
    notifyListeners();
  }

  void seed(List<ChatMessage> initial, {int unread = 0}) {
    _messages
      ..clear()
      ..addAll(initial);
    _unread = unread;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
