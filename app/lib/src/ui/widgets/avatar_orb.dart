import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../state/ai_member.dart';
import '../../state/ai_state.dart';
import '../../state/models.dart';
import '../../theme/tokens.dart';
import 'ai_orb.dart';
import 'speaking_ripple.dart';

/// 说话光晕的不透明度与模糊半径(相对头像直径)。
const double _speakingGlowAlpha = 0.45;
const double _speakingGlowBlur = 0.28;

/// AI 状态的一句人话(座位状态字 / 读屏)。
String aiActivityLabel(AppLocalizations t, AiActivity a) => switch (a) {
      AiActivity.idle => t.aiVoiceSeatStatus,
      AiActivity.listening => t.aiStateListening,
      AiActivity.thinking => t.aiStateThinking,
      AiActivity.speaking => t.aiStateSpeaking,
    };

/// 成员头像球:状态色环 + 说话波纹 + 静音标记。
/// 这是房间内 UI 的最小单元,视觉语言是「人」,不是「会」。
///
/// AI 语音助手(userId 以 `u_ai_` 开头)换成 [AiOrb]:一团渐变的光,按 [aiActivity]
/// 呼吸 / 转弧 / 起波纹;状态字是「在听 / 在想… / 在说话 / AI 助手」。
class AvatarOrb extends StatelessWidget {
  const AvatarOrb({
    super.key,
    required this.member,
    required this.speaking,
    required this.muted,
    this.size = 88,
    this.compact = false,
    this.showName = true,
    this.aiActivity,
  });

  final Member member;
  final bool speaking;

  /// 仅对「我」有意义:显示自己的静音状态
  final bool muted;
  final double size;

  /// 紧凑形态(聊天展开 / 字幕开着时的顶部语音条):名字变小、不显示状态字。
  /// 状态仍由色环表达,说话波纹照常 —— 「谁在说话」任何时候都看得见。
  final bool compact;

  /// 键盘弹起、竖向空间极紧时连名字也收起,只留头像球。
  final bool showName;

  /// 仅对 AI 成员有意义:它此刻在干什么。null = 按 [speaking] 推断
  /// (在说话 → speaking,否则 listening)。房间页传 `controller.aiState(id)`。
  final AiActivity? aiActivity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bool ai = isAiMemberId(member.userId);
    if (ai) return _buildAi(context, theme);
    final String statusLabel = member.status.label;
    final Color statusColor = member.status.color;
    return Semantics(
      label: '${member.name} · $statusLabel${speaking ? ' · 正在说话' : ''}',
      excludeSemantics: true,
      child: SizedBox(
        width: size + 24,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: size + 16,
              height: size + 16,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SpeakingRipple(speaking: speaking, size: size + 16),
                  Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: statusColor,
                        width: 2.5,
                      ),
                      color: theme.colorScheme.surface,
                      // 说话时一圈暖光:波纹是动态的,光晕是静态的 ——
                      // 截图、低动效模式下也能一眼认出谁在说话。
                      boxShadow: speaking
                          ? [
                              BoxShadow(
                                color: LaresColors.ember.withValues(
                                  alpha: _speakingGlowAlpha,
                                ),
                                blurRadius: size * _speakingGlowBlur,
                                spreadRadius: 1,
                              ),
                            ]
                          : null,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      _initial(member.name),
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontSize: size * 0.36,
                      ),
                    ),
                  ),
                  if (muted)
                    Positioned(
                      right: compact ? 2 : 6,
                      bottom: compact ? 2 : 6,
                      child: Container(
                        padding: EdgeInsets.all(compact ? 2 : 4),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: theme.colorScheme.surface,
                        ),
                        child: Icon(
                          Icons.mic_off_rounded,
                          size: compact ? 12 : 16,
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            ..._nameAndStatus(theme, statusLabel, statusColor),
          ],
        ),
      ),
    );
  }

  Widget _buildAi(BuildContext context, ThemeData theme) {
    final t = AppLocalizations.of(context);
    final AiActivity activity = aiActivity ??
        (speaking ? AiActivity.speaking : AiActivity.listening);
    final String statusLabel = aiActivityLabel(t, activity);
    final bool dark = theme.brightness == Brightness.dark;
    // 状态字:说话时余烬色(与真人说话同色);在听 / 在想用光球的杏色 / 梅紫;闲着淡灰
    final Color statusColor = switch (activity) {
      AiActivity.idle => theme.colorScheme.onSurfaceVariant,
      AiActivity.speaking => LaresColors.ember,
      _ => dark ? LaresColors.aiGlow : LaresColors.aiPlum,
    };
    // 「AI」小牌:不再压在光球的环上,挪到状态字(紧凑时是名字)前面;
    // 用反色底(深色主题浅底深字、浅色主题深底浅字),两套主题都清楚。
    final Widget badge = Container(
      key: const ValueKey('seat-ai-badge'),
      padding: EdgeInsets.symmetric(horizontal: compact ? 3 : 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.inverseSurface,
        borderRadius: BorderRadius.circular(LaresRadii.sm),
      ),
      child: Text(
        t.aiVoiceSeatBadge,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onInverseSurface,
          fontSize: compact ? 9 : 10,
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
      ),
    );
    return Semantics(
      label: t.aiOrbSemantics(member.name, statusLabel),
      excludeSemantics: true,
      child: SizedBox(
        width: size + 24,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: size + 16,
              height: size + 16,
              child: Center(child: AiOrb(activity: activity, size: size)),
            ),
            ..._nameAndStatus(
              theme,
              statusLabel,
              statusColor,
              statusKey: ValueKey('ai-orb-status-${activity.name}'),
              speakingName: activity == AiActivity.speaking,
              badge: badge,
            ),
          ],
        ),
      ),
    );
  }
  List<Widget> _nameAndStatus(
    ThemeData theme,
    String statusLabel,
    Color statusColor, {
    Key? statusKey,
    bool? speakingName,
    Widget? badge,
  }) {
    final bool lit = speakingName ?? speaking;
    // 带小牌的一行:小牌 + 文字居中,文字太长时只截文字
    Widget withBadge(Widget text) => badge == null
        ? text
        : Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              badge,
              const SizedBox(width: LaresSpacing.xs),
              Flexible(child: text),
            ],
          );
    final Widget name = Text(
      member.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: compact
          ? theme.textTheme.bodyMedium?.copyWith(
              fontSize: 13,
              color: lit ? theme.colorScheme.onSurface : null,
            )
          : theme.textTheme.bodyLarge,
    );
    final Widget status = Text(
      statusLabel,
      key: statusKey,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: statusColor,
        fontSize: 12,
      ),
    );
    // 小牌跟着状态字走;紧凑(没有状态字)时跟名字;连名字都不显示时单独一行
    return [
      if (showName) ...[
        SizedBox(height: compact ? LaresSpacing.xs : LaresSpacing.sm),
        compact ? withBadge(name) : name,
      ],
      if (!compact) withBadge(status),
      if (compact && !showName && badge != null) ...[
        const SizedBox(height: LaresSpacing.xs),
        badge,
      ],
    ];
  }

  static String _initial(String name) =>
      name.isEmpty ? '?' : name.characters.first;
}
