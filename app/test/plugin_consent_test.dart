import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/plugins/plugin_consent.dart';
import 'package:lares_app/src/plugins/plugin_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/localized_app.dart';

PluginView _plugin({List<String>? perms, String url = 'https://hello.example.com/app/index.html'}) =>
    PluginView(
      id: 'com.example.hello',
      name: 'Hello',
      entryUrl: url,
      permissions: perms ??
          const [PluginPermissions.circleRead, PluginPermissions.chatSend],
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<bool?> openAndChoose(WidgetTester tester, PluginView p,
      {required bool e2ee, String? tap, PluginConsentStore? store}) async {
    bool? result;
    await tester.pumpWidget(localizedApp(Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () async {
              result = await ensurePluginConsent(context,
                  circleId: 'c1', plugin: p, e2ee: e2ee, store: store);
            },
            child: const Text('open'),
          ),
        ),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    if (tap != null) {
      await tester.tap(find.text(tap));
      await tester.pumpAndSettle();
    }
    return result;
  }

  testWidgets('shows name, origin, permissions, E2EE warning', (tester) async {
    await openAndChoose(tester, _plugin(), e2ee: true);
    expect(find.text('打开插件'), findsOneWidget);
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('来自 https://hello.example.com'), findsOneWidget);
    expect(find.text('看圈子名字和设置'), findsOneWidget);
    expect(find.text('以你的名义发聊天消息'), findsOneWidget);
    expect(find.byKey(const ValueKey('plugin-consent-e2ee')), findsOneWidget);
    expect(find.text('允许'), findsOneWidget);
    expect(find.text('算了'), findsOneWidget);
    expect(find.text('取消'), findsNothing);
  });

  testWidgets('no E2EE warning on plain circle', (tester) async {
    await openAndChoose(tester, _plugin(), e2ee: false);
    expect(find.byKey(const ValueKey('plugin-consent-e2ee')), findsNothing);
  });

  testWidgets('算了 → false and not remembered', (tester) async {
    final store = PluginConsentStore();
    final r = await openAndChoose(tester, _plugin(), e2ee: false, tap: '算了', store: store);
    expect(r, isFalse);
    expect(await store.isAllowed('c1', _plugin()), isFalse);
  });

  testWidgets('允许 → true, remembered; re-ask on permission change', (tester) async {
    final store = PluginConsentStore();
    final r = await openAndChoose(tester, _plugin(), e2ee: false, tap: '允许', store: store);
    expect(r, isTrue);
    expect(await store.isAllowed('c1', _plugin()), isTrue);
    // 另一个圈不算
    expect(await store.isAllowed('c2', _plugin()), isFalse);

    // 同一权限集(顺序不同)直接放行,不弹
    final same = _plugin(perms: const [PluginPermissions.chatSend, PluginPermissions.circleRead]);
    final r2 = await openAndChoose(tester, same, e2ee: false, store: store);
    expect(r2, isTrue);
    expect(find.text('打开插件'), findsNothing);

    // 权限变了 → 重新问
    final more = _plugin(perms: const [
      PluginPermissions.circleRead,
      PluginPermissions.chatSend,
      PluginPermissions.chatRead,
    ]);
    await openAndChoose(tester, more, e2ee: false, store: store);
    expect(find.text('打开插件'), findsOneWidget);
    expect(find.text('读聊天消息'), findsOneWidget);
  });

  test('origin change also re-asks; hash is order-insensitive', () async {
    final store = PluginConsentStore();
    await store.allow('c1', _plugin());
    expect(await store.isAllowed('c1', _plugin(url: 'https://evil.example.com/')), isFalse);
    expect(pluginConsentHash(['a', 'b']), pluginConsentHash(['b', 'a', 'a']));
    expect(pluginOrigin('https://x.y:8443/a?b'), 'https://x.y:8443');
  });
}
