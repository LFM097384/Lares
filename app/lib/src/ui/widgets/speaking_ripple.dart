import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// 说话波纹:品牌记忆点(设计.md §8.2-3)。
/// 正在说话时用 CustomPainter 画扩散环;安静时完全停帧(P2 省电)。
class SpeakingRipple extends StatefulWidget {
  const SpeakingRipple({
    super.key,
    required this.speaking,
    required this.size,
    this.color = LaresColors.ember,
  });

  final bool speaking;
  final double size;
  final Color color;

  @override
  State<SpeakingRipple> createState() => _SpeakingRippleState();
}

class _SpeakingRippleState extends State<SpeakingRipple>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    if (widget.speaking) _controller.repeat();
  }

  @override
  void didUpdateWidget(SpeakingRipple oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.speaking && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.speaking && _controller.isAnimating) {
      _controller.stop(); // 挂机安静时零动画开销
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(widget.size),
      painter: _RipplePainter(
        progress: _controller,
        color: widget.color,
        active: widget.speaking,
      ),
    );
  }
}

class _RipplePainter extends CustomPainter {
  _RipplePainter({
    required this.progress,
    required this.color,
    required this.active,
  }) : super(repaint: active ? progress : null);

  final Animation<double> progress;
  final Color color;
  final bool active;

  static const _ringCount = 3;

  @override
  void paint(Canvas canvas, Size size) {
    if (!active) return;
    final center = size.center(Offset.zero);
    final maxRadius = size.width / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    for (var i = 0; i < _ringCount; i++) {
      // 三环错相位扩散
      final t = (progress.value + i / _ringCount) % 1.0;
      final radius = maxRadius * (0.55 + 0.45 * t);
      final opacity = (1 - t) * 0.55;
      paint.color = color.withValues(alpha: opacity);
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(_RipplePainter oldDelegate) =>
      oldDelegate.active != active || oldDelegate.color != color;
}
