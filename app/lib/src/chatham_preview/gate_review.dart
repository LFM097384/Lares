// ④ 守门人审阅:原话 → 隐名稿,带删改理由与「归属风险」读数。
import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'chatham_data.dart';
import 'chatham_kit.dart';

class GateReviewPreview extends StatelessWidget {
  const GateReviewPreview({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const PreviewTopBar(
              title: '守门人',
              subtitle: '一份出门稿 · 将分享到「街坊群」',
              trailing: Pill(label: '1 / 3', dense: true),
            ),
            Expanded(
              child: ListView(
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(LaresSpacing.lg, LaresSpacing.md, LaresSpacing.lg, 0),
                children: [
                  Row(
                    children: [
                      const Overline('屋内原话'),
                      const Spacer(),
                      Icon(Icons.lock_outline_rounded, size: 12, color: theme.faint),
                      const SizedBox(width: 4),
                      Text('仅你可见 · 不出门', style: TextStyle(fontSize: 11, color: theme.faint)),
                    ],
                  ),
                  const SizedBox(height: LaresSpacing.sm),
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    decoration: BoxDecoration(
                      color: cs.surface,
                      borderRadius: BorderRadius.circular(LaresRadii.md),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (int i = 0; i < kRawLines.length; i++) ...[
                          if (i > 0) const SizedBox(height: 4),
                          _RawLine(kRawLines[i]),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 6,
                    children: [for (final Redaction r in Redaction.values) _Legend(r)],
                  ),
                  // 过门:一条细线中间一扇门
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Expanded(child: Divider(color: theme.hairline, height: 1)),
                        Container(
                          margin: const EdgeInsets.symmetric(horizontal: 10),
                          padding: const EdgeInsets.all(7),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: LaresColors.ember.withValues(alpha: 0.45)),
                          ),
                          child: const Icon(Icons.south_rounded, size: 15, color: LaresColors.ember),
                        ),
                        Expanded(child: Divider(color: theme.hairline, height: 1)),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      Overline('隐名稿 · 只留观点', color: LaresColors.ember.withValues(alpha: 0.85)),
                      const Spacer(),
                      const RuleSeal(size: 22, years: false),
                    ],
                  ),
                  const SizedBox(height: LaresSpacing.sm),
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                    decoration: BoxDecoration(
                      color: theme.isDark
                          ? Color.alphaBlend(LaresColors.ember.withValues(alpha: 0.05), cs.surface)
                          : const Color(0xFFFFFBF6),
                      borderRadius: BorderRadius.circular(LaresRadii.md),
                      border: Border.all(color: LaresColors.ember.withValues(alpha: 0.2)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          kDigestMain,
                          style: TextStyle(
                            fontFamily: ChathamType.serifCjk,
                            fontSize: 14.5,
                            height: 1.6,
                            color: cs.onSurface.withValues(alpha: 0.92),
                          ),
                        ),
                        const SizedBox(height: 8),
                        const _RoleFlagClaim(text: kDigestRoleClaim),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  const _RiskMeter(),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                LaresSpacing.lg,
                LaresSpacing.sm,
                LaresSpacing.lg,
                MediaQuery.paddingOf(context).bottom + LaresSpacing.md,
              ),
              child: Row(
                children: [
                  _Ghost(icon: Icons.delete_outline_rounded, label: '删掉这条', color: cs.error),
                  const SizedBox(width: 8),
                  _Ghost(icon: Icons.blur_linear_rounded, label: '要求再模糊', color: cs.onSurface),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: FilledButton(
                        onPressed: () {},
                        style: FilledButton.styleFrom(padding: EdgeInsets.zero),
                        child: const Text('同意放行'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RawLine extends StatelessWidget {
  const _RawLine(this.spans);
  final List<Span> spans;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color base = theme.colorScheme.onSurface.withValues(alpha: 0.72);
    return Text.rich(
      TextSpan(
        children: [
          for (final Span s in spans)
            if (s.reason == null)
              TextSpan(text: s.text)
            else
              TextSpan(
                text: s.text,
                style: TextStyle(
                  color: s.reason!.color,
                  decoration: TextDecoration.lineThrough,
                  decorationColor: s.reason!.color.withValues(alpha: 0.7),
                  backgroundColor: s.reason!.color.withValues(alpha: theme.isDark ? 0.12 : 0.14),
                ),
              ),
        ],
      ),
      style: TextStyle(fontSize: 14, height: 1.5, color: base),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend(this.r);
  final Redaction r;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: r.color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 5),
        Text(r.label, style: TextStyle(fontSize: 11.5, color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

/// 被标为「暴露角色」的一条:高亮 + 标签 + 保留 / 泛化 / 删去 三选一。
class _RoleFlagClaim extends StatelessWidget {
  const _RoleFlagClaim({required this.text});
  final String text;

  static const Color _amber = Color(0xFFE8B45A);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    Widget choice(String label, {bool selected = false}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: selected ? _amber.withValues(alpha: 0.22) : null,
        border: Border.all(color: _amber.withValues(alpha: selected ? 0.8 : 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          height: 1.3,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected ? cs.onSurface : cs.onSurfaceVariant,
        ),
      ),
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(LaresRadii.sm),
        color: _amber.withValues(alpha: theme.isDark ? 0.08 : 0.1),
        border: Border(left: BorderSide(color: _amber.withValues(alpha: 0.8), width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: TextStyle(
              fontFamily: ChathamType.serifCjk,
              fontSize: 14.5,
              height: 1.5,
              color: cs.onSurface.withValues(alpha: 0.92),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Pill(
                label: '暴露角色',
                icon: Icons.badge_outlined,
                color: _amber,
                filled: true,
                dense: true,
              ),
              const Spacer(),
              choice('保留'),
              const SizedBox(width: 5),
              choice('泛化', selected: true),
              const SizedBox(width: 5),
              choice('删去'),
            ],
          ),
        ],
      ),
    );
  }
}

/// 归属风险:分两类读者各给一个实测值,不合并成一个「安全」结论。
class _RiskMeter extends StatelessWidget {
  const _RiskMeter();

  static const Color _green = Color(0xFF6FD08C);
  static const Color _red = Color(0xFFE07A5F);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    Widget row({
      required IconData icon,
      required Color color,
      required String who,
      required String value,
      String? caption,
    }) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 15, color: color),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '$who：', style: TextStyle(color: cs.onSurfaceVariant)),
                    TextSpan(
                      text: value,
                      style: TextStyle(color: color, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                style: const TextStyle(fontSize: 12, height: 1.4),
              ),
              if (caption != null)
                Text(caption, style: TextStyle(fontSize: 11, height: 1.4, color: theme.faint)),
            ],
          ),
        ),
      ],
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(color: cs.surface, borderRadius: BorderRadius.circular(LaresRadii.md)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('归属风险', style: TextStyle(fontSize: 14, color: cs.onSurface, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('实测 · 两类读者', style: TextStyle(fontSize: 11, color: theme.faint)),
            ],
          ),
          const SizedBox(height: 8),
          row(
            icon: Icons.check_circle_outline_rounded,
            color: _green,
            who: '局外人（无名单）',
            value: '0/35 人可被认出',
          ),
          const SizedBox(height: 6),
          row(
            icon: Icons.warning_amber_rounded,
            color: _red,
            who: '知情者（知道名单与职务）',
            // 不换行字符:整段数值一起折到下一行,不拆开。
            value: '72%\u00A0vs\u00A0随\u2060机\u00A020%',
            caption: '知道名单的人大概率仍能认出；n≈60，±11pp',
          ),
        ],
      ),
    );
  }
}

class _Ghost extends StatelessWidget {
  const _Ghost({required this.icon, required this.label, required this.color});
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(LaresRadii.md),
        color: theme.colorScheme.surfaceContainerHighest,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 17, color: color.withValues(alpha: 0.85)),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(fontSize: 13.5, color: color.withValues(alpha: 0.9))),
        ],
      ),
    );
  }
}
