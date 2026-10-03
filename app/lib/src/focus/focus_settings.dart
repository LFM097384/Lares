import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../theme/tokens.dart';
import 'focus_models.dart';

/// 圈主的专注配置编辑器(契约 §6.1)。改完点「存下」才回调 [onSave] ——
/// 拖滑块时不往服务器发一串 plugin_config_set。
class FocusSettingsPanel extends StatefulWidget {
  const FocusSettingsPanel({
    super.key,
    required this.config,
    required this.onSave,
  });

  final FocusConfig config;
  final ValueChanged<FocusConfig> onSave;

  @override
  State<FocusSettingsPanel> createState() => _FocusSettingsPanelState();
}

class _FocusSettingsPanelState extends State<FocusSettingsPanel> {
  late FocusConfig _draft = widget.config;

  @override
  void didUpdateWidget(FocusSettingsPanel old) {
    super.didUpdateWidget(old);
    // 服务器回推了新配置(别处改的),且本地没有未存的修改 → 跟上
    if (old.config != widget.config && _draft == old.config) {
      _draft = widget.config;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final dirty = _draft != widget.config;
    return Column(
      key: const ValueKey('focus-settings'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _SliderRow(
          key: const ValueKey('focus-settings-focusMin'),
          label: t.focusSettingsFocusMin,
          valueLabel: t.focusMinutes(_draft.focusMin),
          value: _draft.focusMin,
          min: 5,
          max: 120,
          step: 5,
          onChanged: (v) => setState(() => _draft = _draft.copyWith(focusMin: v)),
        ),
        _SliderRow(
          key: const ValueKey('focus-settings-breakMin'),
          label: t.focusSettingsBreakMin,
          valueLabel: t.focusMinutes(_draft.breakMin),
          value: _draft.breakMin,
          min: 1,
          max: 30,
          onChanged: (v) => setState(() => _draft = _draft.copyWith(breakMin: v)),
        ),
        _SliderRow(
          key: const ValueKey('focus-settings-rounds'),
          label: t.focusSettingsRounds,
          valueLabel: t.focusSettingsRoundsValue(_draft.rounds),
          value: _draft.rounds,
          min: 1,
          max: 12,
          onChanged: (v) => setState(() => _draft = _draft.copyWith(rounds: v)),
        ),
        _SliderRow(
          key: const ValueKey('focus-settings-grace'),
          label: t.focusSettingsGrace,
          hint: t.focusSettingsGraceHint,
          valueLabel: t.focusSettingsGraceValue(_draft.graceSec),
          value: _draft.graceSec,
          min: 0,
          max: 120,
          step: 5,
          onChanged: (v) => setState(() => _draft = _draft.copyWith(graceSec: v)),
        ),
        SwitchListTile(
          key: const ValueKey('focus-settings-membersCanStart'),
          contentPadding: EdgeInsets.zero,
          title: Text(t.focusSettingsMembersCanStart),
          value: _draft.membersCanStart,
          onChanged: (v) =>
              setState(() => _draft = _draft.copyWith(membersCanStart: v)),
        ),
        const SizedBox(height: LaresSpacing.xs),
        Text(
          t.focusSettingsPrivacy,
          style: theme.textTheme.bodyMedium?.copyWith(fontSize: 12),
        ),
        const SizedBox(height: LaresSpacing.sm),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            key: const ValueKey('focus-settings-save'),
            onPressed: dirty ? () => widget.onSave(_draft) : null,
            child: Text(t.focusSettingsSave),
          ),
        ),
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    super.key,
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.step = 1,
    this.hint,
  });

  final String label;
  final String valueLabel;
  final String? hint;
  final int value;
  final int min;
  final int max;
  final int step;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 服务器允许的值可能不在步进格上(比如 focusMin=7),滑块只显示夹紧后的位置
    final v = value.clamp(min, max);
    return Padding(
      padding: const EdgeInsets.only(top: LaresSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: theme.textTheme.bodyLarge)),
              Text(
                valueLabel,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: LaresColors.ember,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          if (hint != null)
            Text(hint!, style: theme.textTheme.bodyMedium?.copyWith(fontSize: 12)),
          Slider(
            value: v.toDouble(),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: ((max - min) / step).round().clamp(1, 1000),
            onChanged: (d) {
              var n = d.round();
              if (step > 1) n = (n / step).round() * step;
              n = n.clamp(min, max);
              if (n != value) onChanged(n);
            },
          ),
        ],
      ),
    );
  }
}

/// 整页形态(插件管理里点「设置」推进来的页面)。[save] 返回 true = 存好了,退页。
class FocusSettingsPage extends StatefulWidget {
  const FocusSettingsPage({
    super.key,
    required this.config,
    required this.save,
  });

  final Map<String, dynamic> config;
  final Future<bool> Function(Map<String, dynamic> config) save;

  @override
  State<FocusSettingsPage> createState() => _FocusSettingsPageState();
}

class _FocusSettingsPageState extends State<FocusSettingsPage> {
  bool _busy = false;

  Future<void> _save(Map<String, dynamic> c) async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await widget.save(c);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      Navigator.of(context).maybePop();
    } else {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).focusErrorGeneric)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.focusSettingsTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(LaresSpacing.lg),
          children: [
            AbsorbPointer(
              absorbing: _busy,
              child: buildFocusSettings(
                context,
                circleId: '',
                config: widget.config,
                onSave: _save,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 给插件系统圈主设置页(`focusSettingsBuilder`)用的入口:
/// 原始 JSON 配置进、原始 JSON 配置出。
Widget buildFocusSettings(
  BuildContext context, {
  required String circleId,
  required Map<String, dynamic> config,
  required void Function(Map<String, dynamic>) onSave,
}) {
  return FocusSettingsPanel(
    key: ValueKey('focus-settings-$circleId'),
    config: FocusConfig.fromJson(config),
    onSave: (c) => onSave(c.toJson()),
  );
}
