import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'hearth_state.dart';
import 'hearth_tokens.dart';

// ═══════════════════════════════════════════════════════════════════════
//  Layer D —— 火星
//
//  设计要点(SPEC §5):
//    · 固定容量对象池,粒子就地复用,**每帧零分配**(连 Color 都走查表,
//      见 _EmberLut ——  Color.lerp 每帧会产生 360 个短命对象,
//      在一个长期挂机的界面上这是不必要的 GC 压力)。
//    · 池满丢弃新粒子,不扩容、不驱逐最老的 —— 丢弃最省。
//    · 绝不持续发射。只有 join / message / leave 三个事件才 burst。
//    · 全熄灭后 painter 直接 return,时钟也不再被粒子钉在 active 档。
//
//  ── 推进时机(重要,只能有一处)──
//    粒子**只在 SparkPainter.paint 里推进**,用 clock.dt,并用
//    `_lastStepMs != clock.nowMs` 做门闩。理由:
//      1. 不抢占 clock.onAdvance —— 那个回调已经被 HearthState 占用,
//         覆盖它会让说话包络整个停摆。
//      2. paint 可能因为非时间原因被多调一次(尺寸变化、图层重新光栅化),
//         门闩保证同一个时钟毫秒内绝不推进两次。推两次 = 粒子速度翻倍。
//      3. clock.dt 用的是「上次放行到现在」的间隔,所以在 calm/deepIdle
//         降频档下粒子速度依然正确(不会变慢)。
//    代价:paint 里有副作用。在这个原型里换来的是「一处推进、绝不重复」,
//    值得,并且用门闩把它变成幂等操作。
// ═══════════════════════════════════════════════════════════════════════

/// 调参常量(SPEC §5.3 的数值,按 ~1080p 桌面标定)。
abstract final class HearthSparkTuning {
  // ── 初速 ──
  /// 向上初速区间(向上为负)。
  static const double vyMin = 55, vyMax = 130;

  /// 横向初速区间(对称)。
  static const double vxSpread = 18;

  // ── 受力 ──
  /// 浮力(向上为负)。真实火星先被热气托着加速,再被阻力拉住。
  static const double buoyancy = -14;

  /// 空气阻力:每秒 v *= exp(-drag)。
  /// 用指数而不是 `v -= k*v*dt` —— 后者在大 dt(降频档)下会发散。
  static const double drag = 1.15;

  // ── 横向扰动 ──
  static const double wobbleAmpMin = 20, wobbleAmpMax = 46; // px/s
  static const double wobbleFreqMin = 1.6, wobbleFreqMax = 4.2; // rad/s

  // ── 寿命与尺寸 ──
  static const double lifeMin = 1.5, lifeMax = 3.0; // s
  static const double coreRadiusMin = 1.1, coreRadiusMax = 3.0; // px

  /// 外圈光晕半径 = 核半径 × 该系数。
  static const double haloScale = 2.6;

  /// 光晕的 alpha 相对核的比例。低到只是「核周围有点热」。
  static const double haloAlphaScale = 0.30;

  // ── alpha 包络 ──
  /// 生命前 10% 从 0 升到 1 —— 快速点燃。
  static const double ignitePhase = 0.10;

  /// 之后按 pow(1-u, decayPower) 衰减。
  static const double decayPower = 1.6;

  // ── 事件数量(SPEC §5.2)──
  static const int countJoin = 28;
  static const int countMessage = 14;
  static const int countLeave = 18;

  /// 「发消息」的火星朝火焰飘的加速度(px/s²)。
  static const double messagePullAccel = 46;
}

/// 每种事件的风味参数。集中在这里,改手感只改这一块。
final class _Flavor {
  const _Flavor({
    required this.vyScale,
    required this.vxScale,
    required this.lifeScale,
    required this.radiusScale,
    required this.alphaScale,
    required this.colorGamma,
    required this.pullToFlame,
  });

  /// 初速 / 寿命 / 半径 / 亮度的缩放。
  final double vyScale;
  final double vxScale;
  final double lifeScale;
  final double radiusScale;
  final double alphaScale;

  /// 颜色进度的 gamma:<1 更快转向灰烬(熄得快),>1 更久保持亮橙。
  final double colorGamma;

  /// 朝火焰中心的恒定加速度(px/s²),0 = 不被吸引。
  final double pullToFlame;

  /// 进房:多、亮、向上扩散。
  static const _Flavor join = _Flavor(
    vyScale: 2.45,
    vxScale: 3.60,
    lifeScale: 1.00,
    radiusScale: 1.00,
    alphaScale: 1.00,
    colorGamma: 1.15,
    pullToFlame: 0,
  );

  /// 发消息:小而快,斜着朝火飘 —— 「把话投进火里」。
  static const _Flavor message = _Flavor(
    vyScale: 2.05,
    vxScale: 1.90,
    lifeScale: 0.62,
    radiusScale: 0.62,
    alphaScale: 0.92,
    colorGamma: 1.00,
    pullToFlame: HearthSparkTuning.messagePullAccel,
  );

  /// 离开:偏暗,飘散后很快熄灭。
  static const _Flavor leave = _Flavor(
    vyScale: 1.55,
    vxScale: 3.10,
    lifeScale: 0.58,
    radiusScale: 0.90,
    alphaScale: 0.62,
    colorGamma: 0.62,
    pullToFlame: 0,
  );

  static _Flavor of(SparkKind k) => switch (k) {
        SparkKind.join => join,
        SparkKind.message => message,
        SparkKind.leave => leave,
      };
}

/// 一颗火星。字段全部可变,由对象池就地复用,从不重新分配。
final class _Spark {
  bool active = false;

  double x = 0, y = 0;
  double vx = 0, vy = 0;

  /// 恒定附加加速度(目前只有「朝火飘」用)。浮力是全局的,不放这里。
  double ax = 0, ay = 0;

  double age = 0;
  double life = 1;

  /// 1/life,避免每帧做除法。
  double invLife = 1;

  double coreR = 2;
  double wobA = 0;
  double wobW = 0;
  double wobPhase = 0;

  double alphaScale = 1;
  double colorGamma = 1;

  /// 每颗粒子自己的亮度权重。让同一簇里有明有暗 ——
  /// 所有粒子一样亮会读成「一把碎屑」,不是火星(SPEC §8.3 要求明暗层次)。
  double bright = 1;
}

/// 余烬色查表:emberDeep → ember → emberAsh,再乘 64 级 alpha。
///
/// 一次性建 32×64 = 2048 个 Color,之后每帧只做两次数组索引。
/// 这样「每帧零分配」才是真的零 —— 否则 180 粒子 × 2 次 Color.lerp
/// = 每帧 360 个短命对象。
abstract final class _EmberLut {
  static const int ramps = 32;
  static const int alphas = 64;

  static final List<Color> table = _build();

  static List<Color> _build() {
    final out = List<Color>.filled(ramps * alphas, HearthColors.ember);
    for (var r = 0; r < ramps; r++) {
      final t = r / (ramps - 1);
      // 两段 lerp:前半生 火心→余烬橙,后半生 余烬橙→将熄的炭。
      final rgb = t < 0.5
          ? Color.lerp(HearthColors.emberDeep, HearthColors.ember, t * 2)!
          : Color.lerp(
              HearthColors.ember, HearthColors.emberAsh, (t - 0.5) * 2)!;
      for (var a = 0; a < alphas; a++) {
        out[r * alphas + a] = rgb.withValues(alpha: a / (alphas - 1));
      }
    }
    return out;
  }

  /// u = 生命进度 0..1,alpha = 0..1。
  static Color pick(double u, double alpha) {
    var ri = (u * (ramps - 1)).round();
    if (ri < 0) ri = 0;
    if (ri > ramps - 1) ri = ramps - 1;
    var ai = (alpha * (alphas - 1)).round();
    if (ai < 0) ai = 0;
    if (ai > alphas - 1) ai = alphas - 1;
    return table[ri * alphas + ai];
  }
}

/// 固定容量火星池。
class SparkField {
  SparkField({int seed = 91}) : _rng = math.Random(seed);

  /// 固定池容量,**绝不动态扩容**。
  static const int capacity = 180;

  final math.Random _rng;

  /// 预分配的粒子数组。整个生命周期内不再 new。
  final List<_Spark> _pool =
      List<_Spark>.generate(capacity, (_) => _Spark(), growable: false);

  int _alive = 0;

  /// 下一个候选空位,线性扫描的起点(摊还 O(1))。
  int _cursor = 0;

  int get alive => _alive;

  /// 迸发一簇火星。
  ///
  /// [origin] 画布绝对坐标;[count] 请求数量,池满时实际发射数会少于它
  /// (多出来的直接丢弃 —— 比扩容或驱逐最老的都省)。
  /// [towards] 给 message 风味用:火焰中心,粒子会朝它加速。
  void burst({
    required Offset origin,
    required SparkKind kind,
    required int count,
    Offset? towards,
  }) {
    final f = _Flavor.of(kind);

    // 朝火焰的单位方向,burst 时算一次,不在每帧循环里算。
    var dirX = 0.0, dirY = 0.0;
    if (f.pullToFlame > 0 && towards != null) {
      final dx = towards.dx - origin.dx;
      final dy = towards.dy - origin.dy;
      final len = math.sqrt(dx * dx + dy * dy);
      if (len > 1) {
        dirX = dx / len;
        dirY = dy / len;
      }
    }

    for (var n = 0; n < count; n++) {
      final s = _take();
      if (s == null) return; // 池满:安静地丢弃剩下的

      // 起点做一点抖动,否则 28 颗粒子会从同一个像素喷出来,像喷泉不像火。
      final jitter = kind == SparkKind.join ? 34.0 : 18.0;
      s.x = origin.dx + (_rng.nextDouble() - 0.5) * 2 * jitter;
      s.y = origin.dy + (_rng.nextDouble() - 0.5) * 2 * jitter;

      const vyMin = HearthSparkTuning.vyMin;
      const vySpan = HearthSparkTuning.vyMax - HearthSparkTuning.vyMin;
      s.vy = -(vyMin + _rng.nextDouble() * vySpan) * f.vyScale;
      s.vx = (_rng.nextDouble() - 0.5) *
          2 *
          HearthSparkTuning.vxSpread *
          f.vxScale;

      s.ax = dirX * f.pullToFlame;
      s.ay = dirY * f.pullToFlame;

      const lifeMin = HearthSparkTuning.lifeMin;
      const lifeSpan = HearthSparkTuning.lifeMax - HearthSparkTuning.lifeMin;
      s.life = (lifeMin + _rng.nextDouble() * lifeSpan) * f.lifeScale;
      s.invLife = 1 / s.life;
      s.age = 0;

      const rMin = HearthSparkTuning.coreRadiusMin;
      const rSpan =
          HearthSparkTuning.coreRadiusMax - HearthSparkTuning.coreRadiusMin;
      s.coreR = (rMin + _rng.nextDouble() * rSpan) * f.radiusScale;

      const aMin = HearthSparkTuning.wobbleAmpMin;
      const aSpan =
          HearthSparkTuning.wobbleAmpMax - HearthSparkTuning.wobbleAmpMin;
      s.wobA = aMin + _rng.nextDouble() * aSpan;

      const wMin = HearthSparkTuning.wobbleFreqMin;
      const wSpan =
          HearthSparkTuning.wobbleFreqMax - HearthSparkTuning.wobbleFreqMin;
      s.wobW = wMin + _rng.nextDouble() * wSpan;
      s.wobPhase = _rng.nextDouble() * math.pi * 2;

      // 少数粒子明显更亮(大火星),多数偏暗 —— 用平方分布拉开层次。
      final b = _rng.nextDouble();
      s.bright = 0.42 + 0.58 * b * b;
      s.alphaScale = f.alphaScale;
      s.colorGamma = f.colorGamma;

      s.active = true;
      _alive++;
    }
  }

  /// 取一个空槽。池满返回 null(不扩容、不驱逐)。
  _Spark? _take() {
    if (_alive >= capacity) return null;
    for (var n = 0; n < capacity; n++) {
      final i = _cursor;
      _cursor = (_cursor + 1) % capacity;
      if (!_pool[i].active) return _pool[i];
    }
    return null;
  }

  /// 推进一帧。返回是否还有存活粒子。
  bool advance(double dtSec) {
    if (_alive == 0) return false;
    if (dtSec <= 0) return true;

    final dt = dtSec;
    // 指数阻力每帧只算一次 exp,180 个粒子共用。
    final dragMul = math.exp(-HearthSparkTuning.drag * dt);

    for (var i = 0; i < capacity; i++) {
      final s = _pool[i];
      if (!s.active) continue;

      s.age += dt;
      if (s.age >= s.life) {
        s.active = false;
        _alive--;
        continue;
      }

      // 受力:浮力 + 风味加速度
      s.vx += s.ax * dt;
      s.vy += (HearthSparkTuning.buoyancy + s.ay) * dt;

      // 阻力
      s.vx *= dragMul;
      s.vy *= dragMul;

      // 位移 + 横向扰动(扰动是位移项,不进速度,否则会被阻力吃掉)
      s.x += s.vx * dt +
          s.wobA * math.sin(s.wobW * s.age + s.wobPhase) * dt;
      s.y += s.vy * dt;
    }
    return _alive > 0;
  }

  /// 全部熄灭(切换演示场景时用)。
  void clear() {
    for (var i = 0; i < capacity; i++) {
      _pool[i].active = false;
    }
    _alive = 0;
  }

  /// 供 painter 只读遍历。
  List<_Spark> get _particles => _pool;
}

/// 火星画笔。
class SparkPainter extends CustomPainter {
  SparkPainter({
    required this.clock,
    required this.state,
    required this.field,
  }) : super(repaint: clock);

  final HearthClock clock;
  final HearthState state;
  final SparkField field;

  /// 复用的 Paint,绝不在 paint 里 new。
  final Paint _paint = Paint()
    ..isAntiAlias = true
    ..style = PaintingStyle.fill;

  /// 门闩:同一个时钟毫秒内只推进一次。见文件头的说明。
  int _lastStepMs = -1;

  @override
  void paint(Canvas canvas, Size size) {
    // 先消费事件 + 推进(两者都是 O(存活数),空池时几乎免费),
    // 再判断是否有东西可画。顺序不能反 —— 反了的话池空时新的 burst
    // 永远不会被取走。
    _step();

    if (field.alive == 0) return;

    final halo = HearthSparkTuning.haloAlphaScale;
    final hs = HearthSparkTuning.haloScale;

    for (final s in field._particles) {
      if (!s.active) continue;

      final u = (s.age * s.invLife).clamp(0.0, 1.0);

      // alpha 包络:前 10% 快速点燃,之后 pow(1-u, 1.6) 衰减。
      final double env;
      if (u < HearthSparkTuning.ignitePhase) {
        env = u / HearthSparkTuning.ignitePhase;
      } else {
        env = math.pow(1 - u, HearthSparkTuning.decayPower).toDouble();
      }
      final a = env * s.alphaScale * s.bright;
      if (a <= 0.004) continue;

      // 颜色进度:gamma 让「离开」的火星更快转灰。
      final cu = s.colorGamma == 1.0
          ? u
          : math.pow(u, s.colorGamma).toDouble();

      // 1) 低 alpha 光晕 —— 没有 blur,靠一个大而淡的实心圆冒充热气。
      _paint.color = _EmberLut.pick(cu, a * halo);
      canvas.drawCircle(Offset(s.x, s.y), s.coreR * hs, _paint);

      // 2) 亮核
      _paint.color = _EmberLut.pick(cu, a);
      canvas.drawCircle(Offset(s.x, s.y), s.coreR, _paint);
    }
  }

  /// 消费 pendingSparks 并推进一帧。幂等:同一时钟毫秒重复调用无副作用。
  void _step() {
    final now = clock.nowMs;
    if (now == _lastStepMs) return;
    _lastStepMs = now;

    final pending = state.pendingSparks;
    if (pending.isNotEmpty) {
      for (final req in pending) {
        field.burst(
          origin: req.origin,
          kind: req.kind,
          count: req.count,
          towards: state.flameCenter,
        );
      }
      pending.clear();
    }

    field.advance(clock.dt);
  }

  /// 只比较非动画配置。时间由 clock(repaint 源)驱动。
  @override
  bool shouldRepaint(covariant SparkPainter old) =>
      !identical(old.clock, clock) ||
      !identical(old.state, state) ||
      !identical(old.field, field);
}

/// D 层组件。
///
/// 独立 [RepaintBoundary]:D 层是**爆发式**重绘(平时完全静止,事件时
/// 两三秒内满帧),A 层是慢速大面积重绘。放在同一个图层里,
/// 火星一飞就会拖着整团光晕重画。
class SparkLayer extends StatefulWidget {
  const SparkLayer({super.key, required this.clock, required this.state});

  final HearthClock clock;
  final HearthState state;

  @override
  State<SparkLayer> createState() => _SparkLayerState();
}

class _SparkLayerState extends State<SparkLayer> {
  final SparkField _field = SparkField();
  late SparkPainter _painter;

  @override
  void initState() {
    super.initState();
    _painter = SparkPainter(
      clock: widget.clock,
      state: widget.state,
      field: _field,
    );
    _attachProbe(widget.state);
  }

  /// 把存活数探针挂给 HearthState:粒子还在烧的时候时钟必须保持满帧,
  /// 否则会看到火星一卡一卡地飘(hearth_state.dart 里已留好钩子)。
  void _attachProbe(HearthState s) => s.sparksAliveProbe = () => _field.alive;

  @override
  void didUpdateWidget(covariant SparkLayer old) {
    super.didUpdateWidget(old);
    if (!identical(old.clock, widget.clock) ||
        !identical(old.state, widget.state)) {
      if (!identical(old.state, widget.state)) {
        if (identical(old.state.sparksAliveProbe, _painterProbeOf(old.state))) {
          old.state.sparksAliveProbe = null;
        }
        _attachProbe(widget.state);
      }
      _painter = SparkPainter(
        clock: widget.clock,
        state: widget.state,
        field: _field,
      );
    }
  }

  // 只是为了让上面的「是不是我挂的探针」判断读起来清楚。
  int Function()? _painterProbeOf(HearthState s) => s.sparksAliveProbe;

  @override
  void dispose() {
    widget.state.sparksAliveProbe = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _painter,
        willChange: true,
        size: Size.infinite,
      ),
    );
  }
}
