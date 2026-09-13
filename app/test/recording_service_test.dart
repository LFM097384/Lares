/// 采集核心的纯 VM 测试。
///
/// 刻意**不 import livekit_client**,也不碰 dart:io 与任何插件通道 ——
/// 被测的 [CaptureSession] / [RendererWatchdog] 本来就设计成不依赖 SDK,
/// 于是整套采集策略可以在 `flutter test` 里被完整驱动,不需要真机、
/// 不需要房间、不需要第二个人对着麦克风说话。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/recording/capture_session.dart';
import 'package:lares_app/src/recording/utterance.dart';
import 'package:lares_app/src/recording/vad.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 测试替身
// ─────────────────────────────────────────────────────────────────────────────

/// 假的同意闸门。
///
/// 真正的 [RecordingConsentController] 需要一个 send 回调和一整套信令依赖,
/// 在纯 VM 里构造不出来;而被测代码只认 `Listenable` + 一个同步 getter 这两个
/// 抽象,所以这个十几行的替身就足以覆盖真实控制器的全部对外语义。
class FakeConsent extends ChangeNotifier {
  FakeConsent({bool allowed = true}) : _allowed = allowed;

  bool _allowed;

  bool get allowed => _allowed;

  set allowed(bool value) {
    if (_allowed == value) return;
    _allowed = value;
    notifyListeners();
  }
}

/// 可手动推进的假墙钟。
class FakeClock {
  FakeClock(this._now);

  DateTime _now;

  DateTime call() => _now;

  void advance(Duration d) => _now = _now.add(d);
}

// ─────────────────────────────────────────────────────────────────────────────
// PCM 生成
// ─────────────────────────────────────────────────────────────────────────────

/// 每毫秒的采样点数(16 kHz ⇒ 16),换算帧长时到处要用。
const int kSamplesPerMs = kPcmSampleRate ~/ 1000;

/// 生成一段**恒定幅度**的方波,幅度即 RMS。
///
/// 用方波而不是正弦:方波的 RMS 精确等于幅度,于是"这段音频的 RMS 是多少"
/// 一眼可算,不用为了跨过 [EnergySpeechDetector] 的 700 门限去猜正弦的 0.707 系数。
/// [signature] 决定正负交替的方式,用来给不同说话人打上可辨认的指纹。
Uint8List tone(int durationMs, {required int amplitude, int signature = 1}) {
  final int count = durationMs * kSamplesPerMs;
  final List<int> samples = List<int>.generate(count, (int i) {
    // signature 参与决定翻转周期,于是不同说话人的字节序列不可能相同,
    // 就算幅度被误配到别人头上也能从波形上认出来。
    final bool high = (i ~/ signature).isEven;
    return high ? amplitude : -amplitude;
  });
  return encodePcm16(samples);
}

/// 生成一段纯静音。
Uint8List silence(int durationMs) =>
    Uint8List(durationMs * kSamplesPerMs * kBytesPerSample);

/// 测试用的紧凑 VAD 参数:语义与默认值完全一致,只是把时间尺度压小,
/// 免得每个用例都要喂好几秒音频。
const VadConfig kFastVad = VadConfig(
  hangover: Duration(milliseconds: 100),
  preRoll: Duration(milliseconds: 20),
  minUtterance: Duration(milliseconds: 60),
  maxUtterance: Duration(seconds: 5),
);

/// 一次喂入一整段音频,按 [chunkMs] 切块,模拟真实的 10 ms 帧节奏。
void feed(
  CaptureSession session,
  String identity,
  String displayName,
  Uint8List pcm, {
  int chunkMs = 10,
  FakeClock? clock,
}) {
  final int chunkBytes = chunkMs * kSamplesPerMs * kBytesPerSample;
  for (int off = 0; off < pcm.lengthInBytes; off += chunkBytes) {
    final int end = (off + chunkBytes) > pcm.lengthInBytes
        ? pcm.lengthInBytes
        : off + chunkBytes;
    session.onFrameBytes(
      identity,
      displayName,
      Uint8List.sublistView(pcm, off, end),
      kPcmSampleRate,
      1,
    );
    // 墙钟与音频同步推进,免得误触发时钟重锚。
    clock?.advance(Duration(milliseconds: chunkMs));
  }
}

/// 判定一段 [Utterance] 的主导幅度,用来反查它到底来自哪个说话人。
int dominantAmplitude(Utterance u) {
  final Int16List s = u.toSamples();
  int maxAbs = 0;
  for (int i = 0; i < s.length; i++) {
    final int a = s[i].abs();
    if (a > maxAbs) maxAbs = a;
  }
  return maxAbs;
}

// ─────────────────────────────────────────────────────────────────────────────

void main() {
  late FakeClock clock;
  late FakeConsent consent;
  late List<Utterance> emitted;
  late CaptureSession session;
  late StreamSubscription<Utterance> sub;

  // 看门狗那一组用例根本不建 CaptureSession,而 late 字段没赋值就读会抛。
  // 用一个标志位记住这个用例到底建没建,tearDown 只清理真正建过的,
  // 免得误清上一个用例遗留的对象。
  bool built = false;

  CaptureSession build({
    bool Function(int additionalBytes)? wouldExceedDisk,
    Duration clockDriftTolerance = const Duration(seconds: 1),
    int expectedSampleRate = kPcmSampleRate,
    int expectedChannels = 1,
  }) {
    final CaptureSession s = CaptureSession(
      isCaptureAllowed: () => consent.allowed,
      now: clock.call,
      consentNotifier: consent,
      wouldExceedDisk: wouldExceedDisk,
      vadConfig: kFastVad,
      expectedSampleRate: expectedSampleRate,
      expectedChannels: expectedChannels,
      clockDriftTolerance: clockDriftTolerance,
    );
    sub = s.utterances.listen(emitted.add);
    built = true;
    return s;
  }

  setUp(() {
    clock = FakeClock(DateTime.utc(2026, 1, 1, 12));
    consent = FakeConsent();
    emitted = <Utterance>[];
    built = false;
  });

  tearDown(() async {
    if (built) {
      await sub.cancel();
      // 重复 dispose 必须是安全的 —— 「dispose 之后再来帧」那个用例已经
      // 自己 dispose 过一次,这里再来一次正好顺带验证幂等。
      session.dispose();
    }
    consent.dispose();
  });

  // ───────────────────────────────────────────────────────────────────────────

  group('说话人归属', () {
    test('两人交替说话时,每段语音都带正确的 identity,且字节不串台', () async {
      session = build();

      // 两个说话人用差异极大的幅度 + 不同的翻转周期,双重指纹。
      const int ampA = 9000;
      const int ampB = 3000;
      const int sigA = 1;
      const int sigB = 4;

      // 交替喂:A 说 200 ms,B 说 200 ms,如此往复三轮,中间穿插静音让
      // 各自的段能被 hangover 收掉。注意两人的音频是**交织**进来的,
      // 这正是真实会议里的样子。
      for (int round = 0; round < 3; round++) {
        feed(
          session,
          'alice',
          'Alice',
          tone(200, amplitude: ampA, signature: sigA),
        );
        feed(
          session,
          'bob',
          'Bob',
          tone(200, amplitude: ampB, signature: sigB),
        );
        feed(session, 'alice', 'Alice', silence(200));
        feed(session, 'bob', 'Bob', silence(200));
      }
      session.flushAll();
      await pumpEventQueue();

      expect(emitted, isNotEmpty, reason: '交替说话应当产出语音段');

      final List<Utterance> fromA = emitted
          .where((Utterance u) => u.speakerIdentity == 'alice')
          .toList();
      final List<Utterance> fromB = emitted
          .where((Utterance u) => u.speakerIdentity == 'bob')
          .toList();

      expect(fromA, isNotEmpty, reason: 'Alice 应当有语音段');
      expect(fromB, isNotEmpty, reason: 'Bob 应当有语音段');
      expect(
        fromA.length + fromB.length,
        emitted.length,
        reason: '不应出现第三个说话人',
      );

      // 关键断言:落在每个人名下的**字节内容**必须是那个人的波形指纹。
      // 只断言标签是不够的 —— 标签对了但缓冲区串了才是最可怕的 bug。
      for (final Utterance u in fromA) {
        expect(u.speakerName, 'Alice');
        expect(
          dominantAmplitude(u),
          ampA,
          reason: 'Alice 名下不该出现 Bob 的幅度',
        );
      }
      for (final Utterance u in fromB) {
        expect(u.speakerName, 'Bob');
        expect(
          dominantAmplitude(u),
          ampB,
          reason: 'Bob 名下不该出现 Alice 的幅度',
        );
      }

      // 两人的统计各自独立。
      final CaptureSessionStats st = session.stats;
      expect(st.activeIdentities, <String>{'alice', 'bob'});
      expect(st.utterancesEmitted, emitted.length);
    });

    test('每人一个切分器:一方的长静音不会关掉另一方正在进行的语音', () async {
      session = build();

      // B 先开口,进入"说话中"。
      feed(session, 'bob', 'Bob', tone(200, amplitude: 9000));
      expect(
        session.stats.identities
            .firstWhere((CaptureIdentityState s) => s.identity == 'bob')
            .speaking,
        isTrue,
        reason: 'Bob 应当处于说话中',
      );

      // A 灌入远超 hangover 的静音。如果两人共用一个切分器,
      // 这段静音会把 B 的话切断。
      feed(session, 'alice', 'Alice', silence(1000));

      expect(
        session.stats.identities
            .firstWhere((CaptureIdentityState s) => s.identity == 'bob')
            .speaking,
        isTrue,
        reason: 'A 的静音绝不能关掉 B 的段',
      );
      expect(
        emitted.where((Utterance u) => u.speakerIdentity == 'bob'),
        isEmpty,
        reason: 'B 的段此时还不该被产出',
      );

      // 反向再验一次:B 的静音也不该影响 A。
      feed(session, 'alice', 'Alice', tone(200, amplitude: 9000));
      feed(session, 'bob', 'Bob', silence(1000));
      await pumpEventQueue();

      expect(
        session.stats.identities
            .firstWhere((CaptureIdentityState s) => s.identity == 'alice')
            .speaking,
        isTrue,
        reason: 'B 的静音不该关掉 A 的段',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────

  group('同意门禁', () {
    test('未获同意时,喂再多帧也不产出、不留存任何字节', () async {
      consent = FakeConsent(allowed: false);
      session = build();

      for (int i = 0; i < 50; i++) {
        feed(session, 'alice', 'Alice', tone(100, amplitude: 9000));
      }
      session.flushAll();
      await pumpEventQueue();

      expect(emitted, isEmpty, reason: '无同意不得产出任何语音段');
      expect(session.totalBytes, 0, reason: '无同意不得留存任何字节');
      expect(session.capturing, isFalse);
      expect(session.stopReason, CaptureStopReason.consentRevoked);
    });

    test('同意打开后开始采集', () async {
      consent = FakeConsent(allowed: false);
      session = build();

      feed(session, 'alice', 'Alice', tone(200, amplitude: 9000));
      expect(session.totalBytes, 0);

      consent.allowed = true;
      feed(session, 'alice', 'Alice', tone(200, amplitude: 9000));
      feed(session, 'alice', 'Alice', silence(300));
      await pumpEventQueue();

      expect(session.totalBytes, greaterThan(0), reason: '同意后应当开始收音');
      expect(emitted, isNotEmpty, reason: '同意后应当能产出语音段');
      expect(session.stopReason, CaptureStopReason.none);
    });

    test('说到一半撤回同意:立即停采,在途音频被丢弃而不是产出', () async {
      session = build();

      // 说到一半,还没到 hangover,段仍在进行中。
      feed(session, 'alice', 'Alice', tone(300, amplitude: 9000));
      expect(emitted, isEmpty, reason: '此刻段还没结束');
      expect(session.totalBytes, greaterThan(0));

      final int bytesBefore = session.totalBytes;
      consent.allowed = false;
      await pumpEventQueue();

      expect(session.stopReason, CaptureStopReason.consentRevoked);
      expect(session.capturing, isFalse);
      expect(
        emitted,
        isEmpty,
        reason: '撤回同意时在途音频必须被丢弃,绝不能产出',
      );

      // 撤回之后继续喂,也必须一字节都不进。
      feed(session, 'alice', 'Alice', tone(300, amplitude: 9000));
      session.flushAll();
      await pumpEventQueue();

      expect(emitted, isEmpty, reason: '撤回后不得再产出');
      expect(
        session.totalBytes,
        bytesBefore,
        reason: '撤回后累计字节数不应再增长',
      );
      expect(
        session.stats.identities
            .firstWhere((CaptureIdentityState s) => s.identity == 'alice')
            .active,
        isFalse,
        reason: '撤回后切分器应被销毁',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────

  group('轨道结束', () {
    test('onTrackGone 只收尾该说话人,另一人的在途段与字节不受影响', () async {
      session = build();

      feed(session, 'alice', 'Alice', tone(300, amplitude: 9000));
      feed(session, 'bob', 'Bob', tone(300, amplitude: 4000));

      final int bobBytesBefore = session.stats.identities
          .firstWhere((CaptureIdentityState s) => s.identity == 'bob')
          .bufferedBytes;
      expect(bobBytesBefore, greaterThan(0));
      expect(emitted, isEmpty, reason: '两段都还在进行中');

      session.onTrackGone('alice');
      await pumpEventQueue();

      expect(emitted.length, 1, reason: 'A 的在途段应被收尾产出');
      expect(emitted.single.speakerIdentity, 'alice');

      final CaptureSessionStats st = session.stats;
      expect(
        st.identities.any((CaptureIdentityState s) => s.identity == 'alice'),
        isFalse,
        reason: 'A 的状态应被释放',
      );

      final CaptureIdentityState bob = st.identities.firstWhere(
        (CaptureIdentityState s) => s.identity == 'bob',
      );
      expect(bob.active, isTrue, reason: 'B 的切分器不该被动到');
      expect(bob.speaking, isTrue, reason: 'B 的段应仍在进行中');
      expect(bob.bufferedBytes, bobBytesBefore, reason: 'B 的字节数不该变');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────

  group('磁盘封顶', () {
    test('谓词判定会超限时停采,并把在途段正常收尾', () async {
      bool wouldExceed = false;
      session = build(wouldExceedDisk: (int _) => wouldExceed);

      feed(session, 'alice', 'Alice', tone(300, amplitude: 9000));
      expect(emitted, isEmpty);
      final int bytesBefore = session.totalBytes;

      wouldExceed = true;
      feed(session, 'alice', 'Alice', tone(100, amplitude: 9000));
      await pumpEventQueue();

      expect(session.stopReason, CaptureStopReason.diskCapReached);
      expect(session.capturing, isFalse);
      expect(
        emitted.length,
        1,
        reason: '磁盘触顶时音频是合法采到的,应当收尾产出而不是丢弃',
      );
      expect(emitted.single.speakerIdentity, 'alice');
      expect(
        session.totalBytes,
        bytesBefore,
        reason: '触顶后不得再追加字节',
      );
    });

    test('磁盘回落后必须显式唤醒才恢复:热路径不自愈', () async {
      bool wouldExceed = false;
      session = build(wouldExceedDisk: (int _) => wouldExceed);

      wouldExceed = true;
      feed(session, 'alice', 'Alice', tone(100, amplitude: 9000));
      expect(session.stopReason, CaptureStopReason.diskCapReached);

      // 磁盘腾出来了,但没人唤醒 —— 按既定策略仍然停着。
      wouldExceed = false;
      feed(session, 'alice', 'Alice', tone(100, amplitude: 9000));
      expect(
        session.stopReason,
        CaptureStopReason.diskCapReached,
        reason: '未唤醒前不得自行恢复,避免在阈值附近反复抖动',
      );

      // 显式唤醒后恢复。
      session.noteDiskUsage(0);
      expect(session.stopReason, CaptureStopReason.none);
      expect(session.capturing, isTrue);

      feed(session, 'alice', 'Alice', tone(200, amplitude: 9000));
      expect(session.totalBytes, greaterThan(0), reason: '唤醒后应能继续收音');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────

  group('采样率与声道校验', () {
    test('48kHz 的帧被拒收,丢帧计数增加,该轨健康度置为 formatMismatch', () async {
      session = build();

      final Uint8List pcm = tone(100, amplitude: 9000);
      for (int i = 0; i < 5; i++) {
        session.onFrameBytes('alice', 'Alice', pcm, 48000, 1);
      }
      await pumpEventQueue();

      final CaptureIdentityState a = session.stats.identities.firstWhere(
        (CaptureIdentityState s) => s.identity == 'alice',
      );
      expect(a.droppedFrames, 5);
      expect(a.health, RendererHealth.formatMismatch);
      expect(a.bufferedBytes, 0, reason: '被拒收的帧不得进入切分器');
      expect(session.totalBytes, 0, reason: '被拒收的帧不得计入累计字节');
      expect(emitted, isEmpty);
      expect(session.stats.anyFailed, isTrue);
    });

    test('立体声的帧被拒收,同时另一个说话人的正常帧照常工作', () async {
      session = build();

      final Uint8List bad = tone(100, amplitude: 9000);
      session.onFrameBytes('alice', 'Alice', bad, kPcmSampleRate, 2);

      feed(session, 'bob', 'Bob', tone(200, amplitude: 9000));
      feed(session, 'bob', 'Bob', silence(300));
      await pumpEventQueue();

      final CaptureSessionStats st = session.stats;
      final CaptureIdentityState a = st.identities.firstWhere(
        (CaptureIdentityState s) => s.identity == 'alice',
      );
      final CaptureIdentityState b = st.identities.firstWhere(
        (CaptureIdentityState s) => s.identity == 'bob',
      );

      expect(a.health, RendererHealth.formatMismatch);
      expect(a.droppedFrames, 1);
      expect(b.health, isNot(RendererHealth.formatMismatch));
      expect(
        emitted.where((Utterance u) => u.speakerIdentity == 'bob'),
        isNotEmpty,
        reason: '一条轨配置错不该拖垮另一条轨',
      );
      expect(
        emitted.where((Utterance u) => u.speakerIdentity == 'alice'),
        isEmpty,
      );
      expect(st.droppedFrames, 1);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────

  group('音频时钟重锚', () {
    test('墙钟跳过一大段空洞后,切分器以新的 sessionStart 重建', () async {
      session = build(clockDriftTolerance: const Duration(seconds: 1));

      // 正常说一段并收掉。喂音频时墙钟同步推进,不触发重锚。
      feed(session, 'alice', 'Alice', tone(200, amplitude: 9000), clock: clock);
      feed(session, 'alice', 'Alice', silence(200), clock: clock);
      await pumpEventQueue();
      expect(emitted.length, 1, reason: '第一段应正常产出');

      // 制造一个 60 秒的空洞:静音停轨/重连期间没有任何帧进来,
      // 但墙钟照走。音频时钟因此落后 60 秒。
      clock.advance(const Duration(seconds: 60));

      feed(session, 'alice', 'Alice', tone(200, amplitude: 9000), clock: clock);
      feed(session, 'alice', 'Alice', silence(200), clock: clock);
      await pumpEventQueue();

      expect(emitted.length, 2, reason: '空洞后应产出第二段');

      // 重锚的证据:第二段的时间戳必须落在空洞**之后**的墙钟附近,
      // 而不是紧接着第一段(那才是漂移未被修正的样子)。
      final Duration gap = emitted[1].startedAt.difference(emitted[0].endedAt);
      expect(
        gap,
        greaterThan(const Duration(seconds: 30)),
        reason: '未重锚的话两段时间戳会几乎连在一起,漂移会无上界累积',
      );
    });

    test('连续采集不触发重锚,时间戳保持连续', () async {
      session = build(clockDriftTolerance: const Duration(seconds: 1));

      for (int i = 0; i < 4; i++) {
        feed(
          session,
          'alice',
          'Alice',
          tone(200, amplitude: 9000),
          clock: clock,
        );
        feed(session, 'alice', 'Alice', silence(200), clock: clock);
      }
      await pumpEventQueue();

      expect(emitted.length, greaterThanOrEqualTo(2));
      for (int i = 1; i < emitted.length; i++) {
        final Duration gap = emitted[i].startedAt.difference(
          emitted[i - 1].endedAt,
        );
        expect(
          gap,
          lessThan(const Duration(seconds: 2)),
          reason: '连续采集不该被重锚打断',
        );
      }
    });
  });

  // ───────────────────────────────────────────────────────────────────────────

  group('生命周期', () {
    test('dispose 之后再来帧是静默空操作,不抛异常', () async {
      session = build();
      feed(session, 'alice', 'Alice', tone(100, amplitude: 9000));
      session.dispose();

      expect(
        () => session.onFrameBytes(
          'alice',
          'Alice',
          tone(100, amplitude: 9000),
          kPcmSampleRate,
          1,
        ),
        returnsNormally,
      );
      expect(session.stopReason, CaptureStopReason.disposed);

      // tearDown 会再 dispose 一次,验证重复 dispose 是安全的。
    });

    test('markAllStale 只改健康度,不销毁切分器', () async {
      session = build();
      feed(session, 'alice', 'Alice', tone(300, amplitude: 9000));
      session.onRendererHealth(
        'alice',
        'Alice',
        RendererHealth.healthy,
        1,
      );

      session.markAllStale();

      final CaptureIdentityState a = session.stats.identities.firstWhere(
        (CaptureIdentityState s) => s.identity == 'alice',
      );
      expect(a.active, isTrue, reason: '重连不该丢掉在途音频');
      expect(a.speaking, isTrue);
      expect(a.health, RendererHealth.idle);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────

  group('渲染器看门狗', () {
    test('收不到首帧时会重注册,且取消一定发生在重新注册之前', () {
      fakeAsync((FakeAsync async) {
        final List<String> log = <String>[];
        int attachCount = 0;

        final RendererWatchdog dog = RendererWatchdog(
          identity: 'alice',
          firstFrameTimeout: const Duration(seconds: 2),
          retryBackoff: const Duration(milliseconds: 400),
          attach: (int attempt) {
            attachCount++;
            log.add('attach#$attempt');
            // 取消句柄刻意做成**耗时**的。真实的 CancelListenFunc 要走到原生
            // 侧去停采集管线,不是一个立刻完成的 future。如果这里写成
            // `() async => ...`(瞬时完成),那么即使实现把取消排在重注册
            // 之后,取消的微任务也会抢在 400ms 的退避定时器前跑完,顺序
            // 断言就会**假装通过** —— 这个用例也就测不出 TRAP 2 了。
            return () async {
              await Future<void>.delayed(const Duration(milliseconds: 900));
              log.add('cancel#$attempt');
            };
          },
        );

        dog.start();
        expect(dog.health, RendererHealth.starting);
        expect(attachCount, 1);

        // 首帧一直不来。
        async.elapse(const Duration(seconds: 5));

        expect(attachCount, greaterThan(1), reason: '超时后必须重注册');

        // 这是 TRAP 2 的核心断言:失败的 capture group 会以 options 为键
        // 留在轨道里,不先取消就重注册只会挂到同一具尸体上。所以
        // cancel#1 必须严格早于 attach#2。
        final int cancel1 = log.indexOf('cancel#1');
        final int attach2 = log.indexOf('attach#2');
        expect(cancel1, isNonNegative, reason: '必须调用过取消句柄');
        expect(attach2, isNonNegative);
        expect(
          cancel1,
          lessThan(attach2),
          reason: '必须先取消再重注册,否则重试必然无效',
        );

        async.elapse(const Duration(minutes: 1));
        dog.dispose();
        async.flushMicrotasks();
      });
    });

    test('收到首帧后不再重试,健康度为 healthy', () {
      fakeAsync((FakeAsync async) {
        int attachCount = 0;
        final List<String> log = <String>[];

        final RendererWatchdog dog = RendererWatchdog(
          identity: 'alice',
          firstFrameTimeout: const Duration(seconds: 2),
          attach: (int attempt) {
            attachCount++;
            return () async => log.add('cancel#$attempt');
          },
        );

        dog.start();
        async.elapse(const Duration(milliseconds: 500));
        dog.noteFrame();

        expect(dog.health, RendererHealth.healthy);
        expect(dog.sawFirstFrame, isTrue);

        async.elapse(const Duration(minutes: 1));
        expect(attachCount, 1, reason: '拿到首帧就不该再重注册');
        expect(log, isEmpty, reason: '健康的渲染器不该被取消');

        // 后续帧上 noteFrame 必须幂等。
        dog.noteFrame();
        dog.noteFrame();
        expect(dog.health, RendererHealth.healthy);

        dog.dispose();
        async.flushMicrotasks();
      });
    });

    test('重试次数封顶后进入 failed 终态', () {
      fakeAsync((FakeAsync async) {
        int attachCount = 0;
        final List<RendererHealth> healths = <RendererHealth>[];

        final RendererWatchdog dog = RendererWatchdog(
          identity: 'alice',
          firstFrameTimeout: const Duration(seconds: 2),
          retryBackoff: const Duration(milliseconds: 400),
          maxAttempts: 3,
          onHealth: (RendererHealth h, int _) => healths.add(h),
          attach: (int attempt) {
            attachCount++;
            return () async {};
          },
        );

        dog.start();
        async.elapse(const Duration(minutes: 1));

        expect(attachCount, 3, reason: '尝试次数必须被 maxAttempts 封顶');
        expect(dog.attempts, 3);
        expect(dog.health, RendererHealth.failed);
        expect(healths.last, RendererHealth.failed);

        dog.dispose();
        async.flushMicrotasks();
      });
    });

    test('attach 返回 null 或抛异常都算失败,继续走重试阶梯', () {
      fakeAsync((FakeAsync async) {
        final List<int> attempts = <int>[];

        final RendererWatchdog dog = RendererWatchdog(
          identity: 'alice',
          firstFrameTimeout: const Duration(seconds: 2),
          retryBackoff: const Duration(milliseconds: 400),
          maxAttempts: 3,
          attach: (int attempt) {
            attempts.add(attempt);
            if (attempt == 1) return null;
            throw StateError('注册失败');
          },
        );

        dog.start();
        async.elapse(const Duration(minutes: 1));

        expect(attempts, <int>[1, 2, 3]);
        expect(dog.health, RendererHealth.failed);

        dog.dispose();
        async.flushMicrotasks();
      });
    });

    test('dispose 会取消存活的渲染器,且可安全重复调用', () {
      fakeAsync((FakeAsync async) {
        final List<String> log = <String>[];

        final RendererWatchdog dog = RendererWatchdog(
          identity: 'alice',
          firstFrameTimeout: const Duration(seconds: 2),
          attach: (int attempt) => () async => log.add('cancel#$attempt'),
        );

        dog.start();
        dog.noteFrame();

        dog.dispose();
        async.flushMicrotasks();
        expect(log, <String>['cancel#1']);

        dog.dispose();
        async.flushMicrotasks();
        expect(log, <String>['cancel#1'], reason: '重复 dispose 不该重复取消');

        async.elapse(const Duration(minutes: 1));
      });
    });
  });
}
