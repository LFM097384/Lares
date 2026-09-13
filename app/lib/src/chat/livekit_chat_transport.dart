import 'dart:async';
import 'dart:typed_data';

import 'package:livekit_client/livekit_client.dart';

import 'chat_limits.dart';
import 'chat_transport.dart';

/// LiveKit 实现:把聊天帧打在 reliable data channel 上(topic = [chatTopic])。
///
/// **当前尚未接线**:`Room` 被私有持有在 `LiveKitRtcService` 内部,
/// 要用本类得先由该服务把 `Room` 暴露出来(或反过来由它构造本类)。
/// 在那之前,本文件只保证自身可编译、可单测。
///
/// 关于分片:livekit_client 2.12.0 其实自带按 `kStreamChunkSize = 15_000`
/// 自动切片的字节流 API(`localParticipant.streamBytes` /
/// `room.registerByteStreamHandler`,并带 `waitForBufferStatusLow` 背压)。
/// 这里仍手写分片是有意为之,因为该 API 目前有两个坑:
/// 1. `ByteStreamReader.readAll()` 把分片收进 `Set<Uint8List>`,
///    **不按 `chunkIndex` 重排**(只有 `TextStreamReader` 按 index 归位)
///    —— 乱序到达即数据损坏;
/// 2. `registerByteStreamHandler` 对同一 topic 重复注册会抛
///    `DataStreamError(HandlerAlreadyRegistered)` 而非替换,重连/热重载下很脆。
/// `streamBytes` 是未来的迁移路径,待上述两个 SDK 问题修复后可切换。
class LiveKitChatTransport implements ChatTransport {
  /// 绑定一个已建立的 [Room],并立即挂上 data 事件监听。
  LiveKitChatTransport(this._room) {
    _listener = _room.createListener();
    _cancel = _listener.on<DataReceivedEvent>(_onData);
  }

  final Room _room;
  late final EventsListener<RoomEvent> _listener;
  CancelListenFunc? _cancel;
  final StreamController<ChatInboundFrame> _controller =
      StreamController<ChatInboundFrame>.broadcast();
  bool _disposed = false;

  void _onData(DataReceivedEvent e) {
    if (_disposed || _controller.isClosed) return;

    // topic 声明为 String?,但 SDK 实际到达的是**空串**而非 null,
    // 所以绝不能写 `e.topic == null` 来判「未设置」。
    final String topic = e.topic ?? '';
    if (topic != chatTopic) return;

    // 无法归因发送方的帧直接丢弃:上层要靠 identity 过滤掉自己的消息,
    // 拿不到 identity 就没法保证这条语义。
    final String identity = e.participant?.identity ?? '';
    if (identity.isEmpty) return;

    // 注意 `e.data` 是 `List<int>` 而不是 `Uint8List`,必须转一道。
    _controller.add(
      ChatInboundFrame(
        senderIdentity: identity,
        bytes: Uint8List.fromList(e.data),
      ),
    );
  }

  @override
  Stream<ChatInboundFrame> get inbound => _controller.stream;

  @override
  Future<void> send(Uint8List frame) async {
    final LocalParticipant? lp = _room.localParticipant;
    // 抛而不是静默返回:让 ChatService 能把这条消息标记为「发送失败」。
    if (lp == null) throw StateError('未进房,无法发送聊天消息');
    // `reliable` 是 `bool?` 且**无默认值**,不传即 LOSSY,必须显式为 true。
    await lp.publishData(frame, reliable: true, topic: chatTopic);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return; // 幂等:重复 dispose 不应报错
    _disposed = true;
    await _cancel?.call();
    _cancel = null;
    await _listener.dispose();
    await _controller.close();
  }
}
