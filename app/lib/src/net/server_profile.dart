import 'dart:convert';

import '../auth/auth_credential.dart';

/// 信令地址校验结果:要么给出规范化后的 URL,要么给出**人话**错误。
///
/// 产品动机:生产地址长这样 `wss://rtc.example.com:8444/ws` —— 非标端口 + /ws 路径,
/// 手输很容易漏 scheme 或写成 https。与其让用户面对一次静默的连不上,
/// 不如在输入框下方当场说清楚哪儿不对。
class UrlValidation {
  const UrlValidation._(this.normalized, this.error);

  const UrlValidation.ok(String url) : this._(url, null);

  const UrlValidation.fail(String message) : this._(null, message);

  /// 规范化后的地址(仅 ok 时非空)
  final String? normalized;

  /// 错误说明(仅失败时非空)
  final String? error;

  bool get isValid => normalized != null;
}

/// 一个「服务器档案」:标签 + 地址 + 鉴权配置。
///
/// 为什么不是一个字符串:主人要在两套部署之间来回切 ——
/// (a) VPS 全自建,(b) LiveKit Cloud 走媒体 + 自建信令。
/// 两者信令地址不同、口令也可能不同,存成具名档案就不用每次手打一遍长地址。
class ServerProfile {
  const ServerProfile({
    required this.id,
    required this.label,
    required this.url,
    this.authMode = AuthMode.none,
    this.token = '',
    this.circlePasscodes = const {},
  });

  /// 稳定标识(创建时生成,改名不影响引用)
  final String id;

  /// 给人看的名字,例:「家里的 VPS」「LiveKit Cloud」
  final String label;

  /// 信令 WebSocket 地址,例:wss://rtc.example.com:8444/ws
  final String url;

  final AuthMode authMode;

  /// token 模式的共享令牌
  final String token;

  /// circle 模式:circleId -> 口令。不同圈子各有各的口令。
  final Map<String, String> circlePasscodes;

  ServerProfile copyWith({
    String? label,
    String? url,
    AuthMode? authMode,
    String? token,
    Map<String, String>? circlePasscodes,
  }) =>
      ServerProfile(
        id: id,
        label: label ?? this.label,
        url: url ?? this.url,
        authMode: authMode ?? this.authMode,
        token: token ?? this.token,
        circlePasscodes: circlePasscodes ?? this.circlePasscodes,
      );

  /// 取某个圈子要用的凭据快照;circle 模式下带上该圈的口令。
  AuthCredential credentialFor(String? circleId) {
    switch (authMode) {
      case AuthMode.none:
        return AuthCredential.none;
      case AuthMode.token:
        return AuthCredential(mode: AuthMode.token, token: token);
      case AuthMode.circle:
        final id = circleId ?? '';
        return AuthCredential(
          mode: AuthMode.circle,
          passcode: circlePasscodes[id] ?? '',
          circleId: id.isEmpty ? null : id,
        );
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'url': url,
        'authMode': authMode.wire,
        if (token.isNotEmpty) 'token': token,
        if (circlePasscodes.isNotEmpty) 'circlePasscodes': circlePasscodes,
      };

  static ServerProfile? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final url = raw['url'];
    if (id is! String || id.isEmpty || url is! String || url.isEmpty) {
      return null; // 坏档案直接丢弃,不让一条脏数据毁掉整份设置
    }
    final passes = <String, String>{};
    final rawPasses = raw['circlePasscodes'];
    if (rawPasses is Map) {
      for (final e in rawPasses.entries) {
        if (e.key is String && e.value is String) {
          passes[e.key as String] = e.value as String;
        }
      }
    }
    return ServerProfile(
      id: id,
      label: raw['label'] is String && (raw['label'] as String).isNotEmpty
          ? raw['label'] as String
          : '未命名',
      url: url,
      authMode: AuthMode.fromWire(raw['authMode'] as String?),
      token: raw['token'] is String ? raw['token'] as String : '',
      circlePasscodes: passes,
    );
  }

  /// 校验并规范化信令地址。
  ///
  /// 规则:
  ///  - 空 → 「用默认地址」,由调用方决定是清空覆盖还是报错
  ///  - 只认 ws / wss(http/https 是最常见的手误,单独给一条提示)
  ///  - 必须有主机名
  ///  - 显式端口(8444)与路径(/ws)原样保留
  static UrlValidation validateUrl(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const UrlValidation.fail('地址不能为空');

    final Uri uri;
    try {
      uri = Uri.parse(text);
    } catch (_) {
      return const UrlValidation.fail('这不是一个合法的地址');
    }

    final scheme = uri.scheme.toLowerCase();
    if (scheme.isEmpty) {
      return const UrlValidation.fail('缺少 ws:// 或 wss:// 开头');
    }
    if (scheme == 'http' || scheme == 'https') {
      return UrlValidation.fail(
          '信令要用 WebSocket:把 $scheme:// 换成 ${scheme == 'https' ? 'wss' : 'ws'}://');
    }
    if (scheme != 'ws' && scheme != 'wss') {
      return UrlValidation.fail('不支持 $scheme:// (只能用 ws:// 或 wss://)');
    }
    if (uri.host.isEmpty) {
      return const UrlValidation.fail('缺少服务器主机名');
    }
    // hasPort 为 false 时 uri.port 会回落到 scheme 默认端口,这里只保留**显式**端口,
    // 避免把 wss://a.com 规范化成 wss://a.com:443 这种用户没写过的样子。
    final port = uri.hasPort ? ':${uri.port}' : '';
    if (uri.hasPort && (uri.port <= 0 || uri.port > 65535)) {
      return const UrlValidation.fail('端口号超出范围(1-65535)');
    }
    final path = uri.path == '/' ? '' : uri.path;
    final query = uri.hasQuery ? '?${uri.query}' : '';
    return UrlValidation.ok('$scheme://${uri.host}$port$path$query');
  }
}

/// 档案集合 + 当前选中项。整体以一个 JSON 字符串存进 shared_preferences,
/// 比散着存十几个 key 更好迁移、也更容易整体替换。
///
/// ⚠️ 安全边界:shared_preferences 在绝大多数平台上是**明文**的
/// (Android SharedPreferences XML、iOS NSUserDefaults plist、Windows 本地文件、
/// Web 直接 localStorage)。
///
/// **令牌与圈口令已迁往 `SecretVault`**(系统级安全存储:iOS/macOS Keychain、
/// Android Keystore、Windows DPAPI),迁移器见 `secret_migration.dart`,
/// 每次启动幂等执行。这里的字段保留是为了迁移期的读取与向后兼容,
/// 新写入一律走 vault。
///
/// 这件事之所以要紧:E2EE 的密钥由圈口令派生。口令泄露 = 密钥泄露。
/// 所以口令的存储强度是 E2EE 安全性的**上界** —— Argon2id 把派生做得再硬,
/// 也架不住口令本身躺在明文文件里。
class ServerProfiles {
  const ServerProfiles({required this.profiles, required this.activeId});

  static const empty = ServerProfiles(profiles: [], activeId: null);

  final List<ServerProfile> profiles;
  final String? activeId;

  /// 当前生效的档案;列表为空或指向不存在的 id 时返回 null(调用方回落到编译期默认地址)
  ServerProfile? get active {
    if (profiles.isEmpty) return null;
    for (final p in profiles) {
      if (p.id == activeId) return p;
    }
    return profiles.first; // activeId 失效时兜底用第一个,别让用户忽然掉回默认服务器
  }

  ServerProfiles copyWith({
    List<ServerProfile>? profiles,
    String? activeId,
    bool clearActive = false,
  }) =>
      ServerProfiles(
        profiles: profiles ?? this.profiles,
        activeId: clearActive ? null : (activeId ?? this.activeId),
      );

  String encode() => jsonEncode({
        'activeId': activeId,
        'profiles': [for (final p in profiles) p.toJson()],
      });

  static ServerProfiles decode(String? raw) {
    if (raw == null || raw.isEmpty) return empty;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return empty;
      final list = <ServerProfile>[];
      for (final item in (json['profiles'] as List? ?? const [])) {
        final p = ServerProfile.fromJson(item);
        if (p != null) list.add(p);
      }
      return ServerProfiles(
        profiles: list,
        activeId: json['activeId'] is String ? json['activeId'] as String : null,
      );
    } catch (_) {
      return empty; // 存坏了就当没有,不崩
    }
  }

  /// 老版本只有一个 `lares.signalingOverride` 字符串。
  /// 升级时把它原样搬进一个名为「我的服务器」的档案并设为当前,谁也别丢设置。
  static ServerProfiles migrateLegacy(String? legacyOverride) {
    final url = legacyOverride?.trim() ?? '';
    if (url.isEmpty) return empty;
    const id = 'legacy';
    return const ServerProfiles(profiles: [], activeId: id).copyWith(
      profiles: [
        ServerProfile(id: id, label: '我的服务器', url: url),
      ],
    );
  }

  /// 生成一个不与现有档案冲突的 id
  String newId() {
    final used = {for (final p in profiles) p.id};
    var n = profiles.length + 1;
    while (used.contains('p$n')) {
      n++;
    }
    return 'p$n';
  }
}
