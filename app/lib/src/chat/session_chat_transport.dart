/// 会话级传输层的「长命包装」。
///
/// 为什么需要这层:`LiveKitChatTransport` 在构造时就绑定一个 `Room` 并挂事件监听,
/// 而 `LiveKitRtcService.room` **只在 `join()` 与 `leave()` 之间非空**,
/// `leave()` 会把它 dispose 掉。于是传输层天然是**会话级**的,
/// 而 UI 需要的 `ChatService` 是**应用级**的(面板要一直在,历史要留着)。
///
/// 若直接把 `LiveKitChatTransport` 交给 `ChatService`:
/// 1. 启动时 `room` 还是 null,根本构造不出来;
/// 2. 就算延迟构造,退房再进房后旧 `Room` 已被 dispose,监听全部失效 ——
///    且**不会抛任何异常**,表现为「消息发得出去但收不到」,极难排查。
///
/// 所以这里做一个转发层:`ChatService` 一直持有它,它自己跟着房间生命周期
/// 换掉内部的真实传输层。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../rtc/livekit_rtc_service.dart';
import '../state/models.dart';
import '../state/room_controller.dart';
import 'chat_transport.dart';
import 'livekit_chat_transport.dart';

/// 跟随房间生命周期自动重建内部传输层的 [ChatTransport]。
class SessionChatTransport implements ChatTransport {
  SessionChatTransport({
    required LiveKitRtcService rtc,
    required RoomController controller,
    ChatTransport Function(LiveKitRtcService rtc)? factory,
  })  : _rtc = rtc,
        _controller = controller,
        _factory = factory ?? ((r) => LiveKitChatTransport(r.room!)) {
    _controller.addListener(_onPhase);
    _onPhase(); // 可能已在房里(热重载/重连)
  }

  final LiveKitRtcService _rtc;
  final RoomController _controller;
  final ChatTransport Function(LiveKitRtcService rtc) _factory;

  final StreamController<ChatInboundFrame> _out =
      StreamController<ChatInboundFrame>.broadcast();

  ChatTransport? _inner;
  StreamSubscription<ChatInboundFrame>? _innerSub;
  bool _disposed = false;

  @override
  Stream<ChatInboundFrame> get inbound => _out.stream;

  /// 不在房间里时静默丢弃 —— 聊天是副通道,绝不能因为没进房而抛异常
  /// 打断语音主路径;上层已有 failed 态可展示。
  @override
  Future<void> send(Uint8List frame) async {
    final ChatTransport? inner = _inner;
    if (inner == null) {
      throw StateError('未在房间内,消息未发送');
    }
    await inner.send(frame);
  }

  void _onPhase() {
    if (_disposed) return;
    final bool inRoom = _controller.phase == RoomPhase.inRoom;

    if (inRoom && _inner == null) {
      // phase 可能先于 room 就绪(竞态),没拿到就等下一次通知
      if (_rtc.room == null) return;
      try {
        final ChatTransport t = _factory(_rtc);
        _inner = t;
        _innerSub = t.inbound.listen(_out.add);
      } catch (e) {
        // 副通道接不上不能影响语音
        debugPrint('[lares] 聊天传输层接入失败(不影响语音): $e');
      }
      return;
    }

    if (!inRoom && _inner != null) {
      _teardownInner();
    }
  }

  void _teardownInner() {
    final ChatTransport? t = _inner;
    _inner = null;
    _innerSub?.cancel();
    _innerSub = null;
    t?.dispose();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _controller.removeListener(_onPhase);
    _teardownInner();
    await _out.close();
  }
}
