import 'dart:async';

import 'package:livekit_client/livekit_client.dart';

import 'rtc_service.dart';

/// LiveKit 实现。进房默认静音(设计.md §2.1-4:想来就来,不打扰)。
class LiveKitRtcService implements RtcService {
  LiveKitRtcService({this.hostOnlyIce = false});

  /// 局域网联调:只用主机候选,跳过 STUN 收集(可省 ~2s 进房时间)
  final bool hostOnlyIce;

  Room? _room;
  CancelListenFunc? _cancelEvents;

  final _speaking = StreamController<Set<String>>.broadcast();
  final _disconnected = StreamController<void>.broadcast();

  @override
  bool get inRoom => _room != null;

  @override
  Stream<Set<String>> get speakingIdentities => _speaking.stream;

  @override
  Stream<void> get onDisconnected => _disconnected.stream;

  @override
  Future<Duration> join({
    required String url,
    required String token,
    required bool startMuted,
    bool highQuality = true,
  }) async {
    final sw = Stopwatch()..start();
    final room = Room(
      roomOptions: RoomOptions(
        // 语音房:只需要音频;自适应流与 dynacast 降低挂机带宽
        adaptiveStream: true,
        dynacast: true,
        // 流量透明度(§2.2):高音质 48k / 省流 24k
        defaultAudioPublishOptions: AudioPublishOptions(
          encoding: highQuality
              ? AudioEncoding.presetMusic
              : AudioEncoding.presetSpeech,
        ),
      ),
    );
    _room = room;

    _cancelEvents = room.events.listen((event) {
      switch (event) {
        case ActiveSpeakersChangedEvent():
          _speaking.add(event.speakers.map((p) => p.identity).toSet());
        case RoomDisconnectedEvent():
          _speaking.add(const {});
          _disconnected.add(null);
        default:
          break;
      }
    });

    await room.connect(
      url,
      token,
      connectOptions: ConnectOptions(
        autoSubscribe: true,
        rtcConfiguration: hostOnlyIce
            ? const RTCConfiguration(iceServers: [])
            : const RTCConfiguration(),
      ),
    );

    // LiveKit 默认不发布麦克风;只有明确要求开麦时才调用(省一次往返)
    if (!startMuted) {
      await room.localParticipant?.setMicrophoneEnabled(true);
    }

    sw.stop();
    return sw.elapsed;
  }

  @override
  Future<void> setMuted(bool muted) async {
    await _room?.localParticipant?.setMicrophoneEnabled(!muted);
  }

  @override
  Future<void> leave() async {
    final room = _room;
    _room = null;
    _cancelEvents?.call();
    _cancelEvents = null;
    _speaking.add(const {});
    await room?.disconnect();
    await room?.dispose();
  }
}
