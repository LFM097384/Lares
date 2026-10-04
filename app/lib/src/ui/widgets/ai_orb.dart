import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../state/ai_state.dart';
import '../../theme/tokens.dart';
import 'speaking_ripple.dart';

/// AI 助手的标志性小图形。座位、聊天小头像、「更多」格、用途开关共用一个,
/// 让人一眼把它们认成同一个东西。
const IconData kAiGlyph = Icons.auto_awesome_rounded;

/// 呼吸一次(吸 + 呼)的时长:慢,接近人安静时的呼吸。
const Duration _breathPeriod = Duration(milliseconds: 3200);

/// 「在想…」的弧转一圈的时长。
const Duration _spinPeriod = Duration(milliseconds: 1400);

/// 光晕相对直径的模糊半径与不透明度(与真人座位的说话光晕同一量级)。
const double _glowBlur = 0.28;
const double _speakingGlowAlpha = 0.45;
const double _listenGlowMin = 0.10;
const double _listenGlowMax = 0.26;
const double _thinkingGlowAlpha = 0.22;

/// 光球的渐变填充:左上偏亮的杏色 → 余烬 → 梅紫,像一团从里往外亮的火。
Gradient aiOrbGradient({bool dim = false}) => RadialGradient(
      center: const Alignment(-0.35, -0.45),
      radius: 1.05,
      colors: <Color>[
        LaresColors.aiGlow,
        LaresColors.ember,
        dim
            ? Color.lerp(LaresColors.aiPlum, LaresColors.statusAway, 0.4)!
            : LaresColors.aiPlum,
      ],
      stops: const <double>[0.0, 0.5, 1.0],
    );

/// 小号静态光球(聊天头像、列表图标):没有动画,只有渐变 + 星芒。
class AiOrbMini extends StatelessWidget {
  const AiOrbMini({super.key, required this.size, this.ring, this.dim = false});

  final double size;

  /// 外圈描边色;null = 不描边。
  final Color? ring;

  /// 不可用(如端到端加密圈子)时整体淡下去。
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final Widget orb = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: aiOrbGradient(dim: dim),
        border: ring == null ? null : Border.all(color: ring!, width: 2),
      ),
      child: Icon(
        kAiGlyph,
        size: size * 0.5,
        color: Colors.white.withValues(alpha: 0.92),
      ),
    );
    return dim ? Opacity(opacity: 0.45, child: orb) : orb;
  }
}

/// AI 助手的座位光球:不画首字,画一团渐变的光 + 星芒,外面按状态动:
///
///  - idle      静止,颜色略收;
///  - listening 很慢的呼吸光晕;
///  - thinking  一段弧绕着转(「在想…」);
///  - speaking  与真人一样的说话波纹 + 暖光。
///
/// 「降低动效」(MediaQuery.disableAnimations)下一律停帧,只留静态的那一帧:
/// 状态仍然看得出来(弧还在、光晕还在),只是不动 —— 也不会让 pumpAndSettle 等不完。
///
/// 外层 [KeyedSubtree] 带 `ValueKey('ai-orb-<state>')`,测试 / 截图据此断言。
class AiOrb extends StatefulWidget {
  const AiOrb({super.key, required this.activity, required this.size});

  final AiActivity activity;

  /// 光球本身的直径;整个控件占 `size + 16` 见方(给波纹 / 弧留位置)。
  final double size;

  @override
  State<AiOrb> createState() => _AiOrbState();
}

class _AiOrbState extends State<AiOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this);
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(AiOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activity != widget.activity) _sync();
  }

  void _sync() {
    final AiActivity a = widget.activity;
    if (_reduceMotion || a == AiActivity.idle || a == AiActivity.speaking) {
      // speaking 的动效交给 SpeakingRipple;这里只留一帧居中的静态值
      _anim.stop();
      _anim.value = 0.5;
      return;
    }
    if (a == AiActivity.listening) {
      _anim.duration = _breathPeriod ~/ 2;
      _anim.repeat(reverse: true);
    } else {
      _anim.duration = _spinPeriod;
      _anim.repeat();
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AiActivity a = widget.activity;
    final double size = widget.size;
    final double box = size + 16;
    final ThemeData theme = Theme.of(context);
    final bool dark = theme.brightness == Brightness.dark;
    // 静息(在听 / 在想)用梅紫的冷光 + 一道中性细描边;余烬色只留给「在说话」,
    // 和真人座位的说话光晕同一个意思,不会让人以为它一直在说。
    final Color restGlow = LaresColors.aiPlum;
    final Color hairline = theme.colorScheme.outlineVariant;
    final Color arc = dark ? LaresColors.aiGlow : LaresColors.aiPlum;

    Widget core(double glow, {Color glowColor = LaresColors.aiPlum}) => Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: aiOrbGradient(dim: a == AiActivity.idle),
            // 一圈中性细描边(不是状态色):亮色主题里光球不会和背景糊成一片
            border: Border.all(color: hairline, width: 1),
            boxShadow: glow <= 0
                ? null
                : <BoxShadow>[
                    BoxShadow(
                      color: glowColor.withValues(alpha: glow),
                      blurRadius: size * _glowBlur,
                      spreadRadius: 1,
                    ),
                  ],
          ),
          child: Icon(
            kAiGlyph,
            size: size * 0.42,
            color: Colors.white.withValues(
              alpha: a == AiActivity.idle ? 0.7 : 0.94,
            ),
          ),
        );

    final Widget body = switch (a) {
      AiActivity.idle => core(0),
      AiActivity.speaking => Stack(
          alignment: Alignment.center,
          children: <Widget>[
            // 降低动效:波纹换成一道静止的余烬色环,「在说话」照样看得出
            if (_reduceMotion)
              Container(
                width: size + 10,
                height: size + 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: LaresColors.ember.withValues(alpha: 0.6),
                    width: 2,
                  ),
                ),
              )
            else
              SpeakingRipple(speaking: true, size: box),
            core(_speakingGlowAlpha, glowColor: LaresColors.ember),
          ],
        ),
      AiActivity.listening => AnimatedBuilder(
          animation: _anim,
          builder: (context, _) {
            final double v = Curves.easeInOut.transform(_anim.value);
            return core(
              _listenGlowMin + (_listenGlowMax - _listenGlowMin) * v,
              glowColor: restGlow,
            );
          },
        ),
      AiActivity.thinking => Stack(
          alignment: Alignment.center,
          children: <Widget>[
            CustomPaint(
              size: Size.square(box),
              painter: _ThinkingArcPainter(
                progress: _anim,
                color: arc,
              ),
            ),
            core(_thinkingGlowAlpha, glowColor: restGlow),
          ],
        ),
    };

    return KeyedSubtree(
      key: ValueKey<String>('ai-orb-${a.name}'),
      child: SizedBox.square(
        dimension: box,
        child: Center(child: body),
      ),
    );
  }
}

/// 「在想…」:一段由淡到实的弧,绕着光球转。
class _ThinkingArcPainter extends CustomPainter {
  _ThinkingArcPainter({required this.progress, required this.color})
      : super(repaint: progress);

  final Animation<double> progress;
  final Color color;

  /// 弧长占一圈的比例。
  static const double _sweep = 0.32;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double r = size.width / 2 - 3;
    final Rect rect = Rect.fromCircle(center: c, radius: r);
    final double start = progress.value * 2 * math.pi - math.pi / 2;
    final double sweep = _sweep * 2 * math.pi;
    // 底圈:很淡的一整圈,告诉人「这是一条轨道」
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withValues(alpha: 0.14),
    );
    final Paint arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: sweep,
        colors: <Color>[color.withValues(alpha: 0), color],
        transform: GradientRotation(start),
      ).createShader(rect);
    canvas.drawArc(rect, start, sweep, false, arc);
  }

  @override
  bool shouldRepaint(_ThinkingArcPainter old) =>
      old.color != color || old.progress != progress;
}
