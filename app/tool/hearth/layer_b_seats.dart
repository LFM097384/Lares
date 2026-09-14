/// Layer B —— 围炉而坐(SPEC §6)。
///
/// 这一层的职责只有两件:
/// 1. 把 n 个人**稳定地**排在火焰周围的同心环上;
/// 2. 在「静息时真的不花钱」的前提下,让状态变化看起来是流动的。
///
/// ## 为什么 B 层是性能的重点
///
/// A 层(光)和 D 层(火星)是 `CustomPainter`,靠 `HearthClock` 逐帧重绘 ——
/// 它们的成本由时钟的三档节流兜底。B 层不一样:它是**真的 Widget 树**,
/// 20 个头像意味着 20 棵子树。如果每个头像都订阅时钟逐帧 rebuild,
/// 或者各自养一个 `AnimationController`,那么「静息零开销」这个目标
/// 会在 B 层这里彻底破产 —— 20 个 Ticker 会把 vsync 回调钉死在满帧,
/// 时钟节流省下来的钱全部又赔进去。
///
/// 所以 B 层的纪律是(SPEC §6.4):
/// * 只用**隐式动画**(`AnimatedPositioned` / `AnimatedOpacity` / `AnimatedScale`)。
///   隐式动画的 Ticker 只在过渡期间存在,过渡结束自动停 —— 稳态是真正的 0。
/// * 头像**不订阅时钟做逐帧重绘**。[SeatRing] 确实挂在时钟上,但它在回调里
///   只做一次 O(n) 的整数比较(见 [_OrbSignature]),**只有量化后的状态真的
///   跨档了才 setState**。静息时这个回调每秒跑 6~12 次,什么都不做。
/// * 每个头像外包 `RepaintBoundary`。
/// * 说话者的「光感」由 A 层和状态环颜色负责,头像自己**不做**呼吸动画。
///
/// ## 相对 SPEC 的三处澄清(必须读)
///
/// SPEC §6.1 的环算法是「已定」的,下面**没有改动任何一个系数**,
/// 但有三处必须明确的解释,否则算法在 1280x720 的桌面画布上自相矛盾。
///
/// ### 澄清 1:`base` 取的是「座位区」,不是整块画布
///
/// SPEC 写的是 `base = min(s.width, s.height)`,其中 `s` 是「可用区域」。
/// 如果把 `s` 直接当成整块画布,在 1280x720 上 `base = 720`,于是
/// `R3 = 414`,而画布半高只有 360 —— 第三环在**还没算头像半径和名字**
/// 之前就已经出界 54px 了。R2 = 317 虽然圆能塞下,名字也会被切掉。
///
/// 所以这里把 `s` 理解为**环心可以落在的区域**:整块画布四周内缩一个
/// 「头像半径 + 名字高度 + 边距」。头像有物理尺寸、名字挂在下面,
/// 环心区域本来就该比画布小。系数一个没动,只是把 `s` 的含义钉死。
///
/// 这个理解还顺带修好了 SPEC 自己的验收标准冲突:按整画布读,n=20 时
/// `d` 收缩到 52,`cap(R1) = 21 >= 20`,于是 20 人排成**单环** ——
/// 直接违反 §8.4「20 人截图:双环排列合理」。按座位区读,`cap(R1) = 15`,
/// 20 人自然分成 8 + 12 双环,正是验收标准要的样子。
///
/// ### 澄清 2:最外环兜底缩放
///
/// `R3 = base * 0.575 > base / 2`,即三环布局的最外环**恒定**超出座位区。
/// 这里加一道兜底:选定环数后,若最外环半径超过 `base / 2`,
/// 把**所有**环半径乘同一个系数缩回去。乘同一个系数意味着
/// 0.30 / 0.44 / 0.575 的比例关系原样保留,只是整体收紧。
/// 单环、双环时 `0.44 < 0.5`,这道兜底不会触发;它只在三环时起作用。
///
/// ### 澄清 3:溢出芯片在桌面尺寸下够不到,靠「紧凑模式」演示
///
/// 名册上限 28 人(`HearthState._names`)。要让 `n > cap1+cap2+cap3`,
/// 代入 d=52 需要 `base < 215px` —— 桌面窗口不可能这么小。
/// 也就是说 §6.1 的「+N 聚合芯片」分支在真实窗口下**永远走不到**,
/// 而 SPEC §7 又明确要求用 28 人验证它。
///
/// 解法是不动算法、加一个演示开关:[SeatLayout.compute] 接受 `maxRings`
/// (默认 3 = SPEC 原义)。控制面板的「紧凑」开关把它压到 1,
/// 于是容量变成 `cap(R1)`,28 人真的溢出,芯片走的是**同一段代码**、
/// 同一套数字,可以被截图验收。这是演示脚手架,不是算法改动。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'hearth_state.dart';
import 'hearth_tokens.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 调参常量(SPEC §2 要求集中在文件顶部,方便产品负责人改)
// ─────────────────────────────────────────────────────────────────────────────

/// B 层的全部可调数值。改这里,不要去正文里找魔数。
abstract final class SeatTuning {
  // ── 环算法(SPEC §6.1,系数已定,不要改)──

  /// 头像基准直径(n=2 时)。
  static const double diameterAtTwo = 96.0;

  /// 每多一个人,直径缩小多少。
  static const double diameterShrinkPerMember = 2.6;

  /// 直径下限。44px 是触摸目标下限,取 52 留余量。
  static const double diameterMin = 52.0;

  /// 三环半径相对 `base` 的比例。
  static const List<double> ringRatios = <double>[0.30, 0.44, 0.575];

  /// 相邻头像间隙系数:环上每个座位占 `d * 1.22` 的弧长。
  static const double gapFactor = 1.22;

  /// 双环时内环占比(内环刻意稀一点,视觉上不挤火)。
  static const double twoRingInnerShare = 0.38;

  /// 三环时的分配比例。
  static const List<double> threeRingShares = <double>[0.22, 0.34, 0.44];

  // ── 座位区内缩(见文件头「澄清 1」)──

  /// 名字 + 状态两行文字的高度。
  static const double labelHeight = 40.0;

  /// 座位区上下额外留白。
  static const double marginVertical = 28.0;

  /// 座位区左右额外留白。桌面是宽屏,横向不紧张。
  static const double marginHorizontal = 24.0;

  // ── 状态表现(SPEC §6.3)──

  /// 说话者的径向内移幅度:半径乘 `1 - inwardPull * speech`。
  static const double inwardPull = 0.10;

  /// 静默 >2min 的外退。
  static const double silentNearPush = 1.02;

  /// 静默 >10min 的外退。
  static const double silentFarPush = 1.04;

  /// 静默「略退」的门槛(秒)。
  static const double silentNearSeconds = 120;

  /// 静默「退入阴影」的门槛(秒)。
  static const double silentFarSeconds = 600;

  static const double opacitySpeaking = 1.00;
  static const double opacityPresent = 0.88;
  static const double opacitySilentNear = 0.55;

  /// **硬下限,不得更低**(SPEC §6.3)。再淡就是「消失」,
  /// 而这个产品的前提是「人一直在」。
  static const double opacitySilentFar = 0.34;

  /// 说话时的轻微放大。
  static const double speakingScale = 1.06;

  // ── 过渡时长 ──

  /// 人数变化导致的重新排位(SPEC §6.2 指定)。
  static const Duration relayoutDuration = Duration(milliseconds: 400);

  /// 说话包络导致的径向微移。比 400ms 短,否则 180ms 的 onset 会拖沓。
  static const Duration speechDuration = Duration(milliseconds: 220);

  /// 透明度 / 缩放过渡。
  static const Duration fadeDuration = Duration(milliseconds: 320);

  /// 说话包络的量化档数。见 [_OrbSignature]:包络是逐帧连续量,
  /// 直接喂给隐式动画等于逐帧 rebuild;量化成 8 档后,一次 onset
  /// 最多触发 8 次重定向,静息时是 0 次。
  static const int speechQuantSteps = 8;
}

// ─────────────────────────────────────────────────────────────────────────────
// 布局:纯数据,可单测,不碰 Widget
// ─────────────────────────────────────────────────────────────────────────────

/// 一个座位。全部是画布绝对坐标(与 [HearthState.flameCenter] 同一坐标系)。
@immutable
class SeatPlacement {
  const SeatPlacement({
    required this.memberId,
    required this.ring,
    required this.angle,
    required this.baseCenter,
    required this.direction,
    required this.baseRadius,
  });

  /// 成员 id。溢出芯片的座位用 [SeatLayout.overflowSeatId]。
  final String memberId;

  /// 所在环(0 = 最内)。
  final int ring;

  /// 极角(弧度)。**说话不会改变它** —— 这是 SPEC §6.2 的稳定性契约。
  final double angle;

  /// 静息时的座位中心(画布绝对坐标)。
  final Offset baseCenter;

  /// 火焰中心指向座位的**单位**向量。回写给 [HearthState.setSeatDirections],
  /// A 层靠它决定光团朝谁偏。
  final Offset direction;

  /// 静息半径 R。说话时实际半径 = `R * (1 - 0.10 * speech)`。
  final double baseRadius;

  /// 按给定半径缩放后的中心点。角度恒定,只动半径。
  Offset centerAtRadius(Offset flameCenter, double radius) =>
      flameCenter + direction * radius;
}

/// 一次布局的完整结果。
@immutable
class SeatLayout {
  const SeatLayout({
    required this.seats,
    required this.diameter,
    required this.base,
    required this.ringCount,
    required this.radii,
    required this.ringCaps,
    required this.ringCounts,
    required this.capacity,
    required this.overflowCount,
    required this.flameCenter,
  });

  /// 溢出芯片占用的那个座位的 id。
  static const String overflowSeatId = '__overflow__';

  /// 全部座位,按 seat 序。若 [overflowCount] > 0,**最后一个**座位的
  /// `memberId` 是 [overflowSeatId]。
  final List<SeatPlacement> seats;

  /// 本次布局的头像直径。
  final double diameter;

  /// 座位区短边(见文件头「澄清 1」)。
  final double base;

  /// 实际用了几个环。
  final int ringCount;

  /// 各环半径(已过「澄清 2」的兜底缩放)。长度 == [ringCount]。
  final List<double> radii;

  /// 各环容量 `cap(R) = max(3, floor(2πR / (d * 1.22)))`。长度 == 可用环数。
  final List<int> ringCaps;

  /// 各环实际放了几个。长度 == [ringCount]。
  final List<int> ringCounts;

  /// 可用环的总容量。`n > capacity` 时触发溢出。
  final int capacity;

  /// 被折叠进「+N」芯片的人数;0 表示没有溢出。
  final int overflowCount;

  final Offset flameCenter;

  bool get hasOverflow => overflowCount > 0;

  /// 每个成员 id → 单位方向向量,喂给 [HearthState.setSeatDirections]。
  Map<String, Offset> directionMap() {
    final Map<String, Offset> out = <String, Offset>{};
    for (final SeatPlacement s in seats) {
      if (s.memberId == overflowSeatId) continue;
      out[s.memberId] = s.direction;
    }
    return out;
  }

  /// 头像方块的宽(比直径宽一点,给名字留位置)。
  double get orbBoxWidth => diameter + 32;

  /// 头像方块的高 = 圆 + 两行文字。
  double get orbBoxHeight => diameter + SeatTuning.labelHeight;

  // ── 几何缓存 ──
  //
  // SPEC §6.4 要求「只在 (n, size) 变化时重算」。这里把**几何**(角度、半径、
  // 环容量)和**成员绑定**(哪个 id 坐哪个座)拆开:几何是贵的部分,缓存它;
  // 绑定是一次 O(n) 的赋值,每次重算无所谓,而且成员集合本来就可能在 n
  // 不变的情况下改变(先走一个再进一个)。
  static _RingGeometry? _cachedGeometry;
  static _GeometryKey? _cachedKey;

  /// 计算一次布局。
  ///
  /// [members] 会按 [HearthMember.seat] 升序使用 —— 座位序入房时分配,
  /// 说话永不重排(SPEC §6.2)。
  ///
  /// [size] 是**整块画布**;内缩成座位区的事在内部做。
  ///
  /// [maxRings] 默认 3(SPEC 原义)。演示用的「紧凑」开关把它压到 1,
  /// 好让溢出芯片在桌面尺寸下也能被截图 —— 见文件头「澄清 3」。
  static SeatLayout compute({
    required List<HearthMember> members,
    required Size size,
    required Offset flameCenter,
    int maxRings = 3,
  }) {
    final List<HearthMember> ordered = List<HearthMember>.of(members)
      ..sort((HearthMember a, HearthMember b) => a.seat.compareTo(b.seat));
    final int n = ordered.length;

    final _GeometryKey key = _GeometryKey(n, size, maxRings);
    if (_cachedKey != key) {
      _cachedKey = key;
      _cachedGeometry = _RingGeometry.compute(n, size, maxRings);
    }
    final _RingGeometry g = _cachedGeometry!;

    // 绑定成员到座位。溢出时:前 slots-1 个正常显示,最后一格换成芯片。
    final int overflow = n > g.capacity ? n - (g.capacity - 1) : 0;
    final int shown = overflow > 0 ? g.capacity - 1 : n;

    final List<SeatPlacement> seats = <SeatPlacement>[];
    for (int i = 0; i < g.slots.length; i++) {
      final _Slot slot = g.slots[i];
      final bool isChip = overflow > 0 && i == g.slots.length - 1;
      if (!isChip && i >= shown) break;
      seats.add(
        SeatPlacement(
          memberId: isChip ? overflowSeatId : ordered[i].id,
          ring: slot.ring,
          angle: slot.angle,
          baseCenter: flameCenter + slot.direction * slot.radius,
          direction: slot.direction,
          baseRadius: slot.radius,
        ),
      );
    }

    return SeatLayout(
      seats: seats,
      diameter: g.diameter,
      base: g.base,
      ringCount: g.ringCount,
      radii: g.radii,
      ringCaps: g.caps,
      ringCounts: g.ringCounts,
      capacity: g.capacity,
      overflowCount: overflow,
      flameCenter: flameCenter,
    );
  }

  /// 测试 / 报告用:只要容量数字,不建座位。
  static List<int> capsFor({required int n, required Size size}) =>
      _RingGeometry.compute(n, size, 3).caps;

  /// 清掉几何缓存(热重载 / 测试用)。
  static void debugClearCache() {
    _cachedKey = null;
    _cachedGeometry = null;
  }
}

@immutable
class _GeometryKey {
  const _GeometryKey(this.n, this.size, this.maxRings);
  final int n;
  final Size size;
  final int maxRings;

  @override
  bool operator ==(Object other) =>
      other is _GeometryKey &&
      other.n == n &&
      other.size == size &&
      other.maxRings == maxRings;

  @override
  int get hashCode => Object.hash(n, size, maxRings);
}

@immutable
class _Slot {
  const _Slot(this.ring, this.angle, this.radius, this.direction);
  final int ring;
  final double angle;
  final double radius;
  final Offset direction;
}

/// 纯几何:不认识成员,只认识「n 个位置」。
class _RingGeometry {
  _RingGeometry({
    required this.slots,
    required this.diameter,
    required this.base,
    required this.ringCount,
    required this.radii,
    required this.caps,
    required this.ringCounts,
    required this.capacity,
  });

  final List<_Slot> slots;
  final double diameter;
  final double base;
  final int ringCount;
  final List<double> radii;
  final List<int> caps;
  final List<int> ringCounts;
  final int capacity;

  static _RingGeometry compute(int n, Size size, int maxRings) {
    // ── d:头像直径随人数收缩,52px 触摸下限 ──
    final double d = (SeatTuning.diameterAtTwo -
            (n - 2) * SeatTuning.diameterShrinkPerMember)
        .clamp(SeatTuning.diameterMin, SeatTuning.diameterAtTwo)
        .toDouble();

    // ── base:座位区短边。见文件头「澄清 1」——
    // 内缩「头像半径 + 名字高 + 边距」,因为环心区不等于画布区。
    final double padV =
        d / 2 + SeatTuning.labelHeight + SeatTuning.marginVertical;
    final double padH = d / 2 + SeatTuning.marginHorizontal;
    final double regionW = math.max(size.width - 2 * padH, 0);
    final double regionH = math.max(size.height - 2 * padV, 0);
    final double base = math.min(regionW, regionH);

    final List<double> allRadii = <double>[
      for (final double r in SeatTuning.ringRatios) base * r,
    ];
    // cap(R) = max(3, floor(2πR / (d * 1.22)))
    final List<int> allCaps = <double>[...allRadii]
        .map(
          (double r) => math.max(
            3,
            (2 * math.pi * r / (d * SeatTuning.gapFactor)).floor(),
          ),
        )
        .toList(growable: false);

    final int usableRings = maxRings.clamp(1, 3);
    final List<int> caps = allCaps.sublist(0, usableRings);

    // ── 选环数 ──
    int ringCount = usableRings;
    int running = 0;
    for (int i = 0; i < usableRings; i++) {
      running += caps[i];
      if (n <= running) {
        ringCount = i + 1;
        break;
      }
    }
    if (n == 0) ringCount = 1;

    final int capacity = caps.take(usableRings).fold(0, (int a, int b) => a + b);

    // ── 「澄清 2」:最外环兜底缩放,整体等比缩回座位区 ──
    List<double> radii = allRadii.sublist(0, ringCount);
    final double limit = base / 2;
    if (radii.isNotEmpty && radii.last > limit && radii.last > 0) {
      final double f = limit / radii.last;
      radii = radii.map((double r) => r * f).toList(growable: false);
    }

    // 溢出时要摆满 capacity 个格子(最后一格给芯片),否则摆 n 个。
    final int slotCount = n > capacity ? capacity : n;
    final List<int> perRing = _distribute(slotCount, ringCount, caps);

    // ── 生成座位 ──
    // 环 i 的起始角错开 `i * π / ringCount`,避免内外环径向对齐显得死板。
    final List<_Slot> slots = <_Slot>[];
    for (int ring = 0; ring < ringCount; ring++) {
      final int m = perRing[ring];
      if (m <= 0) continue;
      final double start = -math.pi / 2 + ring * math.pi / ringCount;
      final double step = 2 * math.pi / m;
      for (int k = 0; k < m; k++) {
        final double a = start + k * step;
        slots.add(
          _Slot(ring, a, radii[ring], Offset(math.cos(a), math.sin(a))),
        );
      }
    }

    return _RingGeometry(
      slots: slots,
      diameter: d,
      base: base,
      ringCount: ringCount,
      radii: radii,
      caps: allCaps,
      ringCounts: perRing,
      capacity: capacity,
    );
  }

  /// 按 SPEC §6.1 的比例分配到各环,并保证不超过每环容量。
  /// 超出的往外环推(外环周长更长,挤外环比挤内环更不显眼,
  /// 而且内环挤会把火压住 —— 这正是 0.38 这个偏小的内环占比想避免的)。
  static List<int> _distribute(int n, int ringCount, List<int> caps) {
    if (n <= 0) return List<int>.filled(ringCount, 0);
    if (ringCount == 1) return <int>[math.min(n, caps[0])];

    List<int> want;
    if (ringCount == 2) {
      final int inner = (n * SeatTuning.twoRingInnerShare).ceil();
      want = <int>[inner, n - inner];
    } else {
      final int a = (n * SeatTuning.threeRingShares[0]).round();
      final int b = (n * SeatTuning.threeRingShares[1]).round();
      want = <int>[a, b, n - a - b];
    }

    // 从内往外做一次溢出传递,再从外往内补一次欠额。
    for (int i = 0; i < ringCount - 1; i++) {
      if (want[i] > caps[i]) {
        want[i + 1] += want[i] - caps[i];
        want[i] = caps[i];
      }
    }
    for (int i = ringCount - 1; i > 0; i--) {
      if (want[i] > caps[i]) {
        want[i - 1] += want[i] - caps[i];
        want[i] = caps[i];
      }
    }
    for (int i = 0; i < ringCount; i++) {
      if (want[i] < 0) want[i] = 0;
      if (want[i] > caps[i]) want[i] = caps[i];
    }
    return want;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 视觉状态:量化后的「档」,这是 B 层不逐帧 rebuild 的关键
// ─────────────────────────────────────────────────────────────────────────────

/// 静默程度。
enum _Dim { present, near, far }

/// 一个头像的**量化**视觉状态。
///
/// `speech` 是逐帧变化的连续量(0..1 的合成包络)。如果直接把它喂给
/// `AnimatedPositioned` 的 `top/left`,那么时钟每放行一帧就要重建一次
/// 整个头像子树 —— 隐式动画「稳态零开销」的好处就没了。
///
/// 所以把它量化成 [SeatTuning.speechQuantSteps] 档。一次 180ms 的 onset
/// 最多让这个签名跨档 8 次,每次跨档触发一次隐式动画重定向,过渡本身
/// 由 Flutter 的动画机制平滑完成 —— 观感上仍然是连续内移,但 rebuild
/// 次数从「每帧一次」降到「整个 onset 8 次」。**静息时是 0 次。**
@immutable
class _OrbSignature {
  const _OrbSignature(this.speechStep, this.dim, this.speaking, this.status);

  final int speechStep;
  final _Dim dim;
  final bool speaking;
  final HearthStatus status;

  factory _OrbSignature.of(HearthMember m, int nowMs) {
    final double silent = m.silentSeconds(nowMs);
    final _Dim dim = silent > SeatTuning.silentFarSeconds
        ? _Dim.far
        : silent > SeatTuning.silentNearSeconds
            ? _Dim.near
            : _Dim.present;
    return _OrbSignature(
      (m.speech * SeatTuning.speechQuantSteps).round(),
      dim,
      m.speaking,
      m.status,
    );
  }

  /// 量化后的包络 0..1。
  double get speech => speechStep / SeatTuning.speechQuantSteps;

  /// 半径系数(SPEC §6.3)。说话内移优先于静默外退 ——
  /// 一个正在说话的人,不该因为「刚才静默很久」而被推远。
  double get radiusFactor {
    if (speechStep > 0) return 1 - SeatTuning.inwardPull * speech;
    return switch (dim) {
      _Dim.present => 1.0,
      _Dim.near => SeatTuning.silentNearPush,
      _Dim.far => SeatTuning.silentFarPush,
    };
  }

  /// 透明度。**0.34 是硬下限,不得更低**(SPEC §6.3)。
  double get opacity {
    if (speechStep > 0) {
      // 从「在场」平滑升到「说话」,而不是布尔跳变。
      final double base = switch (dim) {
        _Dim.present => SeatTuning.opacityPresent,
        _Dim.near => SeatTuning.opacitySilentNear,
        _Dim.far => SeatTuning.opacitySilentFar,
      };
      return base + (SeatTuning.opacitySpeaking - base) * speech;
    }
    return switch (dim) {
      _Dim.present => SeatTuning.opacityPresent,
      _Dim.near => SeatTuning.opacitySilentNear,
      _Dim.far => SeatTuning.opacitySilentFar,
    };
  }

  double get scale => 1 + (SeatTuning.speakingScale - 1) * speech;

  /// 「退入阴影」时名字再淡一档(SPEC §6.3 表格最后一列)。
  double get labelOpacity => dim == _Dim.far && speechStep == 0 ? 0.5 : 1.0;

  @override
  bool operator ==(Object other) =>
      other is _OrbSignature &&
      other.speechStep == speechStep &&
      other.dim == dim &&
      other.speaking == speaking &&
      other.status == status;

  @override
  int get hashCode => Object.hash(speechStep, dim, speaking, status);
}

// ─────────────────────────────────────────────────────────────────────────────
// SeatRing —— B 层的根 Widget
// ─────────────────────────────────────────────────────────────────────────────

/// 围炉而坐的一整层。
///
/// 它订阅 [HearthClock] 和 [HearthState],但**不是**为了逐帧重绘:
/// 时钟回调里只做一次 O(n) 的量化签名比较,跨档才 setState。
/// 见 [_OrbSignature] 的文档。
class SeatRing extends StatefulWidget {
  const SeatRing({
    super.key,
    required this.clock,
    required this.state,
    required this.size,
    required this.flameCenter,
    this.maxRings = 3,
    this.onLayout,
  });

  final HearthClock clock;
  final HearthState state;

  /// 整块画布尺寸(不是座位区;内缩在 [SeatLayout.compute] 里做)。
  final Size size;

  /// 火焰中心,与 A / D 层同一坐标系。
  final Offset flameCenter;

  /// 最多用几个环。默认 3(SPEC 原义);演示的「紧凑」开关传 1,
  /// 好让溢出芯片在桌面尺寸下真的出现 —— 见文件头「澄清 3」。
  final int maxRings;

  /// 每次布局变化时回调,给控制面板显示环容量等调试数字。
  final ValueChanged<SeatLayout>? onLayout;

  @override
  State<SeatRing> createState() => _SeatRingState();
}

class _SeatRingState extends State<SeatRing> {
  /// 上一次 setState 时的量化签名。时钟回调拿新签名跟它比。
  List<_OrbSignature> _signatures = const <_OrbSignature>[];

  /// 几何是否刚变过 —— 决定这一帧用 400ms(重排)还是 220ms(说话微移)。
  bool _geometryDirty = true;
  Object? _lastGeometryKey;

  @override
  void initState() {
    super.initState();
    widget.clock.addListener(_onClock);
    widget.state.addListener(_onState);
  }

  @override
  void didUpdateWidget(covariant SeatRing old) {
    super.didUpdateWidget(old);
    if (old.clock != widget.clock) {
      old.clock.removeListener(_onClock);
      widget.clock.addListener(_onClock);
    }
    if (old.state != widget.state) {
      old.state.removeListener(_onState);
      widget.state.addListener(_onState);
    }
  }

  @override
  void dispose() {
    widget.clock.removeListener(_onClock);
    widget.state.removeListener(_onState);
    super.dispose();
  }

  /// 成员集合变了(进房 / 离开 / 改人数 / 切说话态)—— 一定要重建。
  void _onState() {
    if (!mounted) return;
    setState(() {});
  }

  /// **时钟回调:B 层性能的关键路径。**
  ///
  /// 这里每次只做 n 次整数/枚举比较。静息档时钟每秒放行 6~12 次,
  /// 于是这段代码每秒跑 6~12 次、每次 O(20),然后**什么都不做**。
  /// 这就是「头像不订阅时钟逐帧重绘」在实现上的确切含义。
  void _onClock() {
    if (!mounted) return;
    final List<HearthMember> members = widget.state.members;
    final int now = widget.clock.nowMs;
    if (members.length != _signatures.length) {
      setState(() {});
      return;
    }
    for (int i = 0; i < members.length; i++) {
      if (_OrbSignature.of(members[i], now) != _signatures[i]) {
        setState(() {});
        return;
      }
    }
    // 没跨档 —— 不 rebuild,不 repaint,不分配。
  }

  @override
  Widget build(BuildContext context) {
    final List<HearthMember> members = widget.state.members;
    final int now = widget.clock.nowMs;

    // 减弱动态效果:过渡时长归零,直接钉在目标态(静态亮帧)。
    final bool reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    final SeatLayout layout = SeatLayout.compute(
      members: members,
      size: widget.size,
      flameCenter: widget.flameCenter,
      maxRings: widget.maxRings,
    );

    // 几何有没有变 —— 决定过渡时长。
    final Object geometryKey = Object.hash(
      members.length,
      widget.size,
      widget.maxRings,
      widget.flameCenter,
    );
    _geometryDirty = geometryKey != _lastGeometryKey;
    _lastGeometryKey = geometryKey;

    // 把座位方向回写给状态源,A 层靠它决定光团朝谁偏。
    // setSeatDirections 内部只更新 _pullTarget,**不会 notifyListeners**,
    // 所以在 build 里调用不会触发「build 期间 setState」。
    widget.state.setSeatDirections(layout.directionMap());
    widget.onLayout?.call(layout);

    final Map<String, HearthMember> byId = <String, HearthMember>{
      for (final HearthMember m in members) m.id: m,
    };

    final List<_OrbSignature> sigs = <_OrbSignature>[
      for (final HearthMember m in members) _OrbSignature.of(m, now),
    ];
    _signatures = sigs;

    final List<Widget> children = <Widget>[];
    for (final SeatPlacement seat in layout.seats) {
      if (seat.memberId == SeatLayout.overflowSeatId) {
        children.add(
          _positioned(
            key: const ValueKey<String>(SeatLayout.overflowSeatId),
            layout: layout,
            center: seat.baseCenter,
            reduceMotion: reduceMotion,
            child: _OverflowChip(
              count: layout.overflowCount,
              diameter: layout.diameter,
              // 溢出的是名册尾部那几位。
              hidden: members.length > layout.capacity - 1
                  ? members.sublist(layout.capacity - 1)
                  : const <HearthMember>[],
              state: widget.state,
            ),
          ),
        );
        continue;
      }

      final HearthMember? m = byId[seat.memberId];
      if (m == null) continue;
      final _OrbSignature sig = _OrbSignature.of(m, now);
      final Offset center = seat.centerAtRadius(
        layout.flameCenter,
        seat.baseRadius * sig.radiusFactor,
      );

      children.add(
        _positioned(
          key: ValueKey<String>(m.id),
          layout: layout,
          center: center,
          reduceMotion: reduceMotion,
          child: MemberOrb(
            member: m,
            diameter: layout.diameter,
            opacity: sig.opacity,
            scale: sig.scale,
            labelOpacity: sig.labelOpacity,
            speaking: sig.speaking,
            reduceMotion: reduceMotion,
            onTap: () => _onTapMember(context, m),
            onLongPress: () => _onLongPressMember(context, m),
          ),
        ),
      );
    }

    return SizedBox(
      width: widget.size.width,
      height: widget.size.height,
      child: Stack(clipBehavior: Clip.none, children: children),
    );
  }

  /// 统一的 `AnimatedPositioned` 包装。
  ///
  /// 圆心对准座位点,名字挂在圆下方 —— 所以 `top` 用的是 `dy - d/2`,
  /// 而不是方块的几何中心。
  Widget _positioned({
    required Key key,
    required SeatLayout layout,
    required Offset center,
    required bool reduceMotion,
    required Widget child,
  }) {
    final Duration duration = reduceMotion
        ? Duration.zero
        : _geometryDirty
            ? SeatTuning.relayoutDuration
            : SeatTuning.speechDuration;
    return AnimatedPositioned(
      key: key,
      duration: duration,
      curve: Curves.easeOutCubic,
      left: center.dx - layout.orbBoxWidth / 2,
      top: center.dy - layout.diameter / 2,
      width: layout.orbBoxWidth,
      height: layout.orbBoxHeight,
      // 每个头像独立 RepaintBoundary:一个人说话不该让另外 19 个人重绘。
      child: RepaintBoundary(child: child),
    );
  }

  void _onTapMember(BuildContext context, HearthMember m) {
    widget.state.toggleSpeaking(m.id);
    // SPEC §6.3:透明度不影响命中测试,所有成员始终可点 —— 用 SnackBar 自证。
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(milliseconds: 1400),
          behavior: SnackBarBehavior.floating,
          width: 320,
          backgroundColor: HearthColors.surfaceHigh,
          content: Text(
            m.speaking ? '${m.name} 开口了' : '${m.name} 安静下来',
            style: const TextStyle(color: HearthColors.textPrimary),
          ),
        ),
      );
  }

  void _onLongPressMember(BuildContext context, HearthMember m) {
    widget.state.sendMessage(m.id);
    ScaffoldMessenger.maybeOf(context)
      ?..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(milliseconds: 1400),
          behavior: SnackBarBehavior.floating,
          width: 320,
          backgroundColor: HearthColors.surfaceHigh,
          content: Text(
            '${m.name} 往火里丢了一句话',
            style: const TextStyle(color: HearthColors.ember),
          ),
        ),
      );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MemberOrb —— 单个头像
// ─────────────────────────────────────────────────────────────────────────────

/// 一个成员的头像球。
///
/// 刻意做成**无状态**:它自己不持有 `AnimationController`,也不认识时钟。
/// 所有动画都是隐式的,目标值由 [SeatRing] 算好传进来 —— 过渡跑完
/// Ticker 自动停,稳态零开销(SPEC §6.4)。
class MemberOrb extends StatelessWidget {
  const MemberOrb({
    super.key,
    required this.member,
    required this.diameter,
    required this.opacity,
    required this.scale,
    required this.labelOpacity,
    required this.speaking,
    required this.onTap,
    required this.onLongPress,
    this.reduceMotion = false,
  });

  final HearthMember member;
  final double diameter;
  final double opacity;
  final double scale;
  final double labelOpacity;
  final bool speaking;
  final bool reduceMotion;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final Duration fade =
        reduceMotion ? Duration.zero : SeatTuning.fadeDuration;

    // 说话时状态环增亮,并在外面再加一圈 ember 描边(SPEC §6.3)。
    final Color ringColor = speaking
        ? Color.lerp(member.status.color, HearthColors.ember, 0.45)!
        : member.status.color;

    return Semantics(
      label: '${member.name} · ${member.status.label}'
          '${speaking ? ' · 正在说话' : ''}',
      button: true,
      excludeSemantics: true,
      child: GestureDetector(
        // GestureDetector 放在 AnimatedOpacity **外面**:
        // RenderOpacity 本来就不改命中测试,这里再加一道保险 ——
        // SPEC §6.3 要求「所有成员始终可点」,这条不能只靠框架行为。
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: AnimatedOpacity(
          duration: fade,
          curve: Curves.easeOutCubic,
          opacity: opacity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AnimatedScale(
                duration: fade,
                curve: Curves.easeOutCubic,
                scale: scale,
                child: AnimatedContainer(
                  duration: fade,
                  curve: Curves.easeOutCubic,
                  width: diameter,
                  height: diameter,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: HearthColors.surface,
                    border: Border.all(color: ringColor, width: 2.5),
                    // 说话者的余烬描边。用 boxShadow 的 spread 做一圈薄光,
                    // 不用 blur —— 与 A 层「不用 MaskFilter」的纪律一致,
                    // 而且这是一次性过渡,不是逐帧动画。
                    boxShadow: speaking
                        ? const <BoxShadow>[
                            BoxShadow(
                              color: Color(0x59FF8A5C), // ember @ 0.35
                              blurRadius: 10,
                              spreadRadius: 1.5,
                            ),
                          ]
                        : const <BoxShadow>[],
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    _initial(member.name),
                    style: TextStyle(
                      fontSize: diameter * 0.36,
                      height: 1.0,
                      color: HearthColors.textPrimary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: HearthSpacing.xs),
              Opacity(
                opacity: labelOpacity,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      member.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.15,
                        color: HearthColors.textPrimary,
                      ),
                    ),
                    Text(
                      member.status.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.15,
                        color: member.status.color,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _initial(String name) =>
      name.isEmpty ? '?' : name.characters.first;
}

// ─────────────────────────────────────────────────────────────────────────────
// 溢出芯片
// ─────────────────────────────────────────────────────────────────────────────

/// 「+N」聚合芯片(SPEC §6.1 最后一条)。
///
/// 占最外环的最后一格,点击弹出可滚动的完整名单。
class _OverflowChip extends StatelessWidget {
  const _OverflowChip({
    required this.count,
    required this.diameter,
    required this.hidden,
    required this.state,
  });

  final int count;
  final double diameter;
  final List<HearthMember> hidden;
  final HearthState state;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '还有 $count 人,点击查看',
      button: true,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _showSheet(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: diameter,
              height: diameter,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: HearthColors.surfaceHigh,
                border: Border.all(
                  color: HearthColors.ember.withValues(alpha: 0.55),
                  width: 2.5,
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                '+$count',
                style: TextStyle(
                  fontSize: diameter * 0.30,
                  height: 1.0,
                  color: HearthColors.ember,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: HearthSpacing.xs),
            const Text(
              '还有这些人',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                height: 1.15,
                color: HearthColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: HearthColors.surface,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(HearthRadii.xl),
        ),
      ),
      builder: (BuildContext ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    HearthSpacing.lg,
                    0,
                    HearthSpacing.lg,
                    HearthSpacing.sm,
                  ),
                  child: Row(
                    children: <Widget>[
                      Text(
                        '还有 $count 人围着',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: HearthColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: hidden.length,
                    itemBuilder: (BuildContext c, int i) {
                      final HearthMember m = hidden[i];
                      return ListTile(
                        leading: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: HearthColors.surfaceHigh,
                            border: Border.all(color: m.status.color, width: 2),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            MemberOrb._initial(m.name),
                            style: const TextStyle(
                              color: HearthColors.textPrimary,
                            ),
                          ),
                        ),
                        title: Text(
                          m.name,
                          style: const TextStyle(
                            color: HearthColors.textPrimary,
                          ),
                        ),
                        subtitle: Text(
                          m.status.label,
                          style: TextStyle(color: m.status.color, fontSize: 12),
                        ),
                        onTap: () {
                          state.toggleSpeaking(m.id);
                          Navigator.of(c).pop();
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
