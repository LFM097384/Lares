/// 「圈子记忆」:隐名之约(受 Chatham House 规则启发 · 非官方)放行过的去名内容。
///
/// 这是知识面(见 server/anonym-agent/INTERFACE.md §「v1 愿景」):服务器按圈持久化,
/// 每条只有内容、类型、日期和放行人数,**永不含说话人**。撤回后成墓碑,不再有正文。
///
/// 协议(客户端假设,见 docs/plans/chatham/client-memory-protocol.md):
/// 打开时发 `anon_mem_list`,收 `anon_mem`;撤回发 `anon_mem_retract`,
/// 等 `anon_mem_retracted` 或重发的 `anon_mem` 才算数 —— 本机不抢先删。
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/gen/app_localizations.dart';
import '../theme/tokens.dart';
import 'anonym_controller.dart';
import 'anonym_kit.dart';

/// 打开圈子记忆页。[circleId] 是要看的圈(可以不是当前房间的圈)。
Future<void> openAnonymMemory(
  BuildContext context, {
  required AnonymController anonym,
  required String circleId,
  required String circleName,
  required bool isOwner,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AnonymMemoryScreen(
        anonym: anonym,
        circleId: circleId,
        circleName: circleName,
        isOwner: isOwner,
      ),
    ),
  );
}

class AnonymMemoryScreen extends StatefulWidget {
  const AnonymMemoryScreen({
    super.key,
    required this.anonym,
    required this.circleId,
    required this.circleName,
    required this.isOwner,
  });

  final AnonymController anonym;
  final String circleId;
  final String circleName;
  final bool isOwner;

  @override
  State<AnonymMemoryScreen> createState() => _AnonymMemoryScreenState();
}

class _AnonymMemoryScreenState extends State<AnonymMemoryScreen> {
  @override
  void initState() {
    super.initState();
    widget.anonym.loadMemory(circleId: widget.circleId);
  }

  void _reload() => widget.anonym.loadMemory(circleId: widget.circleId);

  Future<void> _confirmRetract(AnonymMemoryItem item) async {
    final t = AppLocalizations.of(context);
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.anonMemRetractTitle),
        content: Text(t.anonMemRetractBody),
        actions: [
          TextButton(
            key: const ValueKey('anon-mem-retract-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.commonCancel),
          ),
          FilledButton(
            key: const ValueKey('anon-mem-retract-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.anonMemRetract),
          ),
        ],
      ),
    );
    if (yes == true && mounted) widget.anonym.retractMemory(item.id);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.anonMemTitle),
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
          // 页面还开着时记忆被清了(离房):重新取一次,别一直转圈
          if (a.memoryCircleId == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && widget.anonym.memoryCircleId == null) _reload();
            });
          }
          final bool mine = a.memoryCircleId == widget.circleId;
          final List<AnonymMemoryItem>? items = mine ? a.memoryItems : null;
          final String? error = mine ? a.memoryError : null;
          final bool loading = !mine || a.memoryLoading;

          final List<Widget> body;
          if (items == null && error != null) {
            body = [_ErrorState(code: error, onRetry: _reload)];
          } else if (items == null || (loading && items.isEmpty)) {
            body = [const _LoadingState()];
          } else if (items.isEmpty) {
            body = [const _EmptyState()];
          } else {
            body = [
              if (error != null) ...[
                _InlineError(code: error, onDismiss: a.clearMemoryError),
                const SizedBox(height: LaresSpacing.sm),
              ],
              for (final item in items) ...[
                if (item.retracted)
                  _TombstoneRow(id: item.id, retractedAt: item.retractedAt)
                else
                  AnonymMemoryCard(
                    item: item,
                    pending: a.memoryRetracting(item.id),
                    onRetract: a.mayRetract(item, isOwner: widget.isOwner)
                        ? () => _confirmRetract(item)
                        : null,
                  ),
                const SizedBox(height: 10),
              ],
            ];
          }

          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              key: const ValueKey('anon-mem-list'),
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                LaresSpacing.lg,
                LaresSpacing.sm,
                LaresSpacing.lg,
                LaresSpacing.xl,
              ),
              children: [
                Overline(
                  t.anonInspired,
                  color: LaresColors.ember.withValues(alpha: 0.85),
                ),
                const SizedBox(height: 6),
                Text(
                  t.anonMemSubtitle(widget.circleName),
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.55,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: LaresSpacing.md),
                ...body,
                const SizedBox(height: LaresSpacing.md),
                Center(
                  child: Text(
                    t.anonNotAffiliated,
                    style: TextStyle(fontSize: 11, color: theme.faint),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 类型的本地化名字。
String anonMemoryKindLabel(AppLocalizations t, AnonymMemoryKind k) =>
    switch (k) {
      AnonymMemoryKind.idea => t.anonMemKindIdea,
      AnonymMemoryKind.decision => t.anonMemKindDecision,
      AnonymMemoryKind.todo => t.anonMemKindTodo,
      AnonymMemoryKind.fact => t.anonMemKindFact,
      AnonymMemoryKind.other => t.anonMemKindOther,
    };

IconData _kindIcon(AnonymMemoryKind k) => switch (k) {
  AnonymMemoryKind.idea => Icons.lightbulb_outline_rounded,
  AnonymMemoryKind.decision => Icons.gavel_rounded,
  AnonymMemoryKind.todo => Icons.check_box_outlined,
  AnonymMemoryKind.fact => Icons.menu_book_outlined,
  AnonymMemoryKind.other => Icons.notes_rounded,
};

Color _kindColor(AnonymMemoryKind k) => switch (k) {
  AnonymMemoryKind.idea => const Color(0xFFE8B45A),
  AnonymMemoryKind.decision => LaresColors.ember,
  AnonymMemoryKind.todo => const Color(0xFF7FB38A),
  AnonymMemoryKind.fact => const Color(0xFF8FA8C8),
  AnonymMemoryKind.other => const Color(0xFF9A948C),
};

/// 一条记忆:类型牌 + 日期,正文(宋体,与出门稿同一种字),脚注「去名 · 经 N 人放行」。
class AnonymMemoryCard extends StatelessWidget {
  const AnonymMemoryCard({
    super.key,
    required this.item,
    this.onRetract,
    this.pending = false,
  });

  final AnonymMemoryItem item;

  /// null = 我没有撤回权限,不显示按钮。
  final VoidCallback? onRetract;

  /// 已请求撤回,等服务器确认。
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final DateTime? at = item.releasedAt;
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final String? date = at == null ? null : DateFormat.yMMMd(locale).format(at);
    final int? n = item.approvals;
    return Container(
      key: ValueKey('anon-mem-item-${item.id}'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(LaresRadii.sm),
        color: theme.card,
        border: Border.all(color: theme.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Row(
              children: [
                Pill(
                  key: ValueKey('anon-mem-kind-${item.id}'),
                  label: anonMemoryKindLabel(t, item.kind),
                  icon: _kindIcon(item.kind),
                  color: _kindColor(item.kind),
                  filled: true,
                  dense: true,
                ),
                const Spacer(),
                if (date != null)
                  Text(
                    date,
                    key: ValueKey('anon-mem-date-${item.id}'),
                    style: TextStyle(fontSize: 11.5, color: theme.faint),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              item.text ?? '',
              style: TextStyle(
                fontFamily: ChathamType.serifCjk,
                fontSize: 14.5,
                height: 1.6,
                color: cs.onSurface.withValues(alpha: 0.92),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.verified_user_outlined, size: 13, color: theme.faint),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  n == null ? t.anonMemProvenanceNoCount : t.anonMemProvenance(n),
                  key: ValueKey('anon-mem-prov-${item.id}'),
                  style: TextStyle(fontSize: 11.5, color: theme.faint),
                ),
              ),
              if (pending)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  child: Row(
                    key: ValueKey('anon-mem-pending-${item.id}'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox.square(
                        dimension: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: theme.faint,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        t.anonMemRetracting,
                        style: TextStyle(fontSize: 11.5, color: theme.faint),
                      ),
                    ],
                  ),
                )
              else if (onRetract != null)
                TextButton.icon(
                  key: ValueKey('anon-mem-retract-${item.id}'),
                  onPressed: onRetract,
                  style: TextButton.styleFrom(
                    foregroundColor: cs.onSurfaceVariant,
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.undo_rounded, size: 15),
                  // 字号写在 Text 上:按钮的 textStyle 会整份替换主题字族
                  label: Text(
                    t.anonMemRetract,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                )
              else
                const SizedBox(height: 40),
            ],
          ),
        ],
      ),
    );
  }
}

/// 墓碑:一行淡字「已撤回」+ 撤回日期(服务器给了才有),没有正文。
class _TombstoneRow extends StatelessWidget {
  const _TombstoneRow({required this.id, this.retractedAt});
  final String id;
  final DateTime? retractedAt;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final DateTime? at = retractedAt;
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final String? date = at == null ? null : DateFormat.yMMMd(locale).format(at);
    return Container(
      key: ValueKey('anon-mem-tombstone-$id'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(LaresRadii.sm),
        border: Border.all(color: theme.hairline),
      ),
      child: Row(
        children: [
          Icon(Icons.remove_circle_outline_rounded, size: 14, color: theme.faint),
          const SizedBox(width: 8),
          Text(
            t.anonMemRetracted,
            style: TextStyle(
              fontSize: 12.5,
              color: theme.faint,
              fontStyle: FontStyle.italic,
            ),
          ),
          const Spacer(),
          if (date != null)
            Text(
              date,
              key: ValueKey('anon-mem-retracted-date-$id'),
              style: TextStyle(fontSize: 11.5, color: theme.faint),
            ),
        ],
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      key: const ValueKey('anon-mem-loading'),
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          const SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: 12),
          Text(
            t.anonMemLoading,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      key: const ValueKey('anon-mem-empty'),
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 12),
      child: Column(
        children: [
          Opacity(
            opacity: 0.6,
            child: const RuleSeal(size: 56, years: false),
          ),
          const SizedBox(height: 16),
          Text(
            t.anonMemEmpty,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          Text(
            t.anonMemEmptyHint,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.55,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.code, required this.onRetry});
  final String code;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return Padding(
      key: const ValueKey('anon-mem-error'),
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(Icons.cloud_off_rounded, color: cs.error),
          const SizedBox(height: 12),
          Text(
            code == 'agent_absent'
                ? t.anonMemAgentAbsent
                : t.anonMemLoadFailed(code),
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            key: const ValueKey('anon-mem-retry'),
            onPressed: onRetry,
            child: Text(t.anonMemRetry),
          ),
        ],
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.code, required this.onDismiss});
  final String code;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('anon-mem-inline-error'),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(LaresRadii.sm),
        color: cs.error.withValues(alpha: 0.08),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, size: 16, color: cs.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t.anonError(code),
              style: TextStyle(fontSize: 12.5, color: cs.onSurface),
            ),
          ),
          IconButton(
            tooltip: t.commonClose,
            onPressed: onDismiss,
            icon: const Icon(Icons.close_rounded, size: 16),
          ),
        ],
      ),
    );
  }
}
