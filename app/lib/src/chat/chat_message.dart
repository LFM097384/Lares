import 'dart:typed_data';

/// 消息类型:当前只支持文字与图片(设计.md §3 轻交互)。
enum ChatMessageKind { text, image }

/// 发送态。纯本地态,不做服务端回执。
enum ChatDeliveryState { sending, sent, failed }

/// 一条聊天消息。**只存在于内存**,不落盘、不上服务器,
/// 与「语音便签听过即删」的克制感一致(设计.md §2.1)。
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.circleId,
    required this.timestamp,
    required this.kind,
    this.text,
    this.imageBytes,
    this.imageWidth,
    this.imageHeight,
    this.state = ChatDeliveryState.sent,
    this.isMine = false,
  });

  /// 文字消息便捷构造
  const ChatMessage.text({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.circleId,
    required this.timestamp,
    required String body,
    this.state = ChatDeliveryState.sent,
    this.isMine = false,
  })  : kind = ChatMessageKind.text,
        text = body,
        imageBytes = null,
        imageWidth = null,
        imageHeight = null;

  /// 图片消息便捷构造([bytes] 为已重组完整的图片字节)
  const ChatMessage.image({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.circleId,
    required this.timestamp,
    required Uint8List bytes,
    this.imageWidth,
    this.imageHeight,
    this.state = ChatDeliveryState.sent,
    this.isMine = false,
  })  : kind = ChatMessageKind.image,
        text = null,
        imageBytes = bytes;

  /// 发送端生成的唯一 id,重组与去重都以它为键
  final String id;
  final String senderId;
  final String senderName;
  final String circleId;
  final DateTime timestamp;
  final ChatMessageKind kind;

  /// kind == text 时非空
  final String? text;

  /// kind == image 时非空(已重组的完整图片字节)
  final Uint8List? imageBytes;

  /// 可空,仅用于渲染前的占位比例,避免图片到达时布局跳动
  final int? imageWidth;
  final int? imageHeight;

  final ChatDeliveryState state;

  /// 是否本人发出,决定气泡左右与配色
  final bool isMine;

  ChatMessage copyWith({
    ChatDeliveryState? state,
    Uint8List? imageBytes,
    int? imageWidth,
    int? imageHeight,
  }) =>
      ChatMessage(
        id: id,
        senderId: senderId,
        senderName: senderName,
        circleId: circleId,
        timestamp: timestamp,
        kind: kind,
        text: text,
        imageBytes: imageBytes ?? this.imageBytes,
        imageWidth: imageWidth ?? this.imageWidth,
        imageHeight: imageHeight ?? this.imageHeight,
        state: state ?? this.state,
        isMine: isMine,
      );
}
