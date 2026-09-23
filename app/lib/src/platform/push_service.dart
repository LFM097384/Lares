import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../state/circle_store.dart';
import '../state/models.dart';
import '../state/room_controller.dart';
import '../state/settings_store.dart';
import 'platform_info.dart'
    if (dart.library.io) 'platform_info_io.dart';

/// 推送通知(目前只有 iOS / APNs):朋友进了我在的圈 → 系统通知 →「加入」一键进圈。
///
/// ## 职责边界
///
/// - 把本机的推送 token 与「我在哪些圈、哪些圈静音了」告诉**当前主连接**那台服务器;
/// - 决定什么时候问系统通知权限(第一次真正进过房之后,只问一次);
/// - 用户点了通知 → 进那个圈(用户主动进圈,麦克风按「进圈时打开麦克风」)。
///
/// ## 刻意不做的
///
/// - **只订阅主连接那台服务器上的圈子。** PresencePool 对其他服务器开的是只做
///   presence 的轻连接,不走这条协议;别的服务器上的圈子不会有通知。
///   要做就得给每条轻连接各注册一遍 token,且服务端要各自持有 APNs 密钥 —— 不在这一轮。
/// - 命名上与平台无关(push 而非 apns):将来接 Android(FCM)时协议里换 provider 即可。
///
/// 下面的常量与 ios/Runner/LaresPushBridge.swift、server/src 里的字符串一一对应,
/// test/push_contract_test.dart 会逐个比对,改名字要三处一起改。
class PushService {
  // ── 原生桥(MethodChannel)──
  static const channelName = 'lares/push';
  static const methodRequestPermission = 'requestPermission';
  static const methodGetToken = 'getToken';
  static const methodPermissionStatus = 'permissionStatus';
  static const methodGetInitialOpen = 'getInitialOpen';
  static const methodGetEnvironment = 'getEnvironment';

  /// 原生 -> Dart
  static const callbackOnToken = 'onToken';
  static const callbackOnOpen = 'onOpen';

  // ── 通知本身 ──
  static const category = 'LARES_JOIN';
  static const joinAction = 'JOIN';

  /// 点通知正文(而不是「加入」按钮)时原生报上来的 action
  static const openAction = 'open';

  /// APNs payload 里我们那一段的键:`{lares: {circleId, server?, kind}}`
  static const payloadKey = 'lares';
  static const payloadCircleId = 'circleId';
  static const payloadServer = 'server';
  static const payloadKind = 'kind';
  static const payloadAction = 'action';

  // ── 与服务器的信令协议 ──
  static const msgRegister = 'push_register';
  static const msgUnregister = 'push_unregister';
  static const msgRegistered = 'push_registered';
  static const msgUnregistered = 'push_unregistered';
  static const msgError = 'push_error';
  static const providerApns = 'apns';

  /// 系统权限状态里算「可以发」的那几种
  static const _grantedStatuses = {'authorized', 'provisional', 'ephemeral'};

  /// [messages] / [send]:主连接信令(`SignalingClient.messages` / `.send`)。
  /// 只要这两样而不是整个 SignalingClient:测试里一个 StreamController 就够了。
  ///
  /// [explain]:弹系统权限框之前的那句说明,返回用户是否愿意开启。
  /// 由 main.dart 用对话框实现;为 null 时不问(相当于用户没点「开启」)。
  PushService({
    required RoomController controller,
    required SettingsStore settings,
    required CircleStore circleStore,
    required Stream<Map<String, dynamic>> messages,
    required void Function(Map<String, dynamic>) send,
    Future<bool> Function()? explain,
    @visibleForTesting PushPlatform? platform,
    @visibleForTesting String? platformOverride,
    @visibleForTesting String Function()? systemLanguage,
  })  : _controller = controller,
        _settings = settings,
        _circles = circleStore,
        _messages = messages,
        _send = send,
        _explain = explain,
        _platform = platform ?? MethodChannelPushPlatform(),
        _platformOverride = platformOverride,
        _systemLanguage = systemLanguage ??
            (() => PlatformDispatcher.instance.locale.languageCode);

  final RoomController _controller;
  final SettingsStore _settings;
  final CircleStore _circles;
  final Stream<Map<String, dynamic>> _messages;
  final void Function(Map<String, dynamic>) _send;
  final Future<bool> Function()? _explain;
  final PushPlatform _platform;
  final String? _platformOverride;
  final String Function() _systemLanguage;

  StreamSubscription<Map<String, dynamic>>? _sub;
  bool _inited = false;

  String? _token;
  String _env = 'production';

  /// 当前连接是否已握手(见过 welcome 且没见过 _disconnected)。
  /// 没连上时不发:send 会把消息排进 outbox,而握手后的 welcome 本来就会重发一遍。
  bool _connected = false;

  /// 上一次发出去的 push_register 的 JSON。内容没变就不重发。
  String? _lastPayload;

  /// 总开关关掉后,这一轮的 push_unregister 是否已经发过 / 已被确认。
  bool _unregisterSent = false;
  bool _unregisterAcked = false;

  /// 本进程里是否已经处理过「第一次进房」—— 权限只在这个时机问。
  bool _sawInRoom = false;
  bool _asking = false;

  bool get _supported => !kIsWeb && (_platformOverride ?? PlatformInfo.current) == 'ios';

  @visibleForTesting
  String? get token => _token;

  /// 在同意内容规范之后调用(与 WidgetService.init 同一个理由):
  /// 这里会**消费冷启动时点的那条通知**并直接进圈,没同意就进圈是审核指南 1.2 禁止的。
  /// 同意之前原生侧把那次打开留在缓冲里,一条都不丢。
  Future<void> init() async {
    if (_inited || !_supported) return;
    _inited = true;

    _platform.setHandler(onToken: _onToken, onOpen: _onOpen);
    _sub = _messages.listen(_onMessage);
    _settings.addListener(_onStateChanged);
    _circles.addListener(_onStateChanged);
    _controller.addListener(_onRoomChanged);

    try {
      _env = await _platform.getEnvironment();
    } catch (_) {
      // 拿不到就按 production:Release 包才是用户手里的那个
    }
    // 之前授权过的:原生启动时已经自己要过 token,这里只是把结果取回来。
    try {
      final status = await _platform.permissionStatus();
      if (_grantedStatuses.contains(status)) {
        final t = await _platform.getToken();
        if (t != null && t.isNotEmpty) _onToken(t);
      }
    } catch (_) {}

    // 冷启动 / 同意之前点的那条通知
    try {
      final open = await _platform.getInitialOpen();
      if (open != null) await _onOpen(open);
    } catch (_) {}

    // 进房发生在 init 之前(同意之后立刻自动进圈)的话,这里补一次判断
    _onRoomChanged();
  }

  void dispose() {
    unawaited(_sub?.cancel());
    _sub = null;
    if (_inited) {
      _settings.removeListener(_onStateChanged);
      _circles.removeListener(_onStateChanged);
      _controller.removeListener(_onRoomChanged);
    }
  }

  // ── 注册 ──

  /// 发给服务器的那份完整名单。`circles` 是**全集**:服务器会把不在里面的圈退订。
  @visibleForTesting
  Map<String, dynamic>? buildRegisterPayload() {
    final token = _token;
    if (token == null) return null;
    final activeId = _settings.serverProfiles.activeId;
    return {
      't': msgRegister,
      'provider': providerApns,
      'token': token,
      'env': _env,
      'lang': _lang(),
      'circles': [
        for (final c in _circles.circles)
          // 只要主连接那台服务器上的圈(见类注释)。serverId 为 null 的是
          // 「跟着当前服务器走」的老圈子,算在当前服务器上。
          if (c.serverId == null || c.serverId == activeId)
            {
              'circleId': c.id,
              'name': c.name,
              'muted': _settings.isCirclePushMuted(c.id),
            },
      ],
    };
  }

  /// 通知文案是服务器拼的(App 被杀掉时也要能显示),所以语言要告诉它。
  String _lang() {
    final code = switch (_settings.appLanguage) {
      AppLanguage.zh => 'zh',
      AppLanguage.en => 'en',
      AppLanguage.system => _systemLanguage(),
    };
    return code.toLowerCase().startsWith('zh') ? 'zh' : 'en';
  }

  void _sync({bool force = false}) {
    if (!_connected) return;
    final token = _token;
    if (token == null) return;
    if (!_settings.pushEnabled) {
      // 关掉之后只说一次「别再发了」,然后彻底安静。
      if (_unregisterSent || _unregisterAcked) return;
      _unregisterSent = true;
      _lastPayload = null;
      _send({'t': msgUnregister, 'token': token});
      return;
    }
    final payload = buildRegisterPayload();
    if (payload == null) return;
    final json = jsonEncode(payload);
    if (!force && json == _lastPayload) return;
    _lastPayload = json;
    _send(payload);
  }

  void _onStateChanged() {
    if (_settings.pushEnabled) {
      // 重新打开:下次允许再退订一次
      _unregisterSent = false;
      _unregisterAcked = false;
    }
    _sync();
  }

  void _onToken(String token) {
    if (token.isEmpty || token == _token) return;
    _token = token;
    _unregisterAcked = false;
    _unregisterSent = false;
    _sync();
  }

  void _onMessage(Map<String, dynamic> msg) {
    switch (msg['t']) {
      case 'welcome':
        _connected = true;
        // 每次握手都整份重发:服务器可能重启过、或者这是另一台服务器。
        // 关着的话这里发的是 push_unregister(这一轮还没发过时)。
        _unregisterSent = false;
        _sync(force: true);
      case '_disconnected':
        _connected = false;
      case msgUnregistered:
        _unregisterAcked = true;
      case msgError:
        // 服务器没收下(没配 APNs、token 非法等)。不重试:下次握手自然再发一遍,
        // 在同一个连接上反复撞同一个错误没有意义。
        _lastPayload = null;
        debugPrint('[push] server rejected: ${msg['reason']}');
      case msgRegistered:
        final rejected = msg['rejected'];
        if (rejected is List && rejected.isNotEmpty) {
          debugPrint('[push] circles rejected by server: $rejected');
        }
    }
  }

  // ── 权限 ──

  void _onRoomChanged() {
    if (_sawInRoom || _controller.phase != RoomPhase.inRoom) return;
    _sawInRoom = true;
    unawaited(_maybeAskPermission());
  }

  /// 第一次真正进过房之后才问:那时用户已经知道圈子是什么,
  /// 「朋友进圈时通知你」才听得懂。装完就弹一个权限框,大多数人会点不允许,
  /// 而 iOS 的权限框一辈子只弹一次。
  Future<void> _maybeAskPermission() async {
    if (_asking) return;
    if (_settings.pushPermissionAsked || !_settings.pushEnabled) return;
    _asking = true;
    try {
      final status = await _platform.permissionStatus();
      if (status != 'notDetermined') return;
      // 先记下「问过了」再问:App 若恰好死在对话框上,下次也不会再问第二遍。
      // 用户点「算了」同样算问过 —— 不纠缠。
      await _settings.markPushPermissionAsked();
      final explain = _explain;
      if (explain == null) return;
      final yes = await explain();
      if (!yes) return;
      final granted = await _platform.requestPermission();
      if (!granted) return;
      // token 通常随后经 onToken 到达;已经到了的话这里顺手取一次。
      final t = await _platform.getToken();
      if (t != null && t.isNotEmpty) _onToken(t);
    } catch (e) {
      debugPrint('[push] permission flow failed: $e');
    } finally {
      _asking = false;
    }
  }

  // ── 点了通知 ──

  Future<void> _onOpen(Map<String, dynamic> open) async {
    final circleId = open[payloadCircleId];
    if (circleId is! String || circleId.isEmpty) return;
    // 本机没有这个圈就不进:没有它的口令,进了也只会 4401;
    // 也防一条伪造/过期的通知把人带进一个自己根本不在的圈。
    if (!_circles.circles.any((c) => c.id == circleId)) return;

    final server = open[payloadServer];
    if (server is String &&
        server.isNotEmpty &&
        _normalizeUrl(server) != _normalizeUrl(_controller.signalingUrl)) {
      // 通知来自另一台服务器:只在它是**本机存过的服务器**时切过去。
      // 不认识的地址一律不理 —— 通知内容来自网络,不能凭一条通知就把
      // 主连接(连同口令证明)指到任意地址上去。
      String? url;
      for (final p in _settings.serverProfiles.profiles) {
        if (_normalizeUrl(p.url) == _normalizeUrl(server)) url = p.url;
      }
      if (url == null) return;
      // micOn: null = 用户主动进圈,按设置开麦(见 switchServerAndJoin 的注释)
      await _controller.switchServerAndJoin(
          circleId: circleId, url: url, micOn: null);
      return;
    }
    // 点「加入」和点正文效果相同:都是用户亲手点的,都进圈。
    await _controller.switchToCircle(circleId);
  }

  /// 比较两个服务器地址是否是同一台。
  ///
  /// 不能只去掉结尾的 `/` 就比字符串:通知里的地址是服务端的 LARES_PUBLIC_URL,
  /// 客户端的是编译期 / 用户填的,同一台机器常见两种写法 ——
  /// `wss://host/ws` 与 `wss://host:443/ws`(CI 默认值就带 :443)。
  /// 若判成「不同服务器」又在档案里查不到,点通知就会被静默忽略,
  /// 用户只会觉得「加入」按钮坏了。所以按 URI 比:主机名不分大小写、
  /// 默认端口补齐、路径去掉结尾斜杠。解析失败才退回字符串比较。
  @visibleForTesting
  static String normalizeUrl(String url) {
    final raw = url.trim();
    final u = Uri.tryParse(raw);
    if (u == null || u.host.isEmpty) {
      var s = raw.toLowerCase();
      while (s.endsWith('/')) {
        s = s.substring(0, s.length - 1);
      }
      return s;
    }
    final scheme = u.scheme.toLowerCase();
    final port = u.hasPort
        ? u.port
        : switch (scheme) {
            'wss' || 'https' => 443,
            'ws' || 'http' => 80,
            _ => 0,
          };
    var path = u.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return '$scheme://${u.host.toLowerCase()}:$port$path';
  }

  static String _normalizeUrl(String url) => normalizeUrl(url);
}

/// 原生推送能力的抽象。生产实现走 [MethodChannelPushPlatform],测试注入假的。
abstract class PushPlatform {
  Future<bool> requestPermission();
  Future<String?> getToken();

  /// "notDetermined" | "denied" | "authorized" | "provisional" | "ephemeral"
  Future<String> permissionStatus();

  /// 取走原生侧缓冲的那次「点了通知」(取一次就清)。
  Future<Map<String, dynamic>?> getInitialOpen();

  /// "sandbox" | "production"
  Future<String> getEnvironment();

  void setHandler({
    required void Function(String token) onToken,
    required Future<void> Function(Map<String, dynamic> open) onOpen,
  });
}

class MethodChannelPushPlatform implements PushPlatform {
  MethodChannelPushPlatform([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel(PushService.channelName);

  final MethodChannel _channel;

  @override
  Future<bool> requestPermission() async =>
      await _channel.invokeMethod<bool>(PushService.methodRequestPermission) ??
      false;

  @override
  Future<String?> getToken() =>
      _channel.invokeMethod<String>(PushService.methodGetToken);

  @override
  Future<String> permissionStatus() async =>
      await _channel.invokeMethod<String>(PushService.methodPermissionStatus) ??
      'notDetermined';

  @override
  Future<Map<String, dynamic>?> getInitialOpen() async {
    final raw = await _channel.invokeMethod<Object?>(PushService.methodGetInitialOpen);
    return raw is Map ? Map<String, dynamic>.from(raw) : null;
  }

  @override
  Future<String> getEnvironment() async =>
      await _channel.invokeMethod<String>(PushService.methodGetEnvironment) ??
      'production';

  @override
  void setHandler({
    required void Function(String token) onToken,
    required Future<void> Function(Map<String, dynamic> open) onOpen,
  }) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case PushService.callbackOnToken:
          final t = call.arguments;
          if (t is String) onToken(t);
          return null;
        case PushService.callbackOnOpen:
          final a = call.arguments;
          if (a is Map) await onOpen(Map<String, dynamic>.from(a));
          // 返回 null(而不是 notImplemented):原生侧据此清掉缓冲
          return null;
      }
      throw MissingPluginException();
    });
  }
}
