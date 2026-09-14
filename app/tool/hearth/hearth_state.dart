import 'dart:math' as math;
import 'dart:ui' show Color, Offset;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'hearth_tokens.dart';

/// 轻状态,对应主 app 的 MemberStatus。
enum HearthStatus {
  free('随时聊', HearthColors.statusFree),
  busy('在忙', HearthColors.statusBusy),
  ears('耳朵在', HearthColors.statusEars),
  away('有事先走', HearthColors.statusAway);

  const HearthStatus(this.label, this.color);
  final String label;
  final Color color;
}

/// 活跃档位 —— 驱动整个原型的降频策略。
enum ActivityLevel {
  active('活跃', 0),
  calm('静息', 80),
  deepIdle('沉睡', 160);

  const ActivityLevel(this.label, this.minFrameGapMs);
  final String label;

  /// 两次重绘之间至少间隔多少毫秒。0 = 不节流(跟随 vsync)。
  final int minFrameGapMs;
}

/// 房间里的一个人。
///
/// 注意主 app 的 Member 是不可变的;原型这里用可变字段,
/// 因为 speech 包络每帧都在变,不可变对象会导致每帧分配。
class HearthMember {
  HearthMember({
    required this.id,
    required this.name,
    required this.seat,
    this.status = HearthStatus.free,
  });

  final String id;
  final String name;

  /// 座位序:入房时分配,**说话不改变**。长期挂机的界面靠位置恒定建立熟悉感。
  final int seat;

  HearthStatus status;

  /// 是否在 activeSpeakers 集合里(离散信号)。
  ///
  /// 主 app 的 RTC 层只给出 `Set<String> speakingIdentities`,**没有音量幅度**。
  bool speaking = false;

  /// 合成的说话包络 0..1。
  ///
  /// 因为上游没有音量,这里自行合成:开口后 ~180ms 升到 1,
  /// 停口后按 ~900ms 时间常数衰减。视觉上比布尔跳变自然得多。
  double speech = 0;

  /// 最后一次说话时刻(HearthClock.nowMs)。主 app 目前**没有**这个字段,
  /// 「久未出声者退入阴影」依赖它,合入时需要在 RoomController 里补。
  int lastSpokeMs = 0;

  /// 该成员座位相对火焰中心的单位方向,由 B 层布局回写。
  /// A 层靠它决定光团朝谁偏。
  Offset seatDirection = Offset.zero;

  /// 静默时长(秒)。
  double silentSeconds(int nowMs) => (nowMs - lastSpokeMs) / 1000.0;
}

/// 三层共用的心跳。**这是本原型的性能核心。**
///
/// ## 为什么不是简单的 AnimationController.repeat()
///
/// 这是一个用户可能盯着看十几个小时的界面。全程 60fps 重绘一团光晕,
/// 在笔记本上意味着风扇长期空转。所以时钟分三档节流。
///
/// ## 节流到底省了什么(必须诚实说明)
///
/// Ticker 在跑的时候,引擎**仍然**每个 vsync 回调一次 —— 这部分开销省不掉,
/// 但它非常便宜(一次回调 + 几次比较)。节流跳过的是
/// `notifyListeners -> markNeedsPaint -> paint -> raster` 这一整条,
/// 这才是真正花钱的部分(CustomPainter 里画 4 层渐变 Path)。
///
/// 想要**真正的零**,只有停掉 ticker。`freezeWhenDeepIdle` 就是干这个的:
/// 进入 deepIdle 后直接 `_ticker.stop()`,画面定格在最后一帧,
/// Flutter 不再申请 vsync,进程回到真正的空闲。代价是光团不再呼吸。
/// 原型里把它做成开关,是为了能实测出「零开销地板」这个对照数字。
class HearthClock extends ChangeNotifier {
  HearthClock({required TickerProvider vsync}) {
    _ticker = vsync.createTicker(_onTick)..start();
  }

  late final Ticker _ticker;

  /// 静息多久进入 calm 档。
  static const int calmAfterMs = 3000;

  /// 静息多久进入 deepIdle 档。
  static const int deepIdleAfterMs = 90000;

  int _nowMs = 0;
  int _lastEmitMs = -1000;
  int _lastActivityMs = 0;
  int _lastEnvelopeMs = 0;
  bool _frozen = false;

  /// 单调毫秒。
  int get nowMs => _nowMs;

  /// 秒(double),给三角函数用。
  double get t => _nowMs / 1000.0;

  /// 外部强制保持 active(例如粒子还活着、有人在说话)。
  /// 每帧由 HearthState 重新设置。
  bool holdActive = false;

  /// 进入 deepIdle 后是否彻底停表(对照组开关)。
  bool freezeWhenDeepIdle = false;

  /// 本帧的 dt(秒),供包络/粒子推进使用。
  double _dt = 0;
  double get dt => _dt;

  /// 统计:实际放行(重绘)了多少帧。
  int emittedFrames = 0;

  /// 统计:ticker 回调了多少次。两者之比即节流效率。
  int tickedFrames = 0;

  int get idleMs => _nowMs - _lastActivityMs;

  ActivityLevel get level {
    if (holdActive || idleMs < calmAfterMs) return ActivityLevel.active;
    if (idleMs < deepIdleAfterMs) return ActivityLevel.calm;
    return ActivityLevel.deepIdle;
  }

  /// 距离进入下一档还剩多少毫秒;已在最低档返回 null。
  int? get msToNextLevel => switch (level) {
        ActivityLevel.active => holdActive ? null : calmAfterMs - idleMs,
        ActivityLevel.calm => deepIdleAfterMs - idleMs,
        ActivityLevel.deepIdle => null,
      };

  bool get isFrozen => _frozen;

  /// 呼吸周期(秒)。沉睡档拉长,像睡着了一样。
  double get breathPeriod =>
      level == ActivityLevel.deepIdle ? 6.5 : 4.5;

  /// 有事件发生:回到 active 并重置闲时计时。
  void requestFullRate() {
    _lastActivityMs = _nowMs;
    if (_frozen) {
      _frozen = false;
      _lastEnvelopeMs = _nowMs;
      _ticker.start();
    }
  }

  /// 每帧回调,在 notifyListeners 之前执行(推进包络、粒子)。
  void Function(double dtSec)? onAdvance;

  void _onTick(Duration elapsed) {
    tickedFrames++;
    _nowMs = elapsed.inMilliseconds;

    // dt 用「上次推进模拟」到现在的间隔,而不是 vsync 间隔 ——
    // 节流时两者差很多,用错会让粒子/包络在低帧档变慢。
    _dt = ((_nowMs - _lastEnvelopeMs) / 1000.0).clamp(0.0, 0.1);

    final gap = level.minFrameGapMs;
    if (gap > 0 && _nowMs - _lastEmitMs < gap) return;

    _lastEmitMs = _nowMs;
    _lastEnvelopeMs = _nowMs;
    emittedFrames++;

    onAdvance?.call(_dt);
    notifyListeners();

    // 停表必须发生在这一帧画完之后,所以放在末尾。
    if (freezeWhenDeepIdle && level == ActivityLevel.deepIdle && !_frozen) {
      _frozen = true;
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

/// 一次火星迸发的请求,由 HearthState 发给 D 层。
class SparkRequest {
  SparkRequest(this.origin, this.kind, this.count);
  final Offset origin; // 逻辑坐标:相对画布的绝对位置
  final SparkKind kind;
  final int count;
}

enum SparkKind { join, message, leave }

/// 整个场景的状态源。
class HearthState extends ChangeNotifier {
  HearthState({required this.clock}) {
    clock.onAdvance = _advance;
    setMemberCount(5);
  }

  final HearthClock clock;
  final math.Random _rng = math.Random(7);

  final List<HearthMember> _members = <HearthMember>[];
  List<HearthMember> get members => List.unmodifiable(_members);

  int _seatCounter = 0;

  /// 待消费的火星迸发请求。D 层每帧取走并清空。
  final List<SparkRequest> pendingSparks = <SparkRequest>[];

  /// 火焰中心的画布坐标,由场景在 layout 后写入。
  Offset flameCenter = Offset.zero;

  /// D 层挂上来的存活粒子数探针。粒子还在烧的时候必须保持满帧,
  /// 否则会看到火星一卡一卡地飘。
  int Function()? sparksAliveProbe;

  Offset _pull = Offset.zero;
  Offset _pullTarget = Offset.zero;

  /// 归一化的「灵」朝向,长度 0..1。多人同时说话会互相抵消 —— 这是对的:
  /// 大家一起说的时候,光就该回到中间,只是更亮。
  Offset get spiritPull => _pull;

  double _arousal = 0;

  /// 整体唤醒度 0..1,驱动 A 层亮度。
  double get arousal => _arousal;

  /// 演示用的名字池。
  static const List<String> _names = <String>[
    '阿岚', '小野', '恒子', '青禾', '柏舟', '沈鹤', '明远', '知夏',
    '林隅', '苏叶', '南舟', '陆迟', '温言', '澄澈', '沈砚', '白露',
    '疏桐', '清和', '砚舟', '子期', '望舒', '停云', '书禾', '长庚',
    '昭昭', '云栖', '之涣', '简宁',
  ];

  static const List<HearthStatus> _statusCycle = <HearthStatus>[
    HearthStatus.free,
    HearthStatus.free,
    HearthStatus.ears,
    HearthStatus.free,
    HearthStatus.busy,
    HearthStatus.ears,
    HearthStatus.free,
    HearthStatus.away,
  ];

  void setMemberCount(int n) {
    n = n.clamp(0, _names.length);
    while (_members.length > n) {
      _members.removeLast();
    }
    while (_members.length < n) {
      final i = _members.length;
      final m = HearthMember(
        id: 'u$i',
        name: _names[i % _names.length],
        seat: _seatCounter++,
        status: _statusCycle[i % _statusCycle.length],
      );
      // 给一点参差的静默历史,这样「退入阴影」在首屏就看得见。
      m.lastSpokeMs = clock.nowMs - _rng.nextInt(14 * 60 * 1000);
      _members.add(m);
    }
    clock.requestFullRate();
    notifyListeners();
  }

  HearthMember? byId(String id) {
    for (final m in _members) {
      if (m.id == id) return m;
    }
    return null;
  }

  void toggleSpeaking(String id) {
    final m = byId(id);
    if (m == null) return;
    m.speaking = !m.speaking;
    if (m.speaking) m.lastSpokeMs = clock.nowMs;
    clock.requestFullRate();
    notifyListeners();
  }

  void setSpeaking(String id, bool value) {
    final m = byId(id);
    if (m == null || m.speaking == value) return;
    m.speaking = value;
    if (value) m.lastSpokeMs = clock.nowMs;
    clock.requestFullRate();
    notifyListeners();
  }

  void silenceAll() {
    for (final m in _members) {
      m.speaking = false;
    }
    clock.requestFullRate();
    notifyListeners();
  }

  /// B 层布局算完后回写每个座位的方向(单位向量,火焰中心指向座位)。
  void setSeatDirections(Map<String, Offset> dirs) {
    var changed = false;
    for (final m in _members) {
      final d = dirs[m.id];
      if (d != null && d != m.seatDirection) {
        m.seatDirection = d;
        changed = true;
      }
    }
    if (changed) _recomputePullTarget();
  }

  // ── 事件:触发 D 层 ──

  void memberJoins() {
    if (_members.length >= _names.length) return;
    setMemberCount(_members.length + 1);
    pendingSparks.add(SparkRequest(flameCenter, SparkKind.join, 28));
    clock.requestFullRate();
    notifyListeners();
  }

  void memberLeaves([String? id]) {
    if (_members.isEmpty) return;
    final m = id == null ? _members.last : byId(id);
    if (m == null) return;
    final origin = flameCenter + m.seatDirection * 180;
    pendingSparks.add(SparkRequest(origin, SparkKind.leave, 18));
    _members.remove(m);
    clock.requestFullRate();
    notifyListeners();
  }

  void sendMessage(String id) {
    final m = byId(id);
    if (m == null) return;
    // 起点在座位与火焰之间靠座位一侧,粒子会朝火飘 —— 「消息投进火里」。
    final origin = flameCenter + m.seatDirection * 150;
    pendingSparks.add(SparkRequest(origin, SparkKind.message, 14));
    clock.requestFullRate();
    notifyListeners();
  }

  void sendRandomMessage() {
    if (_members.isEmpty) return;
    sendMessage(_members[_rng.nextInt(_members.length)].id);
  }

  // ── 随机对话模拟 ──

  bool _autoChatter = false;
  bool get autoChatter => _autoChatter;
  double _nextChatterIn = 0;

  set autoChatter(bool v) {
    _autoChatter = v;
    _nextChatterIn = 0.6;
    if (!v) silenceAll();
    clock.requestFullRate();
    notifyListeners();
  }

  // ── 每帧推进 ──

  /// 由 HearthClock 每次放行时调用。
  void _advance(double dt) {
    if (dt <= 0) return;

    if (_autoChatter) {
      _nextChatterIn -= dt;
      if (_nextChatterIn <= 0) {
        _nextChatterIn = 1.5 + _rng.nextDouble() * 2.5;
        if (_members.isNotEmpty) {
          // 大部分时间只有一个人说,偶尔两个人重叠。
          for (final m in _members) {
            m.speaking = false;
          }
          _members[_rng.nextInt(_members.length)].speaking = true;
          if (_rng.nextDouble() < 0.22 && _members.length > 1) {
            _members[_rng.nextInt(_members.length)].speaking = true;
          }
        }
      }
    }

    // 说话包络:开口 180ms 升满,停口 900ms 时间常数衰减。
    const attackPerSec = 1 / 0.18;
    final decay = math.exp(-dt / 0.9);
    var maxSpeech = 0.0;
    var anySpeaking = false;

    for (final m in _members) {
      if (m.speaking) {
        anySpeaking = true;
        m.lastSpokeMs = clock.nowMs;
        m.speech = math.min(1.0, m.speech + attackPerSec * dt);
      } else {
        m.speech *= decay;
        if (m.speech < 0.003) m.speech = 0;
      }
      if (m.speech > maxSpeech) maxSpeech = m.speech;
    }

    _arousal = maxSpeech;
    _recomputePullTarget();

    // 弹簧式平滑:光团转向要有惯性,不能瞬移。时间常数 ~450ms。
    final k = 1 - math.exp(-dt / 0.45);
    _pull = Offset(
      _pull.dx + (_pullTarget.dx - _pull.dx) * k,
      _pull.dy + (_pullTarget.dy - _pull.dy) * k,
    );

    // 只要还有余温(包络未归零)或火星未熄,就保持满帧,否则会看到降频的台阶。
    final sparksAlive = sparksAliveProbe?.call() ?? 0;
    clock.holdActive = anySpeaking ||
        maxSpeech > 0.01 ||
        _pull.distance > 0.01 ||
        sparksAlive > 0;
  }

  void _recomputePullTarget() {
    var x = 0.0, y = 0.0;
    for (final m in _members) {
      if (m.speech <= 0) continue;
      x += m.seatDirection.dx * m.speech;
      y += m.seatDirection.dy * m.speech;
    }
    final v = Offset(x, y);
    final len = v.distance;
    _pullTarget = len > 1 ? v / len : v;
  }
}
