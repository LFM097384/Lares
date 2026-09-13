import 'dart:typed_data';

/// 聊天传输抽象(设计.md §8.1 同款思路:业务只依赖接口)。
///
/// **本文件禁止 import livekit_client**:`Room` 被私有持有在
/// `lib/src/rtc/livekit_rtc_service.dart` 里,聊天核心若直接依赖 LiveKit,
/// 就没法在单测里脱离真实房间跑。实现见 `livekit_chat_transport.dart`。
abstract interface class ChatTransport {
  /// 可靠发送一帧(LiveKit reliable data channel)
  Future<void> send(Uint8List frame);

  /// 收到的帧(已剥离 LiveKit 层)
  Stream<ChatInboundFrame> get inbound;

  Future<void> dispose();
}

/// 一帧入站数据:发送方 identity + 原始字节。
/// identity 由传输层给出,不信任帧内自称的 sid,用于「忽略自己的消息」。
class ChatInboundFrame {
  const ChatInboundFrame({required this.senderIdentity, required this.bytes});

  final String senderIdentity;
  final Uint8List bytes;
}
