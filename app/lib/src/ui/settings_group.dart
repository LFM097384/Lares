/// 设置页的分组容器 —— 一个小标题 + 一组条目。
///
/// 为什么要分组:设置页原本是十来个 ListTile 平铺的一长串,滚起来找不到东西。
/// 这里**只做结构性整理**,不引入新的视觉语言:小标题用的是现成的
/// `textTheme.labelLarge` 与品牌色 ember,间距全部来自 tokens.dart。
/// (整体 UI 重设计另有其人在做,这里刻意不抢戏。)
///
/// 设计纪律(设计.md §8.2):不硬编码颜色/圆角/间距,一律引用 tokens.dart。
library;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// 一组设置项,带一个中文小标题。
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    required this.title,
    required this.children,
    this.caption,
  });

  /// 小标题(中文,语气跟着产品走:是「说人话」而不是「系统设置」)
  final String title;

  /// 标题下面的一句说明;不需要时留空。
  final String? caption;

  /// 组内条目。为空时整组不渲染(免得留下一个孤零零的标题)。
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            left: LaresSpacing.md,
            right: LaresSpacing.md,
            top: LaresSpacing.lg,
            bottom: LaresSpacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                // labelLarge 已是 w600;这里只染上品牌色,让小标题在
                // 一长串 ListTile 里能被一眼扫到,但不至于喧宾夺主。
                style: theme.textTheme.labelLarge?.copyWith(
                  color: LaresColors.ember,
                ),
              ),
              if (caption != null) ...[
                const SizedBox(height: LaresSpacing.xs),
                Text(caption!, style: theme.textTheme.bodyMedium),
              ],
            ],
          ),
        ),
        ...children,
      ],
    );
  }
}
