import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/plugins/plugin_models.dart';
import 'package:lares_app/src/plugins/plugin_owner_section.dart';
import 'package:lares_app/src/plugins/plugin_service.dart';

import 'helpers/localized_app.dart';

class _FakeSignaling {
  final sent = <Map<String, dynamic>>[];
  final ctrl = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  void inject(Map<String, dynamic> m) => ctrl.add(m);
}

Map<String, dynamic> _view(String id, {bool enabled = true}) => {
      'id': id,
      'name': id == focusPluginId ? '专注学习' : 'Hello',
      'version': '1.0.0',
      'author': 'A',
      'permissions': ['circle:read'],
      'enabled': enabled,
      'rev': 0,
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
      timeout: const Duration(seconds: 5),
    );
  });

  Future<void> pumpScreen(WidgetTester tester, {FocusSettingsBuilder? focus}) async {
    await tester.pumpWidget(localizedApp(PluginsScreen(
      service: s,
      circleId: 'c1',
      focusSettingsBuilder: focus,
    )));
    await tester.pump();
  }

  testWidgets('owner tile hidden without owner key', (tester) async {
    ownerKey = null;
    await pumpLocalized(tester, PluginOwnerTile(service: s, circleId: 'c1'));
    expect(find.text('插件'), findsNothing);
    ownerKey = 'k';
    await pumpLocalized(tester, PluginOwnerTile(service: s, circleId: 'c2'));
    expect(find.text('插件'), findsOneWidget);
  });

  testWidgets('lists plugins after asking; toggle sends plugin_set_enabled',
      (tester) async {
    await pumpScreen(tester);
    expect(sig.sent.first, {'t': 'plugin_list', 'circleId': 'c1'});
    expect(find.text('还没装插件'), findsOneWidget);
    sig.inject({
      't': 'plugins',
      'circleId': 'c1',
      'items': [_view('com.example.hello')],
    });
    await tester.pump();
    expect(find.text('Hello'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('plugin-switch-com.example.hello')));
    await tester.pump();
    expect(sig.sent.last, {
      't': 'plugin_set_enabled',
      'circleId': 'c1',
      'ownerKey': 'ok-1',
      'pluginId': 'com.example.hello',
      'enabled': false,
    });
    sig.inject({'t': 'owner_ok', 'op': 'plugin_set_enabled', 'circleId': 'c1'});
    await tester.pumpAndSettle();
    final sw = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('plugin-switch-com.example.hello')));
    expect(sw.value, isFalse);
  });

  testWidgets('install builtin focus sends plugin_install with pluginId',
      (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.byKey(const ValueKey('plugin-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('plugin-add-focus')));
    await tester.pumpAndSettle();
    expect(sig.sent.last, {
      't': 'plugin_install',
      'circleId': 'c1',
      'ownerKey': 'ok-1',
      'pluginId': 'lares.focus',
    });
    sig.inject({'t': 'plugin_installed', 'circleId': 'c1', 'plugin': _view(focusPluginId)});
    await tester.pumpAndSettle();
    expect(find.text('「专注学习」装好了'), findsOneWidget);
    expect(find.byKey(const ValueKey('plugin-item-lares.focus')), findsOneWidget);
    expect(find.byKey(const ValueKey('plugin-settings-lares.focus')), findsOneWidget);
  });

  testWidgets('focus settings uses injected builder', (tester) async {
    sig.inject({'t': 'plugins', 'circleId': 'c1', 'items': [_view(focusPluginId)]});
    await pumpScreen(tester,
        focus: (ctx, svc, cid, p) => Scaffold(body: Text('FOCUS-$cid-${p.id}')));
    await tester.tap(find.byKey(const ValueKey('plugin-settings-lares.focus')));
    await tester.pumpAndSettle();
    expect(find.text('FOCUS-c1-lares.focus'), findsOneWidget);
  });

  testWidgets('generic config editor sends plugin_config_set', (tester) async {
    sig.inject({'t': 'plugins', 'circleId': 'c1', 'items': [_view(focusPluginId)]});
    await pumpScreen(tester);
    await tester.tap(find.byKey(const ValueKey('plugin-settings-lares.focus')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('plugin-config-input')), '{"pomodoro": 25}');
    await tester.tap(find.byKey(const ValueKey('plugin-config-save')));
    await tester.pump();
    expect(sig.sent.last['t'], 'plugin_config_set');
    expect(sig.sent.last['config'], {'pomodoro': 25});
    sig.inject({'t': 'owner_ok', 'op': 'plugin_config_set', 'circleId': 'c1'});
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plugin-config-input')), findsNothing);
  });

  testWidgets('uninstall asks first; 算了 sends nothing', (tester) async {
    sig.inject({'t': 'plugins', 'circleId': 'c1', 'items': [_view('com.example.hello')]});
    await pumpScreen(tester);
    sig.sent.clear();
    await tester.tap(find.byKey(const ValueKey('plugin-uninstall-com.example.hello')));
    await tester.pumpAndSettle();
    expect(find.text('卸载「Hello」?'), findsOneWidget);
    await tester.tap(find.text('算了'));
    await tester.pumpAndSettle();
    expect(sig.sent, isEmpty);

    await tester.tap(find.byKey(const ValueKey('plugin-uninstall-com.example.hello')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('plugin-uninstall-confirm')));
    await tester.pump();
    expect(sig.sent.single, {
      't': 'plugin_uninstall',
      'circleId': 'c1',
      'ownerKey': 'ok-1',
      'pluginId': 'com.example.hello',
    });
    sig.inject({'t': 'owner_ok', 'op': 'plugin_uninstall', 'circleId': 'c1'});
    await tester.pumpAndSettle();
    expect(find.text('Hello'), findsNothing);
  });

  testWidgets('install from pasted manifest shows one-time token', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.byKey(const ValueKey('plugin-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('plugin-add-paste')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('plugin-input')),
        '{"id": "com.example.hello", "name": "Hello"}');
    await tester.tap(find.byKey(const ValueKey('plugin-input-ok')));
    await tester.pumpAndSettle();
    expect(sig.sent.last['t'], 'plugin_install');
    expect(sig.sent.last['manifest'], {'id': 'com.example.hello', 'name': 'Hello'});
    sig.inject({
      't': 'plugin_installed',
      'circleId': 'c1',
      'plugin': _view('com.example.hello'),
      'token': 'plg_TOKEN',
      'webhookSecret': 'whsec_SECRET',
    });
    await tester.pumpAndSettle();
    expect(find.text('plg_TOKEN'), findsOneWidget);
    expect(find.text('whsec_SECRET'), findsOneWidget);
    expect(find.byKey(const ValueKey('plugin-token-copy')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('plugin-secrets-done')));
    await tester.pumpAndSettle();
    expect(find.text('plg_TOKEN'), findsNothing);
  });

  testWidgets('install from URL rejects non-https; error snack on failure',
      (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.byKey(const ValueKey('plugin-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('plugin-add-url')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('plugin-input')), 'http://x.y/m.json');
    await tester.tap(find.byKey(const ValueKey('plugin-input-ok')));
    await tester.pumpAndSettle();
    expect(find.text('网址要以 https:// 开头'), findsOneWidget);
    expect(sig.sent.where((m) => m['t'] == 'plugin_install'), isEmpty);

    await tester.tap(find.byKey(const ValueKey('plugin-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('plugin-add-url')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('plugin-input')), 'https://x.y/m.json');
    await tester.tap(find.byKey(const ValueKey('plugin-input-ok')));
    await tester.pumpAndSettle();
    expect(sig.sent.last['manifestUrl'], 'https://x.y/m.json');
    sig.inject({
      't': 'owner_error',
      'op': 'plugin_install',
      'circleId': 'c1',
      'reason': 'already_installed',
    });
    await tester.pumpAndSettle();
    expect(find.text('这个插件已经装过了'), findsOneWidget);
  });
}
