/// 专注社交的界面(plugin-focus-contract §10):出勤卡、🔥 连续打卡徽标、周报卡,
/// 以及房里圈主的「叫大家来」(§9.4)。
///
/// 房间页只挂一个 [FocusSocialCards](计时卡下面)和 [SummonButton](头部);
/// 座位 / 排行榜的 🔥 由 focus_widgets.dart 调 [FocusStreakBadge]。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../theme/tokens.dart';
import 'activity_push.dart';
import 'focus_service.dart';
import 'focus_social.dart';

/// 「专注多久」的文字(与排行榜一致)。
String _fmtMs(AppLocalizations t, int ms) {
  final minutes = ms ~/ 60000;
  if (minutes < 60) return t.focusMinutes(minutes);
  return t.focusHoursMinutes(minutes ~/ 60, minutes % 60);
}

/// 出勤一句话:「本轮 4 人全勤 🎉」/「3/4 全勤 · 小鹿离开 2 分钟」。
String focusRoundText(AppLocalizations t, FocusRound r) {
  if (r.allIn) {
    return r.total == 1 ? t.focusRoundSolo : t.focusRoundAllIn(r.total);
  }
  final parts = <String>[t.focusRoundPartial(r.full, r.total)];
  final missed = r.missed;
  if (missed.isNotEmpty) {
    final m = missed.first;
    final min = (m.awayMs / 60000).round();
    parts.add(
      min < 1 ? t.focusRoundAwayBrief(m.name) : t.focusRoundAway(m.name, min),
    );
    if (missed.length > 1) parts.add(t.focusRoundMore(missed.length - 1));
  }
  return parts.join(' · ');
}

// ─────────────────────────── 🔥 徽标 ───────────────────────────

/// 「🔥5」:连续 N 天完成过一轮专注。N = 0 时不画。
class FocusStreakBadge extends StatelessWidget {
  const FocusStreakBadge({
    super.key,
    required this.days,
    this.compact = false,
    this.badgeKey,
  });

  final int days;
  final bool compact;
  final Key? badgeKey;

  @override
  Widget build(BuildContext context) {
    if (days <= 0) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Tooltip(
      message: t.focusStreakTooltip(days),
      child: Container(
        key: badgeKey,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 4 : 6,
          vertical: compact ? 0 : 1,
        ),
        decoration: BoxDecoration(
          color: Color.alphaBlend(
            LaresColors.ember.withValues(alpha: 0.18),
            theme.colorScheme.surface,
          ),
          borderRadius: BorderRadius.circular(LaresRadii.lg),
          border: Border.all(color: LaresColors.ember.withValues(alpha: 0.5)),
        ),
        child: Text(
          '🔥$days',
          maxLines: 1,
          softWrap: false,
          style: theme.textTheme.labelSmall?.copyWith(
            color: LaresColors.ember,
            fontSize: compact ? 9.5 : 11,
            height: 1.25,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

/// 座位右上角的 🔥(压在头像球的右上沿)。没有连续天数时原样返回 [seat]。
Widget withStreakBadge({
  required Widget seat,
  required FocusService? focus,
  required String userId,
  required double orbBox,
  bool compact = false,
}) {
  if (focus == null) return seat;
  return ListenableBuilder(
    listenable: Listenable.merge([focus, focus.social]),
    builder: (context, _) {
      final n = focus.active ? focus.social.streakOf(userId) : 0;
      if (n <= 0) return seat;
      return Stack(
        clipBehavior: Clip.none,
        children: [
          seat,
          Positioned(
            top: compact ? -2 : 2,
            right: compact ? -6 : -2,
            child: FocusStreakBadge(
              days: n,
              compact: compact,
              badgeKey: ValueKey('focus-streak-$userId'),
            ),
          ),
        ],
      );
    },
  );
}

// ─────────────────────────── 计时卡下的两张卡 ───────────────────────────

/// 计时卡下面:本轮出勤卡 + 待看的周报卡。都没有时不占位。
class FocusSocialCards extends StatelessWidget {
  const FocusSocialCards({super.key, required this.focus});

  final FocusService focus;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([focus, focus.social]),
      builder: (context, _) {
        final s = focus.social;
        final round = s.lastRound;
        final weekly = s.weekly;
        if (round == null && weekly == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            LaresSpacing.md,
            LaresSpacing.sm,
            LaresSpacing.md,
            0,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (weekly != null)
                    FocusWeeklyCardView(card: weekly, onDismiss: s.dismissWeekly),
                  if (weekly != null && round != null)
                    const SizedBox(height: LaresSpacing.sm),
                  if (round != null)
                    FocusRoundCard(round: round, onDismiss: s.dismissRound),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

BoxDecoration _cardDecoration(BuildContext context, Color accent) {
  final theme = Theme.of(context);
  return BoxDecoration(
    color: Color.alphaBlend(
      accent.withValues(alpha: 0.07),
      theme.colorScheme.surface,
    ),
    borderRadius: BorderRadius.circular(LaresRadii.md),
    border: Border.all(color: accent.withValues(alpha: 0.32)),
  );
}

class FocusRoundCard extends StatelessWidget {
  const FocusRoundCard({super.key, required this.round, this.onDismiss});

  final FocusRound round;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final accent = round.allIn ? LaresColors.statusFree : LaresColors.ember;
    return Container(
      key: const ValueKey('focus-round-card'),
      padding: const EdgeInsets.fromLTRB(
        LaresSpacing.md - 4,
        LaresSpacing.sm,
        LaresSpacing.xs,
        LaresSpacing.sm,
      ),
      decoration: _cardDecoration(context, accent),
      child: Row(
        children: [
          Icon(
            round.allIn ? Icons.celebration_rounded : Icons.how_to_reg_rounded,
            color: accent,
            size: 22,
          ),
          const SizedBox(width: LaresSpacing.sm + 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  t.focusRoundTitle(round.round),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  focusRoundText(t, round),
                  key: const ValueKey('focus-round-text'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (onDismiss != null)
            IconButton(
              key: const ValueKey('focus-round-dismiss'),
              tooltip: t.focusRoundDismiss,
              visualDensity: VisualDensity.compact,
              onPressed: onDismiss,
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
        ],
      ),
    );
  }
}

class FocusWeeklyCardView extends StatelessWidget {
  const FocusWeeklyCardView({super.key, required this.card, this.onDismiss});

  final FocusWeeklyCard card;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Container(
      key: const ValueKey('focus-weekly-card'),
      padding: const EdgeInsets.fromLTRB(
        LaresSpacing.md - 4,
        LaresSpacing.xs,
        LaresSpacing.xs,
        LaresSpacing.sm + 2,
      ),
      decoration: _cardDecoration(context, LaresColors.ember),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(
                Icons.insights_rounded,
                color: LaresColors.ember,
                size: 20,
              ),
              const SizedBox(width: LaresSpacing.sm),
              Expanded(
                child: Text(
                  t.focusWeeklyTitle,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              IconButton(
                key: const ValueKey('focus-weekly-dismiss'),
                tooltip: t.focusWeeklyDismiss,
                visualDensity: VisualDensity.compact,
                onPressed: onDismiss,
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ],
          ),
          Text(
            t.focusWeeklyTime(_fmtMs(t, card.focusMs)),
            key: const ValueKey('focus-weekly-time'),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            [
              if (card.rank > 0 && card.of > 0)
                t.focusWeeklyRank(card.rank, card.of),
              if (card.streak > 0) t.focusWeeklyStreak(card.streak),
            ].join(' · '),
            style: muted,
          ),
          Text(t.focusWeeklyTotal(_fmtMs(t, card.circleTotalMs)), style: muted),
        ],
      ),
    );
  }
}

// ─────────────────────────── 叫大家来 ───────────────────────────

/// 房间头部的「叫大家来」:只给本圈圈主;冷却中显示「n 分」并禁用。
class SummonButton extends StatefulWidget {
  const SummonButton({
    super.key,
    required this.focus,
    required this.circleId,
    required this.myName,
  });

  final FocusService focus;
  final String circleId;
  final String myName;

  @override
  State<SummonButton> createState() => _SummonButtonState();
}

class _SummonButtonState extends State<SummonButton> {
  Timer? _tick;
  bool _busy = false;

  ActivityPush get _a => widget.focus.activity;

  @override
  void initState() {
    super.initState();
    if (_a.viewOf(widget.circleId) == null && _a.isOwner(widget.circleId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _a.refresh(widget.circleId);
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _syncTick(bool waiting) {
    if (waiting && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 15), (_) {
        if (mounted) setState(() {});
      });
    } else if (!waiting && _tick != null) {
      _tick!.cancel();
      _tick = null;
    }
  }

  Future<void> _press() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final minutes = _a.viewOf(widget.circleId)?.summonMin ?? 10;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.summonConfirmTitle),
        content: Text(t.summonConfirmBody(widget.myName, minutes)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.commonCancel),
          ),
          FilledButton(
            key: const ValueKey('summon-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.summonButton),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final r = await _a.summon(widget.circleId);
    if (!mounted) return;
    setState(() => _busy = false);
    final String text = switch (r) {
      SummonSent(:final count) =>
        count > 0 ? t.summonSent(count) : t.summonNobody,
      SummonCooldown() => t.summonCooldown(_waitMinutes() ?? 1),
      SummonFailed() => t.summonFailed,
    };
    messenger?.showSnackBar(SnackBar(content: Text(text)));
  }

  int? _waitMinutes() {
    final w = _a.summonWait(widget.circleId);
    if (w == null) return null;
    return (w.inSeconds / 60).ceil().clamp(1, 999);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: _a,
      builder: (context, _) {
        if (!_a.isOwner(widget.circleId)) return const SizedBox.shrink();
        final wait = _waitMinutes();
        _syncTick(wait != null);
        final waiting = wait != null;
        return Tooltip(
          message: waiting ? t.summonCooldown(wait) : t.summonButton,
          child: TextButton.icon(
            key: const ValueKey('room-summon'),
            onPressed: waiting || _busy ? null : _press,
            style: TextButton.styleFrom(
              foregroundColor: LaresColors.ember,
              visualDensity: VisualDensity.compact,
            ),
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.campaign_rounded, size: 20),
            label: Text(
              waiting ? t.summonCooldownShort(wait) : t.summonButton,
              key: const ValueKey('room-summon-label'),
            ),
          ),
        );
      },
    );
  }
}
