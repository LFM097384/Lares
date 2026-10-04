/// 把 LiveKit 房间里 topic `lares.ai` 的数据帧喂给 [RoomController.aiStates]。
///
/// 与 `captions/caption_wiring.dart` 同一套路:跟着 controller 变化,按 Room 对象身份
/// 重绑(闲时降级 / 唤醒会换掉 Room)。规则(谁能发、seq、过期)全在 ai_state.dart。
library;

import 'package:livekit_client/livekit_client.dart';

import '../state/ai_state.dart';
import '../state/room_controller.dart';
import 'livekit_rtc_service.dart';

class LiveKitAiStateWiring {
  LiveKitAiStateWiring({required this.controller, required this.rtc}) {
    controller.addListener(_sync);
    _sync();
  }

  final RoomController controller;
  final LiveKitRtcService rtc;

  Room? _room;
  EventsListener<RoomEvent>? _listener;
  bool _disposed = false;

  void _sync() {
    if (_disposed) return;
    final Room? room = controller.isInRoom ? rtc.room : null;
    if (identical(room, _room)) return;
    final EventsListener<RoomEvent>? old = _listener;
    _listener = null;
    _room = room;
    if (old != null) old.dispose();
    if (room == null) return;
    _listener = room.createListener()
      ..on<DataReceivedEvent>((DataReceivedEvent e) {
        if (_disposed || !identical(_room, room)) return;
        // SDK 给的是空串而非 null
        if ((e.topic ?? '') != kAiStateTopic) return;
        final String identity = e.participant?.identity ?? '';
        controller.aiStates.ingest(identity, e.data);
      });
  }

  void dispose() {
    _disposed = true;
    controller.removeListener(_sync);
    _listener?.dispose();
    _listener = null;
    _room = null;
  }
}
