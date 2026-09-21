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

  group('进房时被服务器拒绝', () {
    // 2026-09-19 真机实测:通过邀请链接加的圈子本地没有口令,
    // 进房时服务端直接 4401 关连接、**不发任何消息**,
    // 于是 'room'/'token' 分支永不执行、_joinCompleter 永不完成,
    // 界面死在「正在进去…」,连「算了」都退不出来。
    RoomController makeController(FakeSignalingClient s) => RoomController(
      signaling: s,
      rtc: FakeRtcService(),
      userId: 'u_me',
      deviceId: 'd_1',
      userName: '我',
    );

    test('4401 让进房落到 error,而不是卡在 joining', () async {
      final signaling = FakeSignalingClient();
      final controller = makeController(signaling);
      addTearDown(controller.dispose);

      // 先挂上错误监听再注入 —— completeError 若无人接会变成未捕获异常,
      // 测试会以 "Bad state" 失败,而那是测试的问题不是代码的问题。
      final joined = controller.join('review');
      final expectation = expectLater(joined, throwsA(isA<StateError>()));
      expect(controller.phase, RoomPhase.joining);

      signaling.testInject({'t': '_disconnected', 'closeCode': 4401});
      await pumpEventQueue();

      expect(controller.phase, RoomPhase.error, reason: '必须给用户一个出路');
      // 文案说「要口令」而不是「口令不对」—— 邀请链接不带口令是有意设计,
      // 本地压根没存过,说「不对」会让用户去改一个不存在的东西。
      expect(controller.errorMessage, contains('口令'));
      await expectation;
    });

    test('4429 同样不卡住', () async {
      final signaling = FakeSignalingClient();
      final controller = makeController(signaling);
      addTearDown(controller.dispose);

      final joined = controller.join('review');
      final expectation = expectLater(joined, throwsA(isA<StateError>()));
      signaling.testInject({'t': '_disconnected', 'closeCode': 4429});
      await pumpEventQueue();

      expect(controller.phase, RoomPhase.error);
      await expectation;
    });

    test('普通断开仍然交给自动重连,不打断用户', () async {
      // 关键边界:网络抖动不该弹错误。只有 4401/4429 这类
      // **确定性失败**才落 error,其余仍由信令层重连。
      final signaling = FakeSignalingClient();
      final controller = makeController(signaling);
      addTearDown(controller.dispose);

      controller.join('review');
      signaling.testInject({'t': '_disconnected'}); // 无 closeCode
      await pumpEventQueue();

      expect(controller.phase, RoomPhase.joining, reason: '抖动不该变成错误');
    });
  });

  group('退出后再进入(真机实测 2026-09-19)', () {
    // 用户报告:第一次能进,退出后再进就卡在「正在进去…」。
    // 此前没有任何测试走过 join → leave → join 这条序列。
    test('leave 之后能再次 join 并真的进到房间', () async {
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

      final first = controller.join('review');
      await controller.testInjectToken('wss://fake', 'tok');
      await first;
      expect(controller.phase, RoomPhase.inRoom);

      await controller.leave();
      expect(controller.phase, RoomPhase.idle);

      final second = controller.join('review');
      expect(controller.phase, RoomPhase.joining);
      await controller.testInjectToken('wss://fake', 'tok');
      await second.timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('第二次 join 永不完成 —— 即「卡在正在进去…」'),
      );
      expect(controller.phase, RoomPhase.inRoom, reason: '再次进入必须成功');
    });

    test('joining 期间重复点击不该卡死', () async {
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

      final a = controller.join('review');
      final b = controller.join('review'); // 守卫应当直接返回
      await controller.testInjectToken('wss://fake', 'tok');
      await a;
      await b;
      expect(controller.phase, RoomPhase.inRoom);
    });
  });

  group('信令层放弃重连之后(真机实测 2026-09-19)', () {
    // 第二次 4401 时信令层发 _auth_failed 并**彻底停止重连**,
    // 此后不会再有 _disconnected。不处理这条就永久卡在 joining ——
    // 这正是用户报告的「再次进入卡住」。
    //
    // FakeSignalingClient 不走真实的 4401 重试逻辑,所以之前
    // 「退出再进入」的测试全绿却掩盖了这个 bug。
    test('_auth_failed 必须终结 joining', () async {
      final signaling = FakeSignalingClient();
      final controller = RoomController(
        signaling: signaling,
        rtc: FakeRtcService(),
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '我',
      );
      addTearDown(controller.dispose);

      final joined = controller.join('review');
      final expectation = expectLater(joined, throwsA(isA<StateError>()));
      expect(controller.phase, RoomPhase.joining);

      // 信令层重试一次仍失败,放弃重连
      signaling.testInject({'t': '_auth_failed', 'message': 'auth_failed'});
      await pumpEventQueue();

      expect(controller.phase, RoomPhase.error, reason: '不能停在 joining');
      expect(controller.errorMessage, contains('口令'));
      await expectation;
    });

    test('_rate_limited 同样终结 joining', () async {
      final signaling = FakeSignalingClient();
      final controller = RoomController(
        signaling: signaling,
        rtc: FakeRtcService(),
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '我',
      );
      addTearDown(controller.dispose);

      final joined = controller.join('review');
      final expectation = expectLater(joined, throwsA(isA<StateError>()));
      signaling.testInject({'t': '_rate_limited'});
      await pumpEventQueue();

      expect(controller.phase, RoomPhase.error);
      await expectation;
    });

    test('已在房间里时收到 _auth_failed 也要给出路', () async {
      // 长时间挂机后 token 过期重连被拒,不能静默停在 inRoom 假装还在。
      final signaling = FakeSignalingClient();
      final controller = RoomController(
        signaling: signaling,
        rtc: FakeRtcService(),
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '我',
      );
      addTearDown(controller.dispose);

      final first = controller.join('review');
      await controller.testInjectToken('wss://fake', 'tok');
      await first;
      expect(controller.phase, RoomPhase.inRoom);

      signaling.testInject({'t': '_auth_failed', 'message': 'auth_failed'});
      await pumpEventQueue();
      expect(controller.phase, RoomPhase.error);
    });
  });
}

extension on FakeRtcService {
  void testEmitSpeakers(Set<String> ids) => _speaking.add(ids);
}