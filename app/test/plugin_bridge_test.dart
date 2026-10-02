import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/plugins/plugin_bridge.dart';
import 'package:lares_app/src/plugins/plugin_models.dart';

class _FakeHost implements PluginHost {
  final calls = <String>[];
  final ctrl = StreamController<PluginHostEvent>.broadcast(sync: true);
  bool captionsAvailable = true;

  @override
  Stream<PluginHostEvent> get events => ctrl.stream;
  @override
  Future<Map<String, dynamic>?> getCircle() async {
    calls.add('getCircle');
    return {'id': 'c1', 'name': '圈'};
  }

  @override
  Future<List<Map<String, dynamic>>> getMembers() async {
    calls.add('getMembers');
    return [
      {'userId': 'u1', 'name': 'A'}
    ];
  }

  @override
  Future<Map<String, dynamic>?> getSelf() async {
    calls.add('getSelf');
    return {'userId': 'me'};
  }

  @override
  Future<void> sendChat(String text) async => calls.add('sendChat:$text');
  @override
  Future<void> sendCaption(String text, {bool isFinal = true}) async {
    if (!captionsAvailable) throw const PluginNotAvailable();
    calls.add('sendCaption:$text:$isFinal');
  }

  @override
  Future<Map<String, dynamic>> getState() async {
    calls.add('getState');
    return {'state': {'a': 1}, 'rev': 3};
  }

  @override
  Future<void> setState(Map<String, dynamic> patch) async =>
      calls.add('setState:${jsonEncode(patch)}');
  @override
  Future<Map<String, dynamic>?> getTranscript(int page) async {
    calls.add('getTranscript:$page');
    return {'items': <Object?>[], 'more': false};
  }
}

String _m(Object? id, String method, [List<Object?> args = const []]) =>
    jsonEncode({'id': id, 'method': method, 'args': args});

void main() {
  late _FakeHost host;
  late DateTime now;
  late MemoryPluginStorage storage;

  PluginBridge bridge(Iterable<String> perms) => PluginBridge(
        permissions: perms,
        host: host,
        storage: storage,
        clock: () => now,
      );

  setUp(() {
    host = _FakeHost();
    now = DateTime(2026, 1, 1);
    storage = MemoryPluginStorage();
  });

  test('permission gating per method', () async {
    final cases = {
      'getCircle': PluginPermissions.circleRead,
      'getMembers': PluginPermissions.membersRead,
      'getSelf': PluginPermissions.membersRead,
      'getState': PluginPermissions.stateRead,
      'getTranscript': PluginPermissions.transcriptRead,
    };
    for (final e in cases.entries) {
      final denied = await bridge(const []).dispatch(_m(1, e.key));
      expect(denied, {'id': 1, 'ok': false, 'error': 'permission_denied'},
          reason: e.key);
      final ok = await bridge([e.value]).dispatch(_m(2, e.key));
      expect(ok['ok'], isTrue, reason: e.key);
      expect(ok['id'], 2);
    }
    final b = bridge(const [PluginPermissions.circleRead]);
    for (final m in [
      _m(3, 'sendChat', ['hi']),
      _m(4, 'sendCaption', ['hi']),
      _m(5, 'setState', [{}]),
      _m(6, 'storage.get', ['k']),
      _m(7, 'storage.set', ['k', 1]),
    ]) {
      expect((await b.dispatch(m))['error'], 'permission_denied');
    }
    expect(host.calls.where((c) => c.startsWith('send')), isEmpty);
  });

  test('allowed calls reach the host with args', () async {
    final b = bridge(PluginPermissions.known);
    expect((await b.dispatch(_m(1, 'getCircle')))['value'],
        {'id': 'c1', 'name': '圈'});
    await b.dispatch(_m(2, 'sendChat', ['hello']));
    now = now.add(const Duration(seconds: 2));
    await b.dispatch(_m(3, 'sendCaption', [
      'cap',
      {'final': false}
    ]));
    await b.dispatch(_m(4, 'setState', [
      {'x': 1}
    ]));
    await b.dispatch(_m(5, 'getTranscript', [2]));
    expect(host.calls, [
      'getCircle',
      'sendChat:hello',
      'sendCaption:cap:false',
      'setState:{"x":1}',
      'getTranscript:2',
    ]);
  });

  test('not_available from host', () async {
    host.captionsAvailable = false;
    final r = await bridge([PluginPermissions.captionsSend])
        .dispatch(_m(1, 'sendCaption', ['x']));
    expect(r, {'id': 1, 'ok': false, 'error': 'not_available'});
  });

  test('unknown method and malformed messages', () async {
    final b = bridge(PluginPermissions.known);
    expect(await b.dispatch(_m(1, 'eval')),
        {'id': 1, 'ok': false, 'error': 'unknown_method'});
    expect((await b.dispatch('not json'))['error'], 'bad_args');
    expect((await b.dispatch('[1]'))['error'], 'bad_args');
    expect(await b.dispatch(jsonEncode({'method': 'getCircle'})),
        {'id': null, 'ok': false, 'error': 'bad_args'});
    expect(
        (await b.dispatch(jsonEncode({'id': 9, 'method': 'getCircle', 'args': 3})))[
            'error'],
        'bad_args');
  });

  test('bad args', () async {
    final b = bridge(PluginPermissions.known);
    Future<String?> err(String m) async => (await b.dispatch(m))['error'] as String?;
    expect(await err(_m(1, 'sendChat', ['x' * 501])), 'bad_args');
    expect(await err(_m(2, 'sendChat', [''])), 'bad_args');
    expect(await err(_m(3, 'sendChat', [5])), 'bad_args');
    expect(await err(_m(4, 'sendCaption', ['x', 'nope'])), 'bad_args');
    expect(await err(_m(5, 'getTranscript', [-1])), 'bad_args');
    expect(await err(_m(6, 'getTranscript', [1.5])), 'bad_args');
    expect(await err(_m(7, 'setState', ['str'])), 'bad_args');
    expect(await err(_m(8, 'storage.get', ['k' * 65])), 'bad_args');
    expect(await err(_m(9, 'storage.set', ['', 1])), 'bad_args');
    expect(await err(_m(10, 'storage.set', ['k', 'v' * (8 * 1024)])), 'bad_args');
    // 500 字刚好可以
    now = now.add(const Duration(seconds: 5));
    expect(await err(_m(11, 'sendChat', ['字' * 500])), isNull);
  });

  test('rate limit: 20 calls per second overall', () async {
    final b = bridge(PluginPermissions.known);
    for (var i = 0; i < 20; i++) {
      expect((await b.dispatch(_m(i, 'getCircle')))['ok'], isTrue);
    }
    expect((await b.dispatch(_m(20, 'getCircle')))['error'], 'rate_limited');
    now = now.add(const Duration(milliseconds: 1001));
    expect((await b.dispatch(_m(21, 'getCircle')))['ok'], isTrue);
  });

  test('rate limit: sendChat 1 per second', () async {
    final b = bridge([PluginPermissions.chatSend]);
    expect((await b.dispatch(_m(1, 'sendChat', ['a'])))['ok'], isTrue);
    now = now.add(const Duration(milliseconds: 500));
    expect((await b.dispatch(_m(2, 'sendChat', ['b'])))['error'], 'rate_limited');
    now = now.add(const Duration(milliseconds: 600));
    expect((await b.dispatch(_m(3, 'sendChat', ['c'])))['ok'], isTrue);
    expect(host.calls, ['sendChat:a', 'sendChat:c']);
  });

  test('event filtering by permission', () async {
    final b = bridge([PluginPermissions.chatRead, PluginPermissions.stateRead]);
    final got = <String>[];
    b.events.listen((e) => got.add(e.name));
    for (final n in ['chat', 'caption', 'transcript', 'join', 'leave', 'state', 'weird']) {
      host.ctrl.add(PluginHostEvent(n, {'x': 1}));
    }
    await Future<void>.delayed(Duration.zero);
    expect(got, ['chat', 'state']);

    final b2 = bridge([
      PluginPermissions.membersRead,
      PluginPermissions.captionsRead,
      PluginPermissions.transcriptRead,
    ]);
    final got2 = <String>[];
    b2.events.listen((e) => got2.add(e.name));
    for (final n in ['chat', 'caption', 'transcript', 'join', 'leave', 'state']) {
      host.ctrl.add(PluginHostEvent(n, null));
    }
    await Future<void>.delayed(Duration.zero);
    expect(got2, ['caption', 'transcript', 'join', 'leave']);
    b.dispose();
    b2.dispose();
  });

  test('storage set/get/delete and total cap', () async {
    final b = bridge([PluginPermissions.storage]);
    Future<Map<String, dynamic>> call(String m) => b.dispatch(m);
    expect((await call(_m(1, 'storage.get', ['a'])))['value'], isNull);
    expect((await call(_m(2, 'storage.set', ['a', {'n': 1}])))['ok'], isTrue);
    expect((await call(_m(3, 'storage.get', ['a'])))['value'], {'n': 1});
    expect(storage.data, {'a': {'n': 1}});
    expect((await call(_m(4, 'storage.set', ['a', null])))['ok'], isTrue);
    expect(storage.data, isEmpty);

    // 每个值 ~7.9KB,第 9 个超过 64KB 总量
    final big = 'x' * 7900;
    for (var i = 0; i < 8; i++) {
      now = now.add(const Duration(milliseconds: 100));
      expect((await call(_m(10 + i, 'storage.set', ['k$i', big])))['ok'], isTrue,
          reason: 'k$i');
    }
    now = now.add(const Duration(seconds: 1));
    expect((await call(_m(30, 'storage.set', ['k9', big])))['error'], 'bad_args');
    expect(storage.data.containsKey('k9'), isFalse);
  });

  test('storage persists across bridges via storage backend', () async {
    await bridge([PluginPermissions.storage]).dispatch(_m(1, 'storage.set', ['k', 7]));
    final r = await bridge([PluginPermissions.storage]).dispatch(_m(2, 'storage.get', ['k']));
    expect(r['value'], 7);
  });

  test('js helpers and shim', () {
    expect(laresBridgeShim, contains('LaresBridge.postMessage'));
    expect(laresBridgeShim, contains('window.__laresResolve'));
    expect(laresBridgeShim, contains('window.__laresEmit'));
    expect(pluginResolveJs({'id': 3, 'ok': true, 'value': 'a"b'}),
        contains(r'(3,true,"a\"b")'));
    expect(pluginResolveJs({'id': 4, 'ok': false, 'error': 'rate_limited'}),
        contains('(4,false,"rate_limited")'));
    expect(pluginEmitJs('chat', {'t': 1}), contains('("chat",{"t":1})'));
  });
}
