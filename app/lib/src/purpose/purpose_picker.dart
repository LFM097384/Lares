/// 用途选择:闲聊 / 学习 / 开会 / 自定义。
library;

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../theme/tokens.dart';
import '../ui/widgets/ai_orb.dart';
import 'purpose_schema.dart';

/// 「自定义」的选项 id(不是服务端预设:选了它由调用方打开编辑器)。
const String kPurposeCustomId = 'custom';

/// 「开会 + AI 助手」的选项结果(不是服务端预设:调用方把它换成
/// [meetingWithAiPurpose] 的完整 JSON 再应用)。
const String kPurposeMeetingAiChoice = 'meeting+ai';

/// 弹出底部面板选用途。[current] 为当前用途 id(内置 id 高亮;
/// 其它非空值视作「自定义」高亮)。
///
/// 选「开会」时先展开一个「加上 AI 助手」开关(默认关)和确认键;
/// [aiUnavailable] 为 true(端到端加密圈)时开关不可拨。
///
/// 返回内置 id(`chat` / `study` / `meeting`)、[kPurposeMeetingAiChoice]
/// 或 [kPurposeCustomId];null = 算了。
Future<String?> showPurposePicker(
  BuildContext context, {
  String? current,
  bool aiUnavailable = false,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    // 与房间「更多」面板一致:拖拽把手 + 紧贴把手的标题
    showDragHandle: true,
    builder: (ctx) =>
        _PurposePickerSheet(current: current, aiUnavailable: aiUnavailable),
  );
}

class _PurposePickerSheet extends StatefulWidget {
  const _PurposePickerSheet({this.current, required this.aiUnavailable});

  final String? current;
  final bool aiUnavailable;

  @override
  State<_PurposePickerSheet> createState() => _PurposePickerSheetState();
}

class _PurposePickerSheetState extends State<_PurposePickerSheet> {
  /// 点了「开会」:展开 AI 开关,等确认
  bool _meeting = false;
  bool _withAi = false;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final extra = !_meeting
        ? null
        // 收在「开会」底下:左边与「开会」的标题列对齐(选项行内缩 + 图标位 + 间距),
        // 一眼看出这是「开会」的子选项,不是第五个选项。
        : Padding(
            padding: const EdgeInsets.fromLTRB(
              _subIndent,
              0,
              LaresSpacing.sm + LaresSpacing.md,
              LaresSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  key: const ValueKey('purpose-meeting-ai-switch'),
                  contentPadding: EdgeInsets.zero,
                  // 与房间座位上的 AI 光球同形同色
                  secondary: AiOrbMini(
                    size: 28,
                    dim: widget.aiUnavailable,
                  ),
                  title: Text(
                    t.purposeMeetingAiSwitch,
                    style: theme.textTheme.bodyLarge,
                  ),
                  subtitle: Text(
                    widget.aiUnavailable
                        ? t.purposeMeetingAiE2ee
                        : t.purposeMeetingAiDesc,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  value: _withAi && !widget.aiUnavailable,
                  onChanged: widget.aiUnavailable
                      ? null
                      : (v) => setState(() => _withAi = v),
                ),
                const SizedBox(height: LaresSpacing.xs),
                // 与开关同一条左边线
                FilledButton(
                  key: const ValueKey('purpose-meeting-confirm'),
                  onPressed: () => Navigator.pop(
                    context,
                    _withAi && !widget.aiUnavailable
                        ? kPurposeMeetingAiChoice
                        : 'meeting',
                  ),
                  child: Text(t.purposeMeetingAiConfirm),
                ),
              ],
            ),
          );    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: LaresSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LaresSpacing.lg,
                0,
                LaresSpacing.lg,
                LaresSpacing.sm,
              ),
              child: Text(
                t.purposePickerTitle,
                style: theme.textTheme.titleMedium,
              ),
            ),
            PurposePickerList(
              current: _meeting ? 'meeting' : widget.current,
              meetingExtra: extra,
              onSelected: (id) {
                if (id == 'meeting') {
                  setState(() => _meeting = true);
                } else {
                  Navigator.pop(context, id);
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 四个选项的列表本体(面板、截图、内嵌都能用)。
class PurposePickerList extends StatelessWidget {
  const PurposePickerList({
    super.key,
    this.current,
    required this.onSelected,
    this.meetingExtra,
  });

  final String? current;
  final ValueChanged<String> onSelected;

  /// 插在「开会」下面的附加内容(「加上 AI 助手」开关)
  final Widget? meetingExtra;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final builtins = builtinPurposes(t);
    final isBuiltin = builtins.any((b) => b.id == current);
    // 选中:内缩的圆角浅底 + 标题与对勾变色;说明文字保持淡色,不整行染色。
    Widget tile(
      String id,
      String icon,
      String name,
      String desc,
      bool selected,
    ) => Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: LaresSpacing.sm,
        vertical: 2,
      ),
      child: ListTile(
        key: ValueKey('purpose-option-$id'),
        selected: selected,
        selectedTileColor: scheme.primary.withValues(alpha: 0.10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LaresRadii.md),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: LaresSpacing.md),
        leading: SizedBox(
          width: 32,
          child: Center(
            child: Text(icon, style: const TextStyle(fontSize: 22)),
          ),
        ),
        title: Text(name),
        subtitle: Text(
          desc,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        trailing: selected
            ? Icon(Icons.check_rounded, color: scheme.primary)
            : null,
        onTap: () => onSelected(id),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final b in builtins) ...[
          tile(b.id, b.icon, b.name, b.description, current == b.id),
          if (b.id == 'meeting' && meetingExtra != null) meetingExtra!,
        ],
        tile(
          kPurposeCustomId,
          '✏️',
          t.purposeCustom,
          t.purposeCustomDesc,
          current != null && !isBuiltin,
        ),
      ],
    );
  }
}

/// 建圈对话框里的紧凑版:四个 ChoiceChip。
class PurposeChips extends StatelessWidget {
  const PurposeChips({super.key, required this.value, required this.onChanged});

  /// 内置 id 或 [kPurposeCustomId]
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final items = [
      for (final b in builtinPurposes(t)) (b.id, b.icon, b.name),
      (kPurposeCustomId, '✏️', t.purposeCustom),
    ];
    return Wrap(
      spacing: LaresSpacing.sm,
      runSpacing: LaresSpacing.xs,
      children: [
        for (final (id, icon, name) in items)
          ChoiceChip(
            key: ValueKey('purpose-chip-$id'),
            label: Text('$icon $name'),
            selected: value == id,
            onSelected: (_) => onChanged(id),
          ),
      ],
    );
  }
}

/// 「开会」子选项的左缩进 = 选项行外边距 + 内边距 + 图标位 + ListTile 标题间距,
/// 与选项标题对齐。
const double _subIndent = LaresSpacing.sm + LaresSpacing.md + 32 + 16;
