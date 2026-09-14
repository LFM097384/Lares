/// 演示外壳(SPEC §7)—— 底部收纳控制条 + 性能 HUD。
///
/// ## 这不是调试面板
///
/// 产品负责人是看截图验收的,所以这条东西本身也要好看:
/// 圆角上沿、`surfaceHigh` 低 alpha、暖橙点缀、中文标签。
/// **不用 `BackdropFilter`** —— 毛玻璃在桌面上要额外拉一次离屏纹理,
/// 为了一个演示面板付这个钱不值(SPEC §7 明确禁用)。
/// 半透明底色 + 顶部一条 ember 细线已经足够有「浮起来」的层次。
///
/// ## HUD 为什么不能每帧 setState
///
/// 性能 HUD 的悖论:测量者本身会污染测量。如果 HUD 在
/// `addTimingsCallback` 里直接 `setState`,那么每一帧都会因为
/// 「要显示上一帧的耗时」而重建一次文本 —— 帧率数字会被自己推高,
/// 更要命的是它让整个原型永远处在满帧状态,时钟的三档节流完全失效。
///
/// 所以这里的分工是:回调只往环形缓冲里**写数**(零分配,不碰 Widget),
/// 一个 1 秒的 `Timer.periodic` 负责把数读出来渲染。HUD 每秒重建一次,
/// 对被测系统的扰动可以忽略。
///
/// ## 「实际帧提交速率」为什么比 FPS 诚实
///
/// 静息降档时帧率**本来就该低** —— 12fps 不是卡顿,是省电。
/// 用「FPS」这个词会让人误以为越高越好。这里显示的是每秒真实发生的
/// `FrameTiming` 回调数,配合 `emitted/ticked` 节流比一起读:
/// 节流比低 + 提交率低 = 正在正确地省电;提交率低但节流比是 1 = 真卡了。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'hearth_scene.dart';
import 'hearth_state.dart';
import 'hearth_tokens.dart';
import 'layer_b_seats.dart';

/// 底部控制条。
class DemoControls extends StatefulWidget {
  const DemoControls({
    super.key,
    required this.clock,
    required this.state,
    required this.layoutProbe,
    required this.compact,
    required this.onCompactChanged,
    required this.showPerformanceOverlay,
    required this.onPerformanceOverlayChanged,
    required this.onCaptureOne,
    required this.onCaptureSequence,
  });

  final HearthClock clock;
  final HearthState state;
  final SeatLayoutProbe layoutProbe;

  /// 紧凑模式(单环),用来让溢出芯片在桌面尺寸下真的出现。
  final bool compact;
  final ValueChanged<bool> onCompactChanged;

  final bool showPerformanceOverlay;
  final ValueChanged<bool>? onPerformanceOverlayChanged;

  final Future<void> Function() onCaptureOne;
  final Future<void> Function() onCaptureSequence;

  @override
  State<DemoControls> createState() => _DemoControlsState();
}

class _DemoControlsState extends State<DemoControls> {
  bool _expanded = true;
  bool _hudVisible = true;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          if (_hudVisible)
            Padding(
              padding: const EdgeInsets.only(
                right: HearthSpacing.md,
                bottom: HearthSpacing.sm,
              ),
              child: PerfHud(
                clock: widget.clock,
                state: widget.state,
                layoutProbe: widget.layoutProbe,
              ),
            ),
          _bar(context),
        ],
      ),
    );
  }

  Widget _bar(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        // 低 alpha 的 surfaceHigh:底下的火光会透上来一点,
        // 面板于是属于这个场景,而不是贴在上面的一块 UI。
        color: HearthColors.surfaceHigh.withValues(alpha: 0.82),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(HearthRadii.lg),
        ),
        border: Border(
          top: BorderSide(
            color: HearthColors.ember.withValues(alpha: 0.22),
            width: 1,
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _handle(),
          AnimatedSize(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(
                      HearthSpacing.lg,
                      0,
                      HearthSpacing.lg,
                      HearthSpacing.md,
                    ),
                    child: _body(context),
                  )
                : const SizedBox(width: double.infinity, height: 0),
          ),
        ],
      ),
    );
  }

  /// 收纳把手 —— 同时兼任「当前档位」的常驻指示。
  Widget _handle() {
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(HearthRadii.lg),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: HearthSpacing.lg,
          vertical: HearthSpacing.sm,
        ),
        child: Row(
          children: <Widget>[
            const _Dot(),
            const SizedBox(width: HearthSpacing.sm),
            const Text(
              '炉边',
              style: TextStyle(
                color: HearthColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: HearthSpacing.md),
            // 档位指示常驻,收起时也看得见。
            _LevelChip(clock: widget.clock),
            const Spacer(),
            IconButton(
              tooltip: _hudVisible ? '隐藏性能 HUD' : '显示性能 HUD',
              iconSize: 18,
              onPressed: () => setState(() => _hudVisible = !_hudVisible),
              icon: Icon(
                _hudVisible ? Icons.speed_rounded : Icons.speed_outlined,
                color: _hudVisible
                    ? HearthColors.ember
                    : HearthColors.textSecondary,
              ),
            ),
            Icon(
              _expanded
                  ? Icons.keyboard_arrow_down_rounded
                  : Icons.keyboard_arrow_up_rounded,
              color: HearthColors.textSecondary,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (BuildContext context, Widget? _) {
        final int n = widget.state.members.length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Wrap(
              spacing: HearthSpacing.sm,
              runSpacing: HearthSpacing.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                const _GroupLabel('人数'),
                for (final int preset in <int>[2, 5, 12, 20, 28])
                  _Pill(
                    label: '$preset',
                    selected: n == preset,
                    onTap: () => widget.state.setMemberCount(preset),
                  ),
                const SizedBox(width: HearthSpacing.md),
                const _GroupLabel('事件'),
                _Pill(
                  label: '有人进房',
                  icon: Icons.person_add_alt_1_rounded,
                  onTap: widget.state.memberJoins,
                ),
                _Pill(
                  label: '发消息',
                  icon: Icons.local_fire_department_rounded,
                  onTap: widget.state.sendRandomMessage,
                ),
                _Pill(
                  label: '有人离开',
                  icon: Icons.logout_rounded,
                  onTap: widget.state.memberLeaves,
                ),
              ],
            ),
            const SizedBox(height: HearthSpacing.sm),
            Wrap(
              spacing: HearthSpacing.md,
              runSpacing: HearthSpacing.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                _Toggle(
                  label: '随机说话',
                  value: widget.state.autoChatter,
                  onChanged: (bool v) => widget.state.autoChatter = v,
                ),
                _Toggle(
                  label: '沉睡时停表',
                  value: widget.clock.freezeWhenDeepIdle,
                  onChanged: (bool v) => setState(
                    () => widget.clock.freezeWhenDeepIdle = v,
                  ),
                ),
                _Toggle(
                  label: '紧凑(验证 +N)',
                  value: widget.compact,
                  onChanged: widget.onCompactChanged,
                ),
                _Toggle(
                  label: '性能浮层',
                  value: widget.showPerformanceOverlay,
                  onChanged: widget.onPerformanceOverlayChanged == null
                      ? null
                      : (bool v) => widget.onPerformanceOverlayChanged!(v),
                ),
                const SizedBox(width: HearthSpacing.sm),
                _Pill(
                  label: '截图',
                  icon: Icons.photo_camera_outlined,
                  onTap: _busy ? null : () => _run(widget.onCaptureOne),
                ),
                _Pill(
                  label: _busy ? '截图中…' : '跑截图序列',
                  icon: Icons.auto_awesome_motion_rounded,
                  emphasized: true,
                  onTap: _busy ? null : () => _run(widget.onCaptureSequence),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 性能 HUD
// ─────────────────────────────────────────────────────────────────────────────

/// 自建性能 HUD(SPEC §7)。不依赖任何包。
class PerfHud extends StatefulWidget {
  const PerfHud({
    super.key,
    required this.clock,
    required this.state,
    required this.layoutProbe,
  });

  final HearthClock clock;
  final HearthState state;
  final SeatLayoutProbe layoutProbe;

  @override
  State<PerfHud> createState() => _PerfHudState();
}

class _PerfHudState extends State<PerfHud> {
  /// 环形缓冲容量。120 帧 ≈ 满帧下的 2 秒窗口。
  static const int _cap = 120;

  /// `buildDuration + rasterDuration`,单位微秒。
  ///
  /// 定长 `List<int>` + 游标 = **每帧零分配**。用 `Queue` 或 `List.add/removeAt`
  /// 会在 timings 回调里持续分配,那是在性能探针里制造性能问题。
  final List<int> _totalsUs = List<int>.filled(_cap, 0);
  int _cursor = 0;
  int _filled = 0;

  /// 本秒内收到的 FrameTiming 个数,1s 定时器读完清零。
  int _framesThisWindow = 0;
  int _lastEmitted = 0;
  int _lastTicked = 0;

  Timer? _timer;

  // ── 渲染出来的快照 ──
  double _meanMs = 0;
  double _p90Ms = 0;
  int _submitRate = 0;
  int _sparks = 0;
  double _throttleRatio = 1;
  int _emittedPerSec = 0;
  int _tickedPerSec = 0;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _lastEmitted = widget.clock.emittedFrames;
    _lastTicked = widget.clock.tickedFrames;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _timer?.cancel();
    super.dispose();
  }

  /// **每帧调用,绝不 setState。** 只往环形缓冲写数。
  void _onTimings(List<FrameTiming> timings) {
    for (final FrameTiming t in timings) {
      _totalsUs[_cursor] = t.buildDuration.inMicroseconds +
          t.rasterDuration.inMicroseconds;
      _cursor = (_cursor + 1) % _cap;
      if (_filled < _cap) _filled++;
      _framesThisWindow++;
    }
  }

  /// 1 秒一次,把缓冲里的数算成可读的指标。
  void _refresh() {
    if (!mounted) return;

    final int n = _filled;
    double mean = 0;
    double p90 = 0;
    if (n > 0) {
      // 排序要在副本上做,不能打乱环形缓冲本身。每秒一次 120 元素排序,
      // 相对 1 秒的预算可以忽略。
      final List<int> sample = _totalsUs.sublist(0, n)..sort();
      int sum = 0;
      for (final int v in sample) {
        sum += v;
      }
      mean = sum / n / 1000.0;
      final int idx = ((n - 1) * 0.9).round().clamp(0, n - 1);
      p90 = sample[idx] / 1000.0;
    }

    final int emitted = widget.clock.emittedFrames;
    final int ticked = widget.clock.tickedFrames;
    final int dEmit = emitted - _lastEmitted;
    final int dTick = ticked - _lastTicked;
    _lastEmitted = emitted;
    _lastTicked = ticked;

    setState(() {
      _meanMs = mean;
      _p90Ms = p90;
      _submitRate = _framesThisWindow;
      _emittedPerSec = dEmit;
      _tickedPerSec = dTick;
      _throttleRatio = dTick > 0 ? dEmit / dTick : (ticked > 0 ? 0 : 1);
      _sparks = widget.state.sparksAliveProbe?.call() ?? 0;
      _framesThisWindow = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final SeatLayout? layout = widget.layoutProbe.last;
    final ActivityLevel level = widget.clock.level;

    return Container(
      width: 268,
      padding: const EdgeInsets.symmetric(
        horizontal: HearthSpacing.md,
        vertical: HearthSpacing.sm + 2,
      ),
      decoration: BoxDecoration(
        color: HearthColors.surface.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(HearthRadii.md),
        border: Border.all(
          color: HearthColors.ember.withValues(alpha: 0.18),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Text(
                '性能',
                style: TextStyle(
                  color: HearthColors.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                widget.clock.isFrozen ? '已停表' : level.label,
                style: TextStyle(
                  color: widget.clock.isFrozen
                      ? HearthColors.statusAway
                      : _levelColor(level),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: HearthSpacing.xs),
          _row('build+raster 均值', '${_meanMs.toStringAsFixed(2)} ms'),
          _row('build+raster p90', '${_p90Ms.toStringAsFixed(2)} ms'),
          // 「提交率」而不是「FPS」:静息时低是对的,见文件头说明。
          _row('帧提交率', '$_submitRate /s'),
          _row(
            '节流比 放行/tick',
            '$_emittedPerSec/$_tickedPerSec '
                '(${(_throttleRatio * 100).toStringAsFixed(0)}%)',
          ),
          _row('存活火星', '$_sparks'),
          if (layout != null)
            _row(
              '环 ${layout.ringCount} · d=${layout.diameter.toStringAsFixed(0)}',
              '${layout.ringCounts.join('/')}'
                  '${layout.hasOverflow ? ' +${layout.overflowCount}' : ''}',
            ),
          if (layout != null)
            _row(
              '环容量 cap',
              layout.ringCaps.join(' / '),
            ),
        ],
      ),
    );
  }

  static Color _levelColor(ActivityLevel l) => switch (l) {
        ActivityLevel.active => HearthColors.ember,
        ActivityLevel.calm => HearthColors.statusEars,
        ActivityLevel.deepIdle => HearthColors.statusAway,
      };

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: HearthColors.textSecondary,
                fontSize: 11,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: HearthColors.textPrimary,
              fontSize: 11,
              fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 小部件
// ─────────────────────────────────────────────────────────────────────────────

/// 档位 + 倒计时。
///
/// 它订阅时钟,但**自己节流到 200ms 才重建一次** —— 一个倒计时读数
/// 没必要每帧刷新,而控制条重建是要花钱的。
class _LevelChip extends StatefulWidget {
  const _LevelChip({required this.clock});
  final HearthClock clock;

  @override
  State<_LevelChip> createState() => _LevelChipState();
}

class _LevelChipState extends State<_LevelChip> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => mounted ? setState(() {}) : null,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ActivityLevel level = widget.clock.level;
    final int? next = widget.clock.msToNextLevel;
    final Color c = switch (level) {
      ActivityLevel.active => HearthColors.ember,
      ActivityLevel.calm => HearthColors.statusEars,
      ActivityLevel.deepIdle => HearthColors.statusAway,
    };
    final String tail = widget.clock.isFrozen
        ? ' · 已停表'
        : next == null
            ? ''
            : ' · ${(next / 1000).clamp(0, 999).toStringAsFixed(1)}s 后降档';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(HearthRadii.sm),
        border: Border.all(color: c.withValues(alpha: 0.40), width: 1),
      ),
      child: Text(
        '${level.label}$tail',
        style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w500),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: HearthColors.ember,
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: HearthColors.textSecondary,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    this.icon,
    this.selected = false,
    this.emphasized = false,
    this.onTap,
  });

  final String label;
  final IconData? icon;
  final bool selected;
  final bool emphasized;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bool hot = selected || emphasized;
    final Color fg = onTap == null
        ? HearthColors.textSecondary
        : hot
            ? HearthColors.ember
            : HearthColors.textPrimary;
    return Material(
      color: hot
          ? HearthColors.ember.withValues(alpha: 0.14)
          : HearthColors.surface.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(HearthRadii.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(HearthRadii.sm),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: icon == null ? 14 : 11,
            vertical: 7,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(HearthRadii.sm),
            border: Border.all(
              color: hot
                  ? HearthColors.ember.withValues(alpha: 0.55)
                  : HearthColors.textSecondary.withValues(alpha: 0.22),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 14, color: fg),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: 12,
                  fontWeight: hot ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          height: 26,
          child: Switch(
            value: value,
            onChanged: onChanged,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            activeThumbColor: HearthColors.ember,
            activeTrackColor: HearthColors.ember.withValues(alpha: 0.35),
            inactiveThumbColor: HearthColors.textSecondary,
            inactiveTrackColor: HearthColors.surface,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: value ? HearthColors.textPrimary : HearthColors.textSecondary,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}
