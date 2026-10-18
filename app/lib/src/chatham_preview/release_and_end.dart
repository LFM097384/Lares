// ⑤ 放行共识 与 ⑥ 散会。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'chatham_data.dart';
import 'chatham_kit.dart';

class ReleaseConsensusPreview extends StatelessWidget {
  const ReleaseConsensusPreview({super.key});

  static const int k = 4;
  /// 只给人数;谁签了不渲染。
  static const int signed = 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final List<Seat> voters = kVoters;
    return Scaffold(
      body: HearthBackground(
        glow: 0.06,
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              const PreviewTopBar(title: '放行', subtitle: '出门稿 · 分享到「街坊群」'),
              const SizedBox(height: LaresSpacing.lg),
              // 圆桌:五个座位围成弧,中间是计数
              SizedBox(
                height: 290,
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints c) {
                    final double cx = c.maxWidth / 2;
                    const double cy = 145;
                    const double r = 108;
                    return Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _TablePainter(
                              center: Offset(cx, cy),
                              radius: r,
                              threshold: k / voters.length,
                              track: theme.hairline,
                            ),
                          ),
                        ),
                        for (int i = 0; i < voters.length; i++)
                          Builder(
                            builder: (BuildContext context) {
                              final double a = -math.pi / 2 + i * 2 * math.pi / voters.length;
                              const double s = 46;
                              return Positioned(
                                left: cx + math.cos(a) * r - (s + 10) / 2,
                                top: cy + math.sin(a) * r - (s + 10) / 2,
                                child: VeiledOrb(
                                  glyph: voters[i].glyph,
                                  size: s,
                                  verified: voters[i].verified,
                                ),
                              );
                            },
                          ),
                        Positioned(
                          left: 0,
                          right: 0,
                          top: cy - 34,
                          child: Column(
                            children: [
                              Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(
                                      text: '$signed',
                                      style: const TextStyle(color: LaresColors.ember),
                                    ),
                                    TextSpan(
                                      text: ' / ${voters.length}',
                                      style: TextStyle(color: theme.faint, fontSize: 22),
                                    ),
                                  ],
                                ),
                                style: TextStyle(
                                  fontFamily: ChathamType.serifLatin,
                                  fontSize: 40,
                                  height: 1.1,
                                  color: cs.onSurface,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text('份同意签名', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
                              const SizedBox(height: 2),
                              Text('门槛 $k · 只计已核验成员', style: TextStyle(fontSize: 11.5, color: theme.faint)),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: LaresSpacing.sm),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: LaresSpacing.lg),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  decoration: BoxDecoration(
                    color: cs.surface,
                    borderRadius: BorderRadius.circular(LaresRadii.md),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Overline('待放行的出门稿'),
                          const Spacer(),
                          Text('守门人已过', style: TextStyle(fontSize: 11, color: theme.faint)),
                          const SizedBox(width: 4),
                          const RuleSeal(size: 16, years: false),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        kDigest,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: ChathamType.serifCjk,
                          fontSize: 14,
                          height: 1.7,
                          color: cs.onSurface.withValues(alpha: 0.82),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: LaresSpacing.md),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: LaresSpacing.lg + 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(Icons.hourglass_empty_rounded, size: 15, color: theme.faint),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '还差 1 人。门槛未到之前，Lares 不会把稿子发出去；散会时未放行的稿子一并销毁。只显示人数，不显示谁签了。',
                        style: TextStyle(fontSize: 12.5, height: 1.6, color: cs.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  LaresSpacing.lg,
                  0,
                  LaresSpacing.lg,
                  MediaQuery.paddingOf(context).bottom + LaresSpacing.md,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 50,
                        child: OutlinedButton(
                          onPressed: () {},
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: theme.hairline),
                            foregroundColor: cs.onSurface,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(LaresRadii.md)),
                          ),
                          child: const Text('撤回我的同意'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SizedBox(
                        height: 50,
                        child: FilledButton(
                          onPressed: null,
                          style: FilledButton.styleFrom(
                            disabledBackgroundColor: LaresColors.emberSoft,
                            disabledForegroundColor: LaresColors.ember.withValues(alpha: 0.7),
                          ),
                          child: const Text('等满 4 人放行'),
                        ),
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
}

class _TablePainter extends CustomPainter {
  _TablePainter({
    required this.center,
    required this.radius,
    required this.threshold,
    required this.track,
  });
  final Offset center;
  final double radius;
  final double threshold;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = track,
    );
    // 不画进度弧:弧线从某个座位起算,会暗示是谁签了。只留门槛刻度。

    // 门槛刻度
    final double a = -math.pi / 2 + 2 * math.pi * threshold;
    final Offset dir = Offset(math.cos(a), math.sin(a));
    canvas.drawLine(
      center + dir * (radius - 7),
      center + dir * (radius + 7),
      Paint()
        ..strokeWidth = 1.5
        ..color = LaresColors.ember.withValues(alpha: 0.5),
    );
  }

  @override
  bool shouldRepaint(_TablePainter old) => old.threshold != threshold;
}

// ─────────────────────────── ⑥ 散会 ───────────────────────────

class SessionEndPreview extends StatelessWidget {
  const SessionEndPreview({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      body: HearthBackground(
        glow: 0.1,
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              const SizedBox(height: LaresSpacing.md),
              // 字幕化灰:字一行行变成余烬点,从下往上越来越稀
              const SizedBox(height: 210, child: _Ashes()),
              const SizedBox(height: LaresSpacing.sm),
              Text(
                '散会',
                style: TextStyle(
                  fontFamily: ChathamType.serifCjk,
                  fontSize: 34,
                  letterSpacing: 8,
                  color: cs.onSurface,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '周四夜谈 · 22:41 · 6 人 · 1 小时 12 分',
                style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: LaresSpacing.lg),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: LaresSpacing.lg),
                child: Container(
                  decoration: BoxDecoration(
                    color: cs.surface,
                    borderRadius: BorderRadius.circular(LaresRadii.lg - 4),
                  ),
                  child: Column(
                    children: [
                      _Ledger(
                        icon: Icons.inventory_2_outlined,
                        color: LaresColors.ember,
                        title: '留下的',
                        lines: const <String>['1 份隐名稿 · 4/5 同意 · 已分享到「街坊群」'],
                      ),
                      Divider(height: 1, color: theme.hairline, indent: 16, endIndent: 16),
                      _Ledger(
                        icon: Icons.local_fire_department_outlined,
                        color: cs.onSurfaceVariant,
                        title: '本设备已销毁的',
                        lines: const <String>[
                          '612 行字幕（本机内存）',
                          '9 次圈内 AI 问答',
                          '2 份未放行的出门稿',
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: LaresSpacing.md),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: LaresSpacing.lg),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(LaresRadii.md),
                    border: Border.all(color: theme.hairline),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.verified_outlined, size: 18, color: theme.faint),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('自证回执：本设备已销毁本场缓存', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                            const SizedBox(height: 2),
                            Text(
                              'sha256  9f3a·c41e·07bd·e2a8',
                              style: TextStyle(
                                fontFamily: ChathamType.mono,
                                fontSize: 12.5,
                                letterSpacing: 0.3,
                                color: cs.onSurface.withValues(alpha: 0.85),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '其他 5 台自报已销毁（无法验证）',
                              style: TextStyle(fontSize: 11.5, color: theme.faint),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.copy_rounded, size: 16, color: theme.faint),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  LaresSpacing.lg,
                  0,
                  LaresSpacing.lg,
                  MediaQuery.paddingOf(context).bottom + LaresSpacing.md,
                ),
                child: Column(
                  children: [
                    Text(
                      'Lares 不存这场的内容。',
                      style: TextStyle(
                        fontFamily: ChathamType.serifCjk,
                        fontSize: 14,
                        color: theme.faint,
                      ),
                    ),
                    const SizedBox(height: LaresSpacing.md),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: FilledButton.tonal(
                        onPressed: () {},
                        style: FilledButton.styleFrom(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(LaresRadii.md)),
                        ),
                        child: const Text('好'),
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
}

class _Ledger extends StatelessWidget {
  const _Ledger({required this.icon, required this.color, required this.title, required this.lines});
  final IconData icon;
  final Color color;
  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
                const SizedBox(height: 4),
                for (final String l in lines)
                  Text(l, style: TextStyle(fontSize: 13, height: 1.65, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 字幕烧成灰:底部几行还是字,往上逐渐只剩字形的点阵,最后是零星余烬。
class _Ashes extends StatelessWidget {
  const _Ashes();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _AshPainter(ink: cs.onSurface, dark: theme.isDark),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: ShaderMask(
            shaderCallback: (Rect r) => const LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0x66000000), Color(0x00000000)],
            ).createShader(r),
            blendMode: BlendMode.dstIn,
            child: Column(
              children: [
                for (final CaptionLine l in kCaptions.sublist(2))
                  Text(
                    l.text,
                    style: TextStyle(fontSize: 13, height: 1.8, color: cs.onSurface),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _AshPainter extends CustomPainter {
  _AshPainter({required this.ink, required this.dark});
  final Color ink;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final math.Random rnd = math.Random(1927);
    // 「字行」的灰:几排水平点列,越往上越稀、越暖、越小
    const int rows = 9;
    for (int row = 0; row < rows; row++) {
      final double t = row / (rows - 1); // 0 底 → 1 顶
      final double y = size.height * (0.62 - t * 0.58);
      final double halfW = size.width * (0.34 - t * 0.08);
      final int n = (70 * (1 - t) + 6).round();
      for (int i = 0; i < n; i++) {
        if (rnd.nextDouble() < t * 0.6) continue;
        final double x = size.width / 2 + (rnd.nextDouble() * 2 - 1) * halfW;
        final double jy = y + (rnd.nextDouble() - 0.5) * (6 + t * 22);
        final double r = (1.4 - t * 0.8) * (0.6 + rnd.nextDouble() * 0.6);
        final bool ember = rnd.nextDouble() < 0.12 + t * 0.5;
        final Color c = ember
            ? LaresColors.ember.withValues(alpha: (0.75 - t * 0.5) * (0.5 + rnd.nextDouble() * 0.5))
            : ink.withValues(alpha: (0.32 - t * 0.26) * (0.5 + rnd.nextDouble() * 0.5));
        canvas.drawCircle(Offset(x, jy), r, Paint()..color = c);
      }
    }
  }

  @override
  bool shouldRepaint(_AshPainter old) => false;
}
