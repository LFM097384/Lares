/// 隐名之约 v2 的 LiveKit data 胶水:topic `lares.anon`(AGENT-V2.md §4)。
///
/// 与 `rtc/livekit_ai_state_wiring.dart` 同一套路:跟着 controller 变化,按 Room 对象身份
/// 重绑(闲时降级 / 唤醒会换掉 Room)。收:把本 topic 的帧交给 [AnonymController.handleData]
/// (它自己核对发送者是不是本圈 agent);发:JSON、reliable、`destinationIdentities` 只填 agent。
/// E2EE 圈里 data 随房间一起加密,这里不用额外处理。
///
/// agent 身份由 [anonAgentIdentityFor] 按约定算出(`u_ai_anon_` + sha256(circleId)[:8]),
/// 信令 `anon_agent_state` 若带了 identity 则以它为准。
library;

import 'dart:async';
import 'dart:convert';

import 'package:livekit_client/livekit_client.dart';

import '../rtc/livekit_rtc_service.dart';
import '../state/room_controller.dart';
import 'anonym_controller.dart';

class LiveKitAnonymWiring {
  LiveKitAnonymWiring({
    required this.controller,
    required this.rtc,
    required this.anonym,
  }) {
    anonym.sendData = _send;
    controller.addListener(_sync);
    _sync();
  }

  final RoomController controller;
  final LiveKitRtcService rtc;
  final AnonymController anonym;

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
    if (old != null) unawaited(old.dispose());
    if (room == null) return;
    _listener = room.createListener()
      ..on<DataReceivedEvent>((DataReceivedEvent e) {
        if (_disposed || !identical(_room, room)) return;
        // SDK 给的是空串而非 null
        if ((e.topic ?? '') != kAnonTopic) return;
        anonym.handleData(e.participant?.identity ?? '', e.data);
      });
  }

  void _send(Map<String, dynamic> msg, String to) {
    final LocalParticipant? lp = _room?.localParticipant;
    if (_disposed || lp == null) return;
    // reliable 无默认值,不传即 LOSSY
    unawaited(
      lp
          .publishData(
            utf8.encode(jsonEncode(msg)),
            reliable: true,
            topic: kAnonTopic,
            destinationIdentities: <String>[to],
          )
          .catchError((Object e) {}),
    );
  }

  void dispose() {
    _disposed = true;
    anonym.sendData = null;
    controller.removeListener(_sync);
    unawaited(_listener?.dispose());
    _listener = null;
    _room = null;
  }
}
