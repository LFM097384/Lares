import 'package:flutter/material.dart';

import '../../state/models.dart';
import '../../theme/tokens.dart';
import 'speaking_ripple.dart';

/// 成员头像球:状态色环 + 说话波纹 + 静音标记。
/// 这是房间内 UI 的最小单元,视觉语言是「人」,不是「会」。
class AvatarOrb extends StatelessWidget {
  const AvatarOrb({
    super.key,
    required this.member,
    required this.speaking,
    required this.muted,
    this.size = 88,
  });

  final Member member;
  final bool speaking;

  /// 仅对「我」有意义:显示自己的静音状态
  final bool muted;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label:
          '${member.name} · ${member.status.label}${speaking ? ' · 正在说话' : ''}',
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
                      color: member.status.color,
                      width: 2.5,
                    ),
                    color: theme.colorScheme.surface,
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
                    right: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: theme.colorScheme.surface,
                      ),
                      child: Icon(
                        Icons.mic_off_rounded,
                        size: 16,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: LaresSpacing.sm),
          Text(
            member.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge,
          ),
          Text(
            member.status.label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: member.status.color,
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
