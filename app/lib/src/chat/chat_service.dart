import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../moderation/blocked_message_filter.dart';
import 'chat_envelope.dart';
import 'chat_limits.dart';
import 'chat_message.dart';
import 'chat_text.dart';
import 'chat_transport.dart';
import 'frame_registry.dart';
import 'image_assembler.dart';

/// 图片超过 [maxImageBytes] 时抛出。
///
/// 这是**前置条件**违约(调用方本就该先压缩),因此直接抛给调用方,
/// 且保证一个包都没发出去 —— 与「发到一半网断了」是两回事,见 [ChatService.sendImage]。
class ChatImageTooLargeError implements Exception {
  /// [bytes] 实际大小,[limit] 上限
  const ChatImageTooLargeError(this.bytes, this.limit);

  /// 实际字节数
  final int bytes;

  /// 允许的上限字节数
  final int limit;

  @override
  String toString() => '图片 $bytes 字节,超过上限 $limit 字节';
}

/// 文字+图片消息服务(设计.md §3 轻交互)。
///
/// **纯内存、易逝**:不落盘、不上服务器、进程退出即烟消云散,
/// 与「语音便签听过即删」的克制感一致(设计.md §2.1)。
///
/// 刻意不持有 `RoomController`,只依赖 [ChatTransport] 抽象:
/// LiveKit 的 `Room` 被私有持有在 `lib/src/rtc/livekit_rtc_service.dart`,
/// 解耦后本类可在无 LiveKit 的环境里完整单测。
class ChatService extends ChangeNotifier {
  /// [circleIdGetter] 每次发送时现取当前圈子 id,避免缓存过期的圈子。
  /// [idGenerator] 仅供单测注入确定性 id。
  /// [isBlocked] 屏蔽判定(通常传 `BlockStore.isBlocked`);不传即不过滤任何人。
  ChatService({
    required ChatTransport transport,
    required this.userId,
    required this.userName,
    required String Function() circleIdGetter,
    String Function()? idGenerator,
    DateTime Function()? now,
    bool Function(String senderId)? isBlocked,
  })  : _transport = transport,
        _circleIdGetter = circleIdGetter,
        _now = now ?? DateTime.now,
        _idGenerator = idGenerator,
        _isBlocked = isBlocked {
    _assembler = ImageAssembler(
      onImage: _onImageAssembled,
      onFailure: _onImageFailed,
      now: _now,
    );
    // 内核自带的两种类型也走注册表,和将来的插件走同一条路 ——
    // 「自己不吃狗粮的插件系统一定是残废的」。
    // 见 docs/plans/plugin-protocol.md。
    frames
      ..register(chatTypeText, (f) => _onTextFrame(f.header))
      ..register(chatTypeImage, (f) => _assembler.addChunk(f.header, f.payload));
    _sub = _transport.inbound.listen(_onFrame);
  }

  /// 帧类型注册表。内核的 text / img 已注册好;插件在这里挂自己的类型。
  ///
  /// 暴露成 public 是为了让上层(将来的 PluginHost)能注册,但
  /// **只能注册,拿不到密钥** —— 处理器收到的 [IncomingFrame] 已经解密完毕。
  /// 这是「即使插件是恶意的,也只能泄露它经手的那一条」的前提。
  final FrameRegistry frames = FrameRegistry();

  final ChatTransport _transport;

  /// 本端用户 id,用于「忽略自己的消息」与生成消息 id
  final String userId;

  /// 本端昵称,随帧发出,接收端直接显示
  final String userName;

  final String Function() _circleIdGetter;
  final DateTime Function() _now;
  final String Function()? _idGenerator;

  /// 屏蔽谓词。null 表示没接屏蔽功能(老调用方、单测),一律不过滤。
  final bool Function(String senderId)? _isBlocked;

  /// 随帧发出的昵称长度上限(字素簇)。
  ///
  /// 为什么必须卡:`encodeFrame` **不校验** [maxPacketBytes],
  /// `publishData` 也不校验 —— 超长帧只会在 SCTP 层**静默失败**,查都难查。
  /// 图片分片帧的预算:15000 - 12288(载荷) - 4(长度前缀) = 2708 字节留给 JSON header。
  /// 昵称是用户可控字段,一个 emoji 昵称最坏每字素簇约 25 字节 UTF-8 + JSON 转义,
  /// 32 簇 ≈ 800 字节,连同 id/圈子 id/固定键仍稳落在 2708 以内。
  static const int _maxSenderNameGraphemes = 32;

  /// 截断后的昵称,发送路径统一用它
  String get _wireName => capGraphemes(userName, _maxSenderNameGraphemes);

  late final ImageAssembler _assembler;
  StreamSubscription<ChatInboundFrame>? _sub;

  final List<ChatMessage> _messages = <ChatMessage>[];
  final Random _random = Random();
  int _seqCounter = 0;
  int _unread = 0;
  bool _disposed = false;

  /// 历史消息,新的在后。不可变视图,UI 直接倒序渲染即可。
  List<ChatMessage> get messages => List<ChatMessage>.unmodifiable(_messages);

  /// 过滤掉屏蔽者之后的消息,UI 应该渲染这个而不是 [messages]。
  ///
  /// 刻意在**读取时**过滤,而不是在 [_append] 时丢弃:
  /// 收进来的一条不落,解除屏蔽后历史会原样回来,不会出现「解封了却还是一片空白」。
  /// 未构造时没传屏蔽谓词的话,它和 [messages] 完全等价。
  List<ChatMessage> get visibleMessages {
    final bool Function(String senderId)? blocked = _isBlocked;
    if (blocked == null) return messages;
    return List<ChatMessage>.unmodifiable(filterBlocked(_messages, blocked));
  }

  /// 未读条数。只统计**入站**消息;本人发的不算未读。
  int get unreadCount => _unread;

  /// 清零未读。面板打开时调一次,打开期间每来一条再调一次。
  void markRead() {
    if (_unread == 0) return;
    _unread = 0;
    notifyListeners();
  }

  /// 生成消息 id:`userId-微秒-自增序号-随机`。
  ///
  /// 不引第三方 uuid 包(不新增依赖)。三段各司其职:
  /// `userId` 保证跨设备不撞;自增序号保证同一微秒内连发不撞
  /// (低精度平台上 `microsecondsSinceEpoch` 会重复);随机段兜底。
  String _newId() {
    final String? injected = _idGenerator?.call();
    if (injected != null) return injected;
    final int seq = _seqCounter++;
    final int salt = _random.nextInt(1 << 20);
    return '$userId-${_now().microsecondsSinceEpoch}-$seq-$salt';
  }

  /// 发送文字。空/纯空白直接拒发;超长按字素簇截断(不切碎 emoji)。
  ///
  /// 传输失败只把该条标为 [ChatDeliveryState.failed],**不抛异常** ——
  /// 网络抖动是常态,不该让 UI 每次都套 try/catch。
  Future<void> sendText(String raw) async {
    final String? body = normalizeOutgoing(raw);
    if (body == null) return; // 空消息:静默拒发
    final String text = capGraphemes(body, maxTextGraphemes);

    final DateTime ts = _now();
    final String id = _newId();
    final String circleId = _circleIdGetter();

    _append(
      ChatMessage.text(
        id: id,
        senderId: userId,
        senderName: _wireName,
        circleId: circleId,
        timestamp: ts,
        body: text,
        state: ChatDeliveryState.sending,
        isMine: true,
      ),
      countUnread: false,
    );

    final Uint8List frame = encodeFrame(
      buildTextHeader(
        id: id,
        senderId: userId,
        senderName: _wireName,
        circleId: circleId,
        timestamp: ts,
        body: text,
      ),
    );

    try {
      await _transport.send(frame);
      _setState(id, ChatDeliveryState.sent);
    } catch (_) {
      _setState(id, ChatDeliveryState.failed);
    }
  }

  /// 发送图片。超过 [maxImageBytes] **发送前**就抛 [ChatImageTooLargeError],
  /// 一个包都不发(调用方应先压到 [targetImageBytes] 附近)。
  ///
  /// 否则按 [imageChunkPayloadBytes] 切片,逐片可靠发送;
  /// 本地先乐观回显,发送者立刻看得见自己的图。
  /// 中途失败即中止余下分片(继续发只是浪费带宽,接收端照样凑不齐),
  /// 标记 failed 但不抛 —— 与 [sendText] 一致。
  Future<void> sendImage(
    Uint8List bytes, {
    int? width,
    int? height,
    String mime = 'image/png',
  }) async {
    if (bytes.length > maxImageBytes) {
      throw ChatImageTooLargeError(bytes.length, maxImageBytes);
    }
    if (bytes.isEmpty) return;

    final DateTime ts = _now();
    final String id = _newId();
    final String circleId = _circleIdGetter();

    // 乐观回显:本地立刻可见,不等对端确认
    _append(
      ChatMessage.image(
        id: id,
        senderId: userId,
        senderName: _wireName,
        circleId: circleId,
        timestamp: ts,
        bytes: bytes,
        imageWidth: width,
        imageHeight: height,
        state: ChatDeliveryState.sending,
        isMine: true,
      ),
      countUnread: false,
    );

    final int total = bytes.length;
    // 向上取整:最后一片通常不满
    final int n = (total + imageChunkPayloadBytes - 1) ~/ imageChunkPayloadBytes;

    for (int seq = 0; seq < n; seq++) {
      final int start = seq * imageChunkPayloadBytes;
      final int end = min(start + imageChunkPayloadBytes, total);
      final Uint8List slice = Uint8List.sublistView(bytes, start, end);
      final Uint8List frame = encodeFrame(
        buildImageChunkHeader(
          id: id,
          senderId: userId,
          senderName: _wireName,
          circleId: circleId,
          timestamp: ts,
          seq: seq,
          totalChunks: n,
          totalBytes: total,
          width: width,
          height: height,
          mime: mime,
        ),
        slice,
      );
      try {
        await _transport.send(frame);
      } catch (_) {
        _setState(id, ChatDeliveryState.failed);
        return; // 中止余下分片
      }
    }
    _setState(id, ChatDeliveryState.sent);
  }

  /// 入站帧分发。任何看不懂的帧一律静默忽略,绝不让远端把本端搞崩。
  void _onFrame(ChatInboundFrame frame) {
    if (_disposed) return;
    final ChatFrame decoded = decodeFrame(frame.bytes);
    // invalid(结构坏)与 unsupportedVersion(未来版本)都直接丢弃
    if (!decoded.isOk) return;

    final Map<String, dynamic> h = decoded.header;
    final Object? sid = h['sid'];
    // 忽略自己的消息:本地已乐观回显,再收一次会重复
    if (sid is String && sid == userId) return;

    // 未知类型不是错误:对方可能装了我们没有的插件。
    // dispatch 返回 false 即无人认领,静默丢弃 —— 这是向前兼容的正确姿态。
    frames.dispatch(
      IncomingFrame(
        type: decoded.type,
        header: h,
        payload: decoded.payload,
      ),
    );
  }

  void _onTextFrame(Map<String, dynamic> h) {
    final String id = _stringOf(h, 'id');
    final Object? bodyRaw = h['body'];
    if (id.isEmpty || bodyRaw is! String) return;
    if (_messages.any((ChatMessage m) => m.id == id)) return; // 去重

    _append(
      ChatMessage.text(
        id: id,
        senderId: _stringOf(h, 'sid'),
        senderName: _stringOf(h, 'sn'),
        circleId: _stringOf(h, 'cid'),
        timestamp: _timeOf(h),
        body: bodyRaw,
      ),
      countUnread: true,
    );
  }

  /// 图片在**重组完成**时才计未读:分片到达是传输细节,用户看不见。
  void _onImageAssembled(AssembledImage img) {
    if (_disposed) return;
    if (_messages.any((ChatMessage m) => m.id == img.id)) return;
    _append(
      ChatMessage.image(
        id: img.id,
        senderId: img.senderId,
        senderName: img.senderName,
        circleId: img.circleId,
        timestamp: img.timestamp,
        bytes: img.bytes,
        imageWidth: img.width,
        imageHeight: img.height,
      ),
      countUnread: true,
    );
  }

  /// 重组失败:放一条 failed 的图片占位,让用户知道「有张图没收到」,
  /// 而不是无声无息。占位不计未读(没内容可读)。
  void _onImageFailed(ImageAssemblyError err) {
    if (_disposed) return;
    if (_messages.any((ChatMessage m) => m.id == err.id)) return;
    _append(
      ChatMessage(
        id: err.id,
        senderId: err.senderId,
        senderName: err.senderName,
        circleId: err.circleId,
        timestamp: err.timestamp,
        kind: ChatMessageKind.image,
        state: ChatDeliveryState.failed,
      ),
      countUnread: false,
    );
  }

  void _append(ChatMessage m, {required bool countUnread}) {
    _messages.add(m);
    // 超出上限丢最旧的:纯内存态,不做分页
    while (_messages.length > maxHistoryMessages) {
      _messages.removeAt(0);
    }
    if (countUnread) _unread++;
    notifyListeners();
  }

  void _setState(String id, ChatDeliveryState state) {
    final int i = _messages.indexWhere((ChatMessage m) => m.id == id);
    if (i < 0) return; // 已被历史上限挤掉
    _messages[i] = _messages[i].copyWith(state: state);
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_sub?.cancel());
    _sub = null;
    _assembler.dispose();
    _messages.clear();
    // 注册表里的处理器是闭包,持有 this。_onFrame 开头已有 _disposed 闸门,
    // 分发本来也到不了这里;清掉是为了断开引用,别让插件的处理器
    // 拖着一个已销毁的 ChatService 不放。
    // 先拷一份再删:registeredTypes 是底层 Map 的视图,
    // 边遍历边删会抛 ConcurrentModificationError。
    for (final String t in List<String>.of(frames.registeredTypes)) {
      frames.unregister(t);
    }
    super.dispose();
  }
}

/// 从 JSON header 安全取字符串:类型不符返回空串而非抛异常。
/// 远端数据一律不可信,`as String` 会让一个坏帧掀翻整个监听器。
String _stringOf(Map<String, dynamic> h, String key) {
  final Object? raw = h[key];
  return raw is String ? raw : '';
}

DateTime _timeOf(Map<String, dynamic> h) {
  final Object? raw = h['ts'];
  final int ms = raw is int ? raw : (raw is num ? raw.toInt() : 0);
  return DateTime.fromMillisecondsSinceEpoch(ms);
}
