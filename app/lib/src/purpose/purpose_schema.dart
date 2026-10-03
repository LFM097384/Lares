/// 用途 JSON 的客户端校验(features-purpose-contract §3.1 的镜像)与内置用途(§3.2)。
///
/// 服务端严格校验、只报第一个错;这里尽量把错都列出来,给编辑器即时提示。
/// manifest 只做轻量结构检查,完整校验(权限白名单、webhook 事件、SSRF)
/// 由服务器做。
library;

import 'dart:convert';

import '../../l10n/gen/app_localizations.dart';
import '../state/circle_features.dart';

const int kPurposeMaxBytes = 32 * 1024;
const int kPurposeMaxPlugins = 10;
const int kPurposeConfigMaxBytes = 4 * 1024;
const String kFocusPluginId = 'lares.focus';

/// 内置 AI 语音助手插件(docs/ai-voice-bot.md)。
const String kAiVoicePluginId = 'lares.ai-voice';

/// 用途 `plugins[].id` 可直接写的内置插件(与 server/src/plugins.js 的 BUILTINS 一致)。
/// 其它 id 只能是本圈已装插件,由服务器判断。
const Set<String> kBuiltinPluginIds = {kFocusPluginId, kAiVoicePluginId};

const Set<String> _topKeys = {
  'v', 'id', 'name', 'icon', 'description', 'features', 'plugins', 'settings',
};
const Set<String> _itemKeys = {
  'id', 'manifest', 'manifestUrl', 'enabled', 'config',
};
const Set<String> kPurposeSettingKeys = {
  'transcript', 'knockRequired', 'e2eeWarning',
};
final RegExp _idRe = RegExp(r'^[a-z0-9][a-z0-9_-]{0,31}$');

enum PurposeIssueCode {
  syntax,
  notObject,
  tooLarge,
  unknownKey,
  version,
  id,
  name,
  icon,
  description,
  notBool,
  notObjectField,
  notArray,
  tooManyPlugins,
  pluginSource,
  pluginId,
  configTooLarge,
  manifestUrl,
  manifest,
  conflict,
  duplicate,
}

class PurposeIssue {
  const PurposeIssue(this.path, this.code,
      {this.field, this.line, this.column, this.detail});

  /// JSON 路径,如 `plugins[1].manifestUrl`;根是 `$`
  final String path;
  final PurposeIssueCode code;

  /// 补充:manifest 缺的字段 / 冲突的另一方
  final String? field;

  /// 1 起算;找不到位置时为 null
  final int? line;
  final int? column;

  /// 语法错误的原始说明
  final String? detail;

  PurposeIssue withPos(int? line, int? column) => PurposeIssue(path, code,
      field: field, line: line, column: column, detail: detail);

  @override
  String toString() => '$path:${code.name}${field == null ? '' : '($field)'}';
}

/// 校验一段编辑器里的文字。语法对了才做结构校验。
({Map<String, dynamic>? purpose, List<PurposeIssue> issues})
    validatePurposeText(String text) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    final off = e.offset;
    final pos = off == null ? null : lineColOf(text, off);
    return (
      purpose: null,
      issues: [
        PurposeIssue(r'$', PurposeIssueCode.syntax,
            line: pos?.line ?? 1, column: pos?.column ?? 1, detail: e.message),
      ],
    );
  }
  final issues = [
    for (final i in validatePurpose(decoded))
      () {
        final p = locatePath(text, i.path);
        return p == null ? i : i.withPos(p.line, p.column);
      }(),
  ];
  return (
    purpose: issues.isEmpty ? Map<String, dynamic>.from(decoded as Map) : null,
    issues: issues,
  );
}

/// 结构校验(§3.1)。空列表 = 通过。
List<PurposeIssue> validatePurpose(Object? p) {
  final out = <PurposeIssue>[];
  void bad(String path, PurposeIssueCode c, {String? field}) =>
      out.add(PurposeIssue(path, c, field: field));

  if (p is! Map) {
    bad(r'$', PurposeIssueCode.notObject);
    return out;
  }
  if (_jsonBytes(p) > kPurposeMaxBytes) {
    bad(r'$', PurposeIssueCode.tooLarge);
    return out;
  }
  for (final k in p.keys) {
    if (!_topKeys.contains(k)) bad('$k', PurposeIssueCode.unknownKey);
  }
  if (p.containsKey('v') && p['v'] != 1) bad('v', PurposeIssueCode.version);
  final id = p['id'];
  if (id is! String || !_idRe.hasMatch(id)) bad('id', PurposeIssueCode.id);
  final name = p['name'];
  if (name is! String || name.trim().isEmpty || name.runes.length > 24) {
    bad('name', PurposeIssueCode.name);
  }
  if (p.containsKey('icon')) {
    final icon = p['icon'];
    if (icon is! String || icon.runes.length > 8) {
      bad('icon', PurposeIssueCode.icon);
    }
  }
  if (p.containsKey('description')) {
    final d = p['description'];
    if (d is! String || d.runes.length > 200) {
      bad('description', PurposeIssueCode.description);
    }
  }

  final features = <String, bool>{};
  if (p.containsKey('features')) {
    final f = p['features'];
    if (f is! Map) {
      bad('features', PurposeIssueCode.notObjectField);
    } else {
      for (final e in f.entries) {
        final k = '${e.key}';
        if (CircleFeature.fromKey(k) == null) {
          bad('features.$k', PurposeIssueCode.unknownKey);
        } else if (e.value is! bool) {
          bad('features.$k', PurposeIssueCode.notBool);
        } else {
          features[k] = e.value as bool;
        }
      }
    }
  }

  final settings = <String, bool>{};
  if (p.containsKey('settings')) {
    final s = p['settings'];
    if (s is! Map) {
      bad('settings', PurposeIssueCode.notObjectField);
    } else {
      for (final e in s.entries) {
        final k = '${e.key}';
        if (!kPurposeSettingKeys.contains(k)) {
          bad('settings.$k', PurposeIssueCode.unknownKey);
        } else if (e.value is! bool) {
          bad('settings.$k', PurposeIssueCode.notBool);
        } else {
          settings[k] = e.value as bool;
        }
      }
    }
  }
  if (features.containsKey('transcript') &&
      settings.containsKey('transcript') &&
      features['transcript'] != settings['transcript']) {
    bad('settings.transcript', PurposeIssueCode.conflict,
        field: 'features.transcript');
  }

  if (p.containsKey('plugins')) {
    final list = p['plugins'];
    if (list is! List) {
      bad('plugins', PurposeIssueCode.notArray);
    } else {
      if (list.length > kPurposeMaxPlugins) {
        bad('plugins', PurposeIssueCode.tooManyPlugins);
      }
      final seen = <String>{};
      for (var i = 0; i < list.length; i++) {
        final at = 'plugins[$i]';
        final it = list[i];
        if (it is! Map) {
          bad(at, PurposeIssueCode.notObjectField);
          continue;
        }
        for (final k in it.keys) {
          if (!_itemKeys.contains(k)) bad('$at.$k', PurposeIssueCode.unknownKey);
        }
        final sources = ['id', 'manifest', 'manifestUrl']
            .where(it.containsKey)
            .toList();
        if (sources.length != 1) bad(at, PurposeIssueCode.pluginSource);
        if (it.containsKey('enabled') && it['enabled'] is! bool) {
          bad('$at.enabled', PurposeIssueCode.notBool);
        }
        final enabled = it['enabled'] != false;
        if (it.containsKey('config')) {
          final c = it['config'];
          if (c is! Map) {
            bad('$at.config', PurposeIssueCode.notObjectField);
          } else if (_jsonBytes(c) > kPurposeConfigMaxBytes) {
            bad('$at.config', PurposeIssueCode.configTooLarge);
          }
        }
        String? pid;
        if (sources.length == 1) {
          switch (sources.first) {
            case 'id':
              final v = it['id'];
              if (v is! String || v.isEmpty || v.length > 64) {
                bad('$at.id', PurposeIssueCode.pluginId);
              } else {
                pid = v;
              }
            case 'manifest':
              final m = it['manifest'];
              final missing = _manifestProblem(m);
              if (missing != null) {
                bad('$at.manifest', PurposeIssueCode.manifest, field: missing);
              } else {
                pid = (m as Map)['id'] as String;
              }
            default:
              final u = it['manifestUrl'];
              if (!_httpsOk(u)) bad('$at.manifestUrl', PurposeIssueCode.manifestUrl);
          }
        }
        if (pid != null) {
          if (!seen.add(pid)) bad(at, PurposeIssueCode.duplicate);
          if (pid == kFocusPluginId &&
              features.containsKey('focus') &&
              features['focus'] != enabled) {
            bad('$at.enabled', PurposeIssueCode.conflict,
                field: 'features.focus');
          }
        }
      }
    }
  }
  return out;
}

int _jsonBytes(Object? v) {
  try {
    return utf8.encode(jsonEncode(v)).length;
  } catch (_) {
    return 1 << 30;
  }
}

bool _httpsOk(Object? u) {
  if (u is! String || u.isEmpty || u.length > 2048) return false;
  final uri = Uri.tryParse(u);
  return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
}

/// manifest 的轻量检查:返回第一个有问题的字段名,没问题返回 null。
String? _manifestProblem(Object? m) {
  if (m is! Map) return 'manifest';
  for (final k in const ['id', 'name', 'version', 'author']) {
    final v = m[k];
    if (v is! String || v.trim().isEmpty) return k;
  }
  final perms = m['permissions'];
  if (perms is! List || perms.any((e) => e is! String)) return 'permissions';
  if (m.containsKey('webhook')) {
    final w = m['webhook'];
    if (w is! Map || !_httpsOk(w['url'])) return 'webhook.url';
  }
  if (m.containsKey('entry')) {
    final e = m['entry'];
    if (e is! Map || !_httpsOk(e['url'])) return 'entry.url';
  }
  return null;
}

/// 字符偏移 → 行列(都从 1 起)。
({int line, int column}) lineColOf(String text, int offset) {
  final end = offset.clamp(0, text.length);
  var line = 1;
  var col = 1;
  for (var i = 0; i < end; i++) {
    if (text.codeUnitAt(i) == 0x0A) {
      line++;
      col = 1;
    } else {
      col++;
    }
  }
  return (line: line, column: col);
}

/// 按路径在原文里粗略定位(给「点错误跳到那一行」用)。找不到返回 null。
///
/// 只是启发式:沿路径依次找 `"键"`;数组下标靠数第几个 `{`(同层)。
/// 对编辑器里人写的 JSON 足够;定位不到就不跳,不影响校验本身。
({int line, int column})? locatePath(String text, String path) {
  if (path == r'$') return (line: 1, column: 1);
  final segs = RegExp(r'([^.\[\]]+)|\[(\d+)\]').allMatches(path);
  var from = 0;
  for (final s in segs) {
    final key = s.group(1);
    if (key != null) {
      final i = text.indexOf('"$key"', from);
      if (i < 0) return null;
      from = i;
    } else {
      final idx = int.parse(s.group(2)!);
      // 从当前位置后的第一个 `[` 开始,数同一层的第 idx 个元素起点
      final open = text.indexOf('[', from);
      if (open < 0) return null;
      int skipWs(int j) {
        while (j < text.length && text[j].trim().isEmpty) {
          j++;
        }
        return j;
      }

      var found = idx == 0 ? skipWs(open + 1) : -1;
      var depth = 0;
      var count = 0;
      var inStr = false;
      for (var i = open; found < 0 && i < text.length; i++) {
        final c = text[i];
        if (inStr) {
          if (c == r'\') {
            i++;
          } else if (c == '"') {
            inStr = false;
          }
          continue;
        }
        if (c == '"') {
          inStr = true;
        } else if (c == '[' || c == '{') {
          depth++;
        } else if (c == ']' || c == '}') {
          depth--;
          if (depth == 0) break;
        } else if (c == ',' && depth == 1) {
          count++;
          if (count == idx) found = skipWs(i + 1);
        }
      }
      if (found < 0 || found >= text.length) return null;
      from = found;
    }
  }
  return lineColOf(text, from);
}

/// 一条校验错误的本地化说明。
String purposeIssueMessage(AppLocalizations t, PurposeIssue i) =>
    switch (i.code) {
      PurposeIssueCode.syntax =>
        t.purposeErrSyntax(i.line ?? 1, i.column ?? 1),
      PurposeIssueCode.notObject => t.purposeErrNotObject,
      PurposeIssueCode.tooLarge => t.purposeErrTooLarge,
      PurposeIssueCode.unknownKey => t.purposeErrUnknownKey,
      PurposeIssueCode.version => t.purposeErrVersion,
      PurposeIssueCode.id => t.purposeErrId,
      PurposeIssueCode.name => t.purposeErrName,
      PurposeIssueCode.icon => t.purposeErrIcon,
      PurposeIssueCode.description => t.purposeErrDescription,
      PurposeIssueCode.notBool => t.purposeErrNotBool,
      PurposeIssueCode.notObjectField => t.purposeErrNotObjectField,
      PurposeIssueCode.notArray => t.purposeErrNotArray,
      PurposeIssueCode.tooManyPlugins => t.purposeErrTooManyPlugins,
      PurposeIssueCode.pluginSource => t.purposeErrPluginSource,
      PurposeIssueCode.pluginId => t.purposeErrPluginId,
      PurposeIssueCode.configTooLarge => t.purposeErrConfigTooLarge,
      PurposeIssueCode.manifestUrl => t.purposeErrManifestUrl,
      PurposeIssueCode.manifest => t.purposeErrManifest(i.field ?? ''),
      PurposeIssueCode.conflict => t.purposeErrConflict(i.field ?? ''),
      PurposeIssueCode.duplicate => t.purposeErrDuplicate,
    };

// ── 内置用途(§3.2 镜像)─────────────────────────────────────────────

/// 内置用途的 JSON(与 server/src/purpose.js 的 BUILTIN_PURPOSES 一致)。
/// 名字是中文原文;界面上显示用 [builtinPurposes] 的本地化名字。
const Map<String, Map<String, dynamic>> kBuiltinPurposeJson = {
  'chat': {
    'v': 1,
    'id': 'chat',
    'name': '闲聊',
    'icon': '💬',
    'features': {
      'captions': false,
      'transcript': false,
      'voiceNotes': true,
      'focus': false,
    },
  },
  'study': {
    'v': 1,
    'id': 'study',
    'name': '学习',
    'icon': '📚',
    'features': {
      'captions': false,
      'transcript': false,
      'voiceNotes': false,
      'focus': true,
    },
    'plugins': [
      {'id': kFocusPluginId, 'enabled': true},
    ],
  },
  'meeting': {
    'v': 1,
    'id': 'meeting',
    'name': '开会',
    'icon': '📝',
    'features': {
      'captions': true,
      'transcript': true,
      'voiceNotes': false,
      'focus': false,
      'plugins': true,
    },
    'settings': {'e2eeWarning': true},
  },
};

class BuiltinPurpose {
  const BuiltinPurpose({
    required this.id,
    required this.icon,
    required this.name,
    required this.description,
  });
  final String id;
  final String icon;
  final String name;
  final String description;

  Map<String, dynamic> get json => _deepCopy(kBuiltinPurposeJson[id]!);
}

/// 内置用途(闲聊 / 学习 / 开会),名字与说明走本地化。
List<BuiltinPurpose> builtinPurposes(AppLocalizations t) => [
      BuiltinPurpose(
          id: 'chat',
          icon: '💬',
          name: t.purposeChat,
          description: t.purposeChatDesc),
      BuiltinPurpose(
          id: 'study',
          icon: '📚',
          name: t.purposeStudy,
          description: t.purposeStudyDesc),
      BuiltinPurpose(
          id: 'meeting',
          icon: '📝',
          name: t.purposeMeeting,
          description: t.purposeMeetingDesc),
    ];

/// 「开会 + AI 助手」:内置开会的完整 JSON,再加一项启用的 AI 语音助手。
/// 服务器只认字符串形式的内置用途,所以这里发完整对象(id 仍是 `meeting`、名字「开会」)。
Map<String, dynamic> meetingWithAiPurpose() {
  final m = _deepCopy(kBuiltinPurposeJson['meeting']!);
  m['plugins'] = <Object>[
    {'id': kAiVoicePluginId, 'enabled': true},
  ];
  return m;
}

/// 「自定义」的起点:以闲聊为底,换个 id / 名字。
Map<String, dynamic> purposeTemplate(AppLocalizations t) {
  final m = _deepCopy(kBuiltinPurposeJson['chat']!);
  m['id'] = 'my-circle';
  m['name'] = t.purposeCustom;
  m['icon'] = '✏️';
  m['description'] = '';
  m['plugins'] = <Object>[];
  m['settings'] = <String, Object>{};
  m.remove('description');
  return m;
}

/// 两个空格缩进的 JSON。
String prettyPurposeJson(Object? v) =>
    const JsonEncoder.withIndent('  ').convert(v);

Map<String, dynamic> _deepCopy(Map<String, dynamic> m) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(m)) as Map);
