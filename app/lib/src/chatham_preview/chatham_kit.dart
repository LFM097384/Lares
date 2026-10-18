// 两档「不具名」圈的概念稿共用零件:
//  - 守则时段:按 Chatham House 规则公开文本进行,只有声音(不暗示背书);
//  - 隐名之约(受规则启发 · 非官方):本机转写 + 守门人 + k/n 放行。
//
// 这是设计预览,不是上线功能:字符串全部写死,不走 l10n;
// 只被 test/chatham_concept_screenshots_test.dart 用来出图。
import 'package:flutter/material.dart';

import '../anonym/anonym_kit.dart';
import '../theme/tokens.dart';

export '../anonym/anonym_kit.dart' hide kRuleEn, kRuleZh;

/// 守门人删改的四类理由,各配一个同族低饱和色(不另起冷色相)。
enum Redaction {
  identity('身份', Color(0xFFFF8A5C)),
  org('机构', Color(0xFFD08FC0)),
  detail('可识别细节', Color(0xFFE8B45A)),
  quote('原话', Color(0xFF8FB6D4));

  const Redaction(this.label, this.color);
  final String label;
  final Color color;
}


/// 「隐名」座位球:不用 presence 色环,统一一道暖色发丝环;
/// 字是名字首字,名字只在圈内渲染。
class VeiledOrb extends StatelessWidget {
  const VeiledOrb({
    super.key,
    required this.glyph,
    this.name,
    this.size = 64,
    this.speaking = false,
    this.lit = false,
    this.dim = false,
    this.badge,
    this.verified = false,
  });

  /// 名字前加一枚小盾勾「已核验」。
  final bool verified;

  final String glyph;
  final String? name;
  final double size;
  final bool speaking;

  /// 同意放行等「点亮」状态:实心余烬底。
  final bool lit;

  /// 还没表态:更暗、环线变虚。
  final bool dim;

  /// 右下角小徽(安全员的盾、已同意的勾)。
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final Color ring = lit
        ? LaresColors.ember
        : speaking
        ? LaresColors.ember.withValues(alpha: 0.9)
        : cs.onSurface.withValues(alpha: dim ? 0.14 : 0.24);
    final Widget ball = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: ring, width: lit || speaking ? 1.8 : 1.2),
        gradient: lit
            ? const RadialGradient(
                center: Alignment(-0.3, -0.4),
                colors: [Color(0xFFFFB08A), LaresColors.ember],
              )
            : RadialGradient(
                center: const Alignment(-0.3, -0.4),
                colors: [
                  Color.alphaBlend(
                    cs.onSurface.withValues(alpha: theme.isDark ? 0.07 : 0.03),
                    cs.surface,
                  ),
                  cs.surface,
                ],
              ),
        boxShadow: [
          if (speaking || lit)
            BoxShadow(
              color: LaresColors.ember.withValues(alpha: lit ? 0.35 : 0.4),
              blurRadius: size * 0.32,
              spreadRadius: 1,
            ),
        ],
      ),
      child: Text(
        glyph,
        style: TextStyle(
          fontFamily: ChathamType.serifCjk,
          fontSize: size * 0.36,
          height: 1.1,
          color: lit
              ? const Color(0xFF2A1408)
              : cs.onSurface.withValues(alpha: dim ? 0.4 : 0.85),
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size + 10,
          height: size + 10,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (speaking)
                Container(
                  width: size + 10,
                  height: size + 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: LaresColors.ember.withValues(alpha: 0.22),
                      width: 1,
                    ),
                  ),
                ),
              ball,
              if (badge != null) Positioned(right: 1, bottom: 1, child: badge!),
            ],
          ),
        ),
        if (name != null) ...[
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (verified) ...[
                Icon(Icons.verified_user_rounded, size: 11, color: const Color(0xFF6FD08C).withValues(alpha: 0.85)),
                const SizedBox(width: 3),
              ],
              Text(
                name!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: speaking || lit ? cs.onSurface : cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// 小圆徽(座位右下角)。
class OrbBadge extends StatelessWidget {
  const OrbBadge({super.key, required this.icon, this.filled = false});
  final IconData icon;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? LaresColors.ember : theme.colorScheme.surfaceContainerHighest,
        border: Border.all(color: theme.scaffoldBackgroundColor, width: 2),
      ),
      child: Icon(
        icon,
        size: 11,
        color: filled ? const Color(0xFF2A1408) : theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}


/// 守门人计数:一扇门 + 「0 出门」。
class GateIndicator extends StatelessWidget {
  const GateIndicator({super.key, this.count = 0, this.pending = 0});
  final int count;
  final int pending;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 5, 10, 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.7),
        border: Border.all(color: theme.hairline),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.door_front_door_outlined, size: 15, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 5),
          Text('守门人', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
              height: 1.1,
            ),
          ),
          Text(' 出门', style: TextStyle(fontSize: 12, color: theme.faint)),
          if (pending > 0) ...[
            const SizedBox(width: 6),
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(shape: BoxShape.circle, color: LaresColors.ember),
            ),
          ],
        ],
      ),
    );
  }
}

/// 预览里用的房间底:与 RoomScreen 的呼吸背景同参,但静止。
class HearthBackground extends StatelessWidget {
  const HearthBackground({super.key, required this.child, this.glow = 0.08});
  final Widget child;
  final double glow;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).scaffoldBackgroundColor;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -0.75),
          radius: 1.15,
          colors: [LaresColors.ember.withValues(alpha: glow), base],
        ),
      ),
      child: child,
    );
  }
}

/// 简化的 AI 光球(静态):杏色到梅紫的渐变。真 AiOrb 带动画,预览不需要。
class StillAiOrb extends StatelessWidget {
  const StillAiOrb({super.key, this.size = 28});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const RadialGradient(
          center: Alignment(-0.35, -0.4),
          colors: [Color(0xFFFFE3D1), LaresColors.aiGlow, LaresColors.ember, LaresColors.aiPlum],
          stops: [0, 0.3, 0.7, 1],
        ),
        boxShadow: [
          BoxShadow(color: LaresColors.aiGlow.withValues(alpha: 0.3), blurRadius: size * 0.5),
        ],
      ),
    );
  }
}

/// 预览屏的通用顶栏:返回 + 标题 + 副标题 + 右侧件。
class PreviewTopBar extends StatelessWidget {
  const PreviewTopBar({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.leading = Icons.arrow_back_rounded,
  });
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final IconData? leading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(LaresSpacing.sm, LaresSpacing.sm, LaresSpacing.md, 0),
      child: Row(
        children: [
          if (leading != null)
            IconButton(
              onPressed: () {},
              icon: Icon(leading, color: theme.colorScheme.onSurfaceVariant),
            )
          else
            const SizedBox(width: LaresSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13, height: 1.4),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
