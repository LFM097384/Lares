import '../chat/chat_message.dart';

/// 过滤掉被屏蔽者的消息。键是稳定的 senderId,不是可改的昵称。
///
/// 刻意做成**纯函数**:不碰 I/O、不持状态,单测里塞一个闭包谓词就能跑,
/// 不需要 SharedPreferences、不需要 ChatService,也就不会有异步时序的坑。
///
/// [isBlocked] 由调用方注入(通常是 `BlockStore.isBlocked`)。
/// 自己发的消息(`isMine == true`)永远不过滤 —— 屏蔽不了自己,
/// 而且真把自己的话吞了,用户只会以为是发送失败。
List<ChatMessage> filterBlocked(
  List<ChatMessage> messages,
  bool Function(String senderId) isBlocked,
) {
  return <ChatMessage>[
    for (final ChatMessage m in messages)
      if (m.isMine || !isBlocked(m.senderId)) m,
  ];
}
