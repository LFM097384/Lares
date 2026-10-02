import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/plugins/plugin_models.dart';
import 'package:lares_app/src/plugins/plugin_service.dart';

class _FakeSignaling {
  final sent = <Map<String, dynamic>>[];
  final ctrl = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  void inject(Map<String, dynamic> m) => ctrl.add(m);
}

Map<String, dynamic> _view(String id, {bool enabled = true, String? url}) => {
      'id': id,
      'name': 'N-$id',
      'version': '1.0.0',
      'permissions': ['circle:read', 'chat:send'],
      'builtin': id.startsWith('lares.'),
      'enabled': enabled,
      'config': {'a': 1},
      'hasWebhook': false,
      'rev': 2,
      if (url != null) 'entry': {'url': url},
    };

void main() {
  late _FakeSignaling sig;
  late PluginService s;
  String? ownerKey;

  setUp(() {
    sig = _FakeSignaling();
    ownerKey = 'ok-1';
    s = PluginService(
      send: sig.sent.add,
      messages: sig.ctrl.stream,
      ownerKeyFor: (_) => ownerKey,
      timeout: const Duration(milliseconds: 200),
    );
  });
  tearDown(() => s.dispose());

  test('PluginView.fromJson is tolerant', () {
    expect(PluginView.fromJson('x'), isNull);
    expect(PluginView.fromJson({'name': 'no id'}), isNull);
    final v = PluginView.fromJson({'id': 'a.b', 'permissions': ['x', 3], 'rev': 'bad'})!;
    expect(v.name, 'a.b');
    expect(v.permissions, ['x']);
    expect(v.enabled, isTrue);
    expect(v.rev, 0);
    final m = PluginManifest.fromJson({
      'id': 'com.x.y',
      'name': 'Y',
      'entry': {'url': 'https://x.y/'},
      'webhook': {'url': 'https://h', 'events': ['join']},
    })!;
    expect(m.entryUrl, 'https://x.y/');
    expect(m.toJson()['webhook'], {'url': 'https://h', 'events': ['join']});
  });

  test('parses plugins / welcome / circle_settings / summary', () {
    sig.inject({
      't': 'plugins',
      'circleId': 'c1',
      'items': [_view('lares.focus'), _view('com.a.b', url: 'https://a.b/')],
    });
    expect(s.pluginsFor('c1').map((p) => p.id), ['lares.focus', 'com.a.b']);
    expect(s.plugin('c1', 'com.a.b')!.entryUrl, 'https://a.b/');
    expect(s.plugin('c1', 'com.a.b')!.config, {'a': 1});

    sig.inject({
      't': 'welcome',
      'circle': {
        'id': 'c2',
        'plugins': [_view('x.y', enabled: false)]
      },
    });
    expect(s.isEnabled('c2', 'x.y'), isFalse);

    sig.inject({
      't': 'circle_settings',
      'circle': {'id': 'c2', 'plugins': <Object?>[]},
    });
    expect(s.pluginsFor('c2'), isEmpty);

    sig.inject({
      't': 'circle_summary',
      'circleId': 'c1',
      'plugins': [
        {'id': 'lares.focus', 'enabled': false}
      ],
    });
    expect(s.pluginsFor('c1').map((p) => p.id), ['lares.focus']);
    expect(s.isEnabled('c1', 'lares.focus'), isFalse);
  });

  test('plugin_state updates cache and stream; stale rev ignored', () async {
    final events = <PluginStateEvent>[];
    s.stateChanges.listen(events.add);
    sig.inject({
      't': 'plugin_state',
      'circleId': 'c1',
      'pluginId': 'p.q',
      'state': {'n': 1},
      'rev': 5,
    });
    sig.inject({
      't': 'plugin_state',
      'circleId': 'c1',
      'pluginId': 'p.q',
      'state': {'n': 0},
      'rev': 4,
    });
    await Future<void>.delayed(Duration.zero);
    expect(s.stateOf('c1', 'p.q'), {'n': 1});
    expect(s.revOf('c1', 'p.q'), 5);
    expect(events.single.rev, 5);
  });

  test('plugin_error goes to errors stream', () async {
    final errs = <PluginErrorEvent>[];
    s.errors.listen(errs.add);
    sig.inject({
      't': 'plugin_error',
      'op': 'plugin_state_set',
      'circleId': 'c1',
      'pluginId': 'p.q',
      'reason': 'forbidden',
    });
    await Future<void>.delayed(Duration.zero);
    expect(errs.single.reason, 'forbidden');
    expect(errs.single.pluginId, 'p.q');
  });

  test('install builtin resolves with plugin', () async {
    final f = s.install('c1', pluginId: 'lares.focus');
    expect(sig.sent.single, {
      't': 'plugin_install',
      'circleId': 'c1',
      'ownerKey': 'ok-1',
      'pluginId': 'lares.focus',
    });
    sig.inject({'t': 'plugin_installed', 'circleId': 'c1', 'plugin': _view('lares.focus')});
    final r = await f;
    expect(r.ok, isTrue);
    expect(r.plugin!.id, 'lares.focus');
    expect(r.token, isNull);
    expect(s.plugin('c1', 'lares.focus'), isNotNull);
  });

  test('install manifest / url; token + webhookSecret once', () async {
    final f = s.install('c1', manifest: {'id': 'com.x.y'});
    expect(sig.sent.last['manifest'], {'id': 'com.x.y'});
    expect(sig.sent.last.containsKey('pluginId'), isFalse);
    sig.inject({
      't': 'plugin_installed',
      'circleId': 'c1',
      'plugin': _view('com.x.y'),
      'token': 'plg_abc',
      'webhookSecret': 'whsec_def',
    });
    final r = await f;
    expect(r.token, 'plg_abc');
    expect(r.webhookSecret, 'whsec_def');

    final f2 = s.install('c1', manifestUrl: 'https://x.y/m.json');
    expect(sig.sent.last['manifestUrl'], 'https://x.y/m.json');
    sig.inject({
      't': 'owner_error',
      'op': 'plugin_install',
      'circleId': 'c1',
      'reason': 'bad_manifest',
      'detail': 'foo',
    });
    final r2 = await f2;
    expect(r2.ok, isFalse);
    expect(r2.reason, 'bad_manifest');
    expect(r2.detail, 'foo');
  });

  test('no owner key → no_key, nothing sent; timeout', () async {
    ownerKey = null;
    final r = await s.setEnabled('c1', 'a.b', true);
    expect(r.reason, 'no_key');
    expect(sig.sent, isEmpty);
    ownerKey = 'k';
    final r2 = await s.uninstall('c1', 'a.b');
    expect(r2.reason, 'timeout');
  });

  test('owner ops send exact wire messages and resolve on owner_ok', () async {
    sig.inject({'t': 'plugins', 'circleId': 'c1', 'items': [_view('a.b'), _view('c.d')]});

    final f1 = s.setEnabled('c1', 'a.b', false);
    expect(sig.sent.last, {
      't': 'plugin_set_enabled',
      'circleId': 'c1',
      'ownerKey': 'ok-1',
      'pluginId': 'a.b',
      'enabled': false,
    });
    sig.inject({'t': 'owner_ok', 'op': 'plugin_set_enabled', 'circleId': 'c1'});
    expect((await f1).ok, isTrue);
    expect(s.isEnabled('c1', 'a.b'), isFalse);

    final f2 = s.setConfig('c1', 'a.b', {'z': 2});
    expect(sig.sent.last, {
      't': 'plugin_config_set',
      'circleId': 'c1',
      'ownerKey': 'ok-1',
      'pluginId': 'a.b',
      'config': {'z': 2},
    });
    sig.inject({'t': 'owner_error', 'op': 'plugin_config_set', 'circleId': 'c1', 'reason': 'bad_config'});
    expect((await f2).reason, 'bad_config');

    final f3 = s.uninstall('c1', 'c.d');
    expect(sig.sent.last, {
      't': 'plugin_uninstall',
      'circleId': 'c1',
      'ownerKey': 'ok-1',
      'pluginId': 'c.d',
    });
    // 别的圈的回执不算
    sig.inject({'t': 'owner_ok', 'op': 'plugin_uninstall', 'circleId': 'c9'});
    // 非插件 op 不碰
    sig.inject({'t': 'owner_ok', 'op': 'circle_transcript_set', 'circleId': 'c1'});
    sig.inject({'t': 'owner_ok', 'op': 'plugin_uninstall', 'circleId': 'c1'});
    expect((await f3).ok, isTrue);
    expect(s.pluginsFor('c1').map((p) => p.id), ['a.b']);
  });

  test('member messages: list / ensureList / getState / setState', () {
    s.list('c1');
    s.getState('c1', 'p.q');
    s.setState('c1', 'p.q', {'k': null});
    expect(sig.sent, [
      {'t': 'plugin_list', 'circleId': 'c1'},
      {'t': 'plugin_state_get', 'circleId': 'c1', 'pluginId': 'p.q'},
      {
        't': 'plugin_state_set',
        'circleId': 'c1',
        'pluginId': 'p.q',
        'patch': {'k': null}
      },
    ]);
    sig.sent.clear();
    s.ensureList('c1'); // 已要过
    s.ensureList('c2');
    s.ensureList('c2');
    expect(sig.sent, [
      {'t': 'plugin_list', 'circleId': 'c2'}
    ]);
  });
}
