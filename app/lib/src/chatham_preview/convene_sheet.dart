// ① 开圈面板:圈主选一档「不具名」的开法,开始后锁定。
//
// 两档,刻意分开、刻意不混用措辞:
//  - 守则时段:按 Chatham House 规则的公开文本进行 —— 不许 AI 记录、
//    不许转写、不许录音录像。Lares 只给声音。
//  - 隐名之约 (受规则启发 · 非官方):本机转写 + 守门人 + k/n 放行。
//    这一档**永远不叫** "under the Chatham House Rule"。
// 不写纪念年份、不写「官方」;页脚声明与 Chatham House 无隶属关系。
import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'chatham_data.dart';
import 'chatham_kit.dart';

enum Tier { strict, veiled }

class ConveneSheetPreview extends StatelessWidget {
  const ConveneSheetPreview({super.key, this.tier = Tier.veiled});
  final Tier tier;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.isDark ? const Color(0xFF0B0A0E) : const Color(0xFF8E8790),
      body: Column(
        children: [
          SizedBox(height: MediaQuery.paddingOf(context).top + 12),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: theme.scaffoldBackgroundColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(LaresRadii.xl)),
              ),
              child: _SheetBody(tier: tier),
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetBody extends StatelessWidget {
  const _SheetBody({required this.tier});
  final Tier tier;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bool strict = tier == Tier.strict;
    return Column(
      children: [
        const SizedBox(height: 10),
        Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(color: theme.hairline, borderRadius: BorderRadius.circular(2)),
        ),
        Expanded(
          child: ListView(
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(LaresSpacing.lg, LaresSpacing.md, LaresSpacing.lg, 0),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Overline('周四夜谈 · 开圈'),
                        const SizedBox(height: 6),
                        Text('不具名地聊', style: theme.textTheme.headlineMedium?.copyWith(fontSize: 26)),
                      ],
                    ),
                  ),
                  const RuleSeal(size: 54, years: false),
                ],
              ),
              const SizedBox(height: LaresSpacing.md),
              const _RuleCard(),
              const SizedBox(height: LaresSpacing.md),
              Row(
                children: [
                  const Overline('选一档 · 整场适用 · 开始后不可切换'),
                  const Spacer(),
                  Icon(Icons.lock_clock_outlined, size: 13, color: theme.faint),
                ],
              ),
              const SizedBox(height: LaresSpacing.sm),
              _TierOption(
                selected: strict,
                title: '守则时段',
                latin: 'Chatham House Rule',
                line: '按规则公开文本进行：只有人声，AI 离席，不转写、不录音。',
                facts: const <(IconData, String)>[
                  (Icons.blur_off_rounded, 'AI 离席'),
                  (Icons.closed_caption_disabled_outlined, '无字幕'),
                  (Icons.schedule_rounded, '整场'),
                ],
              ),
              const SizedBox(height: LaresSpacing.sm),
              _TierOption(
                selected: !strict,
                title: '隐名之约',
                latin: 'Rule-inspired · 非官方',
                line: '字幕只在本机内存，圈内 AI 答完即忘；出门稿经守门人去名，众人点头才放行。',
                facts: const <(IconData, String)>[
                  (Icons.graphic_eq_rounded, '本机字幕'),
                  (Icons.how_to_vote_outlined, '4/5 放行'),
                  (Icons.shield_outlined, '安全员'),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            LaresSpacing.lg,
            LaresSpacing.sm,
            LaresSpacing.lg,
            MediaQuery.paddingOf(context).bottom + LaresSpacing.xs,
          ),
          child: Column(
            children: [
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: () {},
                  child: Text(strict ? '开始守则时段' : '立约开圈'),
                ),
              ),
              const SizedBox(height: LaresSpacing.sm),
              Text(
                'Lares 与 Chatham House 无隶属关系',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: theme.faint),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TierOption extends StatelessWidget {
  const _TierOption({
    required this.selected,
    required this.title,
    required this.latin,
    required this.line,
    required this.facts,
  });
  final List<(IconData, String)> facts;
  final bool selected;
  final String title;
  final String latin;
  final String line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      decoration: BoxDecoration(
        color: selected
            ? Color.alphaBlend(LaresColors.ember.withValues(alpha: theme.isDark ? 0.08 : 0.07), cs.surface)
            : cs.surface,
        borderRadius: BorderRadius.circular(LaresRadii.md),
        border: Border.all(
          color: selected ? LaresColors.ember.withValues(alpha: 0.7) : theme.hairline,
          width: selected ? 1.4 : 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: selected ? LaresColors.ember : theme.faint, width: 1.5),
              ),
              alignment: Alignment.center,
              child: selected
                  ? Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(shape: BoxShape.circle, color: LaresColors.ember),
                    )
                  : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(title, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: cs.onSurface)),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        latin,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: ChathamType.serifLatin,
                          fontFamilyFallback: const <String>['Msyh'],
                          fontStyle: FontStyle.italic,
                          fontSize: 12,
                          color: theme.faint,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(line, style: TextStyle(fontSize: 12.5, height: 1.5, color: cs.onSurfaceVariant)),
                if (selected) const SizedBox(height: 8),
                if (selected) Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final (IconData i, String t) in facts)
                      Container(
                        padding: const EdgeInsets.fromLTRB(7, 3, 8, 3),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: selected
                              ? LaresColors.ember.withValues(alpha: theme.isDark ? 0.12 : 0.1)
                              : cs.onSurface.withValues(alpha: 0.05),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(i, size: 12, color: selected ? LaresColors.ember : theme.faint),
                            const SizedBox(width: 4),
                            Text(
                              t,
                              style: TextStyle(
                                fontSize: 11,
                                color: selected ? cs.onSurface.withValues(alpha: 0.85) : theme.faint,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RuleCard extends StatelessWidget {
  const _RuleCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      decoration: BoxDecoration(
        color: theme.isDark
            ? Color.alphaBlend(LaresColors.ember.withValues(alpha: 0.05), cs.surface)
            : const Color(0xFFFFFBF6),
        borderRadius: BorderRadius.circular(LaresRadii.md + 4),
        border: Border.all(color: LaresColors.ember.withValues(alpha: theme.isDark ? 0.16 : 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Overline('THE CHATHAM HOUSE RULE', color: LaresColors.ember.withValues(alpha: 0.85)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            kRuleEn,
            style: TextStyle(
              fontFamily: ChathamType.serifLatin,
              fontStyle: FontStyle.italic,
              fontSize: 12,
              height: 1.4,
              color: cs.onSurface.withValues(alpha: 0.86),
            ),
          ),
          const SizedBox(height: 8),
          Container(width: 24, height: 1, color: LaresColors.ember.withValues(alpha: 0.4)),
          const SizedBox(height: 8),
          Text(
            kRuleZh,
            style: TextStyle(
              fontFamily: ChathamType.serifCjk,
              fontSize: 12.5,
              height: 1.6,
              color: cs.onSurface.withValues(alpha: 0.78),
            ),
          ),
        ],
      ),
    );
  }
}
