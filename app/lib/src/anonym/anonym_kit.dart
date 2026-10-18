/// 隐名之约(受 Chatham House 规则启发 · 非官方)的共用视觉零件:
/// 约印、约带、眉标、胶囊、规则原文。设计预览(lib/src/chatham_preview)也从这里取。
///
/// 规则原文是 chathamhouse.org 公布的英文与官方中文译文,逐字引用,不得改写,
/// 因此不进 l10n。
library;

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

extension ChathamTheme on ThemeData {
  bool get isDark => brightness == Brightness.dark;

  /// 正文辅色(比 onSurfaceVariant 再退半步,给脚注用)。
  Color get faint =>
      colorScheme.onSurface.withValues(alpha: isDark ? 0.42 : 0.5);

  Color get hairline =>
      colorScheme.onSurface.withValues(alpha: isDark ? 0.09 : 0.1);

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
    final Color ink = LaresColors.ember.withValues(
      alpha: theme.isDark ? 0.9 : 1,
    );
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
      canvas.drawCircle(
        c + Offset(math.cos(a), math.sin(a)) * (r - 4),
        1.1,
        dot,
      );
    }
  }

  @override
  bool shouldRepaint(_SealPainter old) => old.ink != ink;
}

/// 房间顶部那条约带:两侧发丝线 + 居中小字。
class RuleBand extends StatelessWidget {
  const RuleBand({
    super.key,
    this.latin = 'RULE-INSPIRED',
    this.zh = '隐名之约 · 非官方',
  });

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
    return LayoutBuilder(
      builder: (context, c) => Row(
        children: [
          line(true),
          const SizedBox(width: LaresSpacing.sm),
          const RuleSeal(size: 18, years: false),
          const SizedBox(width: LaresSpacing.sm),
          // 窄屏 / 大字号时整条可省略,不撑破
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth:
                  (c.maxWidth - 2 * LaresSpacing.sm - 18 - LaresSpacing.sm - 24)
                      .clamp(0, double.infinity),
            ),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: latin,
                    style: TextStyle(
                      fontFamily: ChathamType.serifLatin,
                      fontSize: 10.5,
                      letterSpacing: 2.2,
                      color: ink,
                    ),
                  ),
                  TextSpan(
                    text: '  ·  $zh',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.2,
                      color: ink,
                    ),
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: LaresSpacing.sm),
          line(false),
        ],
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
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 7 : 10,
        vertical: dense ? 2 : 5,
      ),
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

const String kRuleEn =
    'When a meeting, or part thereof, is held under the Chatham House Rule, '
    'participants are free to use the information received, but neither the '
    'identity nor the affiliation of the speaker(s), nor that of any other '
    'participant, may be revealed.';

/// 官方中文译文(chathamhouse.org),逐字引用,不得改写。
const String kRuleZh =
    '如果一个会议，或会议的一部分，是按照Chatham House规则进行的，'
    '则与会者可自由使用在会议中获得的信息，但不得透露演讲者及其他与会者的身份与所属机构。';
