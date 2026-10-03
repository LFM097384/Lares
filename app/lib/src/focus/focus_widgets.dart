import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../theme/tokens.dart';
import 'focus_lock.dart';
import 'focus_models.dart';
import 'focus_service.dart';
import 'focus_social_widgets.dart' show FocusStreakBadge;

/// 把 [FocusService] 挂在树上:房间页按需取,不必沿 HomeScreen 一路加参数。
/// 没挂(测试 / 老入口)时 [maybeOf] 返回 null,专注 UI 整块不出现。
class FocusStudyScope extends InheritedWidget {
  const FocusStudyScope({
    super.key,
    required this.service,
    required super.child,
  });

  final FocusService service;

  static FocusService? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<FocusStudyScope>()
      ?.service;

  @override
  bool updateShouldNotify(FocusStudyScope old) => old.service != service;
}

// ── 颜色:都取自 tokens,不新造 ──
const Color _focusColor = LaresColors.ember;
const Color _breakColor = LaresColors.statusFree;
const Color _awayColor = LaresColors.statusBusy;

/// 倒计时文本:mm:ss(满一小时 h:mm:ss)。
String formatClock(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// 离开时长:m:ss(满一小时 h:mm:ss)。比倒计时少一个前导零,读起来更像「多久」。
String formatAway(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

String formatFocusMs(AppLocalizations t, int ms) {
  final minutes = ms ~/ 60000;
  if (minutes < 60) return t.focusMinutes(minutes);
  return t.focusHoursMinutes(minutes ~/ 60, minutes % 60);
}

/// 每秒重建一次的小壳。只在 [enabled] 时开表 —— 没有倒计时就不白跑。
class FocusTicker extends StatefulWidget {
  const FocusTicker({super.key, required this.builder, this.enabled = true});

  final WidgetBuilder builder;
  final bool enabled;

  @override
  State<FocusTicker> createState() => _FocusTickerState();
}

class _FocusTickerState extends State<FocusTicker> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(FocusTicker old) {
    super.didUpdateWidget(old);
    if (old.enabled != widget.enabled) _sync();
  }

  void _sync() {
    _timer?.cancel();
    _timer = widget.enabled
        ? Timer.periodic(const Duration(seconds: 1), (_) {
            if (mounted) setState(() {});
          })
        : null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

// ─────────────────────────── 计时卡 ───────────────────────────

/// 房间顶部的专注计时卡:阶段 + 倒计时环 + 轮次 + 操作。
///
/// [slim] = 语音区收成一条时的单行形态(只剩阶段、倒计时与排行榜)。
class FocusTimerCard extends StatelessWidget {
  const FocusTimerCard({
    super.key,
    required this.focus,
    this.lock,
    this.slim = false,
  });

  final FocusService focus;
  final FocusLock? lock;
  final bool slim;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable?>[focus, lock]),
      builder: (context, _) {
        if (!focus.active) return const SizedBox.shrink();
        final p = focus.pomodoro;
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
              child: FocusTicker(
                enabled: p.running && p.endsAt != null,
                builder: (context) =>
                    slim ? _slim(context) : _full(context),
              ),
            ),
          ),
        );
      },
    );
  }

  Color _phaseColor(PomodoroPhase p) => switch (p) {
    PomodoroPhase.focus => _focusColor,
    PomodoroPhase.breakTime => _breakColor,
    PomodoroPhase.idle => _focusColor,
  };

  String _phaseLabel(AppLocalizations t, PomodoroPhase p) => switch (p) {
    PomodoroPhase.focus => t.focusPhaseFocus,
    PomodoroPhase.breakTime => t.focusPhaseBreak,
    PomodoroPhase.idle => t.focusPhaseIdle,
  };

  /// 本阶段已过去的比例(0..1),供环用。
  double _progress() {
    final p = focus.pomodoro;
    final left = focus.remaining;
    if (!p.running || left == null) return 0;
    final total = Duration(
      minutes: p.phase == PomodoroPhase.breakTime
          ? focus.config.breakMin
          : focus.config.focusMin,
    );
    if (total.inMilliseconds <= 0) return 0;
    return (1 - left.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
  }

  BoxDecoration _decoration(BuildContext context, Color accent) {
    final theme = Theme.of(context);
    return BoxDecoration(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(LaresRadii.md),
      border: Border.all(color: accent.withValues(alpha: 0.28)),
      boxShadow: [
        BoxShadow(
          color: accent.withValues(alpha: 0.08),
          blurRadius: 18,
        ),
      ],
    );
  }

  Widget _full(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final p = focus.pomodoro;
    final accent = _phaseColor(p.phase);
    final left = focus.remaining;
    return Container(
      key: const ValueKey('focus-timer-card'),
      padding: const EdgeInsets.all(LaresSpacing.md - 4),
      decoration: _decoration(context, accent),
      child: Row(
        children: [
          _Ring(
            size: 76,
            progress: _progress(),
            color: accent,
            running: p.running,
            child: left == null
                ? Icon(
                    Icons.self_improvement_rounded,
                    color: accent,
                    size: 30,
                  )
                : FittedBox(
                    child: Text(
                      formatClock(left),
                      key: const ValueKey('focus-countdown'),
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: LaresSpacing.md - 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    _Dot(color: accent),
                    const SizedBox(width: LaresSpacing.xs + 2),
                    Flexible(
                      child: Text(
                        _phaseLabel(t, p.phase),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (p.running && p.rounds > 0) ...[
                      const SizedBox(width: LaresSpacing.sm),
                      Text(
                        t.focusRound(p.round, p.rounds),
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ],
                ),
                if (!p.running)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      t.focusPhaseIdleHint,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 12,
                      ),
                    ),
                  ),
                // 排行榜 / 锁定专注挪到了底部控件排(静音键右侧),卡里只留开始 / 结束
                if (focus.canControl) ...[
                  const SizedBox(height: LaresSpacing.xs + 2),
                  _startStop(t, p),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _startStop(AppLocalizations t, Pomodoro p) => _PillButton(
    key: ValueKey(p.running ? 'focus-stop' : 'focus-start'),
    icon: p.running ? Icons.stop_rounded : Icons.play_arrow_rounded,
    label: p.running ? t.focusStop : t.focusStart,
    filled: !p.running,
    onTap: p.running ? focus.stopPomodoro : focus.startPomodoro,
  );
  Widget _slim(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final p = focus.pomodoro;
    final accent = _phaseColor(p.phase);
    final left = focus.remaining;
    return Container(
      key: const ValueKey('focus-timer-card'),
      padding: const EdgeInsets.fromLTRB(
        LaresSpacing.md - 4,
        LaresSpacing.xs,
        LaresSpacing.xs,
        LaresSpacing.xs,
      ),
      decoration: _decoration(context, accent),
      child: Row(
        children: [
          _Dot(color: accent),
          const SizedBox(width: LaresSpacing.sm),
          Expanded(
            child: Text(
              [
                _phaseLabel(t, p.phase),
                if (p.running && p.rounds > 0) t.focusRound(p.round, p.rounds),
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge?.copyWith(color: accent),
            ),
          ),
          const SizedBox(width: LaresSpacing.sm),
          if (left != null)
            Text(
              formatClock(left),
              key: const ValueKey('focus-countdown'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w600,
              ),
            ),
          // 排行榜在底部控件排;这里只留开始 / 结束,没权限的人只看
          if (focus.canControl) ...[
            const SizedBox(width: LaresSpacing.xs),
            if (p.running)
              IconButton(
                key: const ValueKey('focus-stop'),
                visualDensity: VisualDensity.compact,
                tooltip: t.focusStop,
                icon: const Icon(Icons.stop_rounded, size: 20),
                onPressed: focus.stopPomodoro,
              )
            else
              _startStop(t, p),
          ] else
            const SizedBox(width: LaresSpacing.sm),
        ],
      ),
    );
  }
}

// ─────────────────────────── 控件排上的专注键 ───────────────────────────

/// 底部控件排里的排行榜键(与离开 / 字幕同为 tonal 圆键)。
class FocusBoardButton extends StatelessWidget {
  const FocusBoardButton({super.key, required this.focus});

  final FocusService focus;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return IconButton.filledTonal(
      key: const ValueKey('focus-board'),
      tooltip: t.focusBoard,
      onPressed: () => showFocusLeaderboard(context, focus),
      icon: const Icon(Icons.leaderboard_rounded),
    );
  }
}

/// 底部控件排里的「锁定专注」键(仅 Android 屏幕固定可用时出现)。锁着时余烬色。
class FocusLockButton extends StatelessWidget {
  const FocusLockButton({super.key, required this.lock});

  final FocusLock lock;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: lock,
      builder: (context, _) {
        final on = lock.requested;
        return IconButton.filledTonal(
          key: const ValueKey('focus-lock'),
          tooltip: on ? t.focusUnlock : t.focusLock,
          isSelected: on,
          style: on
              ? IconButton.styleFrom(
                  backgroundColor: LaresColors.emberSoft,
                  foregroundColor: LaresColors.ember,
                )
              : null,
          onPressed: () => on
              ? unawaited(lock.stop())
              : unawaited(confirmFocusLock(context, lock)),
          icon: Icon(on ? Icons.lock_rounded : Icons.lock_outline_rounded),
        );
      },
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: color,
      boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6)],
    ),
  );
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color bg = filled
        ? LaresColors.ember
        : theme.colorScheme.surfaceContainerHighest;
    final Color fg = filled
        ? const Color(0xFF1A120C)
        : theme.colorScheme.onSurface;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(LaresRadii.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(LaresRadii.lg),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 34),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: fg),
                const SizedBox(width: LaresSpacing.xs),
                Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: fg,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 倒计时环:底环 + 已过去的弧。不跑番茄钟时是一圈淡色的静环。
class _Ring extends StatelessWidget {
  const _Ring({
    required this.size,
    required this.progress,
    required this.color,
    required this.running,
    required this.child,
  });

  final double size;
  final double progress;
  final Color color;
  final bool running;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(
          progress: running ? progress : 0,
          color: color,
          track: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Center(child: child),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.color,
    required this.track,
  });

  final double progress;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 5.0;
    final rect = Offset.zero & size;
    final arc = rect.deflate(stroke / 2);
    canvas.drawArc(
      arc,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = track,
    );
    // 剩余部分亮着:时间在「消耗」,亮弧随之缩短
    final remain = 1 - progress;
    if (remain <= 0) return;
    canvas.drawArc(
      arc,
      -math.pi / 2,
      math.pi * 2 * remain,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.color != color || old.track != track;
}

// ─────────────────────────── 座位徽标 ───────────────────────────

/// 座位上的小药丸:「专注中」/「离开 2:13」(每秒走)/「休息」。
/// 成员不在专注名单里(刚进房、服务器还没推)时什么都不画。
class FocusSeatBadge extends StatelessWidget {
  const FocusSeatBadge({
    super.key,
    required this.focus,
    required this.userId,
    this.compact = false,
  });

  final FocusService focus;
  final String userId;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: focus,
      builder: (context, _) {
        final m = focus.memberState(userId);
        // 没开番茄钟时不挂徽标:房间照常,没有「专注中 / 离开」可言
        if (m == null || m.state == FocusMemberMode.idle) {
          return const SizedBox.shrink();
        }
        final away = m.state == FocusMemberMode.away;
        return FocusTicker(
          enabled: away,
          builder: (context) => _pill(context, m),
        );
      },
    );
  }

  Widget _pill(BuildContext context, FocusMemberState m) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final (String label, Color color) = switch (m.state) {
      FocusMemberMode.focus => (t.focusBadgeFocus, _focusColor),
      FocusMemberMode.breakTime ||
      FocusMemberMode.idle => (t.focusBadgeBreak, _breakColor),
      FocusMemberMode.away => (
        t.focusBadgeAway(formatAway(focus.awayFor(userId) ?? Duration.zero)),
        _awayColor,
      ),
    };
    return Container(
      key: ValueKey('focus-badge-$userId'),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 5 : 8,
        vertical: compact ? 1 : 2,
      ),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          color.withValues(alpha: 0.16),
          theme.colorScheme.surface,
        ),
        borderRadius: BorderRadius.circular(LaresRadii.lg),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Text(
        label,
        maxLines: 1,
        softWrap: false,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontSize: compact ? 9.5 : 11,
          height: 1.25,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// 把徽标叠在头像球的下沿(压住色环底部),不额外占高度 ——
/// 网格座位的高度本来就是按「球 + 名字 + 状态字」算死的。
///
/// [orbBox] = AvatarOrb 里球所在方框的边长(size + 16)。
Widget withFocusBadge({
  required Widget seat,
  required FocusService? focus,
  required String userId,
  required double orbBox,
  bool compact = false,
}) {
  if (focus == null) return seat;
  return ListenableBuilder(
    listenable: focus,
    builder: (context, _) {
      final m = focus.memberState(userId);
      if (m == null || m.state == FocusMemberMode.idle) return seat;
      final away = m.state == FocusMemberMode.away;
      return Stack(
        clipBehavior: Clip.none,
        children: [
          // 离开的人淡一点:「人还在房里,但此刻不在桌前」
          Opacity(opacity: away ? 0.62 : 1, child: seat),
          Positioned(
            top: orbBox - (compact ? 12 : 16),
            left: -6,
            right: -6,
            child: Center(
              child: FocusSeatBadge(
                focus: focus,
                userId: userId,
                compact: compact,
              ),
            ),
          ),
        ],
      );
    },
  );
}

// ─────────────────────────── 提示 snackbar ───────────────────────────

/// 订阅 [FocusService.notices] 并弹 snackbar。不占位。
class FocusNoticeListener extends StatefulWidget {
  const FocusNoticeListener({
    super.key,
    required this.focus,
    this.myUserId,
  });

  final FocusService focus;
  final String? myUserId;

  @override
  State<FocusNoticeListener> createState() => _FocusNoticeListenerState();
}

class _FocusNoticeListenerState extends State<FocusNoticeListener> {
  StreamSubscription<FocusNotice>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.focus.notices.listen(_show);
  }

  @override
  void didUpdateWidget(FocusNoticeListener old) {
    super.didUpdateWidget(old);
    if (old.focus != widget.focus) {
      _sub?.cancel();
      _sub = widget.focus.notices.listen(_show);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _show(FocusNotice n) {
    if (!mounted) return;
    // 自己的离开 / 回来不必告诉自己
    if (n.userId != null && n.userId == widget.myUserId) {
      if (n.kind == FocusNoticeKind.away ||
          n.kind == FocusNoticeKind.back ||
          n.kind == FocusNoticeKind.leftEarly) {
        return;
      }
    }
    final text = focusNoticeText(AppLocalizations.of(context), n);
    if (text == null) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// notice → 一句人话。返回 null = 不提示。
String? focusNoticeText(AppLocalizations t, FocusNotice n) {
  final name = (n.name == null || n.name!.isEmpty) ? '?' : n.name!;
  return switch (n.kind) {
    FocusNoticeKind.away => t.focusNoticeAway(name),
    FocusNoticeKind.back =>
      (n.awayMs ?? 0) >= 1000
          ? t.focusNoticeBackAfter(
              name,
              formatAway(Duration(milliseconds: n.awayMs!)),
            )
          : t.focusNoticeBack(name),
    FocusNoticeKind.leftEarly => t.focusNoticeLeftEarly(name),
    FocusNoticeKind.phase => switch (n.phase) {
      PomodoroPhase.focus => t.focusNoticePhaseFocus(n.round ?? 1),
      PomodoroPhase.breakTime => t.focusNoticePhaseBreak,
      _ => null,
    },
    FocusNoticeKind.started => t.focusNoticeStarted,
    FocusNoticeKind.stopped => t.focusNoticeStopped,
    FocusNoticeKind.endedByOwner => t.focusNoticeEnded,
    FocusNoticeKind.error =>
      n.reason == 'forbidden' ? t.focusErrorForbidden : t.focusErrorGeneric,
  };
}

// ─────────────────────────── 锁定确认 ───────────────────────────

Future<void> confirmFocusLock(BuildContext context, FocusLock lock) async {
  final t = AppLocalizations.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.lock_outline_rounded),
      title: Text(t.focusLockTitle),
      content: Text(t.focusLockBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(t.focusLockCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(t.focusLockConfirm),
        ),
      ],
    ),
  );
  if (ok != true) return;
  final started = await lock.start();
  if (!started && context.mounted) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(t.focusLockFailed)));
  }
}

// ─────────────────────────── 排行榜 ───────────────────────────

Future<void> showFocusLeaderboard(BuildContext context, FocusService focus) {
  focus.requestBoard();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => FocusLeaderboardSheet(focus: focus),
  );
}

class FocusLeaderboardSheet extends StatelessWidget {
  const FocusLeaderboardSheet({super.key, required this.focus});

  final FocusService focus;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final height = MediaQuery.sizeOf(context).height * 0.62;
    return SizedBox(
      key: const ValueKey('focus-leaderboard'),
      height: height,
      child: DefaultTabController(
        length: 3,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: LaresSpacing.lg),
              child: Row(
                children: [
                  const Icon(
                    Icons.leaderboard_rounded,
                    color: LaresColors.ember,
                    size: 20,
                  ),
                  const SizedBox(width: LaresSpacing.sm),
                  Text(t.focusBoard, style: theme.textTheme.titleLarge),
                ],
              ),
            ),
            const SizedBox(height: LaresSpacing.sm),
            TabBar(
              indicatorColor: LaresColors.ember,
              labelColor: LaresColors.ember,
              dividerColor: Colors.transparent,
              tabs: [
                Tab(text: t.focusBoardToday),
                Tab(text: t.focusBoardWeek),
                Tab(text: t.focusBoardAll),
              ],
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: Listenable.merge([focus, focus.social]),
                builder: (context, _) {
                  final b = focus.leaderboard;
                  return TabBarView(
                    children: [
                      _BoardList(rows: b.today, me: focus.myUserId?.call(), streakOf: focus.social.streakOf),
                      _BoardList(rows: b.week, me: focus.myUserId?.call(), streakOf: focus.social.streakOf),
                      _BoardList(rows: b.all, me: focus.myUserId?.call(), streakOf: focus.social.streakOf),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BoardList extends StatelessWidget {
  const _BoardList({required this.rows, this.me, this.streakOf});

  final List<LeaderboardRow> rows;
  final String? me;

  /// 连续打卡天数(§10.2);排行榜行名字后面挂 🔥N
  final int Function(String userId)? streakOf;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(LaresSpacing.lg),
          child: Text(
            t.focusBoardEmpty,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      );
    }
    final top = rows.first.ms <= 0 ? 1 : rows.first.ms;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        LaresSpacing.md,
        LaresSpacing.sm,
        LaresSpacing.md,
        LaresSpacing.lg,
      ),
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final r = rows[i];
        final mine = r.userId == me;
        final rank = i + 1;
        final Color rankColor = switch (rank) {
          1 => LaresColors.ember,
          2 => LaresColors.statusBusy,
          3 => LaresColors.statusEars,
          _ => theme.textTheme.bodyMedium?.color ?? Colors.grey,
        };
        return Container(
          key: ValueKey('focus-board-row-${r.userId}'),
          margin: const EdgeInsets.only(bottom: LaresSpacing.xs),
          padding: const EdgeInsets.symmetric(
            horizontal: LaresSpacing.md - 4,
            vertical: LaresSpacing.sm + 2,
          ),
          decoration: BoxDecoration(
            color: mine
                ? LaresColors.emberSoft
                : theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.5,
                  ),
            borderRadius: BorderRadius.circular(LaresRadii.sm),
            border: mine
                ? Border.all(color: LaresColors.ember.withValues(alpha: 0.6))
                : null,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 28,
                child: Text(
                  '$rank',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: rankColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            mine ? t.focusBoardMe : r.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: mine ? FontWeight.w600 : null,
                            ),
                          ),
                        ),
                        if ((streakOf?.call(r.userId) ?? 0) > 0) ...[
                          const SizedBox(width: LaresSpacing.xs + 2),
                          FocusStreakBadge(
                            days: streakOf!(r.userId),
                            badgeKey: ValueKey('focus-board-streak-${r.userId}'),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: (r.ms / top).clamp(0.0, 1.0),
                        minHeight: 3,
                        color: mine ? LaresColors.ember : rankColor,
                        backgroundColor: theme.colorScheme.surface,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: LaresSpacing.md),
              Text(
                formatFocusMs(t, r.ms),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
