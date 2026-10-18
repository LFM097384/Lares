/// 出门稿审阅页([AnonymGateScreen])与散会卡([AnonymEndCard])。
///
/// - 指标:服务器给什么显示什么;没给就整块不显示,绝不写死「≈随机」之类的结论。
/// - 放行:签名见 anonym_crypto.dart;只显示人数 / 门槛,不显示谁签了。
/// - 放行后的文本可复制(App 里没有系统分享通道,用剪贴板)。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/gen/app_localizations.dart';
import '../theme/tokens.dart';
import 'anonym_controller.dart';
import 'anonym_kit.dart';

/// 打开出门稿页。会话散了它自己关。
Future<void> openAnonymGate(BuildContext context, AnonymController anonym) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => AnonymGateScreen(anonym: anonym)),
  );
}

class AnonymGateScreen extends StatefulWidget {
  const AnonymGateScreen({super.key, required this.anonym});
  final AnonymController anonym;

  @override
  State<AnonymGateScreen> createState() => _AnonymGateScreenState();
}

class _AnonymGateScreenState extends State<AnonymGateScreen> {
  /// 本机在每条上点过的动作(只为高亮;权威结果是服务器发回的新稿)。
  final Map<String, AnonymReviewAction> _chosen = {};
  bool _popped = false;

  @override
  void initState() {
    super.initState();
    widget.anonym.addListener(_onChange);
  }

  void _onChange() {
    if (!widget.anonym.active && !_popped && mounted) {
      _popped = true;
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    widget.anonym.removeListener(_onChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.anonGateTitle),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: LaresSpacing.md),
            child: RuleSeal(size: 22, years: false),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.anonym,
        builder: (context, _) {
          final a = widget.anonym;
          final AnonymDraft? d = a.draft;
          final String? released = a.releasedText;
          return Column(
            children: [
              Expanded(
                child: ListView(
                  key: const ValueKey('anon-gate-list'),
                  padding: const EdgeInsets.fromLTRB(
                    LaresSpacing.lg,
                    LaresSpacing.sm,
                    LaresSpacing.lg,
                    LaresSpacing.lg,
                  ),
                  children: [
                    Overline(
                      t.anonInspired,
                      color: LaresColors.ember.withValues(alpha: 0.85),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      t.anonGateSubtitle,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: LaresSpacing.md),
                    if (d == null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 40),
                        child: Center(
                          child: Column(
                            children: [
                              const SizedBox.square(
                                dimension: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                t.anonDraftPending,
                                style: TextStyle(color: cs.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      )
                    else ...[
                      if (d.items.isEmpty)
                        Text(
                          t.anonDraftEmpty,
                          key: const ValueKey('anon-draft-empty'),
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                      for (final (i, group) in _byTopic(d.items).indexed) ...[
                        if (group.topic case final topic?)
                          Padding(
                            padding: EdgeInsets.only(
                              top: i == 0 ? 0 : LaresSpacing.sm,
                              bottom: 8,
                            ),
                            child: Text(
                              topic,
                              key: ValueKey('anon-topic-$i'),
                              style: TextStyle(
                                fontFamily: ChathamType.serifCjk,
                                fontSize: 16,
                                height: 1.4,
                                fontWeight: FontWeight.w600,
                                color: cs.onSurface,
                              ),
                            ),
                          ),
                        for (final item in group.items) ...[
                          AnonymDraftItemCard(
                            item: item,
                            chosen: _chosen[item.id],
                            enabled: released == null,
                            onAction: (act) {
                              setState(() => _chosen[item.id] = act);
                              a.review(item.id, act);
                            },
                          ),
                          const SizedBox(height: 10),
                        ],
                      ],
                      if (d.metrics.isNotEmpty) ...[
                        const SizedBox(height: LaresSpacing.sm),
                        _Metrics(metrics: d.metrics),
                      ],
                    ],
                    if (released != null) ...[
                      const SizedBox(height: LaresSpacing.md),
                      _Released(text: released),
                    ],
                  ],
                ),
              ),
              if (d != null && released == null) _ApproveBar(anonym: a),
            ],
          );
        },
      ),
    );
  }
}

/// 按 topic 分节,节序 = 首次出现的顺序(与服务器放行文本里 `## topic` 的分节一致)。
/// topic 原样显示;没给(null)的条目归一节、不带标题。
List<({String? topic, List<AnonymDraftItem> items})> _byTopic(
  List<AnonymDraftItem> items,
) {
  final List<({String? topic, List<AnonymDraftItem> items})> out = [];
  for (final it in items) {
    final int at = out.indexWhere((g) => g.topic == it.topic);
    if (at >= 0) {
      out[at].items.add(it);
    } else {
      out.add((topic: it.topic, items: [it]));
    }
  }
  return out;
}

class AnonymDraftItemCard extends StatelessWidget {
  const AnonymDraftItemCard({
    super.key,
    required this.item,
    required this.onAction,
    this.chosen,
    this.enabled = true,
  });

  final AnonymDraftItem item;
  final AnonymReviewAction? chosen;
  final bool enabled;
  final ValueChanged<AnonymReviewAction> onAction;

  static const Color _amber = Color(0xFFE8B45A);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final bool risk = item.roleRisk;
    Widget choice(AnonymReviewAction act, String label) {
      final bool selected = chosen == act;
      return InkWell(
        key: ValueKey('anon-review-${item.id}-${act.wire}'),
        borderRadius: BorderRadius.circular(999),
        onTap: enabled ? () => onAction(act) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: selected ? _amber.withValues(alpha: 0.22) : null,
            border: Border.all(
              color: _amber.withValues(alpha: selected ? 0.8 : 0.35),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              height: 1.3,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? cs.onSurface : cs.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return Container(
      key: ValueKey('anon-item-${item.id}'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(LaresRadii.sm),
        color: risk
            ? _amber.withValues(alpha: theme.isDark ? 0.08 : 0.1)
            : cs.surface,
        border: risk
            ? Border(
                left: BorderSide(
                  color: _amber.withValues(alpha: 0.8),
                  width: 2,
                ),
              )
            : Border.all(color: theme.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.text,
            style: TextStyle(
              fontFamily: ChathamType.serifCjk,
              fontSize: 14.5,
              height: 1.55,
              color: cs.onSurface.withValues(alpha: 0.92),
            ),
          ),
          if (risk) ...[
            if (item.reason case final reason?) ...[
              const SizedBox(height: 4),
              Text(
                reason,
                style: TextStyle(fontSize: 11.5, color: theme.faint),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 5,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Pill(
                  key: ValueKey('anon-role-risk-${item.id}'),
                  label: t.anonRoleRiskTag,
                  icon: Icons.badge_outlined,
                  color: _amber,
                  filled: true,
                  dense: true,
                ),
                const SizedBox(width: 6),
                choice(AnonymReviewAction.keep, t.anonActionKeep),
                choice(AnonymReviewAction.generalise, t.anonActionGeneralise),
                choice(AnonymReviewAction.cut, t.anonActionCut),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Metrics extends StatelessWidget {
  const _Metrics({required this.metrics});
  final Map<String, Object> metrics;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    String fmt(Object v) => v is double
        ? (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(3))
        : '$v';
    return Container(
      key: const ValueKey('anon-metrics'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(LaresRadii.sm),
        border: Border.all(color: theme.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Overline(t.anonMetricsTitle),
          const SizedBox(height: 6),
          for (final e in metrics.entries)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      e.key,
                      style: TextStyle(
                        fontFamily: ChathamType.mono,
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Text(
                    fmt(e.value),
                    style: TextStyle(
                      fontFamily: ChathamType.mono,
                      fontSize: 12,
                      color: cs.onSurface,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ApproveBar extends StatelessWidget {
  const _ApproveBar({required this.anonym});
  final AnonymController anonym;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final int k = anonym.approvalsK;
    final int count = anonym.approvals;
    final bool done = anonym.approvedCurrent;
    return Container(
      padding: EdgeInsets.fromLTRB(
        LaresSpacing.lg,
        10,
        LaresSpacing.lg,
        MediaQuery.paddingOf(context).bottom + LaresSpacing.md,
      ),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.hairline)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: k <= 0 ? 0 : (count / k).clamp(0, 1).toDouble(),
                    minHeight: 4,
                    color: LaresColors.ember,
                    backgroundColor: theme.hairline,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                t.anonApprovals(count, k),
                key: const ValueKey('anon-approvals'),
                style: TextStyle(
                  fontSize: 12.5,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 50,
            child: FilledButton(
              key: const ValueKey('anon-approve'),
              onPressed: done ? null : anonym.approve,
              child: Text(done ? t.anonApproved : t.anonApprove),
            ),
          ),
        ],
      ),
    );
  }
}

class _Released extends StatelessWidget {
  const _Released({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      key: const ValueKey('anon-released'),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(LaresRadii.md),
        color: Color.alphaBlend(
          LaresColors.ember.withValues(alpha: 0.06),
          cs.surface,
        ),
        border: Border.all(color: LaresColors.ember.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.door_front_door_outlined,
                size: 16,
                color: LaresColors.ember,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Overline(t.anonReleasedTitle, color: LaresColors.ember),
              ),
              TextButton.icon(
                key: const ValueKey('anon-copy-released'),
                style: _smallText,
                onPressed: () => _copy(context, text),
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: Text(t.anonCopy, style: const TextStyle(fontSize: 13)),
              ),
            ],
          ),
          SelectableText(
            text,
            style: TextStyle(fontSize: 14, height: 1.6, color: cs.onSurface),
          ),
        ],
      ),
    );
  }
}

final ButtonStyle _smallText = TextButton.styleFrom(
  visualDensity: VisualDensity.compact,
);

void _copy(BuildContext context, String text) {
  Clipboard.setData(ClipboardData(text: text));
  final t = AppLocalizations.of(context);
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(t.anonCopied)));
}

// ─────────────────────────── 散会 ───────────────────────────

/// 散会卡(整页)。关掉时调 [AnonymController.dismissEnded]:回执与已放行原文一并清掉。
Future<void> showAnonymEndCard(
  BuildContext context, {
  required AnonymController anonym,
}) async {
  final AnonymReceipt? r = anonym.receipt;
  if (r == null) return;
  final String? released = anonym.releasedText;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => AnonymEndCard(receipt: r, releasedText: released),
    ),
  );
  anonym.dismissEnded();
}

class AnonymEndCard extends StatelessWidget {
  const AnonymEndCard({super.key, required this.receipt, this.releasedText});

  final AnonymReceipt receipt;
  final String? releasedText;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final String? released = releasedText;
    return Scaffold(
      key: const ValueKey('anon-end-card'),
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -0.75),
            radius: 1.15,
            colors: [
              LaresColors.ember.withValues(alpha: 0.1),
              theme.scaffoldBackgroundColor,
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LaresSpacing.lg,
                  ),
                  children: [
                    const SizedBox(height: 48),
                    const Center(child: RuleSeal(size: 64, years: false)),
                    const SizedBox(height: LaresSpacing.md),
                    Center(
                      child: Text(
                        t.anonEndedTitle,
                        style: TextStyle(
                          fontFamily: ChathamType.serifCjk,
                          fontSize: 34,
                          letterSpacing: 8,
                          color: cs.onSurface,
                          height: 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Center(
                      child: Text(
                        t.anonInspired,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(height: LaresSpacing.lg),
                    Container(
                      decoration: BoxDecoration(
                        color: cs.surface,
                        borderRadius: BorderRadius.circular(LaresRadii.lg - 4),
                      ),
                      child: Column(
                        children: [
                          _Ledger(
                            icon: Icons.inventory_2_outlined,
                            color: LaresColors.ember,
                            title: t.anonEndedKept,
                            lines: [
                              if (released == null) t.anonEndedNothingReleased,
                              for (final e in receipt.counts.entries)
                                '${e.key}  ${e.value}',
                            ],
                            trailing: released == null
                                ? null
                                : _ReleasedPreview(text: released),
                          ),
                          Divider(
                            height: 1,
                            color: theme.hairline,
                            indent: 16,
                            endIndent: 16,
                          ),
                          _Ledger(
                            icon: Icons.local_fire_department_outlined,
                            color: cs.onSurfaceVariant,
                            title: t.anonEndedBurned,
                            lines: [t.anonEndedBurnedList],
                          ),
                        ],
                      ),
                    ),
                    if (receipt.sha256.isNotEmpty) ...[
                      const SizedBox(height: LaresSpacing.md),
                      Container(
                        key: const ValueKey('anon-receipt'),
                        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(LaresRadii.md),
                          border: Border.all(color: theme.hairline),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.verified_outlined,
                              size: 18,
                              color: theme.faint,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    t.anonReceipt,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    receipt.sha256,
                                    style: TextStyle(
                                      fontFamily: ChathamType.mono,
                                      fontSize: 11.5,
                                      letterSpacing: 0.2,
                                      height: 1.4,
                                      color: cs.onSurface.withValues(
                                        alpha: 0.85,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              key: const ValueKey('anon-copy-receipt'),
                              tooltip: t.anonCopy,
                              onPressed: () => _copy(context, receipt.sha256),
                              icon: Icon(
                                Icons.copy_rounded,
                                size: 18,
                                color: theme.faint,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: LaresSpacing.md),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  LaresSpacing.lg,
                  0,
                  LaresSpacing.lg,
                  LaresSpacing.md,
                ),
                child: SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: FilledButton(
                    key: const ValueKey('anon-end-ok'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(t.anonEndedOk),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Ledger extends StatelessWidget {
  const _Ledger({
    required this.icon,
    required this.color,
    required this.title,
    required this.lines,
    this.trailing,
  });
  final IconData icon;
  final Color color;
  final String title;
  final List<String> lines;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                for (final l in lines) ...[
                  const SizedBox(height: 4),
                  Text(
                    l,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
                if (trailing != null) ...[const SizedBox(height: 8), trailing!],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReleasedPreview extends StatelessWidget {
  const _ReleasedPreview({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          text,
          maxLines: 6,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, height: 1.55, color: cs.onSurface),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('anon-end-copy-released'),
            style: _smallText.copyWith(
              padding: const WidgetStatePropertyAll(EdgeInsets.zero),
            ),
            onPressed: () => _copy(context, text),
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: Text(t.anonCopy, style: const TextStyle(fontSize: 13)),
          ),
        ),
      ],
    );
  }
}
