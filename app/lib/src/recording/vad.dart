/// 能量门限 VAD + 语音分段。
///
/// 输入:16 kHz 单声道 int16 **小端** PCM,以**任意大小**的块喂进来
/// (真实链路一帧是 10 ms = 320 字节,但绝不能假设这一点 —— 块边界可能把
/// 一个采样点劈成两半)。输出:切好的 [Utterance]。
///
/// 全文件纯 Dart:无插件、无平台通道、不读时钟、不做 IO,可在纯 VM 测试里跑。
library;

import 'dart:math' as math;
import 'dart:typed_data';

// 只用 foundation 的 @immutable 注解(纯值语义标记),不引入任何平台通道依赖。
// 未选用 package:meta 是因为它不是本包的直接依赖(depend_on_referenced_packages)。
import 'package:flutter/foundation.dart';

import 'utterance.dart';

/// 默认分析帧长:10 ms。
///
/// 提成具名常量而不是到处写 160:帧长同时决定了"静音判定的时间分辨率"
/// (滞后/最短时长都按整帧累计),看到 160 这个裸数字的人没法反推出这层含义。
/// 10 ms 也正好与 WebRTC 的音频回调粒度一致,绝大多数块天然就是整帧。
const Duration kVadFrameDuration = Duration(milliseconds: 10);

/// 语音检测器抽象。
///
/// 存在的唯一理由是**将来能换成 ML VAD**:Silero-ONNX 只需实现本接口
/// ([frameSamples] 返回它要求的 512,[score] 返回 0..1 概率,两个门限取
/// 0.5 / 0.35),[UtteranceSegmenter] 一行都不用改 —— 因为切分器只做
/// "分数与门限比大小",从不假设分数的量纲。
///
/// 门限**属于检测器而不属于 [VadConfig]**,这是刻意的:分数空间是检测器的
/// 私事(能量检测器是 int16 RMS 量纲,Silero 是概率量纲),把两套量纲的门限
/// 塞进同一个配置对象,换检测器时必然出现"字段语义静默漂移"的坑。
/// [VadConfig] 只管与量纲无关的**时间策略**。
abstract class SpeechDetector {
  const SpeechDetector();

  /// 本检测器要求的分析帧采样点数。切分器按它切帧,多余的采样点留到下一块。
  int get frameSamples;

  /// 开启门限:超过它才**起始**一段语音。
  double get openThreshold;

  /// 关闭门限:低于它才算**静音**。必须 < [openThreshold]。
  double get closeThreshold;

  /// 给一帧打分。分数越大越像语音,量纲由实现自己定义。
  double score(Int16List frame);

  /// 便捷判定:是否仍在"说话"(用低门限,与滞后逻辑一致)。
  bool isSpeech(Int16List frame) => score(frame) >= closeThreshold;

  /// 重置内部状态。能量检测器无状态,ML 检测器(LSTM/GRU 隐状态)必须实现。
  void reset() {}
}

/// 基于帧 RMS 的能量检测器。
///
/// 两个门限构成**滞后(hysteresis)**:开启门限高、关闭门限低。
/// 只用一个门限的话,说话人音量在门限附近来回蹭时会疯狂开合,
/// 一句话被剁成十几段,ASR 拿到一堆半个字的碎片。高开低关让
/// "已经在说话"这个状态更难被打断,正是我们要的粘滞感。
@immutable
class EnergySpeechDetector extends SpeechDetector {
  const EnergySpeechDetector({
    this.frameSamples = 160,
    // 必须写成 double 字面量:写 700 会让常量求值器在 assert 的比较里
    // 无法证明操作数是 num(const_eval_type_num),整个文件编不过。
    this.openThreshold = 700.0,
    this.closeThreshold = 350.0,
  }) : assert(frameSamples > 0, '帧长必须为正'),
       assert(closeThreshold < openThreshold, '关闭门限必须低于开启门限,否则没有滞后');

  @override
  final int frameSamples;

  @override
  final double openThreshold;

  @override
  final double closeThreshold;

  /// 帧 RMS。量纲是 int16 幅度单位(0..32767)。
  ///
  /// 平方和用 **int** 累加而不是 double:一帧 160 点、单点平方上限
  /// 32768² ≈ 1.07e9,合计约 1.7e11,离 int64 上限(9.2e18)差七个数量级,
  /// 不可能溢出,而整数累加是**精确**的 —— double 累加会引入与帧长相关的
  /// 舍入抖动,让"同一信号换个分块方式"产出不同分数,直接破坏分块无关性。
  /// (对比:`tool/audio_capture_harness.dart` 里的 Goertzel 就是栽在
  /// 累加器溢出上,长缓冲返回 0.0。这里用整数正是为了不重蹈覆辙。)
  @override
  double score(Int16List frame) {
    if (frame.isEmpty) return 0;
    int sum = 0;
    for (int i = 0; i < frame.length; i++) {
      final int s = frame[i];
      sum += s * s;
    }
    return math.sqrt(sum / frame.length);
  }

  EnergySpeechDetector copyWith({
    int? frameSamples,
    double? openThreshold,
    double? closeThreshold,
  }) {
    return EnergySpeechDetector(
      frameSamples: frameSamples ?? this.frameSamples,
      openThreshold: openThreshold ?? this.openThreshold,
      closeThreshold: closeThreshold ?? this.closeThreshold,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EnergySpeechDetector &&
          other.frameSamples == frameSamples &&
          other.openThreshold == openThreshold &&
          other.closeThreshold == closeThreshold;

  @override
  int get hashCode => Object.hash(frameSamples, openThreshold, closeThreshold);

  @override
  String toString() =>
      'EnergySpeechDetector(frameSamples: $frameSamples, '
      'openThreshold: $openThreshold, closeThreshold: $closeThreshold)';
}

/// 分段的**时间策略**(与检测器的分数量纲无关,换 ML VAD 时原样复用)。
@immutable
class VadConfig {
  const VadConfig({
    this.sampleRate = kPcmSampleRate,
    this.hangover = const Duration(milliseconds: 600),
    this.preRoll = const Duration(milliseconds: 200),
    this.minUtterance = const Duration(milliseconds: 300),
    this.maxUtterance = const Duration(seconds: 20),
  }) : assert(sampleRate > 0, '采样率必须为正');
  // 注意:这里**不能**加「minUtterance <= maxUtterance」的 const assert。
  // 常量求值器既不接受 Duration 之间的比较运算符(const_eval_type_num),
  // 也不允许在常量表达式里访问 .inMicroseconds(const_eval_property_access);
  // 而且报错点会落在调用方(`const VadConfig()` 处)而非此处,极难定位。
  // 该不变量改由 UtteranceSegmenter 构造时在运行期校验。

  final int sampleRate;

  /// 挂起时长:能量跌破关闭门限后,**继续**把这段话当作未结束的时间。
  ///
  /// 没有它的话,句中一次换气、一个停顿就会把一句话切成两半,
  /// ASR 拿到的两个半句各自缺上下文,识别率明显更差。600 ms 大致是
  /// 汉语/英语自然句内停顿的上界,句间停顿通常更长,因此它能区分二者。
  final Duration hangover;

  /// 预滚:把**触发开启之前**的这段音频也补进来。
  ///
  /// 能量门限总是慢半拍 —— 等 RMS 涨到开启门限时,词首的爆破音/擦音
  /// ("p" "t" "k" "s")已经过去了。缺了词首辅音的音频喂给 ASR,首字
  /// 错得非常离谱。补 200 ms 基本能把整个音节起始包回来,代价只是
  /// 一个几 KB 的环形缓冲。这一项对识别质量的影响比门限调参大得多。
  final Duration preRoll;

  /// 最短时长:比它短的一律丢弃(咳嗽、鼠标键盘、桌面磕碰)。
  ///
  /// 判定用的是**语音跨度**(开启处到最后一个过关闭门限的帧),不是
  /// 最终产出的长度 —— 否则 50 ms 的敲击 + 600 ms 挂起尾巴会量出 650 ms,
  /// 这条规则就永远不会生效。
  final Duration minUtterance;

  /// 最长时长:硬切。
  ///
  /// 有人一口气念五分钟稿子时,不切就意味着 STT 的一次调用要吃五分钟音频:
  /// 内存峰值、首字延迟、失败重试代价全部失控。硬切**不丢音频** ——
  /// 切点之后立刻开始新的一段继续接着录。
  final Duration maxUtterance;

  VadConfig copyWith({
    int? sampleRate,
    Duration? hangover,
    Duration? preRoll,
    Duration? minUtterance,
    Duration? maxUtterance,
  }) {
    return VadConfig(
      sampleRate: sampleRate ?? this.sampleRate,
      hangover: hangover ?? this.hangover,
      preRoll: preRoll ?? this.preRoll,
      minUtterance: minUtterance ?? this.minUtterance,
      maxUtterance: maxUtterance ?? this.maxUtterance,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VadConfig &&
          other.sampleRate == sampleRate &&
          other.hangover == hangover &&
          other.preRoll == preRoll &&
          other.minUtterance == minUtterance &&
          other.maxUtterance == maxUtterance;

  @override
  int get hashCode =>
      Object.hash(sampleRate, hangover, preRoll, minUtterance, maxUtterance);

  @override
  String toString() =>
      'VadConfig(sampleRate: $sampleRate, hangover: $hangover, '
      'preRoll: $preRoll, minUtterance: $minUtterance, '
      'maxUtterance: $maxUtterance)';
}

/// 单个说话人的语音分段器(一条轨一个实例)。
///
/// **时间戳用音频时钟而不是墙钟。** 每个采样点的绝对时刻 =
/// `sessionStart + 已处理采样数 / 采样率`,内部**从不**调用 `DateTime.now()`。
/// 这么做有两层收益:
/// 1. 可测:喂什么音频就得到什么时间戳,不用注入假时钟、不用 fake_async;
/// 2. 更准:音频是实时到达的,采样计数本身就是一把 16 kHz 的秒表,而
///    `DateTime.now()` 量到的是**回调被调度的时刻**,含 GC、线程抖动、
///    缓冲累积带来的几十毫秒噪声,还会被 NTP 校时/休眠唤醒整体跳变。
///    转写稿要按时间对齐多条轨,墙钟跳一下就全错位了。
/// 代价是长跑后音频时钟会相对墙钟缓慢漂移(取决于声卡晶振),
/// 对"看转写稿"这个用途完全无关紧要 —— 段间相对顺序才是我们要的。
class UtteranceSegmenter {
  UtteranceSegmenter({
    required this.speakerIdentity,
    required this.speakerName,
    required this.sessionStart,
    this.config = const VadConfig(),
    SpeechDetector? detector,
  }) : detector = detector ?? const EnergySpeechDetector() {
    // VadConfig 的 const 构造里无法校验这条(常量求值器不接受 Duration 比较,
    // 也不允许访问 .inMicroseconds),故挪到运行期这里。
    assert(
      config.minUtterance <= config.maxUtterance,
      '最短时长不能超过最长时长,否则每段都会被丢弃',
    );
    _frameSamples = this.detector.frameSamples;
    _frame = Int16List(_frameSamples);

    _hangoverSamples = _samplesFor(config.hangover);
    _minSamples = _samplesFor(config.minUtterance);

    // 预滚缓冲向上取整到整帧:切分器只按整帧推进,半帧的预滚既没意义
    // 也会让 buffer 长度不再是帧长的整数倍,硬切点就对不齐了。
    final int rawPreRoll = _samplesFor(config.preRoll);
    _preRollSamples = _ceilToFrame(rawPreRoll);
    _ring = Int16List(_preRollSamples);

    // 硬切阈值向**下**取整到整帧,保证 `buffer.length` 能精确命中它
    // (buffer 长度恒为帧长整数倍),从而每段都严格 ≤ maxUtterance,不会超一帧。
    final int rawMax = _samplesFor(config.maxUtterance);
    _maxSamples = math.max(_frameSamples, rawMax ~/ _frameSamples * _frameSamples);
  }

  /// LiveKit participant identity,原样写进每一段 [Utterance]。
  final String speakerIdentity;

  /// 显示名,原样写进每一段 [Utterance]。
  final String speakerName;

  /// 会话起点(绝对时刻)。音频时钟以它为零点。
  final DateTime sessionStart;

  final VadConfig config;

  /// 语音检测器。默认能量门限,可换成 ML 实现。
  final SpeechDetector detector;

  late final int _frameSamples;
  late final Int16List _frame;
  late final int _hangoverSamples;
  late final int _minSamples;
  late final int _preRollSamples;
  late final int _maxSamples;

  /// 预滚环形缓冲。**任何状态下都在写**,包括说话中 —— 否则一段话刚结束、
  /// 紧接着下一句开口时环里是空的,第二句照样被削掉词首。
  late final Int16List _ring;
  int _ringWrite = 0;
  int _ringCount = 0;

  /// 当前正在拼的帧已填入的采样点数。
  int _frameFill = 0;

  /// 跨块残留的**半个采样点**(块边界劈开了低字节和高字节)。
  /// -1 表示没有残留。这是分块无关性最容易翻车的地方:丢掉这个字节,
  /// 后面所有采样点的高低位就会整体错位一个字节,音频变成白噪声。
  int _carry = -1;

  /// 已处理(已进入分析帧)的采样点总数,即音频时钟的刻度。
  int _samplesProcessed = 0;

  bool _open = false;
  final List<int> _buffer = <int>[];

  /// [_buffer] 第一个采样点的全局下标(含预滚)。
  int _utteranceStart = 0;

  /// 触发开启的那一帧的起点全局下标(用于最短时长判定,不含预滚)。
  int _speechStart = 0;

  /// 最后一个"过关闭门限"的帧的**结束**全局下标(左闭右开)。
  int _speechEnd = 0;

  /// 连续静音累计采样点数。
  int _silenceRun = 0;

  /// 当前这段是否由硬切**续接**而来。
  ///
  /// 续接段要豁免最短时长判定:它续的是一段已经被确认为语音的音频,
  /// 不是什么咳嗽。20.05 秒的独白如果因为"尾巴只有 50 ms"就被丢掉,
  /// 那就是硬切把音频弄丢了 —— 而硬切的承诺恰恰是"一个采样点都不丢"。
  bool _continuation = false;

  /// 已产出音频的结束全局下标。预滚回溯不得越过它,否则同一段音频
  /// 会同时出现在相邻两个 [Utterance] 里(重复识别、转写稿出现重影)。
  int _emittedEnd = 0;

  /// 是否正处在一段语音中(含挂起尾巴)。UI 可以拿它点亮说话指示。
  bool get isSpeaking => _open;

  /// 已处理的音频总时长(音频时钟读数)。
  Duration get processedAudio =>
      Duration(microseconds: _samplesProcessed * 1000000 ~/ config.sampleRate);

  /// 喂入一块 PCM,返回**本块内被切完**的语音段(绝大多数情况是空表)。
  ///
  /// 同步返回而不是走 Stream:分段本身是纯计算,同步接口让测试可以
  /// "喂一块、立刻断言",不需要 `await`、不需要 fake_async、不需要任何 mock。
  /// 需要流式的话在外层套 [segmentUtterances] 即可。
  List<Utterance> addChunk(Uint8List pcm) {
    final List<Utterance> done = <Utterance>[];
    int i = 0;
    final int end = pcm.lengthInBytes;

    // 先把上一块留下的半个采样点补齐。
    if (_carry >= 0) {
      if (end == 0) return done;
      _pushSample(_int16LE(_carry, pcm[0]), done);
      _carry = -1;
      i = 1;
    }
    while (end - i >= kBytesPerSample) {
      _pushSample(_int16LE(pcm[i], pcm[i + 1]), done);
      i += kBytesPerSample;
    }
    if (i < end) _carry = pcm[i];
    return done;
  }

  /// 会话结束时收尾:把正在进行的一段收掉。
  ///
  /// 不足一帧的尾部采样点会被丢弃(最多 10 ms,且几乎必然是挂起期的静音),
  /// 换来的是"任何时刻 buffer 长度都是帧长整数倍"这个不变量。
  Utterance? flush() {
    if (!_open) return null;
    return _close();
  }

  /// 重置到初始状态(换会话/换轨时用)。注意音频时钟也归零。
  void reset() {
    detector.reset();
    _ringWrite = 0;
    _ringCount = 0;
    _frameFill = 0;
    _carry = -1;
    _samplesProcessed = 0;
    _open = false;
    _buffer.clear();
    _utteranceStart = 0;
    _speechStart = 0;
    _speechEnd = 0;
    _silenceRun = 0;
    _emittedEnd = 0;
    _continuation = false;
  }

  void _pushSample(int sample, List<Utterance> out) {
    _frame[_frameFill++] = sample;
    if (_frameFill < _frameSamples) return;
    _frameFill = 0;
    _processFrame(out);
  }

  void _processFrame(List<Utterance> out) {
    final int frameStart = _samplesProcessed;
    final int frameEnd = frameStart + _frameSamples;
    final double sc = detector.score(_frame);

    if (!_open) {
      if (sc >= detector.openThreshold) {
        _startUtterance(frameStart, frameEnd);
      }
    } else {
      _buffer.addAll(_frame);
      if (sc >= detector.closeThreshold) {
        _speechEnd = frameEnd;
        _silenceRun = 0;
      } else {
        _silenceRun += _frameSamples;
      }

      if (_silenceRun >= _hangoverSamples) {
        final Utterance? u = _close();
        if (u != null) out.add(u);
      } else if (_buffer.length >= _maxSamples) {
        out.add(_forceCut(frameEnd));
      }
    }

    _pushRing();
    _samplesProcessed = frameEnd;
  }

  void _startUtterance(int frameStart, int frameEnd) {
    // 预滚能回溯多远,受三件事夹逼:配置的预滚长度、环里真有多少、
    // 以及绝不能回溯到已产出的音频里去。
    int back = math.min(_ringCount, _preRollSamples);
    if (frameStart - back < _emittedEnd) back = frameStart - _emittedEnd;
    if (back < 0) back = 0;

    _buffer
      ..clear()
      ..addAll(_ringTail(back))
      ..addAll(_frame);

    _utteranceStart = frameStart - back;
    _speechStart = frameStart;
    _speechEnd = frameEnd;
    _silenceRun = 0;
    _open = true;
    _continuation = false;
  }

  /// 硬切:整段原样产出,然后**无缝**接着录。
  ///
  /// 关键是不做尾部裁剪也不做预滚 —— 切点前后的音频本来就是连续的,
  /// 裁剪会丢音频,预滚会让同一段音频出现两次。
  Utterance _forceCut(int cutEnd) {
    final Utterance u = _emit(_utteranceStart, _buffer.length);
    _buffer.clear();
    _utteranceStart = cutEnd;
    _speechStart = cutEnd;
    _speechEnd = cutEnd;
    _continuation = true;
    // _silenceRun 刻意保留:如果切点正好落在挂起尾巴里,
    // 后半段应该继续数同一段静音,而不是把挂起计时重置。
    return u;
  }

  /// 收尾一段:裁掉挂起期的尾部静音,再做最短时长判定。
  ///
  /// 裁尾而不是保留:关闭门限比开启门限低,词尾的自然衰减仍在关闭门限之上
  /// 因而被保留下来;越过关闭门限之后的那段挂起静音不含任何信息,
  /// 留着只会让 STT 多算几百毫秒空白。
  Utterance? _close() {
    final int speechSpan = _speechEnd - _speechStart;
    final int emitLen = _speechEnd - _utteranceStart;
    final bool continuation = _continuation;
    _open = false;
    _silenceRun = 0;
    _continuation = false;

    if ((speechSpan < _minSamples && !continuation) || emitLen <= 0) {
      _buffer.clear();
      return null; // 太短:咳嗽/键盘/碰桌子,丢掉
    }

    final Utterance u = _emit(_utteranceStart, emitLen);
    _buffer.clear();
    return u;
  }

  Utterance _emit(int startSample, int length) {
    final Utterance u = Utterance(
      speakerIdentity: speakerIdentity,
      speakerName: speakerName,
      startedAt: _timeAt(startSample),
      endedAt: _timeAt(startSample + length),
      pcm: encodePcm16(_buffer.sublist(0, length)),
      sampleRate: config.sampleRate,
    );
    _emittedEnd = startSample + length;
    return u;
  }

  /// 音频时钟 -> 绝对时刻。
  ///
  /// 先乘后整除保住微秒精度。乘法溢出?16 kHz 跑满一年约 5e17,
  /// 距 int64 上限还有 18 倍余量,而本模块的会话以小时计。
  DateTime _timeAt(int sampleIndex) => sessionStart.add(
    Duration(microseconds: sampleIndex * 1000000 ~/ config.sampleRate),
  );

  void _pushRing() {
    if (_ring.isEmpty) return;
    for (int i = 0; i < _frameSamples; i++) {
      _ring[_ringWrite] = _frame[i];
      _ringWrite = (_ringWrite + 1) % _ring.length;
    }
    _ringCount = math.min(_ringCount + _frameSamples, _ring.length);
  }

  /// 取环里最后 [n] 个采样点(按时间先后)。调用方保证 `n <= _ringCount`。
  Int16List _ringTail(int n) {
    final Int16List out = Int16List(n);
    if (n == 0) return out;
    final int cap = _ring.length;
    for (int k = 0; k < n; k++) {
      int idx = (_ringWrite - n + k) % cap;
      if (idx < 0) idx += cap;
      out[k] = _ring[idx];
    }
    return out;
  }

  int _samplesFor(Duration d) =>
      d.inMicroseconds * config.sampleRate ~/ 1000000;

  int _ceilToFrame(int samples) =>
      (samples + _frameSamples - 1) ~/ _frameSamples * _frameSamples;
}

/// 小端两字节 -> 有符号 int16。
///
/// 手写拼装而不是 `Int16List.view` 重解释:后者用**宿主机字节序**,
/// 在大端机器上会静默读反。这条链路的字节序必须由我们说了算。
int _int16LE(int lo, int hi) {
  final int v = lo | (hi << 8);
  return v >= 0x8000 ? v - 0x10000 : v;
}

/// 流式包装:把 PCM 块流切成语音段流。
///
/// 只是 [UtteranceSegmenter] 的薄壳 —— 核心逻辑保持同步、可测;
/// 真实链路(LiveKit 的音频帧回调)拿到的是流,这层省掉调用方自己攒循环。
/// 流正常结束时会自动 [UtteranceSegmenter.flush],不会丢掉最后一句。
Stream<Utterance> segmentUtterances(
  Stream<Uint8List> chunks, {
  required String speakerIdentity,
  required String speakerName,
  required DateTime sessionStart,
  VadConfig config = const VadConfig(),
  SpeechDetector? detector,
}) async* {
  final UtteranceSegmenter seg = UtteranceSegmenter(
    speakerIdentity: speakerIdentity,
    speakerName: speakerName,
    sessionStart: sessionStart,
    config: config,
    detector: detector,
  );
  await for (final Uint8List chunk in chunks) {
    for (final Utterance u in seg.addChunk(chunk)) {
      yield u;
    }
  }
  final Utterance? tail = seg.flush();
  if (tail != null) yield tail;
}
