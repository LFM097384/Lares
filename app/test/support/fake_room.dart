import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/net/signaling_client.dart';
import 'package:lares_app/src/rtc/rtc_service.dart';
import 'package:lares_app/src/state/room_controller.dart';

/// 假信令:不碰真实 socket,只记录发出的消息。
/// (与 room_screen_test.dart / moderation_ui_test.dart 里的同名类同款,
/// 这里单独放一份是为了给设置页的用例用,不去动那两个文件。)
class FakeSignalingClient extends SignalingClient {
  FakeSignalingClient() : super(url: 'ws://fake');

  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  @override
  void connect() {}

  @override
  void send(Map<String, dynamic> msg) => sent.add(msg);

  @override
  Future<void> dispose() async {}
}

/// 假 RTC:一行网络都不碰。
///
/// ⚠️ 刻意用 `implements RtcService` 而不是继承 ——
/// 这样接口一旦新增成员,编译期就会在这里报错,而不是在运行时才炸。
class FakeRtcService implements RtcService {
  final StreamController<Set<String>> _speaking =
      StreamController<Set<String>>.broadcast();
  final StreamController<void> _dropped = StreamController<void>.broadcast();
  bool _inRoom = false;
  bool muted = true;

  @override
  bool get inRoom => _inRoom;

  @override
  Future<Duration> join({
    required String url,
    required String token,
    required bool startMuted,
    bool highQuality = true,
    AudioTuning tuning = AudioTuning.standard,
  }) async {
    _inRoom = true;
    muted = startMuted;
    return const Duration(milliseconds: 120);
  }

  @override
  ResolvedAudioTuning? get activeTuning =>
      _inRoom ? previewTuning(AudioTuning.standard) : null;

  @override
  ResolvedAudioTuning previewTuning(AudioTuning tuning) => resolveAudioTuning(
        tuning,
        const AudioPlatformCapabilities(
          platform: 'windows',
          supportsAudioSession: false,
          supportsEnhanced: false,
        ),
      );

  @override
  Future<void> leave() async {
    _inRoom = false;
  }

  @override
  Future<void> setMuted(bool m) async {
    muted = m;
  }

  @override
  Stream<Set<String>> get speakingIdentities => _speaking.stream;

  @override
  Stream<void> get onDisconnected => _dropped.stream;
}

/// 造一个什么网络都不碰的 RoomController,并登记好 dispose。
/// 设置页只用到它的 userId / rtcPreview / lastJoinLatency / phase。
RoomController fakeRoomController(WidgetTester tester) {
  final controller = RoomController(
    signaling: FakeSignalingClient(),
    rtc: FakeRtcService(),
    userId: 'u_me',
    deviceId: 'd_1',
    userName: '我',
  );
  addTearDown(controller.dispose);
  return controller;
}
