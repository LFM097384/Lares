/// 接线测试:**每一条**走到 `rtc.join()` 的路径都必须先过加密准备钩子。
///
/// 为什么值得单独一组:漏掉任何一条路径的后果不是崩溃、不是报错,
/// 而是用户在一个「开关明明是开着的」圈子里**明文通话** ——
/// 静默降级是这个功能唯一不可接受的失败方式,而它不会自己叫出声来。
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/net/signaling_client.dart';
import 'package:lares_app/src/rtc/rtc_service.dart';
import 'package:lares_app/src/state/room_controller.dart';

class _FakeSignaling extends SignalingClient {
  _FakeSignaling() : super(url: 'ws://fake');

  @override
  void connect() {}

  @override
  void send(Map<String, dynamic> msg) {}

  @override
  Future<void> dispose() async {}
}

class _FakeRtc implements RtcService {
  final _speaking = StreamController<Set<String>>.broadcast();
  final _dropped = StreamController<void>.broadcast();
  bool _inRoom = false;

  /// join 被调用时,钩子已经跑过几次 —— 用来证明顺序对得上
  final List<int> prepareCountAtJoin = [];
  int prepareCalls = 0;

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
    prepareCountAtJoin.add(prepareCalls);
    return const Duration(milliseconds: 10);
  }

  @override
  ResolvedAudioTuning? get activeTuning => null;

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

RoomController _makeController(_FakeRtc rtc, List<String?> seen) {
  final c = RoomController(
    signaling: _FakeSignaling(),
    rtc: rtc,
    userId: 'u1',
    deviceId: 'd1',
    userName: '测试',
  );
  c.prepareEncryption = (circleId) async {
    seen.add(circleId);
    rtc.prepareCalls++;
  };
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('正常进房:钩子在 rtc.join() 之前跑,且拿到的是当前圈子 id', () async {
    final rtc = _FakeRtc();
    final seen = <String?>[];
    final c = _makeController(rtc, seen);

    await c.join('home').timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
    // join() 要等服务器 token 才真正连;这里直接注入一次 token 事件
    await c.testInjectToken('wss://media', 'tok');

    expect(rtc.prepareCountAtJoin, isNotEmpty,
        reason: 'rtc.join() 应当已被调用');
    // 密钥必须在 Room 构造之前装好:进房之后再改一个字都不会生效
    expect(rtc.prepareCountAtJoin.first, greaterThan(0),
        reason: '钩子必须在 rtc.join() **之前**跑完');
    expect(seen, contains('home'));
  });

  test('闲时降级后的媒体唤醒:同样要重做一次加密准备', () {
    fakeAsync((async) {
      final rtc = _FakeRtc();
      final seen = <String?>[];
      final c = _makeController(rtc, seen);

      c.join('home');
      c.testInjectToken('wss://media', 'tok');
      async.flushMicrotasks();
      expect(c.isInRoom, isTrue);

      final joinsBefore = rtc.prepareCountAtJoin.length;
      final prepareBefore = rtc.prepareCalls;

      // 5 分钟无人说话 -> 断媒体只留 presence
      async.elapse(RoomController.idleDowngradeAfter + const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(c.mediaDowngraded, isTrue);

      // 开麦唤醒媒体:这是一次真正的 join,绝不能跳过加密准备 ——
      // 跳过了,降级唤醒后的那段通话就会悄悄变成明文。
      c.toggleMute();
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 100));
      async.flushMicrotasks();

      expect(rtc.prepareCountAtJoin.length, greaterThan(joinsBefore),
          reason: '唤醒应当触发一次新的 rtc.join()');
      expect(rtc.prepareCalls, greaterThan(prepareBefore),
          reason: '唤醒路径也必须调加密准备钩子');
      expect(rtc.prepareCountAtJoin.last, rtc.prepareCalls,
          reason: '钩子必须在这次 join 之前跑完');
    });
  });

  test('没注入钩子时一切照旧 —— 可选协作者优雅降级,不影响既有测试', () async {
    final rtc = _FakeRtc();
    final c = RoomController(
      signaling: _FakeSignaling(),
      rtc: rtc,
      userId: 'u1',
      deviceId: 'd1',
      userName: '测试',
    );
    expect(c.prepareEncryption, isNull);
    await c.testInjectToken('wss://media', 'tok');
    expect(c.isInRoom, isTrue);
  });
}
