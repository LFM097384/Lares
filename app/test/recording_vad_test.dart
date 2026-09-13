import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/recording/utterance.dart';
import 'package:lares_app/src/recording/vad.dart';

const int _sr = kPcmSampleRate;

/// 构造一段正弦波的 int16 采样点([amp] 是峰值幅度)。
///
/// 用正弦而不是常数直流:RMS 对直流和交流都一样算,但直流不是"声音",
/// 万一将来换成带高通的检测器,直流信号会被滤没,测试就会莫名其妙地挂。
/// 正弦波的 RMS = amp / sqrt(2),据此挑幅度来跨越/不跨越门限。
List<int> tone(Duration d, {int amp = 8000, double freq = 440}) {
  final int n = d.inMicroseconds * _sr ~/ 1000000;
  return List<int>.generate(n, (int i) {
    return (amp * math.sin(2 * math.pi * freq * i / _sr)).round();
  }, growable: false);
}

/// 纯静音采样点。
List<int> silence(Duration d) =>
    List<int>.filled(d.inMicroseconds * _sr ~/ 1000000, 0, growable: false);

/// 采样点 -> 小端字节块。
Uint8List bytes(List<int> samples) => encodePcm16(samples);

/// 把整段字节按 [chunk] 大小切开依次喂入,收集所有产出(含 flush)。
List<Utterance> feed(
  UtteranceSegmenter seg,
  Uint8List data, {
  int chunk = 320,
}) {
  final List<Utterance> out = <Utterance>[];
  for (int i = 0; i < data.lengthInBytes; i += chunk) {
    final int end = math.min(i + chunk, data.lengthInBytes);
    out.addAll(seg.addChunk(Uint8List.sublistView(data, i, end)));
  }
  final Utterance? tail = seg.flush();
  if (tail != null) out.add(tail);
  return out;
}

UtteranceSegmenter makeSegmenter({VadConfig config = const VadConfig()}) =>
    UtteranceSegmenter(
      speakerIdentity: 'u-1',
      speakerName: '张三',
      sessionStart: DateTime.utc(2026, 1, 1, 12),
      config: config,
    );

void main() {
  group('RMS 能量计算', () {
    test('静音帧 RMS 为 0,正弦帧 RMS 约等于 峰值/√2', () {
      const EnergySpeechDetector d = EnergySpeechDetector();

      expect(d.score(Int16List.fromList(silence(kVadFrameDuration))), 0);

      final Int16List frame = Int16List.fromList(
        tone(kVadFrameDuration, amp: 10000),
      );
      // 10 ms @440 Hz 只有 4.4 个周期,不是整周期,允许一点偏差。
      expect(d.score(frame), closeTo(10000 / math.sqrt2, 600));
    });

    test('长缓冲不会因累加器溢出而归零(对照 harness 里已知损坏的 Goertzel)', () {
      // 刻意用满幅信号 + 远长于一帧的缓冲:整数平方和累加必须精确不溢出。
      final Int16List big = Int16List.fromList(
        List<int>.filled(16000, 32767),
      );
      const EnergySpeechDetector d = EnergySpeechDetector();
      expect(d.score(big), closeTo(32767, 1));
    });

    test('空帧返回 0 而不是 NaN(除零防御)', () {
      expect(const EnergySpeechDetector().score(Int16List(0)), 0);
    });
  });

  group('基本分段', () {
    test('纯静音不产出任何语音段', () {
      final UtteranceSegmenter seg = makeSegmenter();
      expect(feed(seg, bytes(silence(const Duration(seconds: 3)))), isEmpty);
    });

    test('一段持续的声音只产出一段语音', () {
      final UtteranceSegmenter seg = makeSegmenter();
      final List<int> sig = <int>[
        ...silence(const Duration(milliseconds: 500)),
        ...tone(const Duration(seconds: 2)),
        ...silence(const Duration(seconds: 2)),
      ];

      final List<Utterance> got = feed(seg, bytes(sig));
      expect(got, hasLength(1));
      expect(got.single.speakerIdentity, 'u-1');
      expect(got.single.speakerName, '张三');
      // 语音本体 2 秒,加上预滚,减去尾部被裁掉的挂起静音。
      expect(
        got.single.duration.inMilliseconds,
        inInclusiveRange(2000, 2000 + 250),
      );
    });

    test('句中短暂停顿(短于挂起时长)不会把一句话切成两段', () {
      final UtteranceSegmenter seg = makeSegmenter();
      final List<int> sig = <int>[
        ...tone(const Duration(milliseconds: 800)),
        // 300 ms < 600 ms 挂起,属于句内换气
        ...silence(const Duration(milliseconds: 300)),
        ...tone(const Duration(milliseconds: 800)),
        ...silence(const Duration(seconds: 2)),
      ];

      expect(feed(seg, bytes(sig)), hasLength(1));
    });

    test('句间长停顿(长于挂起时长)切成两段', () {
      final UtteranceSegmenter seg = makeSegmenter();
      final List<int> sig = <int>[
        ...tone(const Duration(milliseconds: 800)),
        // 1.2 s > 600 ms 挂起,属于句间停顿
        ...silence(const Duration(milliseconds: 1200)),
        ...tone(const Duration(milliseconds: 800)),
        ...silence(const Duration(seconds: 2)),
      ];

      final List<Utterance> got = feed(seg, bytes(sig));
      expect(got, hasLength(2));
      // 第二段必须晚于第一段,且区间不重叠(预滚不得回溯到已产出的音频里)
      expect(got[1].startedAt.isAfter(got[0].endedAt), isTrue);
    });

    test('短于最短时长的杂音(咳嗽/键盘)被丢弃', () {
      final UtteranceSegmenter seg = makeSegmenter();
      final List<int> sig = <int>[
        ...silence(const Duration(milliseconds: 500)),
        // 100 ms < 300 ms 最短时长
        ...tone(const Duration(milliseconds: 100)),
        ...silence(const Duration(seconds: 2)),
      ];

      expect(feed(seg, bytes(sig)), isEmpty);
    });

    test('低于开启门限的背景噪声不会触发分段', () {
      final UtteranceSegmenter seg = makeSegmenter();
      // amp=200 -> RMS≈141,远低于开启门限 700
      final List<int> sig = tone(const Duration(seconds: 3), amp: 200);
      expect(feed(seg, bytes(sig)), isEmpty);
    });
  });

  group('预滚', () {
    test('产出的音频比过门限区域更长,说明词首被补了回来', () {
      final UtteranceSegmenter seg = makeSegmenter();
      const Duration speech = Duration(milliseconds: 1000);
      final List<int> sig = <int>[
        ...silence(const Duration(milliseconds: 800)),
        ...tone(speech),
        ...silence(const Duration(seconds: 2)),
      ];

      final Utterance u = feed(seg, bytes(sig)).single;
      // 严格长于语音本体 —— 多出来的就是预滚。
      expect(u.duration, greaterThan(speech));
      expect(
        u.duration.inMilliseconds - speech.inMilliseconds,
        inInclusiveRange(100, 250),
      );
      // 起点必须早于语音真正开始的 800 ms 处。
      final DateTime speechOnset = DateTime.utc(
        2026,
        1,
        1,
        12,
      ).add(const Duration(milliseconds: 800));
      expect(u.startedAt.isBefore(speechOnset), isTrue);
    });

    test('预滚为 0 时产出长度回落到语音本体', () {
      final UtteranceSegmenter seg = makeSegmenter(
        config: const VadConfig(preRoll: Duration.zero),
      );
      const Duration speech = Duration(milliseconds: 1000);
      final List<int> sig = <int>[
        ...silence(const Duration(milliseconds: 800)),
        ...tone(speech),
        ...silence(const Duration(seconds: 2)),
      ];

      final Utterance u = feed(seg, bytes(sig)).single;
      expect(u.duration.inMilliseconds, inInclusiveRange(990, 1010));
    });
  });

  group('超长硬切', () {
    test('超长独白被切成多段,每段都不超过上限', () {
      // 上限调小到 1 s,避免测试真的合成 20 秒音频。
      const VadConfig cfg = VadConfig(maxUtterance: Duration(seconds: 1));
      final UtteranceSegmenter seg = makeSegmenter(config: cfg);
      final List<int> sig = <int>[
        ...tone(const Duration(milliseconds: 4500)),
        ...silence(const Duration(seconds: 2)),
      ];

      final List<Utterance> got = feed(seg, bytes(sig));
      expect(got.length, greaterThanOrEqualTo(4));
      for (final Utterance u in got) {
        expect(
          u.duration,
          lessThanOrEqualTo(const Duration(seconds: 1)),
          reason: '硬切后仍有超长段:$u',
        );
      }
    });

    test('硬切不丢音频:各段首尾相接,拼回去与原信号逐样本一致', () {
      const VadConfig cfg = VadConfig(
        maxUtterance: Duration(seconds: 1),
        // 预滚置 0,让"拼接 == 原信号"成为可精确断言的等式
        preRoll: Duration.zero,
      );
      final UtteranceSegmenter seg = makeSegmenter(config: cfg);
      final List<int> speech = tone(const Duration(milliseconds: 4500));
      final List<int> sig = <int>[
        ...speech,
        ...silence(const Duration(seconds: 2)),
      ];

      final List<Utterance> got = feed(seg, bytes(sig));
      expect(got.length, greaterThanOrEqualTo(4));

      // 相邻段必须严格首尾相接(无空洞、无重叠)
      for (int i = 1; i < got.length; i++) {
        expect(
          got[i].startedAt,
          got[i - 1].endedAt,
          reason: '第 $i 段与上一段之间出现了空洞或重叠',
        );
      }

      final List<int> joined = <int>[];
      for (final Utterance u in got) {
        joined.addAll(u.toSamples());
      }

      // 「不丢音频」的准确含义:原始语音必须是拼接结果的**前缀**,一个采样点不少。
      expect(
        joined.length,
        greaterThanOrEqualTo(speech.length),
        reason: '硬切把音频弄丢了',
      );
      for (int i = 0; i < speech.length; i++) {
        expect(joined[i], speech[i], reason: '第 $i 个采样点在硬切处被破坏');
      }

      // 多出来的尾巴只可能是静音,且不超过一个硬切周期。
      // 成因:硬切点恰好落在挂起窗口内时,整块 buffer(含尚未判定为结束的
      // 那段静音)被原样产出 —— 这是「宁可多带静音也绝不丢音频」的取舍,
      // 与正常收尾会裁掉挂起静音的行为刻意不同。
      expect(joined.length - speech.length, lessThanOrEqualTo(16000));
      for (int i = speech.length; i < joined.length; i++) {
        expect(joined[i], 0, reason: '硬切尾部混入了非静音数据');
      }
    });

    test('硬切续接段不因尾巴太短而被最短时长规则吃掉', () {
      // 语音总长 1.05 s,上限 1 s -> 第二段只有 50 ms,短于 300 ms 最短时长。
      // 但它是续接段,必须保留,否则硬切就把音频弄丢了。
      const VadConfig cfg = VadConfig(
        maxUtterance: Duration(seconds: 1),
        preRoll: Duration.zero,
      );
      final UtteranceSegmenter seg = makeSegmenter(config: cfg);
      final List<int> sig = <int>[
        ...tone(const Duration(milliseconds: 1050)),
        ...silence(const Duration(seconds: 2)),
      ];

      final List<Utterance> got = feed(seg, bytes(sig));
      expect(got, hasLength(2));
      expect(got[1].duration.inMilliseconds, inInclusiveRange(40, 60));
    });
  });

  group('块边界鲁棒性', () {
    test('奇数字节块切分不破坏采样点(半个采样点被正确续接)', () {
      final UtteranceSegmenter seg = makeSegmenter(
        config: const VadConfig(preRoll: Duration.zero),
      );
      final List<int> speech = tone(const Duration(milliseconds: 1000));
      final Uint8List data = bytes(<int>[
        ...speech,
        ...silence(const Duration(seconds: 2)),
      ]);

      // 7 字节一块:必然在奇数位置劈开采样点
      final Utterance u = feed(seg, data, chunk: 7).single;
      final Int16List got = u.toSamples();
      final int n = math.min(got.length, speech.length);
      expect(n, greaterThan(0));
      for (int i = 0; i < n; i++) {
        expect(got[i], speech[i], reason: '第 $i 个采样点被块边界破坏');
      }
    });

    test('分块无关性:320 字节块与一次性整块产出完全一致的分段', () {
      final List<int> sig = <int>[
        ...silence(const Duration(milliseconds: 300)),
        ...tone(const Duration(milliseconds: 900)),
        ...silence(const Duration(milliseconds: 1200)),
        ...tone(const Duration(milliseconds: 700)),
        ...silence(const Duration(seconds: 2)),
      ];
      final Uint8List data = bytes(sig);

      final List<Utterance> small = feed(makeSegmenter(), data, chunk: 320);
      final List<Utterance> whole = feed(
        makeSegmenter(),
        data,
        chunk: data.lengthInBytes,
      );

      expect(small, hasLength(2));
      // 值相等(说话人 + 时间区间 + 长度)
      expect(small, equals(whole));
      // 再逐字节确认音频本身也一致
      for (int i = 0; i < small.length; i++) {
        expect(small[i].pcm, equals(whole[i].pcm));
      }
    });

    test('多种古怪块大小产出的分段全部一致', () {
      final List<int> sig = <int>[
        ...tone(const Duration(milliseconds: 800)),
        ...silence(const Duration(milliseconds: 1000)),
        ...tone(const Duration(milliseconds: 800)),
        ...silence(const Duration(seconds: 2)),
      ];
      final Uint8List data = bytes(sig);
      final List<Utterance> baseline = feed(
        makeSegmenter(),
        data,
        chunk: data.lengthInBytes,
      );

      for (final int c in <int>[1, 3, 7, 64, 321, 999, 4096]) {
        expect(
          feed(makeSegmenter(), data, chunk: c),
          equals(baseline),
          reason: '块大小 $c 下分段结果发生了变化',
        );
      }
    });

    test('空块不影响状态', () {
      final UtteranceSegmenter seg = makeSegmenter();
      expect(seg.addChunk(Uint8List(0)), isEmpty);
      expect(seg.flush(), isNull);
    });
  });

  group('音频时钟时间戳', () {
    test('时间戳由会话起点 + 采样数推出,不依赖墙钟', () {
      final DateTime start = DateTime.utc(2026, 3, 4, 9, 30);
      final UtteranceSegmenter seg = UtteranceSegmenter(
        speakerIdentity: 'u-9',
        speakerName: '李四',
        sessionStart: start,
        config: const VadConfig(preRoll: Duration.zero),
      );
      final List<int> sig = <int>[
        ...silence(const Duration(seconds: 1)),
        ...tone(const Duration(milliseconds: 1000)),
        ...silence(const Duration(seconds: 2)),
      ];

      final Utterance u = feed(seg, bytes(sig)).single;
      // 语音从第 1 秒开始,预滚为 0 -> 起点就是 start + 1s(容一帧误差)
      expect(
        u.startedAt.difference(start).inMilliseconds,
        inInclusiveRange(990, 1010),
      );
      // endedAt 与 duration 必须严格自洽
      expect(u.endedAt.difference(u.startedAt), u.duration);
    });

    test('两次喂同样的音频得到完全相同的时间戳(可复现,无墙钟抖动)', () {
      final List<int> sig = <int>[
        ...tone(const Duration(milliseconds: 700)),
        ...silence(const Duration(seconds: 2)),
      ];
      final Uint8List data = bytes(sig);

      final Utterance a = feed(makeSegmenter(), data).single;
      final Utterance b = feed(makeSegmenter(), data).single;
      expect(a.startedAt, b.startedAt);
      expect(a.endedAt, b.endedAt);
    });

    test('processedAudio 随喂入量线性增长', () {
      final UtteranceSegmenter seg = makeSegmenter();
      seg.addChunk(bytes(silence(const Duration(milliseconds: 500))));
      expect(seg.processedAudio, const Duration(milliseconds: 500));
    });
  });

  group('flush 与 reset', () {
    test('会话结束时 flush 收掉正在进行的一段', () {
      final UtteranceSegmenter seg = makeSegmenter();
      // 只喂语音,不喂结尾静音 -> 段仍处于打开状态
      seg.addChunk(bytes(tone(const Duration(milliseconds: 900))));
      expect(seg.isSpeaking, isTrue);

      final Utterance? u = seg.flush();
      expect(u, isNotNull);
      expect(seg.isSpeaking, isFalse);
      // 再 flush 一次不应重复产出
      expect(seg.flush(), isNull);
    });

    test('flush 时正在进行的一段若太短则同样丢弃', () {
      final UtteranceSegmenter seg = makeSegmenter();
      seg.addChunk(bytes(tone(const Duration(milliseconds: 100))));
      expect(seg.flush(), isNull);
    });

    test('reset 后音频时钟与状态全部归零', () {
      final UtteranceSegmenter seg = makeSegmenter();
      seg.addChunk(bytes(tone(const Duration(milliseconds: 900))));
      seg.reset();

      expect(seg.isSpeaking, isFalse);
      expect(seg.processedAudio, Duration.zero);
      expect(seg.flush(), isNull);
    });
  });

  group('检测器可替换性', () {
    test('自定义检测器可完全接管判定,切分器不关心分数量纲', () {
      // 一个概率量纲的假检测器:模拟将来的 Silero(0..1),
      // 前 50 帧判为语音,之后判为静音。
      final _ScriptedDetector fake = _ScriptedDetector(speechFrames: 50);
      final UtteranceSegmenter seg = UtteranceSegmenter(
        speakerIdentity: 'u-2',
        speakerName: '王五',
        sessionStart: DateTime.utc(2026, 1, 1),
        // 用静音喂,证明产出完全由检测器决定,与能量无关
        detector: fake,
      );

      final List<Utterance> got = feed(
        seg,
        bytes(silence(const Duration(seconds: 3))),
      );
      expect(got, hasLength(1));
      // 50 帧 * 10 ms = 500 ms 语音
      expect(got.single.duration.inMilliseconds, inInclusiveRange(490, 760));
      expect(fake.resetCalls, 0);

      seg.reset();
      expect(fake.resetCalls, 1);
    });
  });

  group('值类型语义', () {
    test('VadConfig 相等性、hashCode 与 copyWith', () {
      const VadConfig a = VadConfig();
      const VadConfig b = VadConfig();
      final VadConfig c = a.copyWith(hangover: const Duration(seconds: 1));

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(c.hangover, const Duration(seconds: 1));
      expect(c.preRoll, a.preRoll);
      expect(a.copyWith(), equals(a));
      expect(a.toString(), contains('hangover'));
    });

    test('VadConfig 默认值符合文档承诺', () {
      const VadConfig c = VadConfig();
      expect(c.sampleRate, 16000);
      expect(c.hangover, const Duration(milliseconds: 600));
      expect(c.preRoll, const Duration(milliseconds: 200));
      expect(c.minUtterance, const Duration(milliseconds: 300));
      expect(c.maxUtterance, const Duration(seconds: 20));
    });

    test('EnergySpeechDetector 是值类型,且默认门限构成滞后', () {
      const EnergySpeechDetector a = EnergySpeechDetector();
      expect(a, equals(const EnergySpeechDetector()));
      expect(a.hashCode, equals(const EnergySpeechDetector().hashCode));
      expect(a.closeThreshold, lessThan(a.openThreshold));
      expect(a.frameSamples, 160);
      expect(a.copyWith(openThreshold: 900).openThreshold, 900);
    });

    test('Utterance 编解码往返保持采样点不变', () {
      final List<int> s = tone(const Duration(milliseconds: 50), amp: 12345);
      final Utterance u = Utterance.fromSamples(
        speakerIdentity: 'x',
        speakerName: 'X',
        startedAt: DateTime.utc(2026, 1, 1),
        samples: s,
      );

      expect(u.sampleCount, s.length);
      expect(u.toSamples(), equals(Int16List.fromList(s)));
      expect(u.duration, const Duration(milliseconds: 50));
      expect(u.endedAt.difference(u.startedAt), u.duration);
    });

    test('编码对越界采样点做截断而不是回绕(避免爆音)', () {
      final Int16List got = decodePcm16(encodePcm16(<int>[40000, -40000]));
      expect(got[0], 32767);
      expect(got[1], -32768);
    });
  });
}

/// 按脚本判定的假检测器:分数量纲是 0..1 概率,模拟将来的 Silero-ONNX。
///
/// 它的存在本身就是"能量门限可被替换"这条设计承诺的可执行证明。
class _ScriptedDetector extends SpeechDetector {
  _ScriptedDetector({required this.speechFrames});

  final int speechFrames;
  int _seen = 0;
  int resetCalls = 0;

  @override
  int get frameSamples => 160;

  @override
  double get openThreshold => 0.5;

  @override
  double get closeThreshold => 0.35;

  @override
  double score(Int16List frame) => _seen++ < speechFrames ? 0.9 : 0.0;

  @override
  void reset() {
    resetCalls++;
    _seen = 0;
  }
}
