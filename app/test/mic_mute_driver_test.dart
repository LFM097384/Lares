import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/net/secret_vault.dart';
import 'package:lares_app/src/net/signaling_client.dart';
import 'package:lares_app/src/rtc/livekit_rtc_service.dart';
import 'package:lares_app/src/rtc/mic_mute.dart';
import 'package:lares_app/src/rtc/rtc_service.dart';
import 'package:lares_app/src/state/room_controller.dart';
import 'package:lares_app/src/state/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 静音状态机回归:TestFlight 46 上「进房后第一次静音总报静音失败」。
///
/// 根因:LiveKit 的 isMicrophoneEnabled() 读 publication.muted,
/// 它由异步广播事件更新,`await setMicrophoneEnabled(false)` 返回时仍是旧值。
/// [_FakeTrack] 忠实复现这一点:[_FakeTrack.staleEnabled] 晚一个事件循环才跟上。

/// 假的麦克风轨道 / 房间。
class _FakeTrack implements MicPort {
  _FakeTrack({this.live = false});

  @override
  bool live;

  /// 模拟 SDK 的 publication.muted:晚一拍才更新(旧代码读的就是它)。
  bool staleEnabled = false;

  /// 前 N 次调用抛异常。
  int failFirst = 0;

  /// 抛异常时状态是否已经改过去了(SDK 做了一半才抛)。
  bool failAfterApplying = false;

  Object error = StateError('AVAudioSession reconfigure timed out');

  /// 设置后 setEnabled 挂住,模拟轨道正在发布。
  Completer<void>? gate;

  final List<bool> calls = [];

  @override
  Future<void> setEnabled(bool enabled) async {
    calls.add(enabled);
    final g = gate;
    if (g != null) await g.future;
    if (failFirst > 0) {
      failFirst--;
      if (failAfterApplying) live = enabled;
      throw error;
    }
    live = enabled;
    // publication 的镜像值异步才跟上
    scheduleMicrotask(() => scheduleMicrotask(() => staleEnabled = live));
  }
}

class _Signaling extends SignalingClient {
  _Signaling() : super(url: 'ws://fake');
  @override
  void connect() {}
  @override
  void send(Map<String, dynamic> msg) {}
  @override
  Future<void> dispose() async {}
}

/// 用真实 [MicMuteDriver] 的 RTC 假件,进房即开麦(与 build 46 的默认一致)。
class _DriverRtc implements RtcService {
  _DriverRtc(this.track) : driver = MicMuteDriver(track, retryDelay: Duration.zero);
  final _FakeTrack track;
  final MicMuteDriver driver;
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
    track.live = !startMuted;
    return RtcJoinResult(
      elapsed: const Duration(milliseconds: 1),
      micOn: track.live,
    );
  }

  @override
  Future<void> setMuted(bool muted) => driver.setMuted(muted);

  @override
  Future<void> leave() async => _inRoom = false;

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MicMuteDriver', () {
    test('按同步真值判定:镜像值滞后也不误报失败(build 46 根因)', () async {
      final t = _FakeTrack(live: true)..staleEnabled = true;
      final d = MicMuteDriver(t, retryDelay: Duration.zero);
      await d.setMuted(true); // 不得抛
      expect(t.live, isFalse);
      // 证明旧判定方式确实会误判:await 返回那一刻镜像值还是「开着」
      expect(t.staleEnabled, isTrue);
      await pumpEventQueue();
      expect(t.staleEnabled, isFalse);
    });

    test('第一次调用抛瞬时错误 -> 重试一次后成功', () async {
      final t = _FakeTrack(live: true)..failFirst = 1;
      final d = MicMuteDriver(t, retryDelay: Duration.zero);
      await d.setMuted(true);
      expect(t.calls, [false, false]);
      expect(t.live, isFalse);
    });

    test('抛了异常但状态其实已达成 -> 按成功处理,不重试', () async {
      final t = _FakeTrack(live: true)
        ..failFirst = 1
        ..failAfterApplying = true;
      final d = MicMuteDriver(t, retryDelay: Duration.zero);
      await d.setMuted(true);
      expect(t.calls, [false]);
      expect(t.live, isFalse);
    });

    test('两次都失败 -> 抛 MicException,micOnNow 为真实状态,cause 保留原始异常', () async {
      final t = _FakeTrack(live: true)..failFirst = 2;
      final d = MicMuteDriver(t, retryDelay: Duration.zero);
      await expectLater(
        d.setMuted(true),
        throwsA(isA<MicException>()
            .having((e) => e.micOnNow, 'micOnNow', isTrue)
            .having((e) => e.cause, 'cause', isA<StateError>())),
      );
      expect(t.calls, [false, false]);
    });

    test('权限被拒不重试', () async {
      final t = _FakeTrack(live: false)
        ..failFirst = 2
        ..error = Exception('Permission denied');
      final d = MicMuteDriver(t,
          retryDelay: Duration.zero,
          classify: LiveKitRtcService.classifyMicError);
      await expectLater(
        d.setMuted(false),
        throwsA(isA<MicException>()
            .having((e) => e.kind, 'kind', MicFailure.permissionDenied)
            .having((e) => e.micOnNow, 'micOnNow', isFalse)),
      );
      expect(t.calls, [true]);
    });

    test('轨道发布在途时的意图排队,只执行最后一个,所有调用者拿到同一结果', () async {
      final t = _FakeTrack(live: false)..gate = Completer<void>();
      final d = MicMuteDriver(t, retryDelay: Duration.zero);
      final publish = d.setMuted(false); // 开麦 -> 发布中
      await pumpEventQueue();
      final a = d.setMuted(true); // 发布还没完就点静音
      final b = d.setMuted(false);
      final c = d.setMuted(true);
      expect(t.calls, [true], reason: '在途期间不许交错调用 SDK');
      t.gate!.complete();
      t.gate = null;
      await Future.wait([publish, a, b, c]);
      expect(t.calls, [true, false], reason: '中间意图被合并,只补最后一个');
      expect(t.live, isFalse);
    });
  });

  group('RoomController + 首次静音失败的假房间', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    Future<RoomController> inRoomWithMicOn(_DriverRtc rtc) async {
      final s = await SettingsStore.load(vault: InMemorySecretVault());
      await s.setJoinWithMicOn(true);
      final c = RoomController(
        signaling: _Signaling(),
        rtc: rtc,
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '我',
        settings: s,
      );
      final joined = c.join('home');
      await c.testInjectToken('wss://fake', 'tok');
      await joined;
      return c;
    }

    test('第一次静音 SDK 抛异常 -> 自动重试,界面显示静音且无失败提示', () async {
      final track = _FakeTrack()..failFirst = 1;
      final rtc = _DriverRtc(track);
      final c = await inRoomWithMicOn(rtc);
      addTearDown(c.dispose);
      expect(c.muted, isFalse);

      final result = await c.toggleMute();
      expect(result, isTrue);
      expect(c.muted, isTrue);
      expect(track.live, isFalse);
      expect(c.micNotice, isNull);
    });

    test('静音彻底失败 -> 界面如实显示麦克风仍开着并提示', () async {
      final track = _FakeTrack()..failFirst = 5;
      final rtc = _DriverRtc(track);
      final c = await inRoomWithMicOn(rtc);
      addTearDown(c.dispose);

      await c.toggleMute();
      expect(track.live, isTrue);
      expect(c.muted, isFalse, reason: '绝不能把开着的麦显示成静音');
      expect(c.micNotice, isNotNull);
    });

    test('失败时真实状态已变 -> 界面跟真实状态走(反方向也不说谎)', () async {
      final track = _FakeTrack()
        ..failFirst = 5
        ..failAfterApplying = true;
      final rtc = _DriverRtc(track);
      final c = await inRoomWithMicOn(rtc);
      addTearDown(c.dispose);

      await c.toggleMute();
      expect(track.live, isFalse);
      expect(c.muted, isTrue);
    });

    test('静音 -> 开麦 -> 静音 连续切换每次都成功', () async {
      final track = _FakeTrack();
      final rtc = _DriverRtc(track);
      final c = await inRoomWithMicOn(rtc);
      addTearDown(c.dispose);
      for (final want in [true, false, true]) {
        expect(await c.toggleMute(), want);
        expect(track.live, !want);
        expect(c.micNotice, isNull);
      }
    });
  });
}
