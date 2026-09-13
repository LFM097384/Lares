import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/net/signaling_client.dart';
import 'package:lares_app/src/rtc/rtc_service.dart';
import 'package:lares_app/src/state/models.dart';
import 'package:lares_app/src/state/room_controller.dart';

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

class FakeRtcService implements RtcService {
  final _speaking = StreamController<Set<String>>.broadcast();
  final _dropped = StreamController<void>.broadcast();
  bool _inRoom = false;
  int joinCount = 0;

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
    joinCount++;
    lastTuning = tuning;
    return const Duration(milliseconds: 50);
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
  Future<void> setMuted(bool m) async {}

  @override
  Stream<Set<String>> get speakingIdentities => _speaking.stream;

  @override
  Stream<void> get onDisconnected => _dropped.stream;
}

void main() {
  test('断线重连后自动恢复到原房间', () async {
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

    final joined = controller.join('home');
    await controller.testInjectToken('wss://fake', 'tok');
    await joined;
    expect(controller.phase, RoomPhase.inRoom);

    // 信令断开 -> 重连成功(welcome)-> 应自动重发 join
    signaling.testInject({'t': '_disconnected'});
    await pumpEventQueue();
    expect(controller.phase, RoomPhase.joining);
    signaling.sent.clear();
    signaling.testInject({'t': 'welcome', 'userId': 'u_me'});
    await pumpEventQueue();
    expect(
      signaling.sent.any((m) => m['t'] == 'join' && m['circleId'] == 'home'),
      isTrue,
    );
  });

  test('预热 token:进房时信令与 RTC 并行,不等服务器 mint', () async {
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

    // 启动预热:发出 prefetch 请求,服务器回 prefetch token -> 只缓存不进房
    controller.prefetchToken('home');
    expect(signaling.sent.any((m) => m['t'] == 'token_prefetch'), isTrue);
    signaling.testInject({
      't': 'token',
      'circleId': 'home',
      'url': 'wss://fake',
      'token': 'cached-tok',
      'prefetch': true,
    });
    await pumpEventQueue();
    expect(controller.phase, RoomPhase.idle);
    expect(rtc.inRoom, isFalse);

    // 进房:无需等服务器 token,RTC 应立即开始连接
    final joined = controller.join('home');
    await pumpEventQueue();
    await joined;
    expect(controller.phase, RoomPhase.inRoom);
    expect(rtc.inRoom, isTrue);
  });

  test('敲门模式:knock_waiting 进入敲门态,超时进入错误态', () {
    fakeAsync((async) {
      final signaling = FakeSignalingClient();
      final rtc = FakeRtcService();
      final controller = RoomController(
        signaling: signaling,
        rtc: rtc,
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '我',
      );

      unawaited(controller.join('vip').catchError((_) {}));
      signaling.testInject({'t': 'knock_waiting', 'circleId': 'vip'});
      async.elapse(Duration.zero);
      expect(controller.knocking, isTrue);
      expect(controller.phase, RoomPhase.joining);

      // 30s 无人应门 -> 错误态 + 发送 leave
      async.elapse(const Duration(seconds: 31));
      expect(controller.knocking, isFalse);
      expect(controller.phase, RoomPhase.error);
      expect(controller.errorMessage, contains('没人应门'));
      expect(signaling.sent.any((m) => m['t'] == 'leave'), isTrue);

      controller.dispose();
    });
  });

  test('敲门圈有人时预热 token 不先行连媒体(隐私红线)', () async {
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

    // 大厅摘要:vip 圈需敲门且有 2 人
    signaling.testInject({
      't': 'circle_summary',
      'circleId': 'vip',
      'count': 2,
      'names': ['阿伟', '小敏'],
      'knockRequired': true,
    });
    await pumpEventQueue();
    // 预热 token 已备好
    signaling.testInject({
      't': 'token',
      'circleId': 'vip',
      'url': 'wss://fake',
      'token': 'cached',
      'prefetch': true,
    });
    await pumpEventQueue();

    unawaited(controller.join('vip').catchError((_) {}));
    await pumpEventQueue();

    // 敲门门控生效:不允许先连媒体
    expect(rtc.inRoom, isFalse);
    expect(controller.phase, RoomPhase.joining);
  });

  test('敲门被放行:room 到达解除敲门态', () async {
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

    unawaited(controller.join('vip').catchError((_) {}));
    signaling.testInject({'t': 'knock_waiting', 'circleId': 'vip'});
    await pumpEventQueue();
    expect(controller.knocking, isTrue);

    signaling.testInject({
      't': 'room',
      'circleId': 'vip',
      'members': <Map<String, dynamic>>[],
    });
    await pumpEventQueue();
    expect(controller.knocking, isFalse);
  });

  test('闲时 5 分钟媒体降级,来人自动唤醒', () {
    fakeAsync((async) {
      final signaling = FakeSignalingClient();
      final rtc = FakeRtcService();
      final controller = RoomController(
        signaling: signaling,
        rtc: rtc,
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '我',
      );

      controller.join('home');
      controller.testInjectToken('wss://fake', 'tok');
      async.flushMicrotasks();
      expect(controller.phase, RoomPhase.inRoom);
      expect(rtc.joinCount, 1);

      // 4 分钟:不降级
      async.elapse(const Duration(minutes: 4));
      async.flushMicrotasks();
      expect(controller.mediaDowngraded, isFalse);
      expect(rtc.inRoom, isTrue);

      // 再过 2 分钟(共 6 分钟无活动):降级,媒体断开但仍在房
      async.elapse(const Duration(minutes: 2));
      async.flushMicrotasks();
      expect(controller.mediaDowngraded, isTrue);
      expect(rtc.inRoom, isFalse);
      expect(controller.phase, RoomPhase.inRoom);

      // 有人进房:媒体唤醒
      signaling.testInject({
        't': 'member_joined',
        'circleId': 'home',
        'member': {'userId': 'u_b', 'name': '小敏', 'status': 'free'},
      });
      async.elapse(Duration.zero); // 投递流事件
      async.flushMicrotasks();
      expect(controller.mediaDowngraded, isFalse);
      expect(rtc.inRoom, isTrue);
      expect(rtc.joinCount, 2);

      controller.dispose();
    });
  });

  test('有说话活动则重置降级计时', () {
    fakeAsync((async) {
      final signaling = FakeSignalingClient();
      final rtc = FakeRtcService();
      final controller = RoomController(
        signaling: signaling,
        rtc: rtc,
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '我',
      );

      controller.join('home');
      controller.testInjectToken('wss://fake', 'tok');
      async.flushMicrotasks();

      // 每 4 分钟有一次说话活动,永远不降级
      for (var i = 0; i < 4; i++) {
        async.elapse(const Duration(minutes: 4));
        rtc.testEmitSpeakers({'u_b'});
        async.elapse(Duration.zero); // 投递流事件
        async.flushMicrotasks();
        expect(controller.mediaDowngraded, isFalse);
      }
      async.elapse(const Duration(minutes: 6));
      async.flushMicrotasks();
      expect(controller.mediaDowngraded, isTrue);

      controller.dispose();
    });
  });
}

extension on FakeRtcService {
  void testEmitSpeakers(Set<String> ids) => _speaking.add(ids);
}
