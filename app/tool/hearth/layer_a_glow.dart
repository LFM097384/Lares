import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'hearth_state.dart';
import 'hearth_tokens.dart';

// ═══════════════════════════════════════════════════════════════════════
//  Layer A —— 呼吸的烬
//
//  渲染原理(SPEC §4.1,方案已定,不要换):
//    不用 MaskFilter.blur(大 sigma 在 Skia/Impeller 上是逐像素卷积,
//    一团 600px 的光晕每帧要花掉几个毫秒),也不用 FragmentProgram
//    (要改 pubspec 的 shaders 段)。
//
//    改用「硬边 Path + alpha 提前归零的径向渐变」:
//      1. 极坐标半径函数生成一个**不规则**闭合 Path(72 段直线);
//      2. 用 ui.Gradient.radial 填充,alpha 在 stop 0.82 处已经是 0。
//
//    关键点在第 2 步:只要渐变半径取得足够小,使得
//      0.82 × gradientRadius ≤ Path 的**最小**极半径,
//    那么 Path 的硬边缘所在的每一个角度上,像素 alpha 都已经是 0,
//    边缘因此完全不可见 —— 不用 blur 也拿到了柔光。
//    (见下方 _paintBlob 里 gradRadius 的算法,这是整个方案的命门:
//     如果用「最大极半径 / 0.82」,在 Path 凹进去的角度上零点会落到
//     Path 外面,那些角度就会露出一圈硬边。)
// ═══════════════════════════════════════════════════════════════════════

/// 调参常量。产品负责人改这里就够了,下面的代码不需要动。
abstract final class HearthGlowTuning {
  // ── 尺寸 ──
  /// 火焰基准半径 = min(宽,高) × 该系数。
  /// B 层第一圈座位在 0.30,这里取 0.26 留出「光不糊到人脸上」的余量。
  static const double flameRadiusFactor = 0.26;

  // ── 呼吸(SPEC §4.2)──
  /// 亮度在 [breathLow, 1.0] 之间做 sin 循环。
  /// 用 sin 而不是反复 easeInOut:后者在端点停留太久,看起来像喘气。
  static const double breathLow = 0.82;

  /// 半径同步微呼吸幅度。±3%,再多就成了脉冲灯。
  static const double breathRadiusAmp = 0.03;

  /// 半径呼吸相对亮度呼吸的相位滞后(弧度)。
  /// 光先亮一点点、体积再跟上,比完全同步更像真火。
  static const double breathRadiusLag = 0.6;

  // ── 说话态(SPEC §4.3)──
  /// arousal 0→1 时整体亮度乘 1.0 → 该值。
  static const double arousalBrightnessGain = 1.45;

  /// 光团沿 spiritPull 的位移 = pull × R × 该系数。
  static const double pullShiftFactor = 0.22;

  /// 沿 pull 轴拉伸 / 垂直方向压缩。
  static const double stretchAlong = 0.18;
  static const double stretchAcross = 0.07;

  // ── 有机形变谐波(SPEC §4.1)──
  /// 三个谐波的阶数、幅度、角频率(rad/s)。
  /// 角频率刻意互质感,让形状长时间不重复。
  static const List<int> harmonicK = <int>[2, 3, 5];
  static const List<double> harmonicA = <double>[0.06, 0.04, 0.025];
  static const List<double> harmonicW = <double>[0.31, 0.47, 0.73];

  // ── 环境(非动画)──
  /// 地面暖光池的强度(炉火在地上洒出的那一摊)。
  static const double floorPoolAlpha = 0.050;

  /// 四角压暗的强度。
  static const double vignetteAlpha = 0.40;
}

/// Path 采样点数。72 段直线在这个尺度下肉眼即为平滑,
/// 用 cubicTo 只会多花 CPU 换不到可见收益(SPEC §4.1)。
const int _kSamples = 72;

/// 渐变色标位置。0.82 与 1.0 两处 alpha 都是 0 ——
/// 0.82→1.0 这段纯透明区就是「吃掉」Path 硬边的缓冲带。
const List<double> _kStops = <double>[
  0.00, 0.12, 0.24, 0.36, 0.48, 0.60, 0.71, 0.82, 1.00,
];

/// 极坐标三角函数查表。
///
/// 每层每帧要算 72 个点 × (1 个角度 + 3 个谐波) 的 sin/cos。
/// 但 sin(kθ + ψ) = sin(kθ)·cos(ψ) + cos(kθ)·sin(ψ),
/// 其中 kθ 只跟采样下标有关、ψ 只跟时间有关。
/// 于是把 sin(kθ)/cos(kθ) 全部预先算好,内层循环里就**一次三角函数都不用调**,
/// 只剩乘加。每帧省掉 4 层 × 72 点 × 4 次 ≈ 1150 次 sin/cos 调用。
final class _PolarTable {
  _PolarTable._() {
    const step = 2 * math.pi / _kSamples;
    for (var i = 0; i < _kSamples; i++) {
      final th = i * step;
      cosT[i] = math.cos(th);
      sinT[i] = math.sin(th);
      for (var h = 0; h < 3; h++) {
        final k = HearthGlowTuning.harmonicK[h];
        cosK[h][i] = math.cos(k * th);
        sinK[h][i] = math.sin(k * th);
      }
    }
  }

  static final _PolarTable instance = _PolarTable._();

  final Float64List cosT = Float64List(_kSamples);
  final Float64List sinT = Float64List(_kSamples);
  final List<Float64List> cosK =
      List<Float64List>.generate(3, (_) => Float64List(_kSamples));
  final List<Float64List> sinK =
      List<Float64List>.generate(3, (_) => Float64List(_kSamples));
}

/// 一层「有机光斑」的静态配置。
///
/// 四层由内到外:火心 → 焰体 → 幔 → 光晕。
/// 内层小而亮(emberDeep,甚至带一点点暖白的芯),外层大而淡(ember 低 alpha)。
final class _BlobSpec {
  _BlobSpec({
    required this.radius,
    required this.alpha,
    required this.sigma,
    required this.core,
    required this.edge,
    required this.offset,
    required this.phase,
    required this.breath,
    required this.arousalRadius,
    required this.shift,
  }) {
    // 渐变的基准颜色只跟配置有关,构造时算一次。
    // 每帧只改 alpha,不再重新 lerp。
    final tail = math.exp(-math.pow(0.82 / sigma, 2).toDouble());
    for (var i = 0; i < _kStops.length; i++) {
      final s = _kStops[i];
      // 颜色沿半径从 core 走到 edge。
      final tone = Color.lerp(core, edge, (s / 0.82).clamp(0.0, 1.0))!;
      baseColors.add(tone);
      // alpha 走高斯 exp(-(s/σ)²),平移到 0.82 处正好归零后再归一化。
      // 为什么不用线性斜坡:线性 alpha 在归零点有一个硬拐角,
      // 眼睛会把它读成一个「锥形的边」,柔光感立刻消失。
      if (s >= 0.82) {
        profile.add(0.0);
      } else {
        final g = math.exp(-(s / sigma) * (s / sigma));
        profile.add(((g - tail) / (1 - tail)).clamp(0.0, 1.0));
      }
    }
    // 每帧复用的颜色数组容器(ui.Gradient.radial 内部会拷贝一份)。
    colorBuf = List<Color>.filled(_kStops.length, core);
  }

  /// 相对火焰基准半径 R 的倍数。
  final double radius;

  /// 基础不透明度。
  final double alpha;

  /// 高斯衰减的 σ。越大核心越平、越「热」。
  final double sigma;

  /// 中心色 / 边缘色。
  final Color core;
  final Color edge;

  /// 中心偏移(单位:R)。内层略微上浮 —— 火是往上烧的。
  final Offset offset;

  /// 谐波相位偏移,让各层形状不同步,产生流动感。
  final double phase;

  /// 呼吸权重:1.0 = 完全按全局呼吸,<1 更稳、>1 更活。
  final double breath;

  /// arousal=1 时半径的增益。火心 +18%,最外光晕 +30%(SPEC §4.3)。
  final double arousalRadius;

  /// 朝向位移的层间倍率(视差:外层拖后腿,内层先动)。
  final double shift;

  final List<Color> baseColors = <Color>[];
  final List<double> profile = <double>[];
  late final List<Color> colorBuf;
}

/// 略带暖意的「白热」芯色。不用纯白 —— 纯白会让整团光显得廉价。
const Color _kWhiteHot = Color(0xFFFFC9A0);

/// 四层配置。由外到内绘制(先画淡的大的,再画亮的小的)。
List<_BlobSpec> _buildSpecs() => <_BlobSpec>[
      // 0 · 光晕:最大最淡,负责把火的存在感铺满房间。
      _BlobSpec(
        radius: 1.00,
        alpha: 0.17,
        sigma: 0.40,
        core: HearthColors.ember,
        edge: HearthColors.emberAsh,
        offset: const Offset(0.00, -0.02),
        phase: 0.0,
        breath: 0.62,
        arousalRadius: 0.30,
        shift: 0.72,
      ),
      // 1 · 幔:光晕与焰体之间的过渡,提供「厚度」。
      _BlobSpec(
        radius: 0.70,
        alpha: 0.26,
        sigma: 0.42,
        core: HearthColors.ember,
        edge: HearthColors.ember,
        offset: const Offset(0.02, -0.05),
        phase: 1.9,
        breath: 0.85,
        arousalRadius: 0.26,
        shift: 0.88,
      ),
      // 2 · 焰体:主体颜色从火心橙过渡到品牌余烬橙。
      _BlobSpec(
        radius: 0.45,
        alpha: 0.40,
        sigma: 0.44,
        core: HearthColors.emberDeep,
        edge: HearthColors.ember,
        offset: const Offset(-0.015, -0.07),
        phase: 3.6,
        breath: 1.00,
        arousalRadius: 0.22,
        shift: 1.00,
      ),
      // 3 · 火心:小而亮,中心一点暖白。
      //     不用 BlendMode.plus 叠加提亮 —— 加法混合四层会把中心顶到纯白,
      //     在 #121016 的底色上看起来很廉价。srcOver 收敛到 emberDeep,
      //     符合「宁可暗一点,不要糊一片橙」。
      _BlobSpec(
        radius: 0.235,
        alpha: 0.72,
        sigma: 0.46,
        core: _kWhiteHot,
        edge: HearthColors.emberDeep,
        offset: const Offset(0.0, -0.085),
        phase: 5.2,
        breath: 1.10,
        arousalRadius: 0.18,
        shift: 1.08,
      ),
    ];

/// 呼吸的烬 —— A 层画笔。
class GlowPainter extends CustomPainter {
  GlowPainter({required this.clock, required this.state})
      : super(repaint: clock);

  final HearthClock clock;
  final HearthState state;

  // ── 复用对象:这些都是字段,不在 paint 里 new(SPEC §4.4)──
  final List<_BlobSpec> _specs = _buildSpecs();
  final Paint _blobPaint = Paint()..isAntiAlias = true;
  final Paint _envPaint = Paint()..isAntiAlias = false;

  /// 预分配的点缓冲:72 个点 × (x, y)。每帧原地覆写,不重新分配。
  final Float32List _pts = Float32List(_kSamples * 2);

  // ── 环境层缓存:静态的,只在尺寸变化时重建 ──
  Size _envSize = Size.zero;
  ui.Shader? _floorShader;
  ui.Shader? _vignetteShader;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final base = math.min(size.width, size.height);
    final r = base * HearthGlowTuning.flameRadiusFactor;
    final center = state.flameCenter == Offset.zero
        ? Offset(size.width / 2, size.height / 2)
        : state.flameCenter;

    _ensureEnvironment(size, center, r);

    // ── 地面暖光池(画在光团之下,让火「落在地上」)──
    final floor = _floorShader;
    if (floor != null) {
      _envPaint.shader = floor;
      canvas.drawRect(Offset.zero & size, _envPaint);
    }

    final t = clock.t;

    // ── 呼吸(SPEC §4.2)──
    // 亮度 0.82 ↔ 1.0,纯 sin。这是一个人会盯着看十小时的界面,
    // 任何肉眼可察的闪烁都是缺陷。
    final period = clock.breathPeriod;
    final w = 2 * math.pi / period;
    const mid = (HearthGlowTuning.breathLow + 1.0) / 2;
    const amp = (1.0 - HearthGlowTuning.breathLow) / 2;
    final breath = mid + amp * math.sin(w * t);
    final radiusBreath = 1 +
        HearthGlowTuning.breathRadiusAmp *
            math.sin(w * t + HearthGlowTuning.breathRadiusLag);

    // ── 说话态 ──
    final arousal = state.arousal.clamp(0.0, 1.0);
    final gain =
        1 + (HearthGlowTuning.arousalBrightnessGain - 1) * arousal;

    final pull = state.spiritPull; // 已在 HearthState 里做过弹簧平滑,不要再平滑一次
    final pullLen = pull.distance.clamp(0.0, 1.0);

    canvas.save();

    // 沿 pull 轴拉伸:rotate → scale → rotate back,绕火焰中心。
    if (pullLen > 0.002) {
      final angle = math.atan2(pull.dy, pull.dx);
      canvas
        ..translate(center.dx, center.dy)
        ..rotate(angle)
        ..scale(
          1 + HearthGlowTuning.stretchAlong * pullLen,
          1 - HearthGlowTuning.stretchAcross * pullLen,
        )
        ..rotate(-angle)
        ..translate(-center.dx, -center.dy);
    }

    final shiftBase = r * HearthGlowTuning.pullShiftFactor;

    for (final spec in _specs) {
      // 层亮度 = 1 + (全局呼吸 - 1) × 该层权重,再乘 arousal 增益。
      final lb = (1 + (breath - 1) * spec.breath) * gain;
      final lr = r *
          spec.radius *
          radiusBreath *
          (1 + spec.arousalRadius * arousal);

      final c = Offset(
        center.dx + spec.offset.dx * r + pull.dx * shiftBase * spec.shift,
        center.dy + spec.offset.dy * r + pull.dy * shiftBase * spec.shift,
      );

      _paintBlob(canvas, spec, c, lr, lb, t);
    }

    canvas.restore();

    // ── 四角压暗:放在最后,让最外圈的光也被环境吃掉一点,更「在场景里」──
    final vig = _vignetteShader;
    if (vig != null) {
      _envPaint.shader = vig;
      canvas.drawRect(Offset.zero & size, _envPaint);
    }
    _envPaint.shader = null;
  }

  /// 画一层有机光斑。
  void _paintBlob(
    Canvas canvas,
    _BlobSpec spec,
    Offset c,
    double radius,
    double brightness,
    double t,
  ) {
    final tbl = _PolarTable.instance;

    // 把 sin(kθ + ωt + φ) 拆成 sin(kθ)cos(ψ) + cos(kθ)sin(ψ),
    // ψ 每层每帧只算三次三角函数,内层 72 次循环里一次都不用调。
    final a0 = HearthGlowTuning.harmonicA[0];
    final a1 = HearthGlowTuning.harmonicA[1];
    final a2 = HearthGlowTuning.harmonicA[2];
    final p0 = HearthGlowTuning.harmonicW[0] * t + spec.phase;
    final p1 = HearthGlowTuning.harmonicW[1] * t + spec.phase * 1.7;
    final p2 = HearthGlowTuning.harmonicW[2] * t + spec.phase * 2.3;
    final c0 = math.cos(p0), s0 = math.sin(p0);
    final c1 = math.cos(p1), s1 = math.sin(p1);
    final c2 = math.cos(p2), s2 = math.sin(p2);

    final sk0 = tbl.sinK[0], ck0 = tbl.cosK[0];
    final sk1 = tbl.sinK[1], ck1 = tbl.cosK[1];
    final sk2 = tbl.sinK[2], ck2 = tbl.cosK[2];

    var minR = double.infinity;

    for (var i = 0; i < _kSamples; i++) {
      final m = 1 +
          a0 * (sk0[i] * c0 + ck0[i] * s0) +
          a1 * (sk1[i] * c1 + ck1[i] * s1) +
          a2 * (sk2[i] * c2 + ck2[i] * s2);
      final rr = radius * m;
      if (rr < minR) minR = rr;
      _pts[i * 2] = (c.dx + rr * tbl.cosT[i]).toDouble();
      _pts[i * 2 + 1] = (c.dy + rr * tbl.sinT[i]).toDouble();
    }

    // ★ 整个方案的命门 ★
    // 渐变半径取「最小极半径 / 0.82」,于是 alpha 归零的那一圈
    // 恰好落在 Path 最窄处的边上 —— 所有角度上边缘 alpha 都已是 0,
    // 硬边彻底不可见。若改用最大半径,凹处就会露边。
    final gradRadius = minR / 0.82;
    if (!(gradRadius > 0)) return;

    for (var i = 0; i < spec.baseColors.length; i++) {
      final a = spec.profile[i] * spec.alpha * brightness;
      spec.colorBuf[i] =
          spec.baseColors[i].withValues(alpha: a.clamp(0.0, 1.0));
    }

    final path = Path()..moveTo(_pts[0], _pts[1]);
    for (var i = 1; i < _kSamples; i++) {
      path.lineTo(_pts[i * 2], _pts[i * 2 + 1]);
    }
    path.close();

    _blobPaint.shader = ui.Gradient.radial(
      c,
      gradRadius,
      spec.colorBuf,
      _kStops,
    );
    canvas.drawPath(path, _blobPaint);
    _blobPaint.shader = null;
  }

  /// 环境层:地面光池 + 四角压暗。
  ///
  /// 两者都是**完全静态**的,不随时间变化,所以 Shader 缓存在字段里,
  /// 只有画布尺寸变了才重建。每帧只是两次 drawRect,成本可忽略。
  void _ensureEnvironment(Size size, Offset center, double r) {
    if (_envSize == size && _floorShader != null) return;
    _envSize = size;

    // 地面暖光池:压扁的椭圆,落在火焰下方一点。
    // 用 matrix4 做纵向压缩,比 save/scale 整个画布干净。
    final poolCenter = Offset(center.dx, center.dy + r * 0.55);
    _floorShader = ui.Gradient.radial(
      poolCenter,
      r * 2.2,
      <Color>[
        HearthColors.ember
            .withValues(alpha: HearthGlowTuning.floorPoolAlpha),
        HearthColors.ember
            .withValues(alpha: HearthGlowTuning.floorPoolAlpha * 0.40),
        HearthColors.emberAsh
            .withValues(alpha: HearthGlowTuning.floorPoolAlpha * 0.12),
        const Color(0x00000000),
      ],
      const <double>[0.0, 0.38, 0.66, 1.0],
      TileMode.clamp,
      _scaleAbout(1.0, 0.42, poolCenter.dx, poolCenter.dy),
    );

    // 四角压暗。用偏暖的极深色而不是纯黑,避免画面发「灰」。
    final sc = Offset(size.width / 2, size.height / 2);
    final diag =
        math.sqrt(size.width * size.width + size.height * size.height) / 2;
    _vignetteShader = ui.Gradient.radial(
      sc,
      diag,
      <Color>[
        const Color(0x000B0910),
        const Color(0x000B0910),
        const Color(0xFF0B0910)
            .withValues(alpha: HearthGlowTuning.vignetteAlpha * 0.40),
        const Color(0xFF0B0910)
            .withValues(alpha: HearthGlowTuning.vignetteAlpha),
      ],
      const <double>[0.0, 0.42, 0.78, 1.0],
    );
  }

  /// 绕点 (cx, cy) 做 (sx, sy) 缩放的列主序 4×4 矩阵。
  static Float64List _scaleAbout(
      double sx, double sy, double cx, double cy) {
    final m = Float64List(16);
    m[0] = sx;
    m[5] = sy;
    m[10] = 1;
    m[15] = 1;
    m[12] = cx * (1 - sx);
    m[13] = cy * (1 - sy);
    return m;
  }

  /// **只比较非动画配置**。时间来自 clock,而 clock 是 repaint 源,
  /// 在这里比较时间既没必要也会掩盖真正的配置变化(SPEC §4.4)。
  @override
  bool shouldRepaint(covariant GlowPainter old) =>
      !identical(old.clock, clock) || !identical(old.state, state);
}

/// A 层组件。
///
/// 自带 [RepaintBoundary]:A 层是慢速大面积重绘,必须和 D 层(爆发式)、
/// B 层(隐式动画,稳态零开销)彻底隔离,否则任何一层动都会拖着另外两层重画。
class GlowLayer extends StatefulWidget {
  const GlowLayer({super.key, required this.clock, required this.state});

  final HearthClock clock;
  final HearthState state;

  @override
  State<GlowLayer> createState() => _GlowLayerState();
}

class _GlowLayerState extends State<GlowLayer> {
  late GlowPainter _painter =
      GlowPainter(clock: widget.clock, state: widget.state);

  @override
  void didUpdateWidget(covariant GlowLayer old) {
    super.didUpdateWidget(old);
    // painter 实例长期持有,环境 Shader 缓存才不会因为父级 rebuild 而丢失。
    if (!identical(old.clock, widget.clock) ||
        !identical(old.state, widget.state)) {
      _painter = GlowPainter(clock: widget.clock, state: widget.state);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _painter,
        isComplex: true,
        willChange: true,
        size: Size.infinite,
      ),
    );
  }
}
