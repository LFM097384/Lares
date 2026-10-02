/// 网页小程序 ↔ App 的桥(契约 §7)。纯 Dart,不依赖 WebView,可完整单测。
///
/// JS → Dart:`LaresBridge.postMessage('{"id":n,"method":"…","args":[…]}')`
/// Dart → JS:`window.__laresResolve(id, ok, value)` / `window.__laresEmit(event, data)`
/// 错误码:permission_denied unknown_method bad_args not_available rate_limited。
library;

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_models.dart';

/// 宿主暂不支持某能力时抛出 → 桥回 `not_available`。
class PluginNotAvailable implements Exception {
  const PluginNotAvailable([this.what = '']);
  final String what;
  @override
  String toString() => 'PluginNotAvailable($what)';
}

/// 宿主推给插件的事件(名字 ∈ chat caption transcript join leave state)。
class PluginHostEvent {
  const PluginHostEvent(this.name, this.data);
  final String name;
  final Object? data;
}

/// 桥背后的能力提供者(房间里由 RoomPluginHost 实现)。
abstract class PluginHost {
  Future<Map<String, dynamic>?> getCircle();
  Future<List<Map<String, dynamic>>> getMembers();
  Future<Map<String, dynamic>?> getSelf();
  Future<void> sendChat(String text);
  Future<void> sendCaption(String text, {bool isFinal = true});
  Future<Map<String, dynamic>> getState();
  Future<void> setState(Map<String, dynamic> patch);
  Future<Map<String, dynamic>?> getTranscript(int page);
  Stream<PluginHostEvent> get events;
}

/// 插件私有存储(按圈按插件隔离)。
abstract class PluginStorage {
  Future<Map<String, dynamic>> load();
  Future<void> save(Map<String, dynamic> data);
}

class MemoryPluginStorage implements PluginStorage {
  MemoryPluginStorage([Map<String, dynamic>? initial])
      : data = {...?initial};
  Map<String, dynamic> data;
  @override
  Future<Map<String, dynamic>> load() async => {...data};
  @override
  Future<void> save(Map<String, dynamic> d) async => data = {...d};
}

/// SharedPreferences 落地,键 `plugin_storage.<circleId>.<pluginId>`。
class SharedPrefsPluginStorage implements PluginStorage {
  SharedPrefsPluginStorage(this.circleId, this.pluginId);
  final String circleId;
  final String pluginId;

  String get key => 'plugin_storage.$circleId.$pluginId';

  @override
  Future<Map<String, dynamic>> load() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString(key);
    if (s == null) return {};
    try {
      final v = jsonDecode(s);
      return v is Map ? Map<String, dynamic>.from(v) : {};
    } on FormatException {
      return {};
    }
  }

  @override
  Future<void> save(Map<String, dynamic> data) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(key, jsonEncode(data));
  }
}

/// 桥的限额。
abstract final class PluginBridgeLimits {
  static const int callsPerSecond = 20;
  static const Duration chatInterval = Duration(seconds: 1);
  static const int maxTextChars = 500;
  static const int maxKeyChars = 64;
  static const int maxValueBytes = 8 * 1024;
  static const int maxStorageBytes = 64 * 1024;
}

class _BridgeError implements Exception {
  const _BridgeError(this.code);
  final String code;
}

/// 方法 → 所需权限。
const Map<String, String> pluginMethodPermissions = {
  'getCircle': PluginPermissions.circleRead,
  'getMembers': PluginPermissions.membersRead,
  'getSelf': PluginPermissions.membersRead,
  'sendChat': PluginPermissions.chatSend,
  'sendCaption': PluginPermissions.captionsSend,
  'getTranscript': PluginPermissions.transcriptRead,
  'getState': PluginPermissions.stateRead,
  'setState': PluginPermissions.stateWrite,
  'storage.get': PluginPermissions.storage,
  'storage.set': PluginPermissions.storage,
};

/// 事件 → 所需权限。
const Map<String, String> pluginEventPermissions = {
  'chat': PluginPermissions.chatRead,
  'caption': PluginPermissions.captionsRead,
  'transcript': PluginPermissions.transcriptRead,
  'join': PluginPermissions.membersRead,
  'leave': PluginPermissions.membersRead,
  'state': PluginPermissions.stateRead,
};

class PluginBridge {
  PluginBridge({
    required Iterable<String> permissions,
    required this.host,
    required this.storage,
    DateTime Function()? clock,
  })  : permissions = Set.unmodifiable(permissions),
        _clock = clock ?? DateTime.now {
    _eventSub = host.events.listen((e) {
      final need = pluginEventPermissions[e.name];
      if (need == null || !this.permissions.contains(need)) return;
      _events.add(e);
    });
  }

  final Set<String> permissions;
  final PluginHost host;
  final PluginStorage storage;
  final DateTime Function() _clock;

  late final StreamSubscription<PluginHostEvent> _eventSub;
  final StreamController<PluginHostEvent> _events =
      StreamController.broadcast();

  /// 按权限过滤后、该推给插件的事件。
  Stream<PluginHostEvent> get events => _events.stream;

  final List<DateTime> _calls = [];
  DateTime? _lastChat;
  Map<String, dynamic>? _store;

  /// 处理一条来自 JS 的消息,返回 `{id, ok, value|error}`。从不抛异常。
  Future<Map<String, dynamic>> dispatch(String jsonMessage) async {
    Object? id;
    try {
      final Object? msg;
      try {
        msg = jsonDecode(jsonMessage);
      } on FormatException {
        throw const _BridgeError('bad_args');
      }
      if (msg is! Map) throw const _BridgeError('bad_args');
      id = msg['id'];
      if (id is! num && id is! String) {
        id = null;
        throw const _BridgeError('bad_args');
      }
      final method = msg['method'];
      final rawArgs = msg['args'];
      final args = rawArgs == null
          ? const <Object?>[]
          : rawArgs is List
              ? rawArgs
              : throw const _BridgeError('bad_args');
      if (method is! String) throw const _BridgeError('bad_args');
      final need = pluginMethodPermissions[method];
      if (need == null) throw const _BridgeError('unknown_method');
      if (!permissions.contains(need)) {
        throw const _BridgeError('permission_denied');
      }
      _rateLimit(method);
      final value = await _call(method, args);
      return {'id': id, 'ok': true, 'value': value};
    } on _BridgeError catch (e) {
      return {'id': id, 'ok': false, 'error': e.code};
    } on PluginNotAvailable {
      return {'id': id, 'ok': false, 'error': 'not_available'};
    } catch (_) {
      return {'id': id, 'ok': false, 'error': 'not_available'};
    }
  }

  void _rateLimit(String method) {
    final now = _clock();
    final cutoff = now.subtract(const Duration(seconds: 1));
    _calls.removeWhere((t) => !t.isAfter(cutoff));
    if (_calls.length >= PluginBridgeLimits.callsPerSecond) {
      throw const _BridgeError('rate_limited');
    }
    if (method == 'sendChat') {
      final last = _lastChat;
      if (last != null &&
          now.difference(last) < PluginBridgeLimits.chatInterval) {
        throw const _BridgeError('rate_limited');
      }
    }
    _calls.add(now);
  }

  static Object? _arg(List<Object?> args, int i) =>
      i < args.length ? args[i] : null;

  static String _text(Object? v) {
    if (v is! String || v.trim().isEmpty) throw const _BridgeError('bad_args');
    if (v.runes.length > PluginBridgeLimits.maxTextChars) {
      throw const _BridgeError('bad_args');
    }
    return v;
  }

  static String _key(Object? v) {
    if (v is! String || v.isEmpty || v.runes.length > PluginBridgeLimits.maxKeyChars) {
      throw const _BridgeError('bad_args');
    }
    return v;
  }

  static int _bytes(Object? v) {
    try {
      return utf8.encode(jsonEncode(v)).length;
    } on JsonUnsupportedObjectError {
      throw const _BridgeError('bad_args');
    }
  }

  Future<Object?> _call(String method, List<Object?> args) async {
    switch (method) {
      case 'getCircle':
        return host.getCircle();
      case 'getMembers':
        return host.getMembers();
      case 'getSelf':
        return host.getSelf();
      case 'sendChat':
        final text = _text(_arg(args, 0));
        _lastChat = _clock();
        await host.sendChat(text);
        return null;
      case 'sendCaption':
        final text = _text(_arg(args, 0));
        final opts = _arg(args, 1);
        if (opts != null && opts is! Map) throw const _BridgeError('bad_args');
        final fin = opts is Map ? opts['final'] : null;
        if (fin != null && fin is! bool) throw const _BridgeError('bad_args');
        await host.sendCaption(text, isFinal: fin as bool? ?? true);
        return null;
      case 'getTranscript':
        final p = _arg(args, 0) ?? 0;
        if (p is! num || p < 0 || p != p.toInt()) {
          throw const _BridgeError('bad_args');
        }
        return host.getTranscript(p.toInt());
      case 'getState':
        return host.getState();
      case 'setState':
        final patch = _arg(args, 0);
        if (patch is! Map) throw const _BridgeError('bad_args');
        if (_bytes(patch) > PluginBridgeLimits.maxStorageBytes) {
          throw const _BridgeError('bad_args');
        }
        await host.setState(Map<String, dynamic>.from(patch));
        return null;
      case 'storage.get':
        final k = _key(_arg(args, 0));
        final s = await _loadStore();
        return s[k];
      case 'storage.set':
        final k = _key(_arg(args, 0));
        final v = _arg(args, 1);
        if (_bytes(v) > PluginBridgeLimits.maxValueBytes) {
          throw const _BridgeError('bad_args');
        }
        final s = {...await _loadStore()};
        if (v == null) {
          s.remove(k);
        } else {
          s[k] = v;
        }
        if (_bytes(s) > PluginBridgeLimits.maxStorageBytes) {
          throw const _BridgeError('bad_args');
        }
        await storage.save(s);
        _store = s;
        return null;
    }
    throw const _BridgeError('unknown_method');
  }

  Future<Map<String, dynamic>> _loadStore() async =>
      _store ??= await storage.load();

  void dispose() {
    unawaited(_eventSub.cancel());
    unawaited(_events.close());
  }
}

/// `window.__laresResolve(...)` 调用语句。
String pluginResolveJs(Map<String, dynamic> result) {
  final ok = result['ok'] == true;
  final value = ok ? result['value'] : result['error'];
  return 'window.__laresResolve&&window.__laresResolve('
      '${jsonEncode(result['id'])},${ok ? 'true' : 'false'},${jsonEncode(value)});';
}

/// `window.__laresEmit(...)` 调用语句。
String pluginEmitJs(String event, Object? data) =>
    'window.__laresEmit&&window.__laresEmit(${jsonEncode(event)},${jsonEncode(data)});';

/// 注入页面的 `window.lares` 垫片(幂等)。
const String laresBridgeShim = r'''
(function(){
  if (window.lares && window.lares.__v) return;
  var nextId = 1, pending = {}, listeners = {};
  function call(method, args){
    return new Promise(function(resolve, reject){
      var id = nextId++;
      pending[id] = {resolve: resolve, reject: reject};
      try {
        LaresBridge.postMessage(JSON.stringify({id: id, method: method, args: args || []}));
      } catch (e) {
        delete pending[id];
        reject(new Error('not_available'));
      }
    });
  }
  window.__laresResolve = function(id, ok, value){
    var p = pending[id];
    if (!p) return;
    delete pending[id];
    if (ok) p.resolve(value); else p.reject(new Error(String(value)));
  };
  window.__laresEmit = function(event, data){
    var ls = (listeners[event] || []).slice();
    for (var i = 0; i < ls.length; i++) {
      try { ls[i](data); } catch (e) { setTimeout(function(){ throw e; }); }
    }
  };
  window.lares = {
    __v: 1,
    getCircle: function(){ return call('getCircle'); },
    getMembers: function(){ return call('getMembers'); },
    getSelf: function(){ return call('getSelf'); },
    sendChat: function(text){ return call('sendChat', [text]); },
    sendCaption: function(text, opts){ return call('sendCaption', [text, opts || {}]); },
    getTranscript: function(page){ return call('getTranscript', [page || 0]); },
    getState: function(){ return call('getState'); },
    setState: function(patch){ return call('setState', [patch]); },
    storage: {
      get: function(key){ return call('storage.get', [key]); },
      set: function(key, value){ return call('storage.set', [key, value === undefined ? null : value]); }
    },
    on: function(event, cb){
      (listeners[event] = listeners[event] || []).push(cb);
      return function(){
        var ls = listeners[event] || [];
        var i = ls.indexOf(cb);
        if (i >= 0) ls.splice(i, 1);
      };
    }
  };
  try { window.dispatchEvent(new Event('lares-ready')); } catch (e) {}
})();
''';
