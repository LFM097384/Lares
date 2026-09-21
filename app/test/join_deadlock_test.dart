import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/net/signaling_client.dart';
import 'package:lares_app/src/rtc/rtc_service.dart';
import 'package:lares_app/src/state/models.dart';
import 'package:lares_app/src/state/room_controller.dart';

/// 「进了 joining 却出不来」的穷举回归。
///
/// ## 为什么要单独一个文件
///
/// 同一个 bug 修了三次(4401 被拒、口令为空、信令层放弃重连),每次都是
/// 某条失败路径忘了解 `_joinCompleter`、忘了把 phase 挪走。三次都是补一条,
/// 补完又冒出下一条。这个文件换个思路:不按 bug 组织,按**出口**组织 ——
/// 每个用例守一条「从 joining 出去」的路,新加的路径必须在这里留下一行。
///
/// ## 为什么直接注入原始信令报文
///
/// `FakeSignalingClient` 的简化正是前三次漏网的原因:它不走真实的 4401
/// 重试逻辑,于是「退出后再进入」的测试一直是绿的,而真机必卡。所以这里
/// 一律用 `testInject` 灌**信令层真的会发出的那条报文**
/// (`_auth_failed` / `_credential_required` / `error` / `_disconnected`),
/// 而不是依赖 fake 的高层行为。fake 能骗过的东西,报文骗不过。
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
  int leaveCount = 0;

  /// 让 `join()` 挂住不返回,模拟「连接卡在半路」。
  Completer<void>? gate;

  /// 让 `join()` 抛异常,模拟媒体层失败。
  Object? throwOnJoin;

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
    joinCount++;
    if (gate != null) await gate!.future;
    final err = throwOnJoin;
    if (err != null) throw err;
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
    leaveCount++;
    _inRoom = false;
  }

  @override
  Future<void> setMuted(bool m) async {}

  @override
  Stream<Set<String>> get speakingIdentities => _speaking.stream;

  @override
  Stream<void> get onDisconnected => _dropped.stream;

  void testEmitDrop() => _dropped.add(null);
}

RoomController _make(FakeSignalingClient s, FakeRtcService rtc) =>
    RoomController(
      signaling: s,
      rtc: rtc,
      userId: 'u_me',
      deviceId: 'd_1',
      userName: '我',
    );

void main() {
  group('服务端 error 报文:每一条都得有出口', () {
    // 以前这个分支**只**认 rtc_not_configured,其余一概落地无声。
    // 而服务端在进房这条路上还会发 token_failed / auth_scope /
    // already_in_room / rate_limited —— 每一条都意味着「不会有 room 了」。
    for (final (String reason, String label) in <(String, String)>[
      ('token_failed', '签不出 RTC token'),
      ('auth_scope', '证明的不是这个圈子'),
      ('already_in_room', '服务端认为会话还在别的房间'),
      ('rate_limited', '被限流'),
      ('say_hello_first', '握手掉了'),
      ('rtc_not_configured', '服务器没配 LiveKit'),
    ]) {
      test('error/$reason($label)必须终结 joining', () async {
        final signaling = FakeSignalingClient();
        final controller = _make(signaling, FakeRtcService());
        addTearDown(controller.dispose);

        final joined = controller.join('work');
        final expectation = expectLater(joined, throwsA(isA<StateError>()));
        expect(controller.phase, RoomPhase.joining);

        signaling.testInject({'t': 'error', 'message': reason});
        await pumpEventQueue();

        expect(controller.phase, RoomPhase.error,
            reason: '$reason 不能让界面停在「正在进去…」');
        expect(controller.errorMessage, isNotNull);
        await expectation;
      });
    }

    test('与进房无关的 error 不打断用户', () async {
      // 同一条 socket 上还跑着聊天和图片。它们被拒(消息太大/坏包)
      // 与这次进房毫无关系,拿来落 error 是另一种误伤 ——
      // 那会表现为「正在打字,进房突然失败了」。
      final signaling = FakeSignalingClient();
      final controller = _make(signaling, FakeRtcService());
      addTearDown(controller.dispose);

      unawaited(controller.join('work').catchError((Object _) {}));
      for (final noise in ['too_large', 'payload_too_large', 'bad_json']) {
        signaling.testInject({'t': 'error', 'message': noise});
        await pumpEventQueue();
        expect(controller.phase, RoomPhase.joining, reason: '$noise 与进房无关');
      }
    });

    test('不在进房时收到 error 不会凭空落错误态', () async {
      final signaling = FakeSignalingClient();
      final rtc = FakeRtcService();
      final controller = _make(signaling, rtc);
      addTearDown(controller.dispose);

      final joined = controller.join('work');
      await controller.testInjectToken('wss://fake', 'tok');
      await joined;
      expect(controller.phase, RoomPhase.inRoom);

      // 已经在房里了,auth_scope 指的是别的消息被拒(比如给别的圈子发东西),
      // 不该把人踢出当前这次通话。
      signaling.testInject({'t': 'error', 'message': 'auth_scope'});
      await pumpEventQueue();
      expect(controller.phase, RoomPhase.inRoom);
    });
  });

  group('信令层压根没去连(_credential_required)', () {
    // 信令层的 connect() 在凭据不全时直接 return 不建连接,
    // _sendHelloWithProof() 在算不出证明时连 hello 都不发(连接却开着)。
    // 两条都不产生任何事件 —— 不喊一声,上层就是永久 joining。
    // 这正是第 2 次 bug 的根因,当时只在 join() 前加了一道检查,
    // 而那道检查读的是 SettingsStore,与信令层自己的凭据来源可能不一致。
    test('_credential_required 必须终结 joining', () async {
      final signaling = FakeSignalingClient();
      final controller = _make(signaling, FakeRtcService());
      addTearDown(controller.dispose);

      final joined = controller.join('work');
      final expectation = expectLater(joined, throwsA(isA<StateError>()));
      expect(controller.phase, RoomPhase.joining);

      signaling.testInject(
          {'t': '_credential_required', 'message': 'auth_required'});
      await pumpEventQueue();

      expect(controller.phase, RoomPhase.error);
      // 这条确实该弹口令框:缺的就是口令。
      expect(controller.needsPasscode, isTrue);
      await expectation;
    });
  });

  group('进房总超时:兜住所有「服务端不回话」', () {
    // 前三次都是「某条具体路径漏了出口」,一条条补。但漏的方式是无穷的:
    // 服务端收下 join 之后因为任何原因不回 room/token,都不产生事件,
    // 因此不可能靠多处理一条消息修好。只有时间能兜住。
    test('服务端收了 join 却一直不回话 -> 超时落 error', () {
      fakeAsync((async) {
        final signaling = FakeSignalingClient();
        final controller = _make(signaling, FakeRtcService());

        unawaited(controller.join('work').catchError((Object _) {}));
        async.flushMicrotasks();
        expect(controller.phase, RoomPhase.joining);

        // 20 秒:还在等。慢网络不能被误伤 —— 信令断开后的指数退避重连
        // (1+2+4+8s)加上重新握手,最坏十几秒仍属正常。
        async.elapse(const Duration(seconds: 20));
        expect(controller.phase, RoomPhase.joining, reason: '慢不等于坏');

        async.elapse(const Duration(seconds: 6));
        expect(controller.phase, RoomPhase.error, reason: '25 秒必须有个说法');
        expect(controller.errorMessage, isNotNull);
        // 服务端可能已经把我们记成在房里了(join 收到了、只是回包没来),
        // 不打招呼就走会在那边留一个幽灵成员。
        expect(signaling.sent.any((m) => m['t'] == 'leave'), isTrue);

        controller.dispose();
      });
    });

    test('敲门不受总超时管(敲门可能要等半分钟)', () {
      fakeAsync((async) {
        final signaling = FakeSignalingClient();
        final controller = _make(signaling, FakeRtcService());

        unawaited(controller.join('vip').catchError((Object _) {}));
        signaling.testInject({'t': 'knock_waiting', 'circleId': 'vip'});
        async.elapse(Duration.zero);
        expect(controller.knocking, isTrue);

        // 25 秒时总超时若还活着就会抢先开枪,而它说的是「服务器没回话」——
        // 与实情(对方还没来应门)不符。措辞必须是敲门那条。
        async.elapse(const Duration(seconds: 26));
        expect(controller.knocking, isTrue, reason: '还在等人应门');
        expect(controller.phase, RoomPhase.joining);

        async.elapse(const Duration(seconds: 5)); // 满 30s
        expect(controller.phase, RoomPhase.error);
        expect(controller.errorMessage, contains('没人应门'));

        controller.dispose();
      });
    });

    test('正常进房会撤掉总超时(不会事后自己变成错误)', () {
      fakeAsync((async) {
        final signaling = FakeSignalingClient();
        final rtc = FakeRtcService();
        final controller = _make(signaling, rtc);

        unawaited(controller.join('work').catchError((Object _) {}));
        unawaited(controller.testInjectToken('wss://fake', 'tok'));
        async.flushMicrotasks();
        expect(controller.phase, RoomPhase.inRoom);

        // 进房成功之后再过很久,不该被自己的超时打下来。
        async.elapse(const Duration(minutes: 1));
        expect(controller.phase, RoomPhase.inRoom);

        controller.dispose();
      });
    });

    test('失败之后超时不会再开第二枪', () {
      fakeAsync((async) {
        final signaling = FakeSignalingClient();
        final controller = _make(signaling, FakeRtcService());

        unawaited(controller.join('work').catchError((Object _) {}));
        signaling.testInject({'t': '_auth_failed', 'message': 'auth_failed'});
        async.elapse(Duration.zero);
        expect(controller.phase, RoomPhase.error);
        final firstMessage = controller.errorMessage;

        // 4401 的措辞(要口令)不能在 25 秒后被超时的措辞盖掉 ——
        // 那会让用户以为是网络问题,而其实是缺口令。
        async.elapse(const Duration(seconds: 30));
        expect(controller.phase, RoomPhase.error);
        expect(controller.errorMessage, firstMessage);

        controller.dispose();
      });
    });
  });

  group('RTC 层的失败与挂起', () {
    test('rtc.join() 抛异常 -> error,不卡 joining', () async {
      final signaling = FakeSignalingClient();
      final rtc = FakeRtcService()..throwOnJoin = StateError('媒体连不上');
      final controller = _make(signaling, rtc);
      addTearDown(controller.dispose);

      final joined = controller.join('work');
      final expectation = expectLater(joined, throwsA(isA<StateError>()));
      unawaited(controller.testInjectToken('wss://fake', 'tok'));
      await pumpEventQueue();

      expect(controller.phase, RoomPhase.error);
      await expectation;
    });

    test('rtc.join() 挂起不返回 -> 由总超时兜底', () {
      fakeAsync((async) {
        final signaling = FakeSignalingClient();
        // gate 永不完成:模拟媒体层连接卡死(真机上见过,SDK 内部等 ICE)。
        final rtc = FakeRtcService()..gate = Completer<void>();
        final controller = _make(signaling, rtc);

        unawaited(controller.join('work').catchError((Object _) {}));
        unawaited(controller.testInjectToken('wss://fake', 'tok'));
        async.flushMicrotasks();
        expect(controller.phase, RoomPhase.joining);

        async.elapse(const Duration(seconds: 26));
        expect(controller.phase, RoomPhase.error, reason: '媒体挂起也得有出口');

        controller.dispose();
      });
    });

    test('媒体掉线会自动用缓存 token 接回来', () async {
      final signaling = FakeSignalingClient();
      final rtc = FakeRtcService();
      final controller = _make(signaling, rtc);
      addTearDown(controller.dispose);

      final joined = controller.join('work');
      await controller.testInjectToken('wss://fake', 'tok');
      await joined;
      expect(controller.phase, RoomPhase.inRoom);

      // 以前这里只是 `phase = joining` 然后「等上层重进」——
      // 可从来没有哪个上层会重进,界面就永久停在「正在进去…」。
      rtc.testEmitDrop();
      await pumpEventQueue();

      expect(controller.phase, RoomPhase.inRoom, reason: '应当自动接回来');
      expect(rtc.joinCount, 2);
    });

    test('媒体掉线且接不回来 -> 落 error 而不是永久 joining', () async {
      final signaling = FakeSignalingClient();
      final rtc = FakeRtcService();
      final controller = _make(signaling, rtc);
      addTearDown(controller.dispose);

      final joined = controller.join('work');
      await controller.testInjectToken('wss://fake', 'tok');
      await joined;

      rtc.throwOnJoin = StateError('接不回来');
      rtc.testEmitDrop();
      await pumpEventQueue();

      expect(controller.phase, RoomPhase.error);
      expect(controller.errorMessage, isNotNull);
    });
  });

  group('用户中途按「算了」', () {
    test('leave 会解开 join 的 future,不留吊着的 await', () async {
      // 这是「卡住」的隐身变体:界面读 phase,看着是好的,
      // 但 `await join()` 的调用方永远回不来。
      final signaling = FakeSignalingClient();
      final controller = _make(signaling, FakeRtcService());
      addTearDown(controller.dispose);

      final joined = controller.join('work');
      final expectation = expectLater(joined, throwsA(isA<StateError>()));
      await controller.leave();

      expect(controller.phase, RoomPhase.idle);
      await expectation.timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('leave 之后 join 的 future 仍然吊着'),
      );
    });

    test('退房之后,在途的 rtc.join() 回来也不许把人拽回房间', () async {
      // 媒体连接要好几秒。这期间用户完全可能按「算了」——
      // 旧那次的 await 一返回就把 inRoom 提交掉,表现是「退了房又自己回去」。
      final signaling = FakeSignalingClient();
      final gate = Completer<void>();
      final rtc = FakeRtcService()..gate = gate;
      final controller = _make(signaling, rtc);
      addTearDown(controller.dispose);

      unawaited(controller.join('work').catchError((Object _) {}));
      unawaited(controller.testInjectToken('wss://fake', 'tok'));
      await pumpEventQueue();
      expect(controller.phase, RoomPhase.joining);

      await controller.leave();
      expect(controller.phase, RoomPhase.idle);

      // 媒体这才连上 —— 但那已经是上一代的事了。
      gate.complete();
      await pumpEventQueue();

      expect(controller.phase, RoomPhase.idle, reason: '不能自己回到房间里');
      // 而且连好的那条媒体流必须拆掉:否则用户明明走了,却还在被人听见。
      expect(rtc.inRoom, isFalse, reason: '不能留下没人管的音频流');
    });

    test('leave 清干净了:下一次进房的耗时不含上一段挂机时间', () {
      fakeAsync((async) {
        final signaling = FakeSignalingClient();
        final rtc = FakeRtcService();
        final controller = _make(signaling, rtc);

        unawaited(controller.join('work').catchError((Object _) {}));
        unawaited(controller.testInjectToken('wss://fake', 'tok'));
        async.flushMicrotasks();

        // 在房里待 10 分钟(_joinStopwatch 不归零的话会把这段算进去)
        async.elapse(const Duration(minutes: 10));
        unawaited(controller.leave());
        async.flushMicrotasks();

        unawaited(controller.join('work').catchError((Object _) {}));
        unawaited(controller.testInjectToken('wss://fake', 'tok2'));
        async.flushMicrotasks();

        expect(controller.phase, RoomPhase.inRoom);
        expect(controller.lastJoinLatency!.inMinutes, lessThan(1),
            reason: '耗时统计被上一段会话污染了');

        controller.dispose();
      });
    });

    test('leave 会丢掉预热 token,不拿旧会话的票去连媒体', () async {
      // 退房往往正是因为口令/权限出了问题,那张旧 token 多半已经不作数,
      // 留着只会让 RTC 先连上去再失败。
      final signaling = FakeSignalingClient();
      final rtc = FakeRtcService();
      final controller = _make(signaling, rtc);
      addTearDown(controller.dispose);

      signaling.testInject({
        't': 'token',
        'circleId': 'work',
        'url': 'wss://fake',
        'token': 'cached',
        'prefetch': true,
      });
      await pumpEventQueue();

      final joined = controller.join('work');
      await pumpEventQueue();
      await joined;
      expect(controller.phase, RoomPhase.inRoom);

      await controller.leave();

      // 再进房:缓存已被清掉,不该再凭空冒出一次媒体连接。
      final before = rtc.joinCount;
      unawaited(controller.join('work').catchError((Object _) {}));
      await pumpEventQueue();
      expect(rtc.joinCount, before, reason: '不该用上一段会话的 token');
      expect(controller.phase, RoomPhase.joining);
    });
  });

  group('_joinCompleter 被覆盖', () {
    test('第二次 join 会了结第一次的 future,不让它永远吊着', () async {
      // retryJoin 走的正是 force 路径,它会直接盖掉 _joinCompleter。
      // 被盖掉的那个从此没有任何人会去 complete。
      final signaling = FakeSignalingClient();
      final rtc = FakeRtcService();
      final controller = _make(signaling, rtc);
      addTearDown(controller.dispose);

      final first = controller.join('work');
      final expectation = expectLater(first, throwsA(isA<StateError>()));

      unawaited(controller.join('other', force: true).catchError((Object _) {}));

      await expectation.timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('第一次 join 的 future 被遗弃了'),
      );
      expect(controller.circleId, 'other');
    });

    test('被覆盖之后,第二次仍然能正常进房', () async {
      final signaling = FakeSignalingClient();
      final rtc = FakeRtcService();
      final controller = _make(signaling, rtc);
      addTearDown(controller.dispose);

      unawaited(controller.join('work').catchError((Object _) {}));
      final second = controller.join('work', force: true);
      await controller.testInjectToken('wss://fake', 'tok');
      await second.timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('覆盖之后第二次也卡住了'),
      );
      expect(controller.phase, RoomPhase.inRoom);
    });
  });

  group('断线重连期间', () {
    test('掉出房间后若重连始终不成,最终要有个说法', () {
      fakeAsync((async) {
        final signaling = FakeSignalingClient();
        final rtc = FakeRtcService();
        final controller = _make(signaling, rtc);

        unawaited(controller.join('work').catchError((Object _) {}));
        unawaited(controller.testInjectToken('wss://fake', 'tok'));
        async.flushMicrotasks();
        expect(controller.phase, RoomPhase.inRoom);

        // 普通抖动:交给信令层自动重连,不打断用户。
        signaling.testInject({'t': '_disconnected'});
        async.elapse(Duration.zero);
        expect(controller.phase, RoomPhase.joining);

        // 但信令层的重连链可能静默断掉(凭据不全时 connect() 直接 return),
        // 此后不会再有任何事件。以前这里就永久停住了。
        async.elapse(const Duration(seconds: 26));
        expect(controller.phase, RoomPhase.error, reason: '重连不成也要有出口');

        controller.dispose();
      });
    });

    test('welcome 恢复房间态时也挂表(服务端可能不回 room)', () {
      fakeAsync((async) {
        final signaling = FakeSignalingClient();
        final rtc = FakeRtcService();
        final controller = _make(signaling, rtc);

        unawaited(controller.join('work').catchError((Object _) {}));
        unawaited(controller.testInjectToken('wss://fake', 'tok'));
        async.flushMicrotasks();

        signaling.testInject({'t': '_disconnected'});
        async.elapse(Duration.zero);
        // 重连上了,自动重发 join —— 但服务端这次不回 room。
        signaling.testInject({'t': 'welcome', 'userId': 'u_me'});
        async.elapse(Duration.zero);
        expect(controller.phase, RoomPhase.joining);

        async.elapse(const Duration(seconds: 26));
        expect(controller.phase, RoomPhase.error,
            reason: '恢复房间态这条路绕开了 join(),以前没有任何东西兜着它');

        controller.dispose();
      });
    });

    test('重连成功拿到 token 就不该再超时', () {
      fakeAsync((async) {
        final signaling = FakeSignalingClient();
        final rtc = FakeRtcService();
        final controller = _make(signaling, rtc);

        unawaited(controller.join('work').catchError((Object _) {}));
        unawaited(controller.testInjectToken('wss://fake', 'tok'));
        async.flushMicrotasks();

        signaling.testInject({'t': '_disconnected'});
        async.elapse(Duration.zero);
        signaling.testInject({'t': 'welcome', 'userId': 'u_me'});
        async.elapse(Duration.zero);

        signaling.testInject({
          't': 'token',
          'circleId': 'work',
          'url': 'wss://fake',
          'token': 'tok2',
        });
        async.elapse(Duration.zero);
        async.flushMicrotasks();
        expect(controller.phase, RoomPhase.inRoom);

        async.elapse(const Duration(minutes: 1));
        expect(controller.phase, RoomPhase.inRoom, reason: '已经回来了');

        controller.dispose();
      });
    });
  });

  group('dispose', () {
    test('controller 被销毁时不留吊着的 future', () async {
      final signaling = FakeSignalingClient();
      final controller = _make(signaling, FakeRtcService());

      final joined = controller.join('work');
      final expectation = expectLater(joined, throwsA(isA<StateError>()));
      controller.dispose();

      await expectation.timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('dispose 之后 join 的 future 仍然吊着'),
      );
    });
  });
}
