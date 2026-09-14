import 'package:flutter/material.dart';

import '../../e2ee/e2ee_status.dart';
import '../../theme/tokens.dart';

// ── 就地常量 ──
// tokens.dart 没有「图标尺寸」这一档,与 room_screen.dart 里的做法保持一致。

/// 加密角标的图标尺寸,与房间页的其它状态角标同量级。
const double _e2eeBadgeIconSize = 16;

/// E2EE 状态角标。
///
/// 纪律:这是**安全状态展示**,含糊即 bug。所以:
/// - 真加密了 -> 一把实心锁 + 「端到端加密」,用品牌暖橙(§8.2 安静但明确);
/// - 开了却没加密 -> **破锁 + 醒目告警色 + 写明原因**,绝不做成灰色小字;
/// - 没开 -> **什么都不画**。给未加密的圈子挂一个「未加密」小标,
///   久了就成了背景噪音,反而稀释了上面那条真正的告警。
class E2EEBadge extends StatelessWidget {
  const E2EEBadge({super.key, required this.status, this.compact = false});

  final E2EEStatus status;

  /// 紧凑模式:只画图标(列表行 / 房间头部用),说明走 Tooltip。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (status == E2EEStatus.disabled) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final bool ok = status.isEncrypted;
    final Color color = ok ? LaresColors.ember : theme.colorScheme.error;
    final IconData icon =
        ok ? Icons.lock_rounded : Icons.lock_open_rounded;

    if (compact) {
      return Tooltip(
        message: '${status.shortLabel}\n${status.explanation}',
        child: Icon(icon, size: _e2eeBadgeIconSize, color: color),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: LaresSpacing.sm,
        vertical: LaresSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(LaresRadii.sm),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: _e2eeBadgeIconSize, color: color),
          const SizedBox(width: LaresSpacing.xs),
          Flexible(
            child: Text(
              status.shortLabel,
              style: theme.textTheme.bodyMedium?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「开了却没加密」时的整条横幅。房间页用 —— 一个小角标不足以承载
/// 「你以为加密了但其实没有」这条消息的分量。
class E2EEWarningBanner extends StatelessWidget {
  const E2EEWarningBanner({super.key, required this.status});

  final E2EEStatus status;

  @override
  Widget build(BuildContext context) {
    if (!status.isBrokenPromise) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final color = theme.colorScheme.error;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LaresSpacing.lg,
        LaresSpacing.sm,
        LaresSpacing.lg,
        0,
      ),
      child: Container(
        padding: const EdgeInsets.all(LaresSpacing.md),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(LaresRadii.md),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.lock_open_rounded,
                size: _e2eeBadgeIconSize, color: color),
            const SizedBox(width: LaresSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    status.shortLabel,
                    style: theme.textTheme.bodyLarge?.copyWith(color: color),
                  ),
                  const SizedBox(height: LaresSpacing.xs),
                  Text(status.explanation,
                      style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
