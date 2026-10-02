/// 打开插件前的同意页 + 按圈按插件记住选择(契约 §7)。
///
/// 记住的是「允许过的权限集」的指纹:插件换了权限(多了或少了)就重新问。
/// 拒绝不落盘 —— 下次打开再问一次,而不是把人永远关在门外。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/gen/app_localizations.dart';
import '../theme/tokens.dart';
import 'plugin_models.dart';

/// 权限集指纹(排序去重后 sha256 前 16 位 hex),与入口 origin 一起算 ——
/// 入口换了站点也要重新问。
String pluginConsentHash(Iterable<String> permissions, {String? origin}) {
  final sorted = permissions.toSet().toList()..sort();
  final s = '${origin ?? ''}|${sorted.join(',')}';
  return sha256.convert(utf8.encode(s)).toString().substring(0, 16);
}

/// 入口 URL 的 origin(scheme://host[:port]),解析失败返回原串。
String pluginOrigin(String? url) {
  if (url == null || url.isEmpty) return '';
  final u = Uri.tryParse(url);
  if (u == null || !u.hasScheme || u.host.isEmpty) return url;
  return u.origin;
}

class PluginConsentStore {
  PluginConsentStore({Future<SharedPreferences> Function()? prefs})
      : _prefs = prefs ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _prefs;

  static String _key(String circleId, String pluginId) =>
      'plugin_consent.$circleId.$pluginId';

  Future<bool> isAllowed(String circleId, PluginView plugin) async {
    final p = await _prefs();
    return p.getString(_key(circleId, plugin.id)) ==
        pluginConsentHash(plugin.permissions,
            origin: pluginOrigin(plugin.entryUrl));
  }

  Future<void> allow(String circleId, PluginView plugin) async {
    final p = await _prefs();
    await p.setString(
        _key(circleId, plugin.id),
        pluginConsentHash(plugin.permissions,
            origin: pluginOrigin(plugin.entryUrl)));
  }

  Future<void> forget(String circleId, String pluginId) async {
    final p = await _prefs();
    await p.remove(_key(circleId, pluginId));
  }
}

/// 同意页内容(放在底部抽屉里)。允许 → pop(true),算了 → pop(false)。
class PluginConsentSheet extends StatelessWidget {
  const PluginConsentSheet({
    super.key,
    required this.plugin,
    required this.e2ee,
  });

  final PluginView plugin;
  final bool e2ee;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final origin = pluginOrigin(plugin.entryUrl);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(LaresSpacing.lg),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.pluginConsentTitle, style: theme.textTheme.titleMedium),
              const SizedBox(height: LaresSpacing.md),
              Text(plugin.name,
                  key: const ValueKey('plugin-consent-name'),
                  style: theme.textTheme.titleLarge),
              if (origin.isNotEmpty)
                Text(t.pluginConsentFrom(origin),
                    key: const ValueKey('plugin-consent-origin'),
                    style: theme.textTheme.bodySmall),
              const SizedBox(height: LaresSpacing.md),
              Text(plugin.permissions.isEmpty
                  ? t.pluginConsentNoPerms
                  : t.pluginConsentPermsHeader),
              for (final p in plugin.permissions)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.check_circle_outline, size: 20),
                  title: Text(pluginPermissionLabel(t, p)),
                ),
              if (e2ee) ...[
                const SizedBox(height: LaresSpacing.sm),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline,
                        size: 18, color: theme.colorScheme.error),
                    const SizedBox(width: LaresSpacing.sm),
                    Expanded(
                      child: Text(t.pluginConsentE2eeWarning,
                          key: const ValueKey('plugin-consent-e2ee'),
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.error)),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: LaresSpacing.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const ValueKey('plugin-consent-deny'),
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(t.commonCancel),
                  ),
                  const SizedBox(width: LaresSpacing.sm),
                  FilledButton(
                    key: const ValueKey('plugin-consent-allow'),
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(t.pluginConsentAllow),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 需要时弹同意页;已允许过同一权限集则直接放行。返回是否允许。
Future<bool> ensurePluginConsent(
  BuildContext context, {
  required String circleId,
  required PluginView plugin,
  required bool e2ee,
  PluginConsentStore? store,
}) async {
  final s = store ?? PluginConsentStore();
  if (await s.isAllowed(circleId, plugin)) return true;
  if (!context.mounted) return false;
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => PluginConsentSheet(plugin: plugin, e2ee: e2ee),
  );
  if (ok == true) {
    await s.allow(circleId, plugin);
    return true;
  }
  return false;
}
