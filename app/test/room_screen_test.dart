import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/net/signaling_client.dart';
import 'package:lares_app/src/rtc/rtc_service.dart';
import 'package:lares_app/src/state/models.dart';
import 'package:lares_app/src/state/room_controller.dart';
import 'package:lares_app/src/theme/theme.dart';
import 'package:lares_app/src/ui/room_screen.dart';

/// 假信令:不碰真实 socket/定时器,只记录发送的消息
class FakeSignalingClient extends SignalingClient {
  FakeSignalingClient() : super(url: 'ws://fake');

  final List<Map<String, dynamic>> sent = [];

  @override
  void connect() {}

  @override
  void send(Map<String, dynamic> msg) => sent.add(msg);

  @override
  Future<void> dispose() async {}
}

/// 假 RTC:不碰真实网络,验证状态机与 UI 绑定
class FakeRtcService implements RtcService {
  final _speaking = StreamController<Set<String>>.broadcast();
  final _dropped = StreamController<void>.broadcast();
  bool _inRoom = false;
  bool muted = true;

  /// 记录最近一次 join 传入的降噪档位
  AudioTuning? lastTuning;

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
    lastTuning = tuning;
    return const Duration(milliseconds: 120);
  }

  @override
  ResolvedAudioTuning? get activeTuning =>
      _inRoom ? previewTuning(lastTuning ?? AudioTuning.standard) : null;

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

void main() {
  testWidgets('房间页渲染:成员网格 + 主按钮 + 状态切换', (tester) async {
    final signaling = FakeSignalingClient();
    final rtc = FakeRtcService();
    final controller = RoomController(
      signaling: signaling,
      rtc: rtc,
      userId: 'u_me',
      deviceId: 'd_1',
      userName: '我',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: LaresTheme.dark(),
        home: RoomScreen(controller: controller, circleName: '我们的圈'),
      ),
    );

    // 空房提示
    expect(find.text('房间里还空着,坐一会儿?'), findsOneWidget);

    // 主按钮存在
    expect(find.byIcon(Icons.mic_off_rounded), findsOneWidget);
    expect(find.byIcon(Icons.call_end_rounded), findsOneWidget);

    // 轻状态三选项
    expect(find.text('随时聊'), findsOneWidget);
    expect(find.text('在忙'), findsOneWidget);
    expect(find.text('耳朵在'), findsOneWidget);

    // 切换状态:控制器更新 + 信令发出
    await tester.tap(find.text('在忙'));
    await tester.pump();
    expect(controller.myStatus, MemberStatus.busy);
    expect(
      signaling.sent.any((m) => m['t'] == 'status' && m['status'] == 'busy'),
      isTrue,
    );
  });

  testWidgets('一键进房:状态机 joining -> inRoom,进房耗时被记录', (tester) async {
    final signaling = FakeSignalingClient();
    final rtc = FakeRtcService();
    final controller = RoomController(
      signaling: signaling,
      rtc: rtc,
      userId: 'u_me',
      deviceId: 'd_1',
      userName: '我',
    );
    addTearDown(controller.dispose);

    final joinFuture = controller.join('home');
    expect(controller.phase, RoomPhase.joining);
    expect(
      signaling.sent.any((m) => m['t'] == 'join' && m['circleId'] == 'home'),
      isTrue,
    );

    // 模拟服务器回 token,RTC 连接成功后应进入 inRoom
    await controller.testInjectToken('wss://fake', 'fake-token');
    await joinFuture;

    expect(controller.phase, RoomPhase.inRoom);
    expect(controller.isInRoom, isTrue);
    expect(controller.lastJoinLatency, isNotNull);
    expect(rtc.inRoom, isTrue);

    // 出房恢复 idle
    await controller.leave();
    expect(controller.phase, RoomPhase.idle);
    expect(rtc.inRoom, isFalse);
  });
}
