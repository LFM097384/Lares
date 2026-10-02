/// 插件的客户端协调层(契约 docs/plans/plugin-focus-contract.md §3)。
///
/// 只依赖 `send` + `messages`:测试用假信令直接驱动(同 TranscriptService)。
/// 圈主操作自带回执等待,失败用 reason 码表达(no_key / timeout / 服务器 reason)。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'plugin_models.dart';

/// 共享状态变化。
@immutable
class PluginStateEvent {
  const PluginStateEvent({
    required this.circleId,
    required this.pluginId,
    required this.state,
    required this.rev,
  });
  final String circleId;
  final String pluginId;
  final Map<String, dynamic> state;
  final int rev;
}

/// `plugin_error`(成员操作失败,如 plugin_state_set 被拒)。
@immutable
class PluginErrorEvent {
  const PluginErrorEvent({
    required this.op,
    required this.circleId,
    this.pluginId,
    required this.reason,
  });
  final String op;
  final String circleId;
  final String? pluginId;
  final String reason;
}

/// 圈主操作结果。[reason] 为 null = 成功。
@immutable
class PluginOpResult {
  const PluginOpResult({this.reason, this.detail});
  final String? reason;
  final String? detail;
  bool get ok => reason == null;
}

/// 安装结果。token / webhookSecret 明文**只此一次**。
@immutable
class PluginInstallResult extends PluginOpResult {
  const PluginInstallResult({
    this.plugin,
    this.token,
    this.webhookSecret,
    super.reason,
    super.detail,
  });
  final PluginView? plugin;
  final String? token;
  final String? webhookSecret;
}

typedef _Waiter = ({
  String op,
  String circleId,
  Completer<Map<String, dynamic>> done,
});

class PluginService extends ChangeNotifier {
  PluginService({
    required this.send,
    required Stream<Map<String, dynamic>> messages,
    required this.ownerKeyFor,
    this.timeout = const Duration(seconds: 15),
  }) {
    _sub = messages.listen(_onMessage);
  }

  final void Function(Map<String, dynamic> msg) send;

  /// 本机持有的圈主钥匙;null = 不是圈主。
  final String? Function(String circleId) ownerKeyFor;
  final Duration timeout;

  late final StreamSubscription<Map<String, dynamic>> _sub;

  final Map<String, List<PluginView>> _plugins = {};
  final Map<String, Map<String, ({Map<String, dynamic> state, int rev})>>
      _states = {};

  final StreamController<PluginStateEvent> _stateCtrl =
      StreamController.broadcast();
  final StreamController<PluginErrorEvent> _errorCtrl =
      StreamController.broadcast();

  Stream<PluginStateEvent> get stateChanges => _stateCtrl.stream;
  Stream<PluginErrorEvent> get errors => _errorCtrl.stream;

  final List<_Waiter> _waiters = [];

  // ── 查 ────────────────────────────────────────────────────────────

  /// 本圈已知的插件(还没收到任何列表 = 空)。
  List<PluginView> pluginsFor(String circleId) =>
      List.unmodifiable(_plugins[circleId] ?? const <PluginView>[]);

  /// 是否收到过本圈的插件列表。
  bool hasListFor(String circleId) => _plugins.containsKey(circleId);

  PluginView? plugin(String circleId, String pluginId) {
    for (final p in _plugins[circleId] ?? const <PluginView>[]) {
      if (p.id == pluginId) return p;
    }
    return null;
  }

  /// 本圈某插件已装且启用。
  bool isEnabled(String circleId, String pluginId) =>
      plugin(circleId, pluginId)?.enabled ?? false;

  Map<String, dynamic>? stateOf(String circleId, String pluginId) =>
      _states[circleId]?[pluginId]?.state;

  int revOf(String circleId, String pluginId) =>
      _states[circleId]?[pluginId]?.rev ?? -1;

  bool isOwner(String circleId) => ownerKeyFor(circleId) != null;

  // ── 收 ────────────────────────────────────────────────────────────

  void _onMessage(Map<String, dynamic> msg) {
    switch (msg['t']) {
      case 'welcome':
      case 'circle_settings':
        final c = msg['circle'];
        if (c is Map && c['id'] is String && c.containsKey('plugins')) {
          _setList(c['id'] as String, PluginView.listFromJson(c['plugins']));
        }
        return;
    }
    final cid = msg['circleId'];
    if (cid is! String) return;
    switch (msg['t']) {
      case 'circle_summary':
        // 小视图 [{id, enabled}]:只更新已知插件的启停,不凭空造插件。
        final raw = msg['plugins'];
        final cur = _plugins[cid];
        if (raw is List && cur != null) {
          final enabled = <String, bool>{
            for (final e in raw)
              if (e is Map && e['id'] is String)
                e['id'] as String: e['enabled'] != false,
          };
          _setList(cid, [
            for (final p in cur)
              if (enabled.containsKey(p.id))
                p.copyWith(enabled: enabled[p.id])
          ]);
        }
      case 'plugins':
        _setList(cid, PluginView.listFromJson(msg['items']));
      case 'plugin_installed':
        final p = PluginView.fromJson(msg['plugin']);
        if (p != null) {
          final cur = [...?_plugins[cid]]..removeWhere((x) => x.id == p.id);
          _setList(cid, [...cur, p]);
        }
        _settle('plugin_install', cid, msg);
      case 'plugin_state':
        final pid = msg['pluginId'];
        if (pid is! String) return;
        final st = msg['state'];
        final rev = msg['rev'];
        final state = st is Map ? Map<String, dynamic>.from(st) : <String, dynamic>{};
        final r = rev is num ? rev.toInt() : 0;
        final prev = _states[cid]?[pid];
        // 旧消息(rev 更小)不覆盖新状态
        if (prev != null && r < prev.rev) return;
        (_states[cid] ??= {})[pid] = (state: state, rev: r);
        _stateCtrl.add(PluginStateEvent(
            circleId: cid, pluginId: pid, state: state, rev: r));
        notifyListeners();
      case 'plugin_error':
        _errorCtrl.add(PluginErrorEvent(
          op: msg['op'] as String? ?? '',
          circleId: cid,
          pluginId: msg['pluginId'] as String?,
          reason: msg['reason'] as String? ?? 'unknown',
        ));
      case 'owner_ok':
        final op = msg['op'];
        if (op is String && op.startsWith('plugin_')) _settle(op, cid, msg);
      case 'owner_error':
        final op = msg['op'];
        if (op is String && op.startsWith('plugin_')) {
          _settle(op, cid, msg, error: true);
        }
    }
  }

  void _setList(String circleId, List<PluginView> items) {
    _plugins[circleId] = items;
    notifyListeners();
  }

  void _settle(String op, String cid, Map<String, dynamic> msg,
      {bool error = false}) {
    final i = _waiters.indexWhere((w) => w.op == op && w.circleId == cid);
    if (i < 0) return;
    final w = _waiters.removeAt(i);
    if (w.done.isCompleted) return;
    w.done.complete({...msg, if (error) '_error': true});
  }

  Future<Map<String, dynamic>> _ownerOp(
      String op, String circleId, Map<String, dynamic> Function(String) build) {
    final key = ownerKeyFor(circleId);
    if (key == null) {
      return Future.value({'_error': true, 'reason': 'no_key'});
    }
    final done = Completer<Map<String, dynamic>>();
    final _Waiter w = (op: op, circleId: circleId, done: done);
    _waiters.add(w);
    send(build(key));
    return done.future.timeout(timeout, onTimeout: () {
      _waiters.remove(w);
      return {'_error': true, 'reason': 'timeout'};
    });
  }

  static PluginOpResult _opResult(Map<String, dynamic> m) => m['_error'] == true
      ? PluginOpResult(
          reason: m['reason'] as String? ?? 'unknown',
          detail: m['detail']?.toString())
      : const PluginOpResult();

  // ── 发 ────────────────────────────────────────────────────────────

  /// 成员可读:拉列表(回 `plugins`)。
  void list(String circleId) {
    _listRequested.add(circleId);
    send({'t': 'plugin_list', 'circleId': circleId});
  }

  final Set<String> _listRequested = {};

  /// 还没有本圈列表、也没要过时拉一次(UI 在 build 里调用也不会刷屏)。
  void ensureList(String circleId) {
    if (hasListFor(circleId) || _listRequested.contains(circleId)) return;
    list(circleId);
  }

  /// 安装:内置 [pluginId] / [manifest] / [manifestUrl] 三选一。
  Future<PluginInstallResult> install(
    String circleId, {
    String? pluginId,
    Map<String, dynamic>? manifest,
    String? manifestUrl,
  }) async {
    final m = await _ownerOp(
        'plugin_install',
        circleId,
        (k) => {
              't': 'plugin_install',
              'circleId': circleId,
              'ownerKey': k,
              'pluginId': ?pluginId,
              'manifest': ?manifest,
              'manifestUrl': ?manifestUrl,
            });
    if (m['_error'] == true) {
      return PluginInstallResult(
          reason: m['reason'] as String? ?? 'unknown',
          detail: m['detail']?.toString());
    }
    final token = m['token'], secret = m['webhookSecret'];
    return PluginInstallResult(
      plugin: PluginView.fromJson(m['plugin']),
      token: token is String && token.isNotEmpty ? token : null,
      webhookSecret: secret is String && secret.isNotEmpty ? secret : null,
    );
  }

  Future<PluginOpResult> uninstall(String circleId, String pluginId) async {
    final r = _opResult(await _ownerOp(
        'plugin_uninstall',
        circleId,
        (k) => {
              't': 'plugin_uninstall',
              'circleId': circleId,
              'ownerKey': k,
              'pluginId': pluginId,
            }));
    if (r.ok && _plugins[circleId] != null) {
      _setList(circleId,
          [..._plugins[circleId]!]..removeWhere((p) => p.id == pluginId));
    }
    return r;
  }

  Future<PluginOpResult> setEnabled(
      String circleId, String pluginId, bool enabled) async {
    final r = _opResult(await _ownerOp(
        'plugin_set_enabled',
        circleId,
        (k) => {
              't': 'plugin_set_enabled',
              'circleId': circleId,
              'ownerKey': k,
              'pluginId': pluginId,
              'enabled': enabled,
            }));
    if (r.ok) _patch(circleId, pluginId, (p) => p.copyWith(enabled: enabled));
    return r;
  }

  Future<PluginOpResult> setConfig(
      String circleId, String pluginId, Map<String, dynamic> config) async {
    final r = _opResult(await _ownerOp(
        'plugin_config_set',
        circleId,
        (k) => {
              't': 'plugin_config_set',
              'circleId': circleId,
              'ownerKey': k,
              'pluginId': pluginId,
              'config': config,
            }));
    if (r.ok) _patch(circleId, pluginId, (p) => p.copyWith(config: config));
    return r;
  }

  void _patch(String cid, String pid, PluginView Function(PluginView) f) {
    final cur = _plugins[cid];
    if (cur == null) return;
    _setList(cid, [for (final p in cur) p.id == pid ? f(p) : p]);
  }

  /// 拉共享状态(回 `plugin_state`)。
  void getState(String circleId, String pluginId) => send({
        't': 'plugin_state_get',
        'circleId': circleId,
        'pluginId': pluginId,
      });

  /// 成员写共享状态(JSON Merge Patch;服务器广播 `plugin_state`)。
  void setState(
          String circleId, String pluginId, Map<String, dynamic> patch) =>
      send({
        't': 'plugin_state_set',
        'circleId': circleId,
        'pluginId': pluginId,
        'patch': patch,
      });

  @override
  void dispose() {
    unawaited(_sub.cancel());
    unawaited(_stateCtrl.close());
    unawaited(_errorCtrl.close());
    for (final w in _waiters) {
      if (!w.done.isCompleted) {
        w.done.complete({'_error': true, 'reason': 'disposed'});
      }
    }
    _waiters.clear();
    super.dispose();
  }
}
