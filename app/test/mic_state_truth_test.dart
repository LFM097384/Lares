import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/net/secret_vault.dart';
import 'package:lares_app/src/net/signaling_client.dart';
import 'package:lares_app/src/platform/widget_service.dart';
import 'package:lares_app/src/rtc/livekit_rtc_service.dart';
import 'package:lares_app/src/rtc/rtc_service.dart';
import 'package:lares_app/src/state/circle_store.dart';
import 'package:lares_app/src/state/mic_notice.dart';
import 'package:lares_app/src/state/models.dart';
import 'package:lares_app/src/state/room_controller.dart';
import 'package:lares_app/src/state/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「开麦状态显示的必须是真实状态」这一原则的验收。
///
/// 两个真实 bug 的回归:
///  1. 媒体闲时挂起时 toggleMute 的 setMuted 被唤醒吞掉,界面说开着、麦克风其实关着;
///  2. 开麦失败(没权限)时 muted 已经翻转,界面说谎且用户不知道去哪改。
/// 以及「进圈时打开麦克风」只对用户主动进圈生效,任何自动路径都不许开麦。

class _Signaling extends SignalingClient {
  _Signaling() : super(url: 'ws://fake');
  final List<Map<String, dynamic>> sent = [];
  @override
  void connect() {}
  @override
  void send(Map<String, dynamic> msg) => sent.add(msg);
  @override
  Future<void> dispose() async {}
}

/// 忠实模拟「麦克风真实状态」的 RTC 假件:
/// - [micOn] 是底层真相,只由成功的操作改变;
/// - [denyMic] 模拟没给权限:开麦失败,且真相保持关闭;
/// - [joinGate] 让 join 挂住,模拟唤醒/连接在途。
class _TruthRtc implements RtcService {
  final _speaking = StreamController<Set<String>>.broadcast();
  final _dropped = StreamController<void>.broadcast();
  bool _inRoom = false;
  bool micOn = false;
  bool denyMic = false;
  Completer<void>? joinGate;
  final List<bool> joinStartMuted = [];
  final List<bool> setMutedCalls = [];

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
    joinStartMuted.add(startMuted);
    final gate = joinGate;
    if (gate != null) await gate.future;
    _inRoom = true;
    micOn = false;
    MicFailure? failure;
    if (!startMuted) {
      if (denyMic) {
        failure = MicFailure.permissionDenied;
      } else {
        micOn = true;
      }
    }
    return RtcJoinResult(
      elapsed: const Duration(milliseconds: 5),
      micOn: micOn,
      micFailure: micOn ? null : failure,
    );
  }

  @override
  Future<void> setMuted(bool muted) async {
    setMutedCalls.add(muted);
    // 不在房里(被唤醒前的挂起态)开麦:真实实现里什么都开不了。
    if (!_inRoom) {
      if (!muted) throw MicException(MicFailure.unavailable, micOnNow: false);
      return;
    }
    if (!muted && denyMic) {
      throw MicException(MicFailure.permissionDenied, micOnNow: micOn);
    }
    micOn = !muted;
  }

  @override
  Future<void> leave() async {
    _inRoom = false;
    micOn = false;
  }

  void drop() {
    _inRoom = false;
    micOn = false;
    _dropped.add(null);
  }

  @override
  Stream<Set<String>> get speakingIdentities => _speaking.stream;
  @override
  Stream<void> get onDisconnected => _dropped.stream;
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
}

Future<SettingsStore> _settings({required bool joinWithMicOn}) async {
  final s = await SettingsStore.load(vault: InMemorySecretVault());
  await s.setJoinWithMicOn(joinWithMicOn);
  return s;
}

RoomController _make(_Signaling s, _TruthRtc rtc, {SettingsStore? settings}) =>
    RoomController(
      signaling: s,
      rtc: rtc,
      userId: 'u_me',
      deviceId: 'd_1',
      userName: '我',
      settings: settings,
    );

/// 用户主动进圈并连上媒体。
Future<void> _joinAndConnect(RoomController c, {bool? micOn}) async {
  final joined = c.join('home', micOn: micOn);
  await c.testInjectToken('wss://fake', 'tok');
  await joined;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('设置「进圈时打开麦克风」', () {
    test('默认开', () async {
      final s = await SettingsStore.load(vault: InMemorySecretVault());
      expect(s.joinWithMicOn, isTrue);
    });

    test('设置开 -> 主动进圈即开麦,显示与底层一致', () async {
      final rtc = _TruthRtc();
      final c = _make(_Signaling(), rtc,
          settings: await _settings(joinWithMicOn: true));
      addTearDown(c.dispose);
      await _joinAndConnect(c);
      expect(rtc.joinStartMuted, [false]);
      expect(rtc.micOn, isTrue);
      expect(c.muted, isFalse);
      expect(c.micNotice, isNull);
    });

    test('设置关 -> 主动进圈静音', () async {
      final rtc = _TruthRtc();
      final c = _make(_Signaling(), rtc,
          settings: await _settings(joinWithMicOn: false));
      addTearDown(c.dispose);
      await _joinAndConnect(c);
      expect(rtc.joinStartMuted, [true]);
      expect(rtc.micOn, isFalse);
      expect(c.muted, isTrue);
    });

    test('设置持久化', () async {
      final s = await _settings(joinWithMicOn: false);
      expect(s.joinWithMicOn, isFalse);
      final again = await SettingsStore.load(vault: InMemorySecretVault());
      expect(again.joinWithMicOn, isFalse);
    });

    test('自动路径(micOn: false,如挂机自动进圈 / 被 reach 拉进来)不看设置', () async {
      final rtc = _TruthRtc();
      final c = _make(_Signaling(), rtc,
          settings: await _settings(joinWithMicOn: true));
      addTearDown(c.dispose);
      await _joinAndConnect(c, micOn: false);
      expect(rtc.joinStartMuted, [true]);
      expect(c.muted, isTrue);
    });

    test('进圈开麦失败(没权限):进房照常成功,显示静音并提示去系统设置', () async {
      final rtc = _TruthRtc()..denyMic = true;
      final c = _make(_Signaling(), rtc,
          settings: await _settings(joinWithMicOn: true));
      addTearDown(c.dispose);
      await _joinAndConnect(c);
      expect(c.phase, RoomPhase.inRoom, reason: '开麦失败不能让进房失败 —— 人照样能听');
      expect(rtc.micOn, isFalse);
      expect(c.muted, isTrue, reason: '麦克风没开,就不能显示成开着');
      expect(c.micNotice, MicNotice.permissionDenied);
    });
  });

  group('自动路径绝不开麦', () {
    test('_recoverMedia:断线前静音 -> 恢复后仍静音(即使设置是进圈开麦)', () async {
      final signaling = _Signaling();
      final rtc = _TruthRtc();
      final c = _make(signaling, rtc,
          settings: await _settings(joinWithMicOn: true));
      addTearDown(c.dispose);
      await _joinAndConnect(c);
      await c.toggleMute(); // 用户手动静音
      expect(c.muted, isTrue);
      expect(rtc.micOn, isFalse);

      rtc.drop(); // 媒体掉线 -> _recoverMedia
      await pumpEventQueue();
      expect(c.phase, RoomPhase.joining);
      expect(c.muted, isTrue);
      // 恢复路径向服务端要新 token,服务端回 token
      signaling.testInject(
          {'t': 'token', 'circleId': 'home', 'url': 'wss://fake', 'token': 't2'});
      await pumpEventQueue();
      expect(c.phase, RoomPhase.inRoom);
      expect(rtc.joinStartMuted.last, isTrue, reason: '静音的人被自动重连成了开麦');
      expect(rtc.micOn, isFalse);
      expect(c.muted, isTrue);
    });

    test('_recoverMedia:断线前开着 -> 恢复后按原状态开着(保持,不是强开)', () async {
      final signaling = _Signaling();
      final rtc = _TruthRtc();
      final c = _make(signaling, rtc,
          settings: await _settings(joinWithMicOn: false));
      addTearDown(c.dispose);
      await _joinAndConnect(c);
      await c.toggleMute(); // 用户手动开麦
      expect(c.muted, isFalse);

      rtc.drop();
      await pumpEventQueue();
      // 媒体已断:恢复期间如实显示静音
      expect(c.muted, isTrue);
      signaling.testInject(
          {'t': 'token', 'circleId': 'home', 'url': 'wss://fake', 'token': 't2'});
      await pumpEventQueue();
      expect(rtc.joinStartMuted.last, isFalse);
      expect(c.muted, isFalse);
      expect(rtc.micOn, isTrue);
    });

    test('信令重连 welcome:断线前静音 -> 恢复后仍静音', () async {
      final signaling = _Signaling();
      final rtc = _TruthRtc();
      final c = _make(signaling, rtc,
          settings: await _settings(joinWithMicOn: true));
      addTearDown(c.dispose);
      await _joinAndConnect(c, micOn: false);
      expect(c.muted, isTrue);

      signaling.testInject({'t': '_disconnected'});
      await pumpEventQueue();
      await rtc.leave(); // 模拟媒体随之断开
      signaling.testInject({'t': 'welcome', 'userId': 'u_me'});
      await pumpEventQueue();
      signaling.testInject(
          {'t': 'token', 'circleId': 'home', 'url': 'wss://fake', 'token': 't2'});
      await pumpEventQueue();
      expect(rtc.joinStartMuted.last, isTrue);
      expect(c.muted, isTrue);
    });

    test('_wakeMedia(来人了自动唤醒)不开麦', () {
      fakeAsync((async) {
        final signaling = _Signaling();
        final rtc = _TruthRtc();
        final c = _make(signaling, rtc);
        unawaited(c.join('home', micOn: false));
        unawaited(c.testInjectToken('wss://fake', 'tok'));
        async.flushMicrotasks();
        expect(c.isInRoom, isTrue);

        async.elapse(RoomController.idleDowngradeAfter + const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(c.mediaDowngraded, isTrue);

        signaling.testInject({
          't': 'member_joined',
          'circleId': 'home',
          'member': {'userId': 'u_x', 'name': 'X', 'status': 'free'},
        });
        async.flushMicrotasks();
        expect(c.mediaDowngraded, isFalse);
        expect(rtc.joinStartMuted.last, isTrue, reason: '别人进来不是你开麦的理由');
        expect(rtc.micOn, isFalse);
        expect(c.muted, isTrue);
        c.dispose();
      });
    });
  });

  group('toggleMute:先做,成了再改', () {
    test('bug 1:媒体挂起时开麦 -> 唤醒完成后麦克风真的开着', () {
      fakeAsync((async) {
        final rtc = _TruthRtc();
        final c = _make(_Signaling(), rtc);
        unawaited(c.join('home', micOn: false));
        unawaited(c.testInjectToken('wss://fake', 'tok'));
        async.flushMicrotasks();
        async.elapse(RoomController.idleDowngradeAfter + const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(c.mediaDowngraded, isTrue);
        expect(rtc.inRoom, isFalse);

        // 唤醒挂住,观察中间态:在它落地之前界面不许说「开着」
        rtc.joinGate = Completer<void>();
        bool? result;
        unawaited(c.toggleMute().then((m) => result = m));
        async.flushMicrotasks();
        expect(c.muted, isTrue, reason: '唤醒还没完成,麦克风还没开,不能先显示开着');
        rtc.joinGate!.complete();
        async.flushMicrotasks();

        expect(rtc.micOn, isTrue, reason: '原 bug:开麦被唤醒吞掉,底层仍是关的');
        expect(c.muted, isFalse);
        expect(result, isFalse);
        expect(c.mediaDowngraded, isFalse);
        c.dispose();
      });
    });

    test('bug 1 变体:自动唤醒在途时按开麦 -> 等它落地再补开', () {
      fakeAsync((async) {
        final signaling = _Signaling();
        final rtc = _TruthRtc();
        final c = _make(signaling, rtc);
        unawaited(c.join('home', micOn: false));
        unawaited(c.testInjectToken('wss://fake', 'tok'));
        async.flushMicrotasks();
        async.elapse(RoomController.idleDowngradeAfter + const Duration(seconds: 1));
        async.flushMicrotasks();

        rtc.joinGate = Completer<void>();
        signaling.testInject({
          't': 'member_joined',
          'circleId': 'home',
          'member': {'userId': 'u_x', 'name': 'X', 'status': 'free'},
        });
        async.flushMicrotasks(); // 静音唤醒已发出、挂着
        unawaited(c.toggleMute());
        async.flushMicrotasks();
        expect(c.muted, isTrue);
        rtc.joinGate!.complete();
        async.flushMicrotasks();
        expect(rtc.micOn, isTrue);
        expect(c.muted, isFalse);
        c.dispose();
      });
    });

    test('bug 2:开麦失败(没权限)-> muted 回到 true,提示去系统设置', () async {
      final rtc = _TruthRtc();
      final c = _make(_Signaling(), rtc);
      addTearDown(c.dispose);
      await _joinAndConnect(c, micOn: false);
      rtc.denyMic = true;
      final after = await c.toggleMute();
      expect(after, isTrue);
      expect(c.muted, isTrue);
      expect(rtc.micOn, isFalse);
      expect(c.micNotice, MicNotice.permissionDenied);
      c.consumeMicNotice();
      expect(c.micNotice, isNull);
    });

    test('静音失败 -> 如实显示仍开着,并提示', () async {
      final rtc = _ThrowingMuteRtc();
      final c = _make(_Signaling(), rtc);
      addTearDown(c.dispose);
      await _joinAndConnect(c, micOn: true);
      expect(c.muted, isFalse);
      await c.toggleMute();
      expect(c.muted, isFalse, reason: '静音没成功,麦克风还开着,不能显示成静音');
      expect(c.micNotice, MicNotice.muteFailed);
    });

    test('不在房时 toggleMute 什么都不做', () async {
      final rtc = _TruthRtc();
      final c = _make(_Signaling(), rtc);
      addTearDown(c.dispose);
      final r = await c.toggleMute();
      expect(r, isTrue);
      expect(c.muted, isTrue);
      expect(rtc.setMutedCalls, isEmpty);
    });

    test('开麦途中退房:迟到的成功不许把 muted 改回开着', () async {
      final rtc = _SlowMuteRtc();
      final c = _make(_Signaling(), rtc);
      addTearDown(c.dispose);
      await _joinAndConnect(c, micOn: false);
      final pending = c.toggleMute();
      await c.leave();
      rtc.gate.complete();
      await pending;
      expect(c.muted, isTrue);
    });
  });

  test('LiveKit 异常归类:权限类 -> permissionDenied,其它 -> unavailable', () {
    expect(LiveKitRtcService.classifyMicError(
            PlatformException(code: 'x', message: 'Permission denied')),
        MicFailure.permissionDenied);
    expect(LiveKitRtcService.classifyMicError(Exception('NotAllowedError')),
        MicFailure.permissionDenied);
    expect(LiveKitRtcService.classifyMicError(Exception('device busy')),
        MicFailure.unavailable);
  });

  group('小组件:推送的在房状态跟着控制器走', () {
    late List<MethodCall> widgetCalls;
    late Map<String, Object?> store;

    setUp(() {
      widgetCalls = [];
      store = {};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('home_widget'),
              (call) async {
        widgetCalls.add(call);
        if (call.method == 'saveWidgetData') {
          final args = (call.arguments as Map).cast<String, Object?>();
          store[args['id']! as String] = args['data'];
        }
        return true;
      });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('home_widget'), null);
    });

    test('进房 / 开麦 / 静音 / 挂起 / 掉线 / 出房,每一步都写真实状态', () {
      fakeAsync((async) {
        final rtc = _TruthRtc();
        final c = _make(_Signaling(), rtc);
        final w = WidgetService(now: () => DateTime(2026, 9, 22))
          ..attachForTest(c);
        c.addListener(() => unawaited(w.syncRoomState()));

        unawaited(w.syncRoomState(force: true));
        async.flushMicrotasks();
        expect(store['in_room'], isFalse);
        expect(store['muted'], isTrue);

        unawaited(c.join('home', micOn: false));
        async.flushMicrotasks();
        expect(store['in_room'], isFalse, reason: 'joining 不算在房:麦克风还没法开');

        unawaited(c.testInjectToken('wss://fake', 'tok'));
        async.flushMicrotasks();
        expect(store['in_room'], isTrue);
        expect(store['muted'], isTrue);
        expect(store['room_circle_id'], 'home');
        expect(store['state_updated_at'], isA<String>());

        unawaited(c.toggleMute());
        async.flushMicrotasks();
        expect(store['muted'], isFalse);
        expect(rtc.micOn, isTrue);

        unawaited(c.toggleMute());
        async.flushMicrotasks();
        expect(store['muted'], isTrue);

        // 心跳:在房期间定期刷新时间戳
        final before = widgetCalls.length;
        async.elapse(WidgetService.heartbeatEvery);
        async.flushMicrotasks();
        expect(widgetCalls.length, greaterThan(before), reason: '在房期间应有心跳');

        // 闲时挂起:仍在房(presence 在),麦克风确实关着
        async.elapse(RoomController.idleDowngradeAfter);
        async.flushMicrotasks();
        expect(c.mediaDowngraded, isTrue);
        expect(store['in_room'], isTrue);
        expect(store['muted'], isTrue);

        // 掉线:joining,不在房
        unawaited(c.toggleMute()); // 借开麦唤醒回来
        async.flushMicrotasks();
        expect(store['muted'], isFalse);
        rtc.drop();
        async.flushMicrotasks();
        expect(store['in_room'], isFalse);
        expect(store['muted'], isTrue);

        unawaited(c.leave());
        async.flushMicrotasks();
        expect(store['in_room'], isFalse);
        expect(store['room_circle_id'], '');

        // 出房后心跳停止
        final afterLeave = widgetCalls.length;
        async.elapse(WidgetService.heartbeatEvery * 3);
        async.flushMicrotasks();
        expect(widgetCalls.length, afterLeave, reason: '不在房就不该再有心跳');
        w.dispose();
        c.dispose();
      });
    });

    test('不在房时收到小组件切换请求 -> 不开麦,回报不在房', () async {
      final rtc = _TruthRtc();
      final c = _make(_Signaling(), rtc);
      addTearDown(c.dispose);
      final w = WidgetService(backgroundMicReady: () async => true)
        ..attachForTest(c);
      final reply = await w.handleToggleRequest(circleId: 'home');
      expect(reply, {'inRoom': false, 'muted': true, 'circleId': ''});
      expect(rtc.setMutedCalls, isEmpty);
      expect(rtc.micOn, isFalse);
    });

    test('在房 -> 小组件切换请求开麦,回报真实结果', () async {
      final rtc = _TruthRtc();
      final c = _make(_Signaling(), rtc);
      addTearDown(c.dispose);
      await _joinAndConnect(c, micOn: false);
      final w = WidgetService(backgroundMicReady: () async => true)
        ..attachForTest(c);
      final reply = await w.handleToggleRequest(circleId: 'home');
      expect(reply, {'inRoom': true, 'muted': false, 'circleId': 'home'});
      expect(rtc.micOn, isTrue);
    });

    test('开麦失败(没权限)时小组件回报的仍是静音', () async {
      final rtc = _TruthRtc();
      final c = _make(_Signaling(), rtc);
      addTearDown(c.dispose);
      await _joinAndConnect(c, micOn: false);
      rtc.denyMic = true;
      final w = WidgetService(backgroundMicReady: () async => true)
        ..attachForTest(c);
      final reply = await w.handleToggleRequest(circleId: 'home');
      expect(reply['muted'], isTrue);
      expect(store['muted'], isTrue);
    });

    test('后台开麦前提不满足(Android 前台服务没在跑)-> 拒绝开麦,但静音照常放行', () async {
      final rtc = _TruthRtc();
      final c = _make(_Signaling(), rtc);
      addTearDown(c.dispose);
      await _joinAndConnect(c, micOn: true);
      final w = WidgetService(backgroundMicReady: () async => false)
        ..attachForTest(c);
      // 静音方向:放行
      var reply = await w.handleToggleRequest(circleId: 'home');
      expect(reply['muted'], isTrue);
      expect(rtc.micOn, isFalse);
      // 开麦方向:拒绝,如实回报仍静音
      reply = await w.handleToggleRequest(circleId: 'home');
      expect(reply['muted'], isTrue);
      expect(rtc.micOn, isFalse);
    });

    test('小组件显示的圈子与所在圈子不一致 -> 不切换', () async {
      final rtc = _TruthRtc();
      final c = _make(_Signaling(), rtc);
      addTearDown(c.dispose);
      await _joinAndConnect(c, micOn: false);
      final w = WidgetService(backgroundMicReady: () async => true)
        ..attachForTest(c);
      final reply = await w.handleToggleRequest(circleId: 'other');
      expect(reply['muted'], isTrue);
      expect(rtc.setMutedCalls, isEmpty);
    });

    test('人在非主圈子:小组件不显示麦克风按钮(不在房)', () async {
      final circles = await CircleStore.load();
      await circles.add(const Circle(id: 'work', name: 'W'));
      final rtc = _TruthRtc();
      final c = _make(_Signaling(), rtc);
      addTearDown(c.dispose);
      final joined = c.join('work', micOn: false);
      await c.testInjectToken('wss://fake', 'tok');
      await joined;
      final w = WidgetService(backgroundMicReady: () async => true)
        ..attachForTest(c, circleStore: circles);
      expect(circles.primaryCircleId, isNot('work'));
      final reply = await w.handleToggleRequest(circleId: 'work');
      expect(reply['inRoom'], isFalse);
      expect(rtc.setMutedCalls, isEmpty);
    });
  });
}

/// 静音会失败、而麦克风仍开着的 RTC(静音失败的最坏情形)。
class _ThrowingMuteRtc extends _TruthRtc {
  @override
  Future<void> setMuted(bool muted) async {
    setMutedCalls.add(muted);
    if (muted) {
      throw MicException(MicFailure.unavailable, micOnNow: micOn);
    }
    micOn = true;
  }
}

/// setMuted 挂住,直到测试放行。
class _SlowMuteRtc extends _TruthRtc {
  final gate = Completer<void>();
  @override
  Future<void> setMuted(bool muted) async {
    await gate.future;
    await super.setMuted(muted);
  }
}
