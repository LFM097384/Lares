import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/net/signaling_client.dart';
import 'package:lares_app/src/rtc/rtc_service.dart';
import 'package:lares_app/src/state/join_error.dart';
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
  _joinWatchdogTests();

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

    test('服务端 error: token_failed 必须终结 joining', () async {
      // 服务端 joinCircle 的顺序是:先发 room 快照、并已向房内其他人广播
      // member_joined,**之后**才 mint LiveKit token(server/src/index.js:
      // 867-878)。mint 抛异常(API key 配错、时钟偏移、LiveKit 挂了)时
      // 只发一条 {t:'error', message:'token_failed'},不关连接、不再发别的。
      //
      // 以前 case 'error' 只认 rtc_not_configured,这条就落进空 if 里消失,
      // _joinCompleter 永不完成 —— 界面卡在「正在进去…」退不出来。
      // 更糟的是服务端已经把人登记进房并广播出去了:
      // **房里其他人会看到一个永远不出现的幽灵成员。**
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

      // 复刻真实顺序:room 先到(人已经被登记进房了),token 换成 error
      signaling.testInject({
        't': 'room',
        'circleId': 'review',
        'members': <Map<String, dynamic>>[],
      });
      signaling.testInject({'t': 'error', 'message': 'token_failed'});
      await pumpEventQueue();

      expect(controller.phase, RoomPhase.error, reason: '必须给用户一个出路');
      await expectation;
    });

    test('token_failed 不弹口令框 —— 填口令对它毫无用处', () {
      // 这条与上一条是**两件不同的事**:上面管「会不会卡死」,
      // 这条管「给的出路对不对」。服务器没能签出 token 是服务端侧的问题,
      // 弹口令框等于让用户去改一个根本没错的东西,而且会让他相信
      // 是自己填错了 —— 比不给提示更误导。
      final signaling = FakeSignalingClient();
      final controller = RoomController(
        signaling: signaling,
        rtc: FakeRtcService(),
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '我',
      );
      addTearDown(controller.dispose);

      unawaited(controller.join('review').catchError((Object _) {}));
      signaling.testInject({'t': 'error', 'message': 'token_failed'});

      return pumpEventQueue().then((_) {
        expect(controller.phase, RoomPhase.error);
        expect(kindOfJoinMessage(controller.errorMessage),
            JoinErrorKind.serverNotReady);
        expect(controller.needsPasscode, isFalse,
            reason: '媒体服务没起来,填口令没有任何用');
      });
    });

    test('服务端 error: auth_scope 必须终结 joining 并给出补填口令的机会', () async {
      // 服务端 case 'join' 的越权检查(server/src/index.js:489):
      // circle 模式下本连接只证明了某一个圈子的口令,进别的圈子就发
      // {t:'error', message:'auth_scope'} 然后 return —— **不关连接、
      // 不发 room、不发 token**。信令层 _onProtocolError 对它刻意什么都不做
      // (连接还活着,交给上层按业务处理),而上层此前从来没处理。
      //
      // 它的现实触发场景是「进一个自己没有口令的圈子」,恰恰是最常见的
      // 误操作之一 —— 所以不只要给出路,还要把出路给对:弹口令框。
      final signaling = FakeSignalingClient();
      final controller = RoomController(
        signaling: signaling,
        rtc: FakeRtcService(),
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '我',
      );
      addTearDown(controller.dispose);

      final joined = controller.join('vip');
      final expectation = expectLater(joined, throwsA(isA<StateError>()));

      signaling.testInject({'t': 'error', 'message': 'auth_scope'});
      await pumpEventQueue();

      expect(controller.phase, RoomPhase.error, reason: '不能停在 joining');
      expect(kindOfJoinMessage(controller.errorMessage),
          JoinErrorKind.needsPasscode);
      expect(controller.needsPasscode, isTrue, reason: '要能弹口令框');
      await expectation;
    });

    test('服务端 error: say_hello_first 也要终结 joining', () async {
      // 服务端 case 'join' 的另一道前置(index.js:486):没握手就发 join。
      // 信令层的 outbox 本该杜绝这件事,真发生了说明握手掉了 ——
      // 等不到 room,必须给出路,否则又是一次无声的永久 joining。
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
      signaling.testInject({'t': 'error', 'message': 'say_hello_first'});
      await pumpEventQueue();

      expect(controller.phase, RoomPhase.error);
      await expectation;
    });

    test('不在进房时的 error 不许打断用户 —— 白名单而非黑名单', () async {
      // 关键边界,也是这次刻意**没有**做「默认全拒」的理由:
      // 同一条 socket 上还跑着聊天和图片,它们被拒(too_large / bad_json)
      // 与这次进房毫无关系;而 token_prefetch 的 auth_scope
      // (index.js:772)是 fire-and-forget、且服务端的 error 报文
      // **不带 circleId 也不带关联 id**,分不清是谁引起的。
      // 所以只在 phase == joining 时才当成进房失败。
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

      // 已经在房里了:此时的 auth_scope 只可能来自别的消息(预热/改敲门模式),
      // 绝不能把人踢出房间。
      signaling.testInject({'t': 'error', 'message': 'auth_scope'});
      await pumpEventQueue();
      expect(controller.phase, RoomPhase.inRoom, reason: '不该打断已在房里的通话');
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

/// 进房总超时(看门狗)。
///
/// ## 这一组存在的理由
///
/// 「卡在正在进去…」已经上线三次,每次的修法都是补一条具体的失败分支
/// (4401 / 4429 / _auth_failed / token_failed / auth_scope)。三次复发
/// 说明枚举不是个完整策略:服务端**将来**多一个错误码,或者干脆不说话
/// (TCP 半开、进程被 kill、LiveKit 卡在握手上),就又没人完成 completer 了。
///
/// 沉默躲得过所有白名单 —— 白名单只能接住「服务端说了失败」。
/// 所以必须有一条与具体错误码无关的下界保证:**进房一定会有结论。**
void _joinWatchdogTests() {
  RoomController make(FakeSignalingClient s, FakeRtcService rtc) =>
      RoomController(
        signaling: s,
        rtc: rtc,
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '我',
      );

  group('进房总超时(看门狗)', () {
    test('服务端收了 join 之后完全不说话 -> 到点必须终结', () {
      fakeAsync((async) {
        final signaling = FakeSignalingClient();
        final controller = make(signaling, FakeRtcService());

        unawaited(controller.join('review').catchError((Object _) {}));
        async.elapse(Duration.zero);
        expect(controller.phase, RoomPhase.joining);

        // 差一点点:还不许开枪。否则就是在误杀慢的正常进房。
        async.elapse(RoomController.joinTimeout - const Duration(seconds: 1));
        expect(controller.phase, RoomPhase.joining,
            reason: '早于 joinTimeout 开枪就会误杀慢速但正常的进房');

        async.elapse(const Duration(seconds: 2));
        expect(controller.phase, RoomPhase.error, reason: '不能永远转圈');
        // 超时用 TimeoutException -> network -> 「网络可能不太稳」。
        // 不需要新文案,也不该弹口令框(网络问题跟口令无关)。
        expect(controller.errorMessage, contains('网络'));
        expect(controller.needsPasscode, isFalse);
        // 服务端可能已经把我们记成在房里了(join 收到了、只是回包没来),
        // 不打招呼就走会在那边留一个幽灵成员。
        expect(signaling.sent.any((m) => m['t'] == 'leave'), isTrue,
            reason: '要跟服务端说一声,别留幽灵成员');

        controller.dispose();
      });
    });

    test('进房成功之后看门狗不许再开枪(不能有走火)', () {
      fakeAsync((async) {
        final signaling = FakeSignalingClient();
        final rtc = FakeRtcService();
        final controller = make(signaling, rtc);

        controller.join('home');
        controller.testInjectToken('wss://fake', 'tok');
        async.flushMicrotasks();
        expect(controller.phase, RoomPhase.inRoom);

        // 远远超过超时:一个漏掉的计时器会在这里把人踢出房间,
        // 表现是「进房好几十秒后界面突然自己报错」——
        // 那会是这次修复**引入**的新 bug,比原来的卡死更难查。
        async.elapse(RoomController.joinTimeout * 3);
        async.flushMicrotasks();
        expect(controller.phase, RoomPhase.inRoom, reason: '成功之后不许走火');
        expect(controller.errorMessage, isNull);

        controller.dispose();
      });
    });

    test('敲门等人时看门狗不许开枪 —— 那 30 秒是正常的', () {
      fakeAsync((async) {
        final signaling = FakeSignalingClient();
        final controller = make(signaling, FakeRtcService());

        unawaited(controller.join('vip').catchError((Object _) {}));
        signaling.testInject({'t': 'knock_waiting', 'circleId': 'vip'});
        async.elapse(Duration.zero);
        expect(controller.knocking, isTrue);

        // 越过总超时但没到敲门超时:此刻是「对方还没来应门」,
        // 完全正常。若看门狗在这里开枪,措辞会说成「网络不太稳」——
        // 把话说错,还把一次本来能成的进房掐掉。
        async.elapse(RoomController.joinTimeout + const Duration(seconds: 2));
        expect(controller.phase, RoomPhase.joining,
            reason: '敲门期间由 knockTimeout 负责,总超时必须让位');
        expect(controller.knocking, isTrue);

        // 到了敲门超时才该有结论,且文案是敲门那一套。
        async.elapse(RoomController.knockTimeout);
        expect(controller.phase, RoomPhase.error);
        expect(controller.errorMessage, contains('没人应门'));
        // 敲门超时的文案对不上任何一条标准文案,反查落 null ——
        // 那正确:没人应门跟口令无关,不该弹口令框。
        expect(controller.needsPasscode, isFalse);

        controller.dispose();
      });
    });

    test('敲门被放行、room 到了但 token 迟迟不来 -> 仍必须终结', () {
      fakeAsync((async) {
        // ⚠️ 这条守的是整条交接链上最容易漏的一环。
        //
        // 服务端是**先发 room、再 mint token**(index.js:867-878)。
        // 而客户端这边:knock_waiting 把总超时交接给敲门 30s,
        // 被放行时 case 'room' 又把 _knockTimer 撤掉。
        // 若 case 'room' 不把总超时**重新挂上**,从 room 到 token 这段
        // 就一个计时器都不剩 —— 服务端恰好在这儿卡住或被 kill
        // (半开连接连 error 都没有,只有沉默),界面就永久转圈。
        //
        // 这正是「枚举错误码不够」的活证据:这一段里根本没有错误码可枚举。
        final signaling = FakeSignalingClient();
        final controller = make(signaling, FakeRtcService());

        unawaited(controller.join('vip').catchError((Object _) {}));
        signaling.testInject({'t': 'knock_waiting', 'circleId': 'vip'});
        async.elapse(Duration.zero);
        expect(controller.knocking, isTrue);

        // 房里的人放行了:room 到达,敲门态解除,_knockTimer 被撤。
        signaling.testInject({
          't': 'room',
          'circleId': 'vip',
          'members': <Map<String, dynamic>>[],
        });
        async.elapse(Duration.zero);
        expect(controller.knocking, isFalse);
        expect(controller.phase, RoomPhase.joining, reason: '还差一个 token');

        // 然后服务端就沉默了 —— mint token 卡住 / 进程被杀 / TCP 半开。
        async.elapse(RoomController.joinTimeout + const Duration(seconds: 1));
        expect(controller.phase, RoomPhase.error,
            reason: 'room 到 token 这段窗口必须有计时器兜着');

        controller.dispose();
      });
    });

    test('room 之后重新挂的表,成功进房时也要撤掉', () {
      fakeAsync((async) {
        // 上一条要求 case 'room' 重新挂表,这条守它的另一面:
        // 挂了就得记得撤。只挂不撤就是把「永久卡死」换成
        // 「进房 25 秒后自己报错」—— 同一个 bug 的另一张脸。
        final signaling = FakeSignalingClient();
        final controller = make(signaling, FakeRtcService());

        controller.join('home');
        signaling.testInject({
          't': 'room',
          'circleId': 'home',
          'members': <Map<String, dynamic>>[],
        });
        async.elapse(Duration.zero);
        controller.testInjectToken('wss://fake', 'tok');
        async.flushMicrotasks();
        expect(controller.phase, RoomPhase.inRoom);

        async.elapse(RoomController.joinTimeout * 3);
        async.flushMicrotasks();
        expect(controller.phase, RoomPhase.inRoom, reason: 'room 挂的表也要撤干净');

        controller.dispose();
      });
    });

    test('dispose 之后不留活计时器(框架会因此报 pending timer)', () {
      // 回归守卫:看门狗刚上线时就因为这个把 moderation_ui / passcode_entry
      // 的 6 个 widget 测试全搞红了 ——「A Timer is still pending even after
      // the widget tree was disposed」。那些用例刻意把 controller 停在
      // joining(只注入 room、不注入 token),而 addTearDown 排在框架这项
      // 检查**之后**才跑,救不了。
      //
      // fakeAsync 在退出时会断言没有待决计时器,所以这条一旦回归就会红。
      fakeAsync((async) {
        final signaling = FakeSignalingClient();
        final controller = make(signaling, FakeRtcService());

        unawaited(controller.join('home').catchError((Object _) {}));
        signaling.testInject({
          't': 'room',
          'circleId': 'home',
          'members': <Map<String, dynamic>>[],
        });
        async.elapse(Duration.zero);
        expect(controller.phase, RoomPhase.joining);

        // 进房还挂在半空中就 dispose —— 必须把表一起收掉。
        controller.dispose();
      });
    });

    test('leave 要撤掉看门狗:退房之后不许再冒出一个错误', () {
      fakeAsync((async) {
        final signaling = FakeSignalingClient();
        final controller = make(signaling, FakeRtcService());

        unawaited(controller.join('home').catchError((Object _) {}));
        async.elapse(Duration.zero);
        unawaited(controller.leave());
        async.flushMicrotasks();
        expect(controller.phase, RoomPhase.idle);

        // 用户已经回到主页了,这时候弹一句「网络不太稳」纯属莫名其妙。
        async.elapse(RoomController.joinTimeout * 2);
        async.flushMicrotasks();
        expect(controller.phase, RoomPhase.idle, reason: '退房之后不许走火');
        expect(controller.errorMessage, isNull);

        controller.dispose();
      });
    });
  });

  group('进房代次:过期的那一次不许提交状态', () {
    test('退房后迟到的 RTC 连接不许把人拉回房间', () async {
      // 真实场景:_rtc.join() 要好几秒。用户等不及按了「算了」,
      // 甚至又进了别的圈 —— 此时上一次的 await 才返回。
      // 若不认代次,它会把 inRoom 提交上去,表现是「退了房又自己回去」,
      // 而且留下一条没人管的音频流:**用户明明已经离开,却还在被别人听见。**
      final signaling = FakeSignalingClient();
      final rtc = _SlowRtcService();
      final controller = RoomController(
        signaling: signaling,
        rtc: rtc,
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '我',
      );
      addTearDown(controller.dispose);

      unawaited(controller.join('home').catchError((Object _) {}));
      // 让 RTC 连接挂在半空中,然后退房
      unawaited(controller.testInjectToken('wss://fake', 'tok'));
      await pumpEventQueue();
      await controller.leave();
      expect(controller.phase, RoomPhase.idle);

      // 现在才让那次 RTC 连接成功返回
      rtc.completeJoin();
      await pumpEventQueue();

      expect(controller.phase, RoomPhase.idle, reason: '过期的连接不许提交 inRoom');
      expect(rtc.inRoom, isFalse, reason: '连上了也要拆掉,否则是条没人管的音频流');
    });
  });
}

/// RTC 假件,但 join() 挂着不返回,直到测试显式放行。
/// 用来复刻「媒体连接很慢,用户等不及退了房」这个真实时序。
class _SlowRtcService implements RtcService {
  final _speaking = StreamController<Set<String>>.broadcast();
  final _dropped = StreamController<void>.broadcast();
  final _gate = Completer<void>();
  bool _inRoom = false;

  void completeJoin() {
    if (!_gate.isCompleted) _gate.complete();
  }

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
    await _gate.future;
    _inRoom = true;
    return const Duration(milliseconds: 50);
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
  Future<void> setMuted(bool m) async {}

  @override
  Stream<Set<String>> get speakingIdentities => _speaking.stream;

  @override
  Stream<void> get onDisconnected => _dropped.stream;
}