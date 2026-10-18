// 两档「不具名」圈的概念稿共用零件:
//  - 守则时段:按 Chatham House 规则公开文本进行,只有声音(不暗示背书);
//  - 隐名之约(受规则启发 · 非官方):本机转写 + 守门人 + k/n 放行。
//
// 这是设计预览,不是上线功能:字符串全部写死,不走 l10n;
// 只被 test/chatham_concept_screenshots_test.dart 用来出图。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// 预览专用的字族名。截图脚手架会把 Georgia / 华文宋体注册成这两个名字;
/// 真机上找不到就回落到系统字体,不会出错。
abstract final class ChathamType {
  static const String serifLatin = 'LaresSerifLatin';
  static const String serifCjk = 'LaresSerifCjk';
  static const String mono = 'monospace';
}

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

extension ChathamTheme on ThemeData {
  bool get isDark => brightness == Brightness.dark;

  /// 正文辅色(比 onSurfaceVariant 再退半步,给脚注用)。
  Color get faint => colorScheme.onSurface.withValues(alpha: isDark ? 0.42 : 0.5);

  Color get hairline => colorScheme.onSurface.withValues(alpha: isDark ? 0.09 : 0.1);

  /// 卡片底:暗色是比背景略亮的暖灰,亮色是纯白。
  Color get card => colorScheme.surface;
}

/// 小号字距拉开的英文/中文眉标,如「THE CHATHAM HOUSE RULE」。
class Overline extends StatelessWidget {
  const Overline(this.text, {super.key, this.color, this.align});
  final String text;
  final Color? color;
  final TextAlign? align;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      textAlign: align,
      style: TextStyle(
        fontSize: 10.5,
        letterSpacing: 1.6,
        fontWeight: FontWeight.w600,
        color: color ?? theme.faint,
        height: 1.2,
      ),
    );
  }
}

/// 约印:两道细环 + 中间一个宋体「约」;years 时上方标 1927(规则起始年,仅作史实)。
class RuleSeal extends StatelessWidget {
  const RuleSeal({super.key, this.size = 56, this.years = true});
  final double size;
  final bool years;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color ink = LaresColors.ember.withValues(alpha: theme.isDark ? 0.9 : 1);
    // 小号印章写不下「约」,只留双环 + 一点。
    if (size < 28) {
      return SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _SealPainter(ink),
          child: Center(
            child: Container(
              width: size * 0.22,
              height: size * 0.22,
              decoration: BoxDecoration(shape: BoxShape.circle, color: ink),
            ),
          ),
        ),
      );
    }
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _SealPainter(ink),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (years)
                Text(
                  '1927',
                  style: TextStyle(
                    fontFamily: ChathamType.serifLatin,
                    fontSize: size * 0.13,
                    letterSpacing: 0.6,
                    color: ink.withValues(alpha: 0.75),
                    height: 1,
                  ),
                ),
              Text(
                '约',
                style: TextStyle(
                  fontFamily: ChathamType.serifCjk,
                  fontSize: size * (years ? 0.34 : 0.44),
                  color: ink,
                  height: 1.15,
                ),
              ),

            ],
          ),
        ),
      ),
    );
  }
}

class _SealPainter extends CustomPainter {
  _SealPainter(this.ink);
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double r = size.shortestSide / 2;
    canvas.drawCircle(
      c,
      r - 0.75,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = ink.withValues(alpha: 0.85),
    );
    canvas.drawCircle(
      c,
      r - 4,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6
        ..color = ink.withValues(alpha: 0.45),
    );
    // 内环上四个刻点,像印泥压出的小缺口
    final Paint dot = Paint()..color = ink.withValues(alpha: 0.6);
    for (int i = 0; i < 4; i++) {
      final double a = math.pi / 4 + i * math.pi / 2;
      canvas.drawCircle(c + Offset(math.cos(a), math.sin(a)) * (r - 4), 1.1, dot);
    }
  }

  @override
  bool shouldRepaint(_SealPainter old) => old.ink != ink;
}

/// 房间顶部那条约带:两侧发丝线 + 居中小字。
class RuleBand extends StatelessWidget {
  const RuleBand({super.key, this.latin = 'RULE-INSPIRED', this.zh = '隐名之约 · 非官方'});

  /// 守则时段传 'CHATHAM HOUSE' / '守则时段';不写 Under the Rule 以免暗示背书。
  final String latin;
  final String zh;

  @override
  Widget build(BuildContext context) {
    final Color ink = LaresColors.ember.withValues(alpha: 0.75);
    Widget line(bool left) => Expanded(
      child: Container(
        height: 1,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: left
                ? [ink.withValues(alpha: 0), ink.withValues(alpha: 0.5)]
                : [ink.withValues(alpha: 0.5), ink.withValues(alpha: 0)],
          ),
        ),
      ),
    );
    return Row(
      children: [
        line(true),
        const SizedBox(width: LaresSpacing.sm),
        const RuleSeal(size: 18, years: false),
        const SizedBox(width: LaresSpacing.sm),
        Text(
          latin,
          style: TextStyle(
            fontFamily: ChathamType.serifLatin,
            fontSize: 10.5,
            letterSpacing: 2.2,
            color: ink,
          ),
        ),
        Text(
          '  ·  $zh',
          style: TextStyle(fontSize: 11, letterSpacing: 1.2, color: ink),
        ),
        const SizedBox(width: LaresSpacing.sm),
        line(false),
      ],
    );
  }
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

/// 一颗胶囊小牌:图标 + 字。
class Pill extends StatelessWidget {
  const Pill({
    super.key,
    required this.label,
    this.icon,
    this.color,
    this.filled = false,
    this.dense = false,
  });
  final String label;
  final IconData? icon;
  final Color? color;
  final bool filled;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color c = color ?? theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 7 : 10, vertical: dense ? 2 : 5),
      decoration: BoxDecoration(
        color: c.withValues(alpha: filled ? 0.16 : 0),
        border: Border.all(color: c.withValues(alpha: filled ? 0 : 0.35)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: dense ? 11 : 13, color: c),
            SizedBox(width: dense ? 3 : 5),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: dense ? 10.5 : 12,
              color: c,
              fontWeight: FontWeight.w500,
              height: 1.3,
            ),
          ),
        ],
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
