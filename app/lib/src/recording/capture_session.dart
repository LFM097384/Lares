/// 录音采集的**纯核心**:把「一帧 PCM 到了」翻译成「某个说话人的一段话」。
///
/// 本文件刻意不 import `livekit_client`,也不 import `dart:io`:
/// 采集链路上真正难写的部分(同意门禁、分说话人切分、格式校验、
/// 音频时钟重锚、磁盘封顶)全部集中在这里,于是它们可以在**没有插件、
/// 没有平台通道、没有真实房间**的纯 VM 测试里被完整驱动。
/// 与 SDK 打交道的那一层薄壳在 `recording_service.dart`,它只做事件转译。
library;

import 'dart:async';

// 只用 foundation 的 @immutable / ChangeNotifier / Listenable —— 前者是纯值语义
// 标记,后两者是纯 Dart 的观察者实现,三者都不引入任何平台通道依赖,
// 本文件因此可在无插件的纯 VM 测试环境中直接使用。
// 未选用 package:meta 是因为它不是本包的直接依赖(depend_on_referenced_packages)。
// Uint8List 也一并从这里拿:foundation 已经转出了 dart:typed_data,
// 再显式 import 一次会被 unnecessary_import 判为多余。
import 'package:flutter/foundation.dart';

import 'utterance.dart';
import 'vad.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 常量
// ─────────────────────────────────────────────────────────────────────────────

/// 音频时钟相对墙钟的默认容忍量。
///
/// 取 1 秒是「够松」与「够紧」的折中:够松,是因为正常连续采集下漂移只来自
/// 声卡晶振(百万分之几,跑一小时才几十毫秒),1 秒绝不会被误触发;够紧,
/// 是因为一次静音/重连造成的空洞通常以秒计,超过 1 秒的错位在多说话人
/// 转写稿里已经能被肉眼看出顺序错乱了。
const Duration kDefaultClockDriftTolerance = Duration(seconds: 1);

/// 渲染器首帧看门狗的默认超时。
///
/// 原生侧启动失败是**静默**的(见 [RendererWatchdog] 的说明),只能靠
/// 「等不到首帧」反推。2 秒足够覆盖真机上最慢的一次冷启动,又不至于让
/// 一条彻底哑掉的轨白白沉默太久。
const Duration kDefaultFirstFrameTimeout = Duration(seconds: 2);

/// 渲染器注册的默认最大尝试次数(含第一次)。
///
/// 4 次配合线性退避,总等待约 2 + 0.4 + 2 + 0.8 + 2 + 1.2 ≈ 8.4 秒。
/// 再多就没意义了:能救回来的早救回来了,救不回来的是设备级故障,
/// 该让 UI 报错而不是无限重试。
const int kDefaultMaxRendererAttempts = 4;

/// 渲染器重注册的默认退避基数(按尝试次数线性放大)。
const Duration kDefaultRetryBackoff = Duration(milliseconds: 400);

// ─────────────────────────────────────────────────────────────────────────────
// 枚举
// ─────────────────────────────────────────────────────────────────────────────

/// 采集停止的原因。
///
/// 优先级从高到低是 [disposed] > [consentRevoked] > [diskCapReached] > [none],
/// 见 [CaptureSession.stopReason] 的说明 —— 同时成立时报告更"致命"的那个。
enum CaptureStopReason {
  /// 没有停止,正在采集(或从未开始)。
  none,

  /// 用户撤回了录音同意。这一档意味着**在途音频已被丢弃**,不是暂停。
  consentRevoked,

  /// 磁盘配额触顶。这一档意味着在途音频已被**正常收尾产出**,不是丢弃。
  diskCapReached,

  /// 会话已 dispose,终态,不可恢复。
  disposed,
}

/// 单条轨渲染器的健康度。UI 直接拿它显示"这个人的声音到底进没进来"。
enum RendererHealth {
  /// 还没注册过渲染器。
  idle,

  /// 已注册,正在等首帧。
  starting,

  /// 收到过首帧,链路确认打通。
  healthy,

  /// 首帧超时,正在取消并重注册。
  retrying,

  /// 重试次数耗尽,仍然一帧都没有。设备级故障,需要人工介入。
  failed,

  /// 帧的采样率/声道数与预期不符。这不是"链路不通"而是"配置错了",
  /// 重试无用,所以它是一个独立的终态而不是 [failed] 的一种。
  formatMismatch,
}

// ─────────────────────────────────────────────────────────────────────────────
// 值对象
// ─────────────────────────────────────────────────────────────────────────────

/// 单个说话人的采集快照(给 UI 看的)。
@immutable
class CaptureIdentityState {
  const CaptureIdentityState({
    required this.identity,
    required this.displayName,
    this.active = false,
    this.health = RendererHealth.idle,
    this.attempts = 0,
    this.bufferedBytes = 0,
    this.droppedFrames = 0,
    this.speaking = false,
  }) : assert(attempts >= 0, '尝试次数不能为负'),
       assert(bufferedBytes >= 0, '已缓冲字节数不能为负'),
       assert(droppedFrames >= 0, '丢帧数不能为负');

  /// LiveKit participant identity。**机器可读的主键**,聚合一律认它。
  final String identity;

  /// 显示名。可能为空字符串,取名逻辑在适配层做过兜底,这里原样存。
  final String displayName;

  /// 当前是否在接收音频。重连期间会被 [CaptureSession.markAllStale] 置回
  /// false,但切分器**不会**被销毁 —— 见那个方法的说明。
  final bool active;

  final RendererHealth health;

  /// 渲染器注册尝试次数(含第一次)。
  final int attempts;

  /// 自**当前这个**切分器被创建以来喂进去的字节数。
  ///
  /// 注意它会在时钟重锚(切分器重建)时归零,所以它衡量的是"当前这段
  /// 采集攒了多少",不是会话累计 —— 会话累计看 [CaptureSessionStats.totalBytes]。
  final int bufferedBytes;

  /// 因格式不符被丢弃的帧数。
  final int droppedFrames;

  /// 切分器当前是否处在一段语音中(含挂起尾巴)。UI 可拿它点亮说话指示。
  final bool speaking;

  CaptureIdentityState copyWith({
    String? identity,
    String? displayName,
    bool? active,
    RendererHealth? health,
    int? attempts,
    int? bufferedBytes,
    int? droppedFrames,
    bool? speaking,
  }) {
    return CaptureIdentityState(
      identity: identity ?? this.identity,
      displayName: displayName ?? this.displayName,
      active: active ?? this.active,
      health: health ?? this.health,
      attempts: attempts ?? this.attempts,
      bufferedBytes: bufferedBytes ?? this.bufferedBytes,
      droppedFrames: droppedFrames ?? this.droppedFrames,
      speaking: speaking ?? this.speaking,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CaptureIdentityState &&
          other.identity == identity &&
          other.displayName == displayName &&
          other.active == active &&
          other.health == health &&
          other.attempts == attempts &&
          other.bufferedBytes == bufferedBytes &&
          other.droppedFrames == droppedFrames &&
          other.speaking == speaking;

  @override
  int get hashCode => Object.hash(
    identity,
    displayName,
    active,
    health,
    attempts,
    bufferedBytes,
    droppedFrames,
    speaking,
  );

  @override
  String toString() =>
      'CaptureIdentityState(identity: $identity, '
      'displayName: $displayName, active: $active, health: $health, '
      'attempts: $attempts, bufferedBytes: $bufferedBytes, '
      'droppedFrames: $droppedFrames, speaking: $speaking)';
}

/// 整个采集会话的快照。
@immutable
class CaptureSessionStats {
  const CaptureSessionStats({
    required this.capturing,
    required this.stopReason,
    required this.totalBytes,
    required this.utterancesEmitted,
    required this.droppedFrames,
    required this.identities,
  }) : assert(totalBytes >= 0, '累计字节数不能为负'),
       assert(utterancesEmitted >= 0, '产出段数不能为负'),
       assert(droppedFrames >= 0, '丢帧数不能为负');

  /// 此刻是否在接受音频。
  final bool capturing;

  final CaptureStopReason stopReason;

  /// 会话累计**被接受**的字节数(不含被格式校验挡下的)。
  final int totalBytes;

  /// 会话累计产出的语音段数。
  final int utterancesEmitted;

  /// 会话累计丢帧数(各说话人之和)。
  final int droppedFrames;

  /// 按 identity 字典序排好的每人快照。排序是为了让 UI 列表不会因为
  /// Map 迭代顺序变化而跳动,也让测试断言稳定。
  final List<CaptureIdentityState> identities;

  /// 是否有任何一条轨处在终态失败(含格式不符)。
  bool get anyFailed => identities.any(
    (CaptureIdentityState s) =>
        s.health == RendererHealth.failed ||
        s.health == RendererHealth.formatMismatch,
  );

  /// 是否有任何一条轨正在重注册。
  bool get anyRetrying => identities.any(
    (CaptureIdentityState s) => s.health == RendererHealth.retrying,
  );

  /// 此刻真正在收音的说话人集合。
  Set<String> get activeIdentities => identities
      .where((CaptureIdentityState s) => s.active)
      .map((CaptureIdentityState s) => s.identity)
      .toSet();

  CaptureSessionStats copyWith({
    bool? capturing,
    CaptureStopReason? stopReason,
    int? totalBytes,
    int? utterancesEmitted,
    int? droppedFrames,
    List<CaptureIdentityState>? identities,
  }) {
    return CaptureSessionStats(
      capturing: capturing ?? this.capturing,
      stopReason: stopReason ?? this.stopReason,
      totalBytes: totalBytes ?? this.totalBytes,
      utterancesEmitted: utterancesEmitted ?? this.utterancesEmitted,
      droppedFrames: droppedFrames ?? this.droppedFrames,
      identities: identities ?? this.identities,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CaptureSessionStats &&
          other.capturing == capturing &&
          other.stopReason == stopReason &&
          other.totalBytes == totalBytes &&
          other.utterancesEmitted == utterancesEmitted &&
          other.droppedFrames == droppedFrames &&
          listEquals(other.identities, identities);

  @override
  int get hashCode => Object.hash(
    capturing,
    stopReason,
    totalBytes,
    utterancesEmitted,
    droppedFrames,
    Object.hashAll(identities),
  );

  @override
  String toString() =>
      'CaptureSessionStats(capturing: $capturing, '
      'stopReason: $stopReason, totalBytes: $totalBytes, '
      'utterancesEmitted: $utterancesEmitted, '
      'droppedFrames: $droppedFrames, identities: $identities)';
}

// ─────────────────────────────────────────────────────────────────────────────
// 每个说话人的可变运行时状态(私有)
// ─────────────────────────────────────────────────────────────────────────────

/// 一个说话人的可变运行时。刻意与对外的 [CaptureIdentityState] 分开:
/// 前者是内部账本,后者是不可变快照,免得 UI 拿到一个会在脚下变化的对象。
class _IdentityRuntime {
  _IdentityRuntime({required this.displayName});

  String displayName;

  /// 懒创建。为 null 表示当前没有在收这个人的音(还没来帧,或已被丢弃)。
  UtteranceSegmenter? segmenter;

  /// 当前切分器的音频时钟零点。重锚时会跟着 [segmenter] 一起换。
  DateTime sessionStart = DateTime.fromMillisecondsSinceEpoch(0);

  RendererHealth health = RendererHealth.idle;
  int attempts = 0;
  int bufferedBytes = 0;
  int droppedFrames = 0;

  /// 格式不符只在**每个说话人**身上记一次日志,否则 10 ms 一帧会把日志刷爆。
  bool formatWarned = false;
}

// ─────────────────────────────────────────────────────────────────────────────
// 采集会话核心
// ─────────────────────────────────────────────────────────────────────────────

/// 采集核心:**一个说话人一个切分器**,靠 LiveKit 的轨道天然分离说话人。
///
/// 这是整个录音特性的架构主张:多人会议的"谁在说话"不需要任何 ML 声纹
/// 分离(diarization)。SFU 已经把每个人的麦克风送成一条独立的轨,轨上带着
/// 权威的 participant identity。我们要做的只是**别把它们混在一起** ——
/// 每条轨喂给自己的 [UtteranceSegmenter],产出的 [Utterance] 天生带着
/// 正确的说话人标签,准确率取决于 SFU 而不是取决于模型。
///
/// 本类**不碰**任何平台 API,可在纯 VM 测试里被完整驱动,见
/// `test/recording_service_test.dart`。
class CaptureSession extends ChangeNotifier {
  CaptureSession({
    required this.isCaptureAllowed,
    required this.now,
    Listenable? consentNotifier,
    bool Function(int additionalBytes)? wouldExceedDisk,
    this.vadConfig = const VadConfig(),
    this.detector,
    this.expectedSampleRate = kPcmSampleRate,
    this.expectedChannels = 1,
    this.clockDriftTolerance = kDefaultClockDriftTolerance,
    this.onLog,
  }) : _consentNotifier = consentNotifier,
       _wouldExceedDisk = wouldExceedDisk,
       assert(expectedSampleRate > 0, '预期采样率必须为正'),
       assert(expectedChannels > 0, '预期声道数必须为正') {
    // 用 addListener 而不是让本类依赖 RecordingConsentController 的具体类型。
    //
    // 真实的同意控制器把 onCaptureAllowedChanged 声明成 **final、只能构造时
    // 注入**的字段,外部既无法订阅也无法改写它;但它本身 extends ChangeNotifier,
    // 而 captureAllowed 又是一个同步 getter。于是"监听通知 + 回读 getter"
    // 就是唯一可用、也是最松的耦合方式:本类只认 [Listenable] 这个抽象,
    // 测试里随便拿一个假的 ChangeNotifier 就能驱动,不必构造真控制器
    // (那需要一个 send 回调和一堆信令依赖)。
    _consentNotifier?.addListener(_onConsentNotified);
  }

  /// 同意门禁。**每帧都会问**,所以实现必须是廉价的同步读。
  final bool Function() isCaptureAllowed;

  /// 墙钟。注入而非直接调 `DateTime.now()`,是为了让时钟重锚可被确定性测试。
  final DateTime Function() now;

  final Listenable? _consentNotifier;

  /// 磁盘封顶判定。为 null 时视为"永远不会超"。
  final bool Function(int additionalBytes)? _wouldExceedDisk;

  final VadConfig vadConfig;

  /// 语音检测器。为 null 时各切分器各自用默认的 [EnergySpeechDetector]。
  final SpeechDetector? detector;

  /// 预期采样率。与之不符的帧一律拒收,见 [onFrameBytes] 的格式策略。
  final int expectedSampleRate;

  /// 预期声道数。
  final int expectedChannels;

  /// 音频时钟相对墙钟的容忍量,超过就重锚。
  final Duration clockDriftTolerance;

  final void Function(String message)? onLog;

  final StreamController<Utterance> _utterances =
      StreamController<Utterance>.broadcast();

  final Map<String, _IdentityRuntime> _identities =
      <String, _IdentityRuntime>{};

  bool _disposed = false;
  bool _consentBlocked = false;
  bool _diskBlocked = false;
  int _totalBytes = 0;
  int _utterancesEmitted = 0;
  int _droppedFrames = 0;

  /// 外部喂进来的最近一次磁盘占用读数,仅用于日志与排查,不参与判定 ——
  /// 判定始终走注入的谓词,见 [noteDiskUsage]。
  int _lastKnownDiskBytes = 0;

  // ───────────────────────────────────────────────────────────────────────────
  // 对外只读状态
  // ───────────────────────────────────────────────────────────────────────────

  /// 产出的语音段。广播流:转写、落盘、UI 波形可以各订各的。
  ///
  /// 是**异步**广播流(不是 sync),所以 `add` 不会在音频回调线程上同步
  /// 触发下游的转写/落盘 —— 那会把几十毫秒的 IO 压回 10 ms 的帧回调里。
  Stream<Utterance> get utterances => _utterances.stream;

  /// 此刻是否在接受音频。
  bool get capturing =>
      !_disposed && !_consentBlocked && !_diskBlocked && isCaptureAllowed();

  /// 停止原因,按 [CaptureStopReason] 的优先级派生。
  ///
  /// 刻意**派生**而不是存一个字段:同意撤回与磁盘触顶是两个正交的闸门,
  /// 各自有独立的置位/复位时机。存单一字段的话,先触磁盘、再撤同意,
  /// 恢复同意时就会把还没解除的磁盘闸门一起抹掉,变成"以为能录其实录不了"。
  CaptureStopReason get stopReason {
    if (_disposed) return CaptureStopReason.disposed;
    if (_consentBlocked || !isCaptureAllowed()) {
      return CaptureStopReason.consentRevoked;
    }
    if (_diskBlocked) return CaptureStopReason.diskCapReached;
    return CaptureStopReason.none;
  }

  /// 会话累计被接受的字节数。
  int get totalBytes => _totalBytes;

  /// 最近一次外部报告的磁盘占用(字节)。
  int get lastKnownDiskBytes => _lastKnownDiskBytes;

  CaptureSessionStats get stats {
    final List<String> keys = _identities.keys.toList()..sort();
    return CaptureSessionStats(
      capturing: capturing,
      stopReason: stopReason,
      totalBytes: _totalBytes,
      utterancesEmitted: _utterancesEmitted,
      droppedFrames: _droppedFrames,
      identities: List<CaptureIdentityState>.unmodifiable(
        keys.map((String id) {
          final _IdentityRuntime st = _identities[id]!;
          return CaptureIdentityState(
            identity: id,
            displayName: st.displayName,
            active: st.segmenter != null,
            health: st.health,
            attempts: st.attempts,
            bufferedBytes: st.bufferedBytes,
            droppedFrames: st.droppedFrames,
            speaking: st.segmenter?.isSpeaking ?? false,
          );
        }),
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 热路径:一帧音频
  // ───────────────────────────────────────────────────────────────────────────

  /// 一帧 PCM 到达。**同步**,由 LiveKit 的 onFrame 直接调用。
  ///
  /// 闸门顺序是刻意排的,从"最便宜且最不可协商"到"最贵":
  /// dispose → 同意 → 磁盘闸门 → 格式校验 → 磁盘谓词 → 落入切分器。
  /// 其中两处顺序有实质含义:
  /// 1. **同意门禁短路一切**。撤回同意之后连"丢了一帧"这种统计都不该记 ——
  ///    用户要的是"什么都别做",不是"记着我拒绝了几帧"。
  /// 2. **格式校验排在磁盘谓词之前**。格式不符的帧根本不会落盘,让它去
  ///    消耗磁盘配额判定既没道理,还会在一条配置错的轨上把整个会话顶停。
  void onFrameBytes(
    String identity,
    String displayName,
    Uint8List pcm,
    int sampleRate,
    int channels,
  ) {
    // dispose 之后静默返回。音频回调来自原生线程,注销与最后一帧之间
    // 天然有竞态,这里崩溃等于"用户点了停止,应用挂了"。
    if (_disposed) return;

    // ── 闸门 1:同意 ────────────────────────────────────────────────────────
    if (!isCaptureAllowed()) {
      if (!_consentBlocked) {
        _enterConsentRevoked();
        notifyListeners();
      }
      return;
    }
    if (_consentBlocked) {
      // 同意恢复。切分器不在这里重建 —— 留给下面的懒创建,这样新的
      // sessionStart 一定取自"真正收到第一帧"的时刻,而不是"用户点了同意"
      // 的时刻,中间那段等待轨道重新可用的空窗不会被算进音频时钟。
      _consentBlocked = false;
      _log('同意已恢复,采集继续');
      notifyListeners();
    }

    // ── 闸门 2:磁盘封顶闩锁 ────────────────────────────────────────────────
    // 注意这里**不重新求值谓词**。恢复只能靠 noteDiskUsage / onConsentChanged
    // 显式触发,理由见 [noteDiskUsage] 的文档。
    if (_diskBlocked) return;

    final _IdentityRuntime st = _identities.putIfAbsent(identity, () {
      _log('新说话人进入采集:$identity');
      return _IdentityRuntime(displayName: displayName);
    });
    st.displayName = displayName;

    // ── 闸门 3:格式校验(不符 = 拒收,绝不重采样)────────────────────────
    if (sampleRate != expectedSampleRate || channels != expectedChannels) {
      _rejectFormat(identity, st, sampleRate, channels);
      return;
    }

    // ── 闸门 4:磁盘配额 ────────────────────────────────────────────────────
    if (_exceedsDisk(pcm.lengthInBytes)) {
      _enterDiskCapReached();
      return;
    }

    // ── 落入切分器 ──────────────────────────────────────────────────────────
    bool changed = false;
    UtteranceSegmenter? seg = st.segmenter;
    if (seg == null) {
      seg = _newSegmenter(identity, st);
      changed = true;
    } else if (_shouldReanchor(st, seg)) {
      // 重锚前先把在途的一段收掉:它是在**有效同意**下采到的合法音频,
      // 丢掉才是错的(与撤回同意的语义正好相反)。
      if (_flushInto(seg)) changed = true;
      seg = _newSegmenter(identity, st);
      changed = true;
    }

    st.bufferedBytes += pcm.lengthInBytes;
    _totalBytes += pcm.lengthInBytes;

    final List<Utterance> done = seg.addChunk(pcm);
    for (final Utterance u in done) {
      _emit(u);
      changed = true;
    }

    // 只在"状态可见地变了"时通知。每帧都 notify 等于 10 ms 一次 rebuild,
    // 会把 UI 线程吃光,而且绝大多数帧什么都没改变。
    if (changed) notifyListeners();
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 生命周期事件
  // ───────────────────────────────────────────────────────────────────────────

  /// 某条轨没了(取消订阅 / 本地取消发布)。
  ///
  /// 只收尾**这一个人**:把在途的一段产出,然后释放它的状态。绝不触碰
  /// 其他说话人 —— 一个人挂断不该让别人的半句话被切断。
  void onTrackGone(String identity) {
    if (_disposed) return;
    final _IdentityRuntime? st = _identities.remove(identity);
    if (st == null) return;
    final UtteranceSegmenter? seg = st.segmenter;
    st.segmenter = null;
    if (seg != null) _flushInto(seg);
    _log('轨道结束,已收尾并释放:$identity');
    notifyListeners();
  }

  /// 适配层报告某条轨的渲染器健康度变化。
  ///
  /// [RendererHealth.formatMismatch] 是本类自己闩上的,不会被这里覆盖为
  /// healthy —— 除非重新走一次注册(适配层会报 [RendererHealth.starting])。
  /// 理由:格式不符是配置问题,链路"通"了也依然是错的,不该被一次成功的
  /// 首帧掩盖掉。
  void onRendererHealth(
    String identity,
    String displayName,
    RendererHealth health,
    int attempts,
  ) {
    if (_disposed) return;
    final _IdentityRuntime st = _identities.putIfAbsent(
      identity,
      () => _IdentityRuntime(displayName: displayName),
    );
    st.displayName = displayName;
    if (st.health == RendererHealth.formatMismatch &&
        health != RendererHealth.starting) {
      st.attempts = attempts;
      return;
    }
    if (health == RendererHealth.starting) {
      // 一次全新的注册意味着格式问题有机会被重新评估。
      st.formatWarned = false;
    }
    final bool changed = st.health != health || st.attempts != attempts;
    st.health = health;
    st.attempts = attempts;
    if (changed) notifyListeners();
  }

  /// 手动重新评估同意与磁盘闸门。
  ///
  /// [consentNotifier] 已经会自动触发它;这个公开入口留给没有 Listenable
  /// 可用的装配方式,以及磁盘清理完成后的主动唤醒。
  void onConsentChanged() => _reevaluate();

  /// 重连等场景下的记账:把所有轨标记为"当前没在收音"。
  ///
  /// 刻意**不销毁切分器**。重连后回来的音频仍然属于同一段对话,保留切分器
  /// 可以让一句被重连打断的话尽量续上;真正的空洞由时钟重锚兜底 ——
  /// 如果这次断开超过了 [clockDriftTolerance],下一帧会自动重锚,
  /// 不会让空洞把后续时间戳整体拽偏。
  void markAllStale() {
    if (_disposed) return;
    if (_identities.isEmpty) return;
    for (final _IdentityRuntime st in _identities.values) {
      if (st.health == RendererHealth.healthy) {
        st.health = RendererHealth.idle;
      }
    }
    _log('连接中断/恢复,已把所有轨标记为待重新注册');
    notifyListeners();
  }

  /// 外部喂入当前磁盘占用,并顺带重新评估磁盘闸门。
  ///
  /// **磁盘恢复规则(明确写死)**:一旦触顶,采集会一直停着,直到有人调用
  /// 本方法或 [onConsentChanged],且此时谓词 `wouldExceedDisk(0)` 返回 false。
  /// 热路径上**不会**自动重试谓词。
  ///
  /// 之所以选"显式唤醒"而不是"每帧自愈":自愈虽然不会卡死,但会在阈值附近
  /// 反复抖动 —— 越过就停+全部收尾、退回就恢复,一秒内可能来回几十次,
  /// 每次都把在途的话切断,转写稿会碎成一地;而且它要在 10 ms 的帧回调里
  /// 反复调用一个可能扫目录的谓词。代价是"没人唤醒就永远停着",这个风险由
  /// 上层的清理任务负责兜底,而且它是**安全方向**的失败:宁可少录,
  /// 不可把用户磁盘写爆。
  void noteDiskUsage(int currentTotalBytes) {
    if (_disposed) return;
    _lastKnownDiskBytes = currentTotalBytes;
    _reevaluate();
  }

  /// 把所有在途的语音段收尾产出(会话正常结束时用)。
  void flushAll() {
    if (_disposed) return;
    if (_flushAllInternal()) notifyListeners();
  }

  @override
  void dispose() {
    // 幂等。ChangeNotifier.dispose 本身**不**幂等(第二次调用会命中
    // debugAssertNotDisposed 断言),所以这里必须在重复调用时直接返回,
    // 而不是再往下透传一次 super.dispose()。采集链路上「谁负责 dispose」
    // 会随注入方式变化(自造 vs 外部注入),重复调用是可以预期的。
    if (_disposed) return;
    _disposed = true;
    _consentNotifier?.removeListener(_onConsentNotified);
    // dispose 不产出任何在途音频:调用方要留下最后一句的话,应该先
    // 显式 flushAll()。让 dispose 顺手产出会在"流已关"和"还要发事件"
    // 之间制造竞态。
    for (final _IdentityRuntime st in _identities.values) {
      st.segmenter = null;
    }
    _identities.clear();
    unawaited(_utterances.close());
    super.dispose();
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 内部实现
  // ───────────────────────────────────────────────────────────────────────────

  void _onConsentNotified() => _reevaluate();

  void _reevaluate() {
    if (_disposed) return;
    bool changed = false;

    final bool allowed = isCaptureAllowed();
    if (!allowed && !_consentBlocked) {
      _enterConsentRevoked();
      changed = true;
    } else if (allowed && _consentBlocked) {
      _consentBlocked = false;
      _log('同意已恢复,采集继续');
      changed = true;
    }

    if (_diskBlocked && !_exceedsDisk(0)) {
      _diskBlocked = false;
      _log('磁盘占用已回落,采集恢复');
      changed = true;
    }

    if (changed) notifyListeners();
  }

  /// 撤回同意:**不收尾,直接丢弃**。
  ///
  /// 这是本文件里唯一一处"故意扔掉已经采到的音频"。理由是法律与信任层面的:
  /// 用户撤回同意的那一刻起,任何还没落地的音频都失去了被保存的依据 ——
  /// 把它收尾产出,就等于把用户刚刚明确拒绝的那几秒钟写进转写稿和磁盘。
  /// 磁盘触顶时的处理正好相反(那时同意仍然有效,收尾是对的),两者的差别
  /// 完全在于"这段音频当初是不是在有效同意下采到的"。
  void _enterConsentRevoked() {
    _consentBlocked = true;
    for (final _IdentityRuntime st in _identities.values) {
      st.segmenter = null; // 不 flush,直接丢
      st.bufferedBytes = 0;
    }
    _log('同意已撤回:已丢弃全部在途音频,未产出任何语音段');
  }

  /// 磁盘触顶:停采,并把在途的一段**正常收尾产出**。
  void _enterDiskCapReached() {
    _diskBlocked = true;
    _flushAllInternal();
    _log('磁盘配额触顶:已停止采集并收尾在途语音段,等待清理后显式唤醒');
    notifyListeners();
  }

  void _rejectFormat(
    String identity,
    _IdentityRuntime st,
    int sampleRate,
    int channels,
  ) {
    st.droppedFrames += 1;
    _droppedFrames += 1;
    final bool healthChanged = st.health != RendererHealth.formatMismatch;
    st.health = RendererHealth.formatMismatch;
    if (!st.formatWarned) {
      st.formatWarned = true;
      _log(
        '格式不符,已拒收 $identity 的音频:收到 ${sampleRate}Hz/${channels}ch,'
        '预期 ${expectedSampleRate}Hz/${expectedChannels}ch',
      );
    }
    // 为什么是拒收而不是重采样或者"截一截凑合用":
    // AudioFrame.sampleRate 只是把我们请求的值**原样回显**,它不是对音频的
    // 测量。所以这里的不一致不可能是"设备实际跑偏了"这种可以容忍的偏差,
    // 只可能是注册渲染器时把参数写错了 —— 是配置错误,不是运行时波动。
    // 而字节流一旦按错误的采样率/声道数追加进切分器,后果不是"音质差一点",
    // 是整段 PCM 的语义错位:声道数错会让左右声道交替成为相邻采样点,
    // 采样率错会让音频时钟按错误刻度推进,时间戳越走越离谱。宁可整轨报错。
    if (healthChanged) notifyListeners();
  }

  bool _exceedsDisk(int additionalBytes) {
    final bool Function(int additionalBytes)? predicate = _wouldExceedDisk;
    if (predicate == null) return false;
    return predicate(additionalBytes);
  }

  /// 是否该重锚音频时钟。
  ///
  /// [UtteranceSegmenter] 的时间戳是 `sessionStart + 已处理采样数 / 采样率`,
  /// 它**从不**读墙钟。这在连续采集时是优点(不受 GC、调度抖动、NTP 校时
  /// 影响),但只要音频流出现空洞 —— 静音、静音自动停轨、重连、撤回同意后
  /// 再恢复 —— 它的时钟就少走了那一段,而墙钟照走。于是切分器的读数会
  /// **单调地、无上界地**落后于真实时间,产出的时间戳越来越偏早。
  ///
  /// 这为什么要紧:转写稿要把多个说话人的段按时间戳归并成一条对话。各人
  /// 静音的时长各不相同,漂移量也就各不相同,几分钟后 A 的话会排到 B 的
  /// 回答后面 —— 对话顺序整个错乱,而每一段自己看起来都好好的。
  ///
  /// 代价必须说清楚:重锚会**在空洞处把一段话切成两段**。这是有意的取舍 ——
  /// 空洞本身就意味着那里丢了音频,与其把断裂藏在一段连续的时间戳里,
  /// 不如让它显式地断开;而且能触发重锚的空洞已经超过一秒,那个位置几乎
  /// 不可能落在一个词的中间。
  bool _shouldReanchor(_IdentityRuntime st, UtteranceSegmenter seg) {
    final DateTime expected = st.sessionStart.add(seg.processedAudio);
    final Duration drift = now().difference(expected);
    if (drift <= clockDriftTolerance) return false;
    _log(
      '音频时钟落后墙钟 ${drift.inMilliseconds}ms,超过容忍量 '
      '${clockDriftTolerance.inMilliseconds}ms,重锚切分器',
    );
    return true;
  }

  UtteranceSegmenter _newSegmenter(String identity, _IdentityRuntime st) {
    final DateTime start = now();
    final UtteranceSegmenter seg = UtteranceSegmenter(
      speakerIdentity: identity,
      speakerName: st.displayName.isEmpty ? identity : st.displayName,
      sessionStart: start,
      config: vadConfig,
      detector: detector,
    );
    st.segmenter = seg;
    st.sessionStart = start;
    st.bufferedBytes = 0;
    return seg;
  }

  /// 收尾一个切分器,产出在途的段(若有)。返回是否真的产出了。
  bool _flushInto(UtteranceSegmenter seg) {
    final Utterance? tail = seg.flush();
    if (tail == null) return false;
    _emit(tail);
    return true;
  }

  bool _flushAllInternal() {
    bool emitted = false;
    for (final _IdentityRuntime st in _identities.values) {
      final UtteranceSegmenter? seg = st.segmenter;
      if (seg == null) continue;
      if (_flushInto(seg)) emitted = true;
    }
    return emitted;
  }

  void _emit(Utterance u) {
    _utterancesEmitted += 1;
    if (!_utterances.isClosed) _utterances.add(u);
  }

  void _log(String message) => onLog?.call(message);
}

// ─────────────────────────────────────────────────────────────────────────────
// 渲染器首帧看门狗
// ─────────────────────────────────────────────────────────────────────────────

/// 取消一次渲染器注册的句柄(即 SDK 的 `CancelListenFunc`)。
typedef RendererCancel = Future<void> Function();

/// 执行一次渲染器注册。
///
/// 返回本次注册拿到的取消句柄;注册本身失败(抛异常)时返回 null。
typedef RendererAttach = RendererCancel? Function(int attempt);

/// 首帧看门狗:用「等不到第一帧」反推「原生渲染器其实没起来」。
///
/// **为什么非要有它。** LiveKit 2.12.0 里渲染器启动失败是彻底静默的,
/// 三层都不报错:原生返回 false → `_AudioCaptureGroup._start` 只打一行
/// `logger.warning` 然后**在订阅帧流之前就 return** → `addAudioRenderer`
/// 早已同步返回,根本没人 await 那个 future。调用方拿到一个看起来正常的
/// 取消句柄,然后永远收不到一帧,没有异常、没有错误回调、没有布尔值。
///
/// **为什么必须先取消再重注册。** 失败的 group 会**留在**轨道的
/// `_captureGroups` 里,而这个 map 以 options 对象为键。于是拿同一份
/// (相等的)options 再 `addAudioRenderer` 一次,只会把新回调挂到那具尸体上,
/// 照样一帧都收不到 —— 重试变成了必然无效的空转。只有先调取消句柄,
/// 让 group 的 renderer 集合空掉,SDK 才会把它从 map 里摘掉并真正 stop,
/// 下一次注册才会新建一个活的 group。顺序在这里是**语义的一部分**。
class RendererWatchdog {
  RendererWatchdog({
    required this.identity,
    required this.attach,
    this.firstFrameTimeout = kDefaultFirstFrameTimeout,
    this.maxAttempts = kDefaultMaxRendererAttempts,
    this.retryBackoff = kDefaultRetryBackoff,
    this.onLog,
    this.onHealth,
  }) : assert(maxAttempts > 0, '至少要尝试一次');

  /// 这条轨属于谁,只用于日志与健康度回调。
  final String identity;

  final RendererAttach attach;

  /// 等首帧的时限。超时即判定这次注册是哑的。
  final Duration firstFrameTimeout;

  /// 最大尝试次数(含第一次)。
  final int maxAttempts;

  /// 重试退避基数,按尝试次数**线性**放大。
  ///
  /// 用线性而不是指数:渲染器失败的成因(设备被占用、轨刚重建还没就绪)
  /// 通常在一两秒内自愈,指数退避会在总次数很少时把最后一次推得过晚,
  /// 反而错过窗口。
  final Duration retryBackoff;

  final void Function(String message)? onLog;

  final void Function(RendererHealth health, int attempts)? onHealth;

  RendererHealth _health = RendererHealth.idle;
  int _attempts = 0;
  bool _sawFirstFrame = false;
  bool _disposed = false;
  bool _started = false;
  RendererCancel? _cancel;
  Timer? _timeoutTimer;
  Timer? _retryTimer;

  RendererHealth get health => _health;

  int get attempts => _attempts;

  /// 是否已经收到过第一帧。收到即证明这条链路真的通了。
  bool get sawFirstFrame => _sawFirstFrame;

  /// 执行第一次注册并武装超时。重复调用无效。
  void start() {
    if (_disposed || _started) return;
    _started = true;
    _attemptRegistration(1);
  }

  /// 由 onFrame 在**每一帧**上调用。
  ///
  /// 热路径,所以第一行就是一个 bool 短路 —— 首帧之后它的开销等于一次
  /// 字段读取。幂等:后续任意多次调用都不会再做任何事。
  void noteFrame() {
    if (_sawFirstFrame || _disposed) return;
    _sawFirstFrame = true;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _setHealth(RendererHealth.healthy);
    _log('$identity:已收到首帧,渲染器确认可用(第 $_attempts 次注册)');
  }

  /// 取消所有定时器,并注销仍然存活的渲染器。可安全重复调用。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    final RendererCancel? cancel = _cancel;
    _cancel = null;
    if (cancel != null) await _safeCancel(cancel);
  }

  // ───────────────────────────────────────────────────────────────────────────

  void _attemptRegistration(int attempt) {
    if (_disposed) return;
    _attempts = attempt;
    _setHealth(
      attempt == 1 ? RendererHealth.starting : RendererHealth.retrying,
    );

    RendererCancel? cancel;
    try {
      cancel = attach(attempt);
    } on Object catch (e) {
      // 注册本身抛异常也算一次失败的尝试,继续走重试阶梯而不是就地放弃:
      // 抛异常的成因(轨道正在重建)与静默失败一样常常是暂时的。
      cancel = null;
      _log('$identity:第 $attempt 次注册抛异常($e),按失败处理');
    }

    _cancel = cancel;
    if (cancel == null) {
      _scheduleRetry(attempt);
      return;
    }
    _timeoutTimer = Timer(firstFrameTimeout, () => _onTimeout(attempt));
  }

  void _onTimeout(int attempt) {
    if (_disposed || _sawFirstFrame) return;
    _timeoutTimer = null;
    _log(
      '$identity:第 $attempt 次注册在 ${firstFrameTimeout.inMilliseconds}ms 内'
      '没有任何音频帧,判定为静默失败',
    );
    final RendererCancel? cancel = _cancel;
    _cancel = null;
    if (cancel == null) {
      _scheduleRetry(attempt);
      return;
    }
    unawaited(_cancelThenRetry(cancel, attempt));
  }

  Future<void> _cancelThenRetry(RendererCancel cancel, int attempt) async {
    // 顺序是**语义的一部分**:必须先 await 取消句柄,让那具失败的
    // _AudioCaptureGroup 从轨道的 _captureGroups 里被摘掉。跳过这一步直接
    // 重注册,只会把新回调挂回同一具尸体上,重试保证无效。见类文档 TRAP 2。
    await _safeCancel(cancel);
    if (_disposed || _sawFirstFrame) return;
    _scheduleRetry(attempt);
  }

  void _scheduleRetry(int attempt) {
    if (_disposed || _sawFirstFrame) return;
    if (attempt >= maxAttempts) {
      _setHealth(RendererHealth.failed);
      _log('$identity:已尝试 $attempt 次仍无音频帧,放弃重试');
      return;
    }
    _setHealth(RendererHealth.retrying);
    _retryTimer = Timer(retryBackoff * attempt, () {
      _retryTimer = null;
      _attemptRegistration(attempt + 1);
    });
  }

  Future<void> _safeCancel(RendererCancel cancel) async {
    try {
      await cancel();
    } on Object catch (e) {
      // 取消失败不该阻断重试阶梯:即使 SDK 侧清理不干净,继续往下走
      // 也比就此卡死强。
      _log('$identity:取消渲染器时抛异常($e),继续');
    }
  }

  /// 上一次已经上报过的 (健康度, 尝试次数) 组合。
  ///
  /// 光比健康度是不够的:第 2、3 次重试之间健康度都停在 [RendererHealth.retrying],
  /// 但尝试次数在涨,UI 要显示「第几次」就必须收到这次变化。
  RendererHealth? _reportedHealth;
  int _reportedAttempts = -1;

  void _setHealth(RendererHealth health) {
    _health = health;
    if (_reportedHealth == health && _reportedAttempts == _attempts) return;
    _reportedHealth = health;
    _reportedAttempts = _attempts;
    onHealth?.call(health, _attempts);
  }

  void _log(String message) => onLog?.call(message);
}
