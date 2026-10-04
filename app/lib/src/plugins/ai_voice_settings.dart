/// 内置 AI 语音助手(`lares.ai-voice`,docs/ai-voice-bot.md)的圈主设置表单,
/// 以及房间「更多」里给成员看的说明面板。
///
/// 存下走插件通用的 `plugin_config_set`;服务器宽松归一(夹紧 / 截断 / 补默认),
/// 这里先把范围校验做在前面,免得存进去的和看到的不一样。
library;

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../theme/tokens.dart';
import '../ui/ai_hint_card.dart';
import 'plugin_models.dart';
import 'plugin_service.dart';

/// 默认人设(与 server/src/ai_voice_config.js 的 AI_VOICE_DEFAULT_PERSONA 一致)。
const String kAiVoiceDefaultPersona =
    '你是圈子里的语音小助手。用口语化、温暖、简短的中文回答,一般一两句话;不确定就直说不知道;不要使用 Markdown、列表或表情符号。';

/// 默认配置(与服务端 AI_VOICE_DEFAULTS 一致;只有 wakeWords 例外)。
///
/// wakeWords 客户端默认留空:名字本身永远是唤醒词,服务端默认的「小助手」
/// 和默认名字重复,表单里再显示一遍只会让人以为要填两次。
const Map<String, Object> kAiVoiceDefaults = {
  'name': '小助手',
  'wakeWords': '',
  'persona': kAiVoiceDefaultPersona,
  'trigger': 'wake',
  'voice': 'Cherry',
  'model': 'qwen-flash',
  'maxReplyChars': 120,
  'maxTurnsPerHour': 30,
  'maxTurnsPerDay': 200,
  'interrupt': true,
};

/// 可选音色(DashScope TTS)。当前配置里若是别的值,下拉里照样保留它。
const List<String> kAiVoiceVoices = ['Cherry', 'Serena', 'Ethan', 'Chelsie'];

const List<String> kAiVoiceTriggers = ['wake', 'always', 'ptt'];

/// 表单里把多个叫法拼回一行用的分隔符(服务端认顿号)。
const String kAiVoiceWakeWordsJoin = '、';

/// 数字字段的范围(与服务端 INT_RANGE 一致)。
const Map<String, (int, int)> kAiVoiceIntRanges = {
  'maxReplyChars': (20, 400),
  'maxTurnsPerHour': (1, 200),
  'maxTurnsPerDay': (1, 2000),
};

final RegExp _tokenRe = RegExp(r'^[A-Za-z0-9._-]+$');

String _str(Map<String, dynamic> c, String k) {
  final v = c[k];
  return v is String && v.trim().isNotEmpty ? v : kAiVoiceDefaults[k]! as String;
}

int _int(Map<String, dynamic> c, String k) {
  final v = c[k];
  return v is num && v.isFinite ? v.round() : kAiVoiceDefaults[k]! as int;
}

/// AI 的名字(配置里没有就用默认「小助手」)。
String aiVoiceName(Map<String, dynamic> config) => _str(config, 'name');

/// 触发方式(不认识的值按 `wake`)。
String aiVoiceTrigger(Map<String, dynamic> config) {
  final v = config['trigger'];
  return kAiVoiceTriggers.contains(v) ? v as String : 'wake';
}

/// 除名字外的别的叫法:按服务端 `parseWakeWords`(voice-agent/wake.mjs)的分隔符
/// (逗号 / 顿号 / 分号 / 换行,全半角都认)拆开,去空、去重、去掉和名字相同的。
/// 分隔符刻意与服务端一字不差:说明卡上列出的叫法必须真的叫得应。
List<String> aiVoiceExtraWakeWords(Map<String, dynamic> config) {
  final String name = aiVoiceName(config);
  final Object? raw = config['wakeWords'];
  final String s = raw is String ? raw : kAiVoiceDefaults['wakeWords']! as String;
  final Set<String> seen = {name};
  final List<String> out = [];
  for (final String part in s.split(RegExp(r'[,，、;；\n]+'))) {
    final String w = part.trim();
    if (w.isEmpty || !seen.add(w)) continue;
    out.add(w);
  }
  return out;
}

/// 圈主设置页:隐私说明 + 表单。[e2ee] 为 true 时额外说明为什么在这个圈用不了。
class AiVoiceSettingsPage extends StatelessWidget {
  const AiVoiceSettingsPage({
    super.key,
    required this.service,
    required this.circleId,
    required this.plugin,
    this.e2ee = false,
  });

  final PluginService service;
  final String circleId;
  final PluginView plugin;
  final bool e2ee;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.aiVoiceSettingsTitle)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(LaresSpacing.lg),
          child: AiVoiceSettingsForm(
            config: plugin.config,
            e2ee: e2ee,
            onSave: (c) => service.setConfig(circleId, plugin.id, c),
            onSaved: () => Navigator.of(context).maybePop(),
            onCancel: () => Navigator.of(context).maybePop(),
          ),
        ),
      ),
    );
  }
}

/// 表单本体(也可以单独嵌进别处 / 测试)。
class AiVoiceSettingsForm extends StatefulWidget {
  const AiVoiceSettingsForm({
    super.key,
    required this.config,
    required this.onSave,
    this.onSaved,
    this.onCancel,
    this.e2ee = false,
  });

  final Map<String, dynamic> config;
  final Future<PluginOpResult> Function(Map<String, dynamic> config) onSave;
  final VoidCallback? onSaved;

  /// 「算了」:不存直接走。null = 不显示(嵌在别处时由外层负责退出)。
  final VoidCallback? onCancel;
  final bool e2ee;

  @override
  State<AiVoiceSettingsForm> createState() => _AiVoiceSettingsFormState();
}

class _AiVoiceSettingsFormState extends State<AiVoiceSettingsForm> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: _str(widget.config, 'name'));
  // 只显示名字以外的叫法(去空、去重、去掉和名字相同的):服务端存的「小助手,小助手」
  // 或等于名字的那一项不再出现在框里;存回去的就是框里这些,服务端不用改。
  late final _wake = TextEditingController(
      text: aiVoiceExtraWakeWords(widget.config).join(kAiVoiceWakeWordsJoin));
  late final _persona =
      TextEditingController(text: _str(widget.config, 'persona'));
  late final _model = TextEditingController(text: _str(widget.config, 'model'));
  late final Map<String, TextEditingController> _ints = {
    for (final k in kAiVoiceIntRanges.keys)
      k: TextEditingController(text: '${_int(widget.config, k)}'),
  };
  late String _trigger = aiVoiceTrigger(widget.config);
  late String _voice = _str(widget.config, 'voice');
  late bool _interrupt = widget.config['interrupt'] is bool
      ? widget.config['interrupt'] as bool
      : true;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _wake.dispose();
    _persona.dispose();
    _model.dispose();
    for (final c in _ints.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> _collect() => {
        'name': _name.text.trim(),
        'wakeWords': _wake.text.trim(),
        'persona': _persona.text.trim(),
        'trigger': _trigger,
        'voice': _voice,
        'model': _model.text.trim(),
        for (final e in _ints.entries) e.key: int.parse(e.value.text.trim()),
        'interrupt': _interrupt,
      };

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final r = await widget.onSave(_collect());
    if (!mounted) return;
    setState(() => _saving = false);
    if (r.ok) {
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(t.aiVoiceSaved)));
      widget.onSaved?.call();
    } else {
      setState(() => _error = t.aiVoiceSaveFailed(r.reason ?? ''));
    }
  }

  String? _intValidator(AppLocalizations t, String key, String? v) {
    final (lo, hi) = kAiVoiceIntRanges[key]!;
    final n = int.tryParse((v ?? '').trim());
    if (n == null || n < lo || n > hi) return t.aiVoiceRangeError(lo, hi);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final voices = [
      ...kAiVoiceVoices,
      if (!kAiVoiceVoices.contains(_voice)) _voice,
    ];
    final triggerDesc = switch (_trigger) {
      'always' => t.aiVoiceTriggerAlwaysDesc,
      'ptt' => t.aiVoiceTriggerPttDesc(
          _name.text.trim().isEmpty ? aiVoiceName(const {}) : _name.text.trim()),
      _ => t.aiVoiceTriggerWakeDesc,
    };
    Widget intField(String key, String label) => Padding(
          padding: const EdgeInsets.only(bottom: LaresSpacing.md),
          child: TextFormField(
            key: ValueKey('ai-voice-$key'),
            controller: _ints[key],
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: label,
              helperText: t.aiVoiceRangeHint(
                  kAiVoiceIntRanges[key]!.$1, kAiVoiceIntRanges[key]!.$2),
            ),
            validator: (v) => _intValidator(t, key, v),
          ),
        );

    return Form(
      key: _form,
      child: Column(
        key: const ValueKey('ai-voice-settings'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Card(
            key: const ValueKey('ai-voice-privacy'),
            color: scheme.surfaceContainerHighest,
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(LaresSpacing.md),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.privacy_tip_outlined,
                      size: 20, color: scheme.onSurfaceVariant),
                  const SizedBox(width: LaresSpacing.sm),
                  Expanded(
                    child: Text(t.aiVoicePrivacyNote,
                        style: theme.textTheme.bodySmall),
                  ),
                ],
              ),
            ),
          ),
          if (widget.e2ee) ...[
            const SizedBox(height: LaresSpacing.sm),
            Text(
              t.aiVoiceE2eeBlocked,
              key: const ValueKey('ai-voice-e2ee'),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ],
          // ── 叫它:名字 / 别的叫法 / 什么时候回答 ──
          _SectionHeader(
            key: const ValueKey('ai-voice-section-call'),
            icon: Icons.record_voice_over_outlined,
            title: t.aiVoiceSectionCall,
          ),
          TextFormField(
            key: const ValueKey('ai-voice-name'),
            controller: _name,
            maxLength: 16,
            decoration: InputDecoration(
              labelText: t.aiVoiceFieldName,
              helperText: t.aiVoiceFieldNameHelper,
            ),
            onChanged: (_) => setState(() {}),
            validator: (v) =>
                (v ?? '').trim().isEmpty ? t.aiVoiceFieldNameEmpty : null,
          ),
          TextFormField(
            key: const ValueKey('ai-voice-wakeWords'),
            controller: _wake,
            maxLength: 100,
            decoration: InputDecoration(
              labelText: t.aiVoiceFieldWakeWords,
              hintText: t.aiVoiceFieldWakeWordsEmpty,
              helperText: t.aiVoiceFieldWakeWordsHint,
            ),
          ),
          const SizedBox(height: LaresSpacing.md),
          Text(t.aiVoiceFieldTrigger, style: theme.textTheme.titleSmall),
          const SizedBox(height: LaresSpacing.sm),
          SegmentedButton<String>(
            key: const ValueKey('ai-voice-trigger'),
            showSelectedIcon: false,
            // 三个选项是并列的选择,不是标题:用正文字重,选中靠底色区分
            style: ButtonStyle(
              textStyle: WidgetStatePropertyAll(theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w400)),
            ),
            segments: [
              ButtonSegment(
                value: 'wake',
                label: Text(t.aiVoiceTriggerWake,
                    key: const ValueKey('ai-voice-trigger-wake')),
              ),
              ButtonSegment(
                value: 'always',
                label: Text(t.aiVoiceTriggerAlways,
                    key: const ValueKey('ai-voice-trigger-always')),
              ),
              ButtonSegment(
                value: 'ptt',
                label: Text(t.aiVoiceTriggerPtt,
                    key: const ValueKey('ai-voice-trigger-ptt')),
              ),
            ],
            selected: {_trigger},
            onSelectionChanged: (s) => setState(() => _trigger = s.first),
          ),
          const SizedBox(height: LaresSpacing.xs),
          Text(
            triggerDesc,
            key: const ValueKey('ai-voice-trigger-desc'),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),

          // ── 它怎么说话:音色 / 人设 / 插话就停 ──
          _SectionHeader(
            key: const ValueKey('ai-voice-section-voice'),
            icon: Icons.graphic_eq_rounded,
            title: t.aiVoiceSectionVoice,
          ),
          DropdownButtonFormField<String>(
            key: const ValueKey('ai-voice-voice'),
            initialValue: _voice,
            decoration: InputDecoration(
              labelText: t.aiVoiceFieldVoice,
              helperText: t.aiVoiceFieldVoiceHelper,
            ),
            items: [
              for (final v in voices)
                DropdownMenuItem(value: v, child: Text(v)),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _voice = v);
            },
          ),
          const SizedBox(height: LaresSpacing.md),
          // 「恢复默认」紧挨着人设框的右上:改坏了随手就能撤回
          Row(
            children: [
              Expanded(
                child: Text(t.aiVoiceFieldPersona,
                    style: theme.textTheme.titleSmall),
              ),
              TextButton(
                key: const ValueKey('ai-voice-persona-reset'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding:
                      const EdgeInsets.symmetric(horizontal: LaresSpacing.sm),
                ),
                onPressed: () =>
                    setState(() => _persona.text = kAiVoiceDefaultPersona),
                child: Text(t.aiVoicePersonaReset),
              ),
            ],
          ),
          const SizedBox(height: LaresSpacing.xs),
          TextFormField(
            key: const ValueKey('ai-voice-persona'),
            controller: _persona,
            maxLength: 1000,
            minLines: 3,
            maxLines: 8,
            decoration: InputDecoration(
              helperText: t.aiVoiceFieldPersonaHelper,
            ),
          ),
          const SizedBox(height: LaresSpacing.sm),
          SwitchListTile(
            key: const ValueKey('ai-voice-interrupt'),
            contentPadding: EdgeInsets.zero,
            title: Text(t.aiVoiceFieldInterrupt),
            subtitle: Text(t.aiVoiceFieldInterruptHelper),
            value: _interrupt,
            onChanged: (v) => setState(() => _interrupt = v),
          ),
          const SizedBox(height: LaresSpacing.sm),
          // ── 用量(折叠):次数 / 字数上限 + 对话模型 ──
          ExpansionTile(
            key: const ValueKey('ai-voice-advanced'),
            // 去掉展开 / 收起时上下两道分隔线:分组靠留白,不靠画线
            shape: const Border(),
            collapsedShape: const Border(),
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            // 收起时子字段仍要参与校验:保持挂在树上
            maintainState: true,
            leading: Icon(Icons.speed_rounded, color: scheme.tertiary),
            title: Text(t.aiVoiceSectionUsage),
            subtitle: Text(t.aiVoiceUsageHelper,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
            children: [
              const SizedBox(height: LaresSpacing.sm),
              intField('maxReplyChars', t.aiVoiceFieldMaxReplyChars),
              intField('maxTurnsPerHour', t.aiVoiceFieldMaxTurnsPerHour),
              intField('maxTurnsPerDay', t.aiVoiceFieldMaxTurnsPerDay),
              Padding(
                padding: const EdgeInsets.only(bottom: LaresSpacing.md),
                child: TextFormField(
                  key: const ValueKey('ai-voice-model'),
                  controller: _model,
                  maxLength: 64,
                  decoration: InputDecoration(
                    labelText: t.aiVoiceFieldModel,
                    helperText: t.aiVoiceFieldModelHelper,
                  ),
                  validator: (v) => _tokenRe.hasMatch((v ?? '').trim())
                      ? null
                      : t.aiVoiceFieldModelInvalid,
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: LaresSpacing.sm),
            Text(_error!,
                key: const ValueKey('ai-voice-error'),
                style: TextStyle(color: scheme.error)),
          ],
          const SizedBox(height: LaresSpacing.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (widget.onCancel != null) ...[
                TextButton(
                  key: const ValueKey('ai-voice-cancel'),
                  onPressed: _saving ? null : widget.onCancel,
                  child: Text(t.commonCancel),
                ),
                const SizedBox(width: LaresSpacing.sm),
              ],
              FilledButton(
                key: const ValueKey('ai-voice-save'),
                onPressed: _saving ? null : _save,
                child: Text(t.commonSave),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 表单分组标题:小图标 + 一行字,上面留出呼吸。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({super.key, required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(
          top: LaresSpacing.lg, bottom: LaresSpacing.sm),
      child: Row(
        children: [
          Icon(icon, size: 20, color: scheme.tertiary),
          const SizedBox(width: LaresSpacing.sm),
          Expanded(
            child: Text(title,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

/// 房间「更多」→「AI 助手」:它叫什么、怎么叫它、语音去了哪儿。
///
/// 内容与点 AI 座位弹出的说明卡([AiHintCard])是同一份,面板按内容高度。
Future<void> showAiVoiceInfoSheet(
    BuildContext context, Map<String, dynamic> config) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => AiVoiceInfoSheet(config: config),
  );
}

class AiVoiceInfoSheet extends StatelessWidget {
  const AiVoiceInfoSheet({super.key, required this.config});

  final Map<String, dynamic> config;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          key: const ValueKey('ai-info-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AiHintCard(
              config: config,
              askKey: const ValueKey('ai-info-how'),
              privacyKey: const ValueKey('ai-info-privacy'),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(
                    right: LaresSpacing.md, bottom: LaresSpacing.sm),
                child: TextButton(
                  key: const ValueKey('ai-info-close'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(t.commonGotIt),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}