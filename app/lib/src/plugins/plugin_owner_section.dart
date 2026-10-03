/// 圈主的插件管理(契约 §3 / §7):列表、启停、卸载、安装(内置 / URL / 粘贴)、
/// 一次性 token 展示、专注学习配置入口。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/gen/app_localizations.dart';
import '../theme/tokens.dart';
import 'ai_voice_settings.dart';
import 'plugin_models.dart';
import 'plugin_service.dart';

/// 专注学习设置页的构造器。另一个模块(lib/src/focus/)可以注入自己的页面。
typedef FocusSettingsBuilder = Widget Function(
    BuildContext context, PluginService service, String circleId, PluginView plugin);

/// 圈子菜单里的「插件」入口(只给本机持有圈主钥匙的圈)。
class PluginOwnerTile extends StatelessWidget {
  const PluginOwnerTile({
    super.key,
    required this.service,
    required this.circleId,
    this.onBeforeOpen,
    this.focusSettingsBuilder,
    this.e2ee = false,
  });

  final PluginService service;
  final String circleId;
  final VoidCallback? onBeforeOpen;
  final FocusSettingsBuilder? focusSettingsBuilder;

  /// 本圈开着端到端加密:AI 助手装不了 / 开不了。
  final bool e2ee;

  @override
  Widget build(BuildContext context) {
    if (!service.isOwner(circleId)) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    final nav = Navigator.of(context);
    return ListTile(
      key: const ValueKey('plugins-owner-tile'),
      leading: const Icon(Icons.extension_outlined),
      title: Text(t.pluginTitle),
      subtitle: Text(t.pluginEntryDesc),
      onTap: () {
        onBeforeOpen?.call();
        nav.push(MaterialPageRoute<void>(
          builder: (_) => PluginsScreen(
            service: service,
            circleId: circleId,
            focusSettingsBuilder: focusSettingsBuilder,
            e2ee: e2ee,
          ),
        ));
      },
    );
  }
}

String _reasonText(AppLocalizations t, PluginOpResult r) {
  final base = switch (r.reason) {
    'already_installed' => t.pluginErrAlreadyInstalled,
    'too_many' => t.pluginErrTooMany,
    'bad_manifest' => t.pluginErrBadManifest,
    'manifest_fetch_failed' || 'ssrf_blocked' => t.pluginErrFetch,
    'timeout' => t.pluginErrTimeout,
    'not_owner' || 'no_key' => t.pluginErrNotOwner,
    _ => t.pluginErrGeneric(r.reason ?? ''),
  };
  return r.detail == null || r.detail!.isEmpty ? base : '$base(${r.detail})';
}

class PluginsScreen extends StatefulWidget {
  const PluginsScreen({
    super.key,
    required this.service,
    required this.circleId,
    this.focusSettingsBuilder,
    this.e2ee = false,
  });

  final PluginService service;
  final String circleId;
  final FocusSettingsBuilder? focusSettingsBuilder;

  /// 本圈开着端到端加密:AI 助手不能装 / 开(说明原因)。
  final bool e2ee;

  @override
  State<PluginsScreen> createState() => _PluginsScreenState();
}

class _PluginsScreenState extends State<PluginsScreen> {
  final Set<String> _busy = {};

  PluginService get _s => widget.service;
  String get _cid => widget.circleId;
  bool get _e2ee => widget.e2ee;

  @override
  void initState() {
    super.initState();
    _s.list(_cid);
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _toggle(PluginView p, bool v) async {
    setState(() => _busy.add(p.id));
    final r = await _s.setEnabled(_cid, p.id, v);
    if (!mounted) return;
    setState(() => _busy.remove(p.id));
    if (!r.ok) _snack(_reasonText(AppLocalizations.of(context), r));
  }

  Future<void> _uninstall(PluginView p) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.pluginUninstallTitle(p.name)),
        content: Text(t.pluginUninstallBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.commonCancel),
          ),
          FilledButton(
            key: const ValueKey('plugin-uninstall-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.pluginUninstall),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final r = await _s.uninstall(_cid, p.id);
    if (!mounted) return;
    if (!r.ok) _snack(_reasonText(t, r));
  }

  Future<void> _install(
      {String? pluginId, Map<String, dynamic>? manifest, String? url}) async {
    final t = AppLocalizations.of(context);
    final r = await _s.install(_cid,
        pluginId: pluginId, manifest: manifest, manifestUrl: url);
    if (!mounted) return;
    if (!r.ok) {
      _snack(_reasonText(t, r));
      return;
    }
    if (r.token != null || r.webhookSecret != null) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PluginSecretsDialog(result: r),
      );
    } else {
      _snack(t.pluginInstalled(r.plugin?.name ?? ''));
    }
  }

  Future<void> _addFlow() async {
    final t = AppLocalizations.of(context);
    final installed = _s.plugin(_cid, focusPluginId) != null;
    final aiInstalled = _s.plugin(_cid, aiVoicePluginId) != null;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('plugin-add-focus'),
              leading: const Icon(Icons.timer_outlined),
              title: Text(t.pluginFocusName),
              subtitle: Text(installed
                  ? t.pluginAlreadyInstalled
                  : t.pluginFocusDesc),
              enabled: !installed,
              onTap: () => Navigator.pop(ctx, 'focus'),
            ),
            ListTile(
              key: const ValueKey('plugin-add-ai'),
              leading: const Icon(Icons.smart_toy_outlined),
              title: Text(t.aiVoicePluginName),
              subtitle: Text(aiInstalled
                  ? t.pluginAlreadyInstalled
                  : _e2ee
                      ? t.aiVoiceE2eeBlocked
                      : t.aiVoicePluginDesc),
              enabled: !aiInstalled && !_e2ee,
              onTap: () => Navigator.pop(ctx, 'ai'),
            ),
            ListTile(
              key: const ValueKey('plugin-add-url'),
              leading: const Icon(Icons.link_rounded),
              title: Text(t.pluginAddFromUrl),
              onTap: () => Navigator.pop(ctx, 'url'),
            ),
            ListTile(
              key: const ValueKey('plugin-add-paste'),
              leading: const Icon(Icons.content_paste_rounded),
              title: Text(t.pluginAddPaste),
              onTap: () => Navigator.pop(ctx, 'paste'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'focus':
        await _install(pluginId: focusPluginId);
      case 'ai':
        await _install(pluginId: aiVoicePluginId);
      case 'url':
        final url = await _askText(t.pluginAddFromUrl, t.pluginManifestUrlHint,
            multiline: false);
        if (url == null) return;
        final u = Uri.tryParse(url);
        if (u == null || u.scheme != 'https' || u.host.isEmpty) {
          _snack(t.pluginErrHttpsOnly);
          return;
        }
        await _install(url: url);
      case 'paste':
        final text = await _askText(t.pluginAddPaste, t.pluginManifestJsonHint,
            multiline: true);
        if (text == null) return;
        Object? j;
        try {
          j = jsonDecode(text);
        } on FormatException {
          j = null;
        }
        if (j is! Map) {
          _snack(t.pluginErrBadJson);
          return;
        }
        await _install(manifest: Map<String, dynamic>.from(j));
    }
  }

  Future<String?> _askText(String title, String hint,
      {required bool multiline}) {
    return showDialog<String>(
      context: context,
      builder: (_) =>
          _TextInputDialog(title: title, hint: hint, multiline: multiline),
    );
  }

  void _openSettings(PluginView p) {
    final b = widget.focusSettingsBuilder;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (ctx) => p.id == focusPluginId && b != null
          ? b(ctx, _s, _cid, p)
          : p.id == aiVoicePluginId
              ? AiVoiceSettingsPage(
                  service: _s, circleId: _cid, plugin: p, e2ee: _e2ee)
              : PluginConfigEditor(service: _s, circleId: _cid, plugin: p),
    ));
  }

  void _details(PluginView p) {
    final t = AppLocalizations.of(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(LaresSpacing.lg),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.name, style: Theme.of(context).textTheme.titleLarge),
                Text(t.pluginMeta(p.version, p.author)),
                if (p.description.isNotEmpty) ...[
                  const SizedBox(height: LaresSpacing.sm),
                  Text(p.description),
                ],
                if (p.entryUrl != null) SelectableText(p.entryUrl!),
                if (p.hasWebhook) Text(t.pluginHasWebhook),
                const SizedBox(height: LaresSpacing.sm),
                Text(t.pluginConsentPermsHeader),
                for (final perm in p.permissions)
                  Text('· ${pluginPermissionLabel(t, perm)}'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.pluginTitle)),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('plugin-add'),
        onPressed: _addFlow,
        icon: const Icon(Icons.add),
        label: Text(t.pluginAdd),
      ),
      body: ListenableBuilder(
        listenable: _s,
        builder: (context, _) {
          final items = _s.pluginsFor(_cid);
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(LaresSpacing.lg),
                child: Text(t.pluginEmpty, textAlign: TextAlign.center),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              for (final p in items)
                Card(
                  key: ValueKey('plugin-item-${p.id}'),
                  margin: const EdgeInsets.symmetric(
                      horizontal: LaresSpacing.md, vertical: LaresSpacing.sm),
                  child: Column(
                    children: [
                      SwitchListTile(
                        key: ValueKey('plugin-switch-${p.id}'),
                        title: Text(p.name),
                        subtitle: Text(p.description.isEmpty
                            ? t.pluginMeta(p.version, p.author)
                            : p.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                        value: p.enabled,
                        // E2EE 圈不给开 AI 助手(服务器拿不到明文音频);已开着的仍可关
                        onChanged: _busy.contains(p.id) ||
                                (p.id == aiVoicePluginId && _e2ee && !p.enabled)
                            ? null
                            : (v) => _toggle(p, v),
                      ),
                      if (p.id == aiVoicePluginId && _e2ee)
                        Padding(
                          key: const ValueKey('plugin-ai-e2ee-note'),
                          padding: const EdgeInsets.fromLTRB(
                              LaresSpacing.md, 0, LaresSpacing.md, 0),
                          child: Text(
                            t.aiVoiceE2eeBlocked,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                    color: Theme.of(context).colorScheme.error),
                          ),
                        ),
                      OverflowBar(
                        alignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            key: ValueKey('plugin-details-${p.id}'),
                            onPressed: () => _details(p),
                            child: Text(t.pluginDetails),
                          ),
                          if (p.id == focusPluginId ||
                              p.id == aiVoicePluginId ||
                              p.settingsSchema != null)
                            TextButton(
                              key: ValueKey('plugin-settings-${p.id}'),
                              onPressed: () => _openSettings(p),
                              child: Text(t.pluginSettings),
                            ),
                          TextButton(
                            key: ValueKey('plugin-uninstall-${p.id}'),
                            onPressed: () => _uninstall(p),
                            child: Text(t.pluginUninstall),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog(
      {required this.title, required this.hint, required this.multiline});
  final String title;
  final String hint;
  final bool multiline;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const ValueKey('plugin-input'),
        controller: _c,
        autofocus: true,
        minLines: widget.multiline ? 4 : 1,
        maxLines: widget.multiline ? 10 : 1,
        keyboardType:
            widget.multiline ? TextInputType.multiline : TextInputType.url,
        decoration: InputDecoration(hintText: widget.hint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.commonCancel),
        ),
        FilledButton(
          key: const ValueKey('plugin-input-ok'),
          onPressed: () {
            final v = _c.text.trim();
            Navigator.pop(context, v.isEmpty ? null : v);
          },
          child: Text(t.pluginInstall),
        ),
      ],
    );
  }
}

/// 安装回执里的一次性 token / webhook 密钥。
class PluginSecretsDialog extends StatelessWidget {
  const PluginSecretsDialog({super.key, required this.result});
  final PluginInstallResult result;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    Widget row(String label, String value, String key) => Padding(
          padding: const EdgeInsets.only(top: LaresSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelMedium),
              Row(
                children: [
                  Expanded(child: SelectableText(value, key: ValueKey(key))),
                  IconButton(
                    key: ValueKey('$key-copy'),
                    tooltip: t.commonCopy,
                    icon: const Icon(Icons.copy_rounded),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: value));
                      if (!context.mounted) return;
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                          SnackBar(content: Text(t.commonCopied)));
                    },
                  ),
                ],
              ),
            ],
          ),
        );
    return AlertDialog(
      title: Text(t.pluginInstalled(result.plugin?.name ?? '')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.pluginSecretsOnce),
            if (result.token != null)
              row(t.pluginToken, result.token!, 'plugin-token'),
            if (result.webhookSecret != null)
              row(t.pluginWebhookSecret, result.webhookSecret!,
                  'plugin-webhook-secret'),
          ],
        ),
      ),
      actions: [
        FilledButton(
          key: const ValueKey('plugin-secrets-done'),
          onPressed: () => Navigator.pop(context),
          child: Text(t.commonDone),
        ),
      ],
    );
  }
}

/// 通用配置编辑器:直接改 config 的 JSON。
class PluginConfigEditor extends StatefulWidget {
  const PluginConfigEditor({
    super.key,
    required this.service,
    required this.circleId,
    required this.plugin,
  });

  final PluginService service;
  final String circleId;
  final PluginView plugin;

  @override
  State<PluginConfigEditor> createState() => _PluginConfigEditorState();
}

class _PluginConfigEditorState extends State<PluginConfigEditor> {
  late final TextEditingController _c = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(widget.plugin.config));
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    Object? j;
    try {
      j = jsonDecode(_c.text);
    } on FormatException {
      j = null;
    }
    if (j is! Map) {
      setState(() => _error = t.pluginErrBadJson);
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    final r = await widget.service.setConfig(
        widget.circleId, widget.plugin.id, Map<String, dynamic>.from(j));
    if (!mounted) return;
    setState(() => _saving = false);
    if (r.ok) {
      Navigator.of(context).pop();
    } else {
      setState(() => _error = _reasonText(t, r));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.pluginSettingsOf(widget.plugin.name)),
        actions: [
          TextButton(
            key: const ValueKey('plugin-config-save'),
            onPressed: _saving ? null : _save,
            child: Text(t.commonSave),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(LaresSpacing.md),
        child: TextField(
          key: const ValueKey('plugin-config-input'),
          controller: _c,
          maxLines: null,
          expands: true,
          style: const TextStyle(fontFamily: 'monospace'),
          decoration: InputDecoration(
            errorText: _error,
            border: const OutlineInputBorder(),
          ),
        ),
      ),
    );
  }
}
