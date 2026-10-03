/// 插件的数据模型(契约 docs/plans/plugin-focus-contract.md §1 / §2)。
///
/// 模型层只存语义标识;权限的人话在 UI 层查表([pluginPermissionLabel])。
library;

import 'package:flutter/foundation.dart';

import '../../l10n/gen/app_localizations.dart';

/// 内置专注学习插件的 id。
const String focusPluginId = 'lares.focus';

/// 内置 AI 语音助手插件的 id(docs/ai-voice-bot.md)。
const String aiVoicePluginId = 'lares.ai-voice';

/// 已知权限(契约 §1 表)。
abstract final class PluginPermissions {
  static const circleRead = 'circle:read';
  static const membersRead = 'members:read';
  static const chatRead = 'chat:read';
  static const chatSend = 'chat:send';
  static const captionsRead = 'captions:read';
  static const captionsSend = 'captions:send';
  static const transcriptRead = 'transcript:read';
  static const stateRead = 'state:read';
  static const stateWrite = 'state:write';
  static const storage = 'storage';
  static const focusRead = 'focus:read';

  static const Set<String> known = {
    circleRead,
    membersRead,
    chatRead,
    chatSend,
    captionsRead,
    captionsSend,
    transcriptRead,
    stateRead,
    stateWrite,
    storage,
    focusRead,
  };
}

/// 权限的人话(未知权限原样显示)。
String pluginPermissionLabel(AppLocalizations t, String perm) => switch (perm) {
      PluginPermissions.circleRead => t.pluginPermCircleRead,
      PluginPermissions.membersRead => t.pluginPermMembersRead,
      PluginPermissions.chatRead => t.pluginPermChatRead,
      PluginPermissions.chatSend => t.pluginPermChatSend,
      PluginPermissions.captionsRead => t.pluginPermCaptionsRead,
      PluginPermissions.captionsSend => t.pluginPermCaptionsSend,
      PluginPermissions.transcriptRead => t.pluginPermTranscriptRead,
      PluginPermissions.stateRead => t.pluginPermStateRead,
      PluginPermissions.stateWrite => t.pluginPermStateWrite,
      PluginPermissions.storage => t.pluginPermStorage,
      PluginPermissions.focusRead => t.pluginPermFocusRead,
      _ => perm,
    };

String? _str(Object? v) => v is String ? v : null;

List<String> _strList(Object? v) => [
      if (v is List)
        for (final e in v)
          if (e is String) e,
    ];

Map<String, dynamic>? _map(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : null;

/// 插件 manifest(客户端只做宽容解析;严格校验在服务器)。
@immutable
class PluginManifest {
  const PluginManifest({
    required this.id,
    required this.name,
    this.version = '',
    this.description = '',
    this.author = '',
    this.homepage,
    this.entryUrl,
    this.permissions = const [],
    this.webhookUrl,
    this.webhookEvents = const [],
    this.settingsSchema,
  });

  final String id;
  final String name;
  final String version;
  final String description;
  final String author;
  final String? homepage;
  final String? entryUrl;
  final List<String> permissions;
  final String? webhookUrl;
  final List<String> webhookEvents;
  final Map<String, dynamic>? settingsSchema;

  static PluginManifest? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = _str(j['id']);
    if (id == null || id.isEmpty) return null;
    final entry = j['entry'];
    final webhook = j['webhook'];
    return PluginManifest(
      id: id,
      name: _str(j['name']) ?? id,
      version: _str(j['version']) ?? '',
      description: _str(j['description']) ?? '',
      author: _str(j['author']) ?? '',
      homepage: _str(j['homepage']),
      entryUrl: entry is Map ? _str(entry['url']) : null,
      permissions: _strList(j['permissions']),
      webhookUrl: webhook is Map ? _str(webhook['url']) : null,
      webhookEvents: webhook is Map ? _strList(webhook['events']) : const [],
      settingsSchema: _map(j['settingsSchema']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'version': version,
        'description': description,
        'author': author,
        if (homepage != null) 'homepage': homepage,
        if (entryUrl != null) 'entry': {'url': entryUrl},
        'permissions': permissions,
        if (webhookUrl != null)
          'webhook': {'url': webhookUrl, 'events': webhookEvents},
        if (settingsSchema != null) 'settingsSchema': settingsSchema,
      };
}

/// 广播给成员的公开视图(契约 §2,不含 webhook URL / 密钥)。
@immutable
class PluginView {
  const PluginView({
    required this.id,
    required this.name,
    this.version = '',
    this.description = '',
    this.author = '',
    this.homepage,
    this.entryUrl,
    this.permissions = const [],
    this.builtin = false,
    this.enabled = true,
    this.config = const {},
    this.hasWebhook = false,
    this.settingsSchema,
    this.rev = 0,
  });

  final String id;
  final String name;
  final String version;
  final String description;
  final String author;
  final String? homepage;
  final String? entryUrl;
  final List<String> permissions;
  final bool builtin;
  final bool enabled;
  final Map<String, dynamic> config;
  final bool hasWebhook;
  final Map<String, dynamic>? settingsSchema;
  final int rev;

  /// 有网页入口(可在房间里打开)。
  bool get hasEntry => entryUrl != null && entryUrl!.isNotEmpty;

  static PluginView? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = _str(j['id']);
    if (id == null || id.isEmpty) return null;
    final entry = j['entry'];
    final rev = j['rev'];
    return PluginView(
      id: id,
      name: _str(j['name']) ?? id,
      version: _str(j['version']) ?? '',
      description: _str(j['description']) ?? '',
      author: _str(j['author']) ?? '',
      homepage: _str(j['homepage']),
      entryUrl: entry is Map ? _str(entry['url']) : _str(entry),
      permissions: _strList(j['permissions']),
      builtin: j['builtin'] == true,
      enabled: j['enabled'] != false,
      config: _map(j['config']) ?? const {},
      hasWebhook: j['hasWebhook'] == true,
      settingsSchema: _map(j['settingsSchema']),
      rev: rev is num ? rev.toInt() : 0,
    );
  }

  static List<PluginView> listFromJson(Object? raw) => [
        if (raw is List)
          for (final e in raw) ?PluginView.fromJson(e),
      ];

  PluginView copyWith({
    bool? enabled,
    Map<String, dynamic>? config,
    int? rev,
  }) =>
      PluginView(
        id: id,
        name: name,
        version: version,
        description: description,
        author: author,
        homepage: homepage,
        entryUrl: entryUrl,
        permissions: permissions,
        builtin: builtin,
        enabled: enabled ?? this.enabled,
        config: config ?? this.config,
        hasWebhook: hasWebhook,
        settingsSchema: settingsSchema,
        rev: rev ?? this.rev,
      );
}
