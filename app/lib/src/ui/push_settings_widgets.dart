/// 活动推送的三处设置(plugin-focus-contract §9.5):
///
/// - [CirclePushLevelTile]:成员按圈「通知我」全部 / 只要被叫 / 关(本机存,随 push_register 上报);
/// - [OwnerPushTriggersTile] + [PushTriggersSheet]:圈主的触发开关与人数阈值(服务器存);
/// - [PushQuietTile]:全局推送免打扰时段(本机时区,随 push_register 上报)。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../focus/activity_push.dart';
import '../state/settings_store.dart';
import '../theme/tokens.dart';

String _levelLabel(AppLocalizations t, String level) => switch (level) {
  'called' => t.pushLevelCalled,
  'off' => t.pushLevelOff,
  _ => t.pushLevelAll,
};

// ─────────────────────────── 成员:通知我 ───────────────────────────

class CirclePushLevelTile extends StatelessWidget {
  const CirclePushLevelTile({
    super.key,
    required this.settings,
    required this.circleId,
  });

  final SettingsStore settings;
  final String circleId;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final level = settings.circlePushLevel(circleId);
        return ListTile(
          key: const ValueKey('circle-push-level'),
          leading: Icon(switch (level) {
            'off' => Icons.notifications_off_outlined,
            'called' => Icons.notifications_paused_outlined,
            _ => Icons.notifications_rounded,
          }),
          title: Text(t.pushLevelTile(_levelLabel(t, level))),
          onTap: () => unawaited(_pick(context, level)),
        );
      },
    );
  }

  Future<void> _pick(BuildContext context, String current) async {
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => PushLevelDialog(current: current),
    );
    if (picked == null || picked == current) return;
    // 只改本机;PushService 监听到变化会把新等级发给服务器
    await settings.setCirclePushLevel(circleId, picked);
  }
}

class PushLevelDialog extends StatelessWidget {
  const PushLevelDialog({super.key, required this.current});

  final String current;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final descs = {
      'all': t.pushLevelAllDesc,
      'called': t.pushLevelCalledDesc,
      'off': t.pushLevelOffDesc,
    };
    return SimpleDialog(
      key: const ValueKey('push-level-dialog'),
      title: Text(t.pushLevelTitle),
      children: [
        RadioGroup<String>(
          groupValue: current,
          onChanged: (v) => Navigator.pop(context, v),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final l in kPushLevels)
                RadioListTile<String>(
                  key: ValueKey('push-level-$l'),
                  value: l,
                  title: Text(_levelLabel(t, l)),
                  subtitle: Text(descs[l]!),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────── 圈主:活动提醒 ───────────────────────────

class OwnerPushTriggersTile extends StatelessWidget {
  const OwnerPushTriggersTile({
    super.key,
    required this.activity,
    required this.circleId,
    required this.hostContext,
    this.onBeforeOpen,
  });

  final ActivityPush activity;
  final String circleId;

  /// 底部菜单关掉后仍活着的 context,用来开设置面板。
  final BuildContext hostContext;
  final VoidCallback? onBeforeOpen;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListTile(
      key: const ValueKey('owner-push-triggers'),
      leading: const Icon(Icons.campaign_outlined),
      title: Text(t.pushTriggersTitle),
      subtitle: Text(t.pushTriggersSub),
      onTap: () {
        onBeforeOpen?.call();
        activity.refresh(circleId);
        unawaited(
          showModalBottomSheet<void>(
            context: hostContext,
            isScrollControlled: true,
            showDragHandle: true,
            builder: (_) =>
                PushTriggersSheet(activity: activity, circleId: circleId),
          ),
        );
      },
    );
  }
}

class PushTriggersSheet extends StatefulWidget {
  const PushTriggersSheet({
    super.key,
    required this.activity,
    required this.circleId,
  });

  final ActivityPush activity;
  final String circleId;

  @override
  State<PushTriggersSheet> createState() => _PushTriggersSheetState();
}

class _PushTriggersSheetState extends State<PushTriggersSheet> {
  bool _saving = false;

  /// 本地正在改、还没被服务器回 push_cfg 覆盖的那份(乐观更新)
  PushTriggerConfig? _draft;

  Future<void> _save(PushTriggerConfig? cfg) async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() {
      _saving = true;
      _draft = cfg;
    });
    final ok = await widget.activity.save(widget.circleId, cfg);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _draft = null;
    });
    if (!ok) {
      messenger?.showSnackBar(SnackBar(content: Text(t.pushTriggersFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.activity,
      builder: (context, _) {
        final view = widget.activity.viewOf(widget.circleId);
        if (view == null) {
          return Padding(
            padding: const EdgeInsets.all(LaresSpacing.xl),
            child: Center(child: Text(t.pushTriggersLoading)),
          );
        }
        final cfg = _draft ?? view.cfg;
        final muted = theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        );
        return SafeArea(
          child: SingleChildScrollView(
            key: const ValueKey('push-triggers-sheet'),
            padding: const EdgeInsets.only(bottom: LaresSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    LaresSpacing.lg,
                    0,
                    LaresSpacing.lg,
                    LaresSpacing.xs,
                  ),
                  child: Text(
                    t.pushTriggersTitle,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LaresSpacing.lg,
                  ),
                  child: Text(t.pushTriggersSub, style: muted),
                ),
                const SizedBox(height: LaresSpacing.sm),
                SwitchListTile(
                  key: const ValueKey('push-trigger-focus'),
                  value: cfg.focus,
                  onChanged: _saving
                      ? null
                      : (v) => _save(cfg.copyWith(focus: v)),
                  title: Text(t.pushTriggerFocus),
                  subtitle: Text(t.pushTriggerFocusDesc),
                ),
                SwitchListTile(
                  key: const ValueKey('push-trigger-crowd'),
                  value: cfg.crowd,
                  onChanged: _saving
                      ? null
                      : (v) => _save(cfg.copyWith(crowd: v)),
                  title: Text(t.pushTriggerCrowd),
                  subtitle: Text(t.pushTriggerCrowdDesc(cfg.crowdN)),
                ),
                if (cfg.crowd)
                  Padding(
                    padding: const EdgeInsets.only(
                      left: LaresSpacing.lg,
                      right: LaresSpacing.sm,
                    ),
                    child: Row(
                      children: [
                        Expanded(child: Text(t.pushTriggerCrowdN)),
                        IconButton(
                          key: const ValueKey('push-crowd-minus'),
                          onPressed: _saving || cfg.crowdN <= kCrowdNMin
                              ? null
                              : () => _save(
                                  cfg.copyWith(crowdN: cfg.crowdN - 1),
                                ),
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                        SizedBox(
                          width: 56,
                          child: Text(
                            t.pushTriggerCrowdNValue(cfg.crowdN),
                            key: const ValueKey('push-crowd-n'),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        IconButton(
                          key: const ValueKey('push-crowd-plus'),
                          onPressed: _saving || cfg.crowdN >= kCrowdNMax
                              ? null
                              : () => _save(
                                  cfg.copyWith(crowdN: cfg.crowdN + 1),
                                ),
                          icon: const Icon(Icons.add_circle_outline),
                        ),
                      ],
                    ),
                  ),
                SwitchListTile(
                  key: const ValueKey('push-trigger-arrive'),
                  value: cfg.arrive,
                  onChanged: _saving
                      ? null
                      : (v) => _save(cfg.copyWith(arrive: v)),
                  title: Text(t.pushTriggerArrive),
                  subtitle: Text(t.pushTriggerArriveDesc),
                ),
                const Divider(height: LaresSpacing.lg),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LaresSpacing.lg,
                  ),
                  child: Text(
                    t.pushTriggersLimits(view.cooldownMin, view.dailyCap),
                    style: muted,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    LaresSpacing.md,
                    LaresSpacing.xs,
                    LaresSpacing.md,
                    0,
                  ),
                  child: cfg.custom
                      ? TextButton.icon(
                          key: const ValueKey('push-triggers-reset'),
                          onPressed: _saving ? null : () => _save(null),
                          icon: const Icon(Icons.restart_alt_rounded),
                          label: Text(t.pushTriggersReset),
                        )
                      : Padding(
                          padding: const EdgeInsets.all(LaresSpacing.sm),
                          child: Text(t.pushTriggersPurpose, style: muted),
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────── 全局:推送免打扰 ───────────────────────────

String formatMinuteOfDay(int m) {
  final h = (m ~/ 60) % 24;
  final mm = m % 60;
  return '${h.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}';
}

class PushQuietTile extends StatelessWidget {
  const PushQuietTile({super.key, required this.settings});

  final SettingsStore settings;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final on = settings.pushQuietOn;
        final range =
            '${formatMinuteOfDay(settings.pushQuietStart)}–${formatMinuteOfDay(settings.pushQuietEnd)}';
        return ListTile(
          key: const ValueKey('push-quiet-tile'),
          leading: const Icon(Icons.bedtime_outlined),
          title: Text(t.pushQuietTitle),
          subtitle: Text(on ? t.pushQuietOnSub(range) : t.pushQuietOffSub),
          onTap: () => unawaited(
            showDialog<void>(
              context: context,
              builder: (_) => PushQuietDialog(settings: settings),
            ),
          ),
        );
      },
    );
  }
}

class PushQuietDialog extends StatelessWidget {
  const PushQuietDialog({super.key, required this.settings});

  final SettingsStore settings;

  Future<void> _pickTime(BuildContext context, {required bool start}) async {
    final cur = start ? settings.pushQuietStart : settings.pushQuietEnd;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: cur ~/ 60, minute: cur % 60),
    );
    if (picked == null) return;
    final m = picked.hour * 60 + picked.minute;
    await settings.setPushQuiet(
      on: true,
      start: start ? m : null,
      end: start ? null : m,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final on = settings.pushQuietOn;
        return AlertDialog(
          key: const ValueKey('push-quiet-dialog'),
          title: Text(t.pushQuietTitle),
          contentPadding: const EdgeInsets.fromLTRB(0, LaresSpacing.md, 0, 0),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                key: const ValueKey('push-quiet-switch'),
                value: on,
                onChanged: (v) => settings.setPushQuiet(on: v),
                title: Text(t.pushQuietSwitch),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: LaresSpacing.lg,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        key: const ValueKey('push-quiet-start'),
                        onPressed: on
                            ? () => _pickTime(context, start: true)
                            : null,
                        child: Text(formatMinuteOfDay(settings.pushQuietStart)),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: LaresSpacing.sm,
                      ),
                      child: Text('–'),
                    ),
                    Expanded(
                      child: OutlinedButton(
                        key: const ValueKey('push-quiet-end'),
                        onPressed: on
                            ? () => _pickTime(context, start: false)
                            : null,
                        child: Text(formatMinuteOfDay(settings.pushQuietEnd)),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  LaresSpacing.lg,
                  LaresSpacing.md,
                  LaresSpacing.lg,
                  0,
                ),
                child: Text(
                  t.pushQuietHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t.pushQuietDone),
            ),
          ],
        );
      },
    );
  }
}
