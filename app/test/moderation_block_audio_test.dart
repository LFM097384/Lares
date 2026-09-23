/// 屏蔽 · 声音侧执行器的纯 VM 测试。
///
/// 这里**不**连真实的 LiveKit:`BlockAudioEnforcer` 特意把「谁该被静音」这个
/// 决策抽成了两个顶层纯函数,又把「当前 Room 从哪来」做成可注入的种子
/// (`roomGetter`),所以整套判定与生命周期纪律都能在 `flutter test` 里跑完 ——
/// 不需要真机、不需要房间、不需要第二个人对着麦克风说话。
///
/// 真正需要一条活着的音频轨才能验证的那一半(`track.disable()` 之后耳朵
/// 是否立刻静音),只能靠真机联调与审核前的人工回归,测试里不做假装。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/moderation/block_audio_enforcer.dart';
import 'package:lares_app/src/moderation/block_store.dart';
import 'package:lares_app/src/net/signaling_client.dart';
import 'package:lares_app/src/rtc/livekit_rtc_service.dart';
import 'package:lares_app/src/rtc/rtc_service.dart';
import 'package:lares_app/src/state/models.dart';
import 'package:lares_app/src/state/room_controller.dart';
import 'package:livekit_client/livekit_client.dart' show Room;
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 测试替身
// ─────────────────────────────────────────────────────────────────────────────

/// 假信令:不碰真实 socket/定时器(与 room_controller_test.dart 同款)
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

/// 假 RTC:`RoomController` 只认抽象接口,这里给它一个不碰网络的实现。
class FakeRtcService implements RtcService {
  final _speaking = StreamController<Set<String>>.broadcast();
  final _dropped = StreamController<void>.broadcast();
  bool _inRoom = false;

  @override
  bool get inRoom => _inRoom;

  @override
  Future<RtcJoinResult> join({
    required String url,
    required String token,
    required bool startMuted,
    bool highQuality = true,
    AudioTuning tuning = AudioTuning.standard,
  }) async {
    _inRoom = true;
    return RtcJoinResult(
        elapsed: const Duration(milliseconds: 1),
        micOn: !startMuted);
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
  Future<void> setMuted(bool muted) async {}

  @override
  Stream<Set<String>> get speakingIdentities => _speaking.stream;

  @override
  Stream<void> get onDisconnected => _dropped.stream;
}

/// 可计数的「未进房」房间种子。
///
/// 数调用次数是为了**证明监听真的被摘掉了**:dispose 之后再改屏蔽名单,
/// 如果计数还在涨,说明 listener 还挂着 —— 那正是「已经退出的对象还在后台
/// 操作媒体轨」这类幽灵 bug 的源头。
class CountingNullRoom {
  int lookups = 0;

  Room? call() {
    lookups++;
    return null;
  }
}

RoomController makeController() => RoomController(
      signaling: FakeSignalingClient(),
      rtc: FakeRtcService(),
      userId: 'u_me',
      deviceId: 'd_1',
      userName: '我',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('静音决策(纯函数,不依赖 LiveKit)', () {
    test('只挑「既被屏蔽、又在房里」的人', () {
      final picked = selectIdentitiesToMute(
        blockedIds: {'u_bad', 'u_worse'},
        presentIdentities: ['u_bad', 'u_ok'],
      );
      expect(picked, {'u_bad'});
    });

    test('被屏蔽但不在房里 —— 纯 no-op,不出现在结果里', () {
      final picked = selectIdentitiesToMute(
        blockedIds: {'u_absent'},
        presentIdentities: ['u_a', 'u_b'],
      );
      expect(picked, isEmpty);
    });

    test('在房但没被屏蔽 —— 一根轨都不许碰', () {
      final picked = selectIdentitiesToMute(
        blockedIds: <String>{},
        presentIdentities: ['u_a', 'u_b'],
      );
      expect(picked, isEmpty);
    });

    test('只认 identity 精确匹配:同名不同人不会被误伤', () {
      // 两个人都叫「小明」,但 identity 一个是 u_ming_1、一个是 u_ming_2。
      // 屏蔽了前者,后者必须完好无损 —— 拿昵称当键就是这里出事。
      final picked = selectIdentitiesToMute(
        blockedIds: {'u_ming_1'},
        presentIdentities: ['u_ming_1', 'u_ming_2'],
      );
      expect(picked, {'u_ming_1'});
      expect(picked.contains('u_ming_2'), isFalse);
    });

    test('前缀/子串都不算命中', () {
      final picked = selectIdentitiesToMute(
        blockedIds: {'u_abc'},
        presentIdentities: ['u_abcd', 'xu_abc', 'U_ABC'],
      );
      expect(picked, isEmpty);
    });

    test('空 identity 永远不匹配', () {
      final picked = selectIdentitiesToMute(
        blockedIds: {''},
        presentIdentities: ['', 'u_a'],
      );
      expect(picked, isEmpty);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('恢复决策(纯函数)', () {
    test('只恢复「我们自己压过、现在不该压、人还在房」的那些', () {
      final restore = selectIdentitiesToRestore(
        previouslyMuted: {'u_a', 'u_b'},
        desiredMuted: {'u_a'}, // u_b 刚被解除屏蔽
        presentIdentities: ['u_a', 'u_b', 'u_c'],
      );
      expect(restore, {'u_b'});
    });

    test('从没压过的人绝不主动 enable —— 不跟 dynacast 抢方向盘', () {
      final restore = selectIdentitiesToRestore(
        previouslyMuted: <String>{},
        desiredMuted: <String>{},
        presentIdentities: ['u_a', 'u_b'],
      );
      expect(restore, isEmpty);
    });

    test('人已经走了就不用恢复(轨都没了)', () {
      final restore = selectIdentitiesToRestore(
        previouslyMuted: {'u_gone'},
        desiredMuted: <String>{},
        presentIdentities: ['u_a'],
      );
      expect(restore, isEmpty);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('未进房时的执行器', () {
    test('room 为 null:构造、扫描、销毁全程不抛', () async {
      final blocks = await BlockStore.load();
      final controller = makeController();
      addTearDown(controller.dispose);

      final enforcer = BlockAudioEnforcer(
        rtc: LiveKitRtcService(),
        controller: controller,
        blocks: blocks,
        roomGetter: () => null,
      );

      await enforcer.applyNow();
      expect(enforcer.appliedMutes, isEmpty);

      await blocks.block('u_bad');
      await enforcer.applyNow();
      // 不在房里 = 什么也压不了,但更重要的是:不许抛。
      expect(enforcer.appliedMutes, isEmpty);

      await enforcer.dispose();
    });

    test('roomGetter 抛异常也要被吞掉,绝不打断通话主路径', () async {
      final blocks = await BlockStore.load();
      final controller = makeController();
      addTearDown(controller.dispose);

      final enforcer = BlockAudioEnforcer(
        rtc: LiveKitRtcService(),
        controller: controller,
        blocks: blocks,
        roomGetter: () => throw StateError('房间炸了'),
      );
      addTearDown(enforcer.dispose);

      await expectLater(enforcer.applyNow(), completes);
      expect(enforcer.appliedMutes, isEmpty);
    });

    test('默认 roomGetter 落在 rtc.room 上:未 join 时就是 null', () async {
      final blocks = await BlockStore.load();
      final controller = makeController();
      addTearDown(controller.dispose);

      final rtc = LiveKitRtcService();
      expect(rtc.room, isNull);

      // 不传 roomGetter,走默认种子 () => rtc.room
      final enforcer = BlockAudioEnforcer(
        rtc: rtc,
        controller: controller,
        blocks: blocks,
      );
      addTearDown(enforcer.dispose);

      await blocks.block('u_bad');
      await expectLater(enforcer.applyNow(), completes);
      expect(enforcer.appliedMutes, isEmpty);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('销毁语义', () {
    test('dispose 幂等:连调三次不报错', () async {
      final blocks = await BlockStore.load();
      final controller = makeController();
      addTearDown(controller.dispose);

      final enforcer = BlockAudioEnforcer(
        rtc: LiveKitRtcService(),
        controller: controller,
        blocks: blocks,
        roomGetter: () => null,
      );

      await enforcer.dispose();
      await enforcer.dispose();
      await expectLater(enforcer.dispose(), completes);
    });

    test('dispose 之后真的不再被 BlockStore 唤醒', () async {
      final blocks = await BlockStore.load();
      final controller = makeController();
      addTearDown(controller.dispose);

      final seed = CountingNullRoom();
      final enforcer = BlockAudioEnforcer(
        rtc: LiveKitRtcService(),
        controller: controller,
        blocks: blocks,
        roomGetter: seed.call,
      );

      // 活着的时候:改名单会触发一次扫描,种子被读到。
      await blocks.block('u_bad');
      await pumpEventQueue();
      expect(seed.lookups, greaterThan(0),
          reason: 'dispose 之前应当对 block 变化有反应');
      final int before = seed.lookups;

      await enforcer.dispose();

      // 死掉之后:名单继续变,但不许再有任何动作。
      await blocks.block('u_worse');
      await blocks.unblock('u_bad');
      await blocks.clear();
      await pumpEventQueue();

      expect(seed.lookups, before, reason: 'dispose 后监听必须已摘,不得重入');
    });

    test('dispose 之后 controller 通知也不再触发扫描', () async {
      final blocks = await BlockStore.load();
      final controller = makeController();
      addTearDown(controller.dispose);

      final seed = CountingNullRoom();
      final enforcer = BlockAudioEnforcer(
        rtc: LiveKitRtcService(),
        controller: controller,
        blocks: blocks,
        roomGetter: seed.call,
      );
      await enforcer.dispose();
      final int before = seed.lookups;

      // 进房事件:phase 转成 inRoom 并 notifyListeners
      await controller.testInjectToken('wss://fake', 'tok');
      await pumpEventQueue();

      expect(seed.lookups, before);
    });

    test('dispose 之后 applyNow 也是安静的 no-op', () async {
      final blocks = await BlockStore.load();
      final controller = makeController();
      addTearDown(controller.dispose);

      final seed = CountingNullRoom();
      final enforcer = BlockAudioEnforcer(
        rtc: LiveKitRtcService(),
        controller: controller,
        blocks: blocks,
        roomGetter: seed.call,
      );
      await enforcer.dispose();
      final int before = seed.lookups;

      await expectLater(enforcer.applyNow(), completes);
      expect(seed.lookups, before);
      expect(enforcer.appliedMutes, isEmpty);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('生命周期接线', () {
    test('进房通知会让执行器去取 Room(热重载/重连后能自愈)', () async {
      final blocks = await BlockStore.load();
      final controller = makeController();
      addTearDown(controller.dispose);

      final seed = CountingNullRoom();
      final enforcer = BlockAudioEnforcer(
        rtc: LiveKitRtcService(),
        controller: controller,
        blocks: blocks,
        roomGetter: seed.call,
      );
      addTearDown(enforcer.dispose);

      final int before = seed.lookups;
      await controller.testInjectToken('wss://fake', 'tok');
      await pumpEventQueue();
      expect(controller.phase, RoomPhase.inRoom);
      expect(seed.lookups, greaterThan(before),
          reason: '进房后必须重新去拿 Room —— Room 是每会话重建的,不能缓存');
    });

    test('构造时就会看一眼房间状态,而不是干等下一次事件', () async {
      final blocks = await BlockStore.load();
      final controller = makeController();
      addTearDown(controller.dispose);

      // 先进房,再创建执行器(热重载后的真实顺序)
      await controller.testInjectToken('wss://fake', 'tok');
      expect(controller.phase, RoomPhase.inRoom);

      final seed = CountingNullRoom();
      final enforcer = BlockAudioEnforcer(
        rtc: LiveKitRtcService(),
        controller: controller,
        blocks: blocks,
        roomGetter: seed.call,
      );
      addTearDown(enforcer.dispose);

      expect(seed.lookups, greaterThan(0),
          reason: '构造体里就该立即 apply 一次,不能等到下次 phase 变化');
    });
  });
}
