import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../state/ai_member.dart';
import '../../state/models.dart';
import '../../theme/tokens.dart';
import 'speaking_ripple.dart';

/// 说话光晕的不透明度与模糊半径(相对头像直径)。
const double _speakingGlowAlpha = 0.45;
const double _speakingGlowBlur = 0.28;

/// 成员头像球:状态色环 + 说话波纹 + 静音标记。
/// 这是房间内 UI 的最小单元,视觉语言是「人」,不是「会」。
class AvatarOrb extends StatelessWidget {
  const AvatarOrb({
    super.key,
    required this.member,
    required this.speaking,
    required this.muted,
    this.size = 88,
    this.compact = false,
    this.showName = true,
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // AI 语音助手:没有「随时聊 / 在忙」这类人的状态,换成「AI 助手」。
    final bool ai = isAiMemberId(member.userId);
    final t = ai ? AppLocalizations.of(context) : null;
    final String statusLabel = ai ? t!.aiVoiceSeatStatus : member.status.label;
    final Color statusColor =
        ai ? theme.colorScheme.tertiary : member.status.color;
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
                  if (ai)
                    Positioned(
                      left: compact ? 0 : 4,
                      top: compact ? 0 : 4,
                      child: Container(
                        key: const ValueKey('seat-ai-badge'),
                        padding: EdgeInsets.symmetric(
                          horizontal: compact ? 4 : 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.tertiary,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          t!.aiVoiceSeatBadge,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onTertiary,
                            fontSize: compact ? 9 : 11,
                            fontWeight: FontWeight.w600,
                          ),
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
            if (showName) ...[
              SizedBox(height: compact ? LaresSpacing.xs : LaresSpacing.sm),
              Text(
                member.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: compact
                    ? theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 13,
                        color: speaking ? theme.colorScheme.onSurface : null,
                      )
                    : theme.textTheme.bodyLarge,
              ),
            ],
            if (!compact)
              Text(
                statusLabel,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: statusColor,
                  fontSize: 12,
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _initial(String name) =>
      name.isEmpty ? '?' : name.characters.first;
}
