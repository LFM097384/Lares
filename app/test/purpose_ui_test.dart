import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/net/secret_vault.dart';
import 'package:lares_app/src/purpose/features_screen.dart';
import 'package:lares_app/src/purpose/purpose_code.dart';
import 'package:lares_app/src/purpose/purpose_editor.dart';
import 'package:lares_app/src/purpose/purpose_flow.dart';
import 'package:lares_app/src/purpose/purpose_picker.dart';
import 'package:lares_app/src/state/circle_features.dart';
import 'package:lares_app/src/state/room_controller.dart';
import 'package:lares_app/src/state/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/localized_app.dart';
import 'support/fake_room.dart';

/// 用途 UI:编辑器、选择面板、功能页。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  debugUseInMemoryVault = true;
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  String? clipboard;
  setUp(() {
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String?;
      } else if (call.method == 'Clipboard.getData') {
        return <String, Object?>{'text': clipboard};
      }
      return null;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));

  void tall(WidgetTester tester) {
    tester.view
      ..physicalSize = const Size(1000, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  FilledButton applyButton(WidgetTester tester) => tester.widget<FilledButton>(
      find.byKey(const ValueKey('purpose-editor-apply')));

  group('编辑器', () {
    testWidgets('语法错 → 列出错误并锁住「应用」;改对 → 解锁', (tester) async {
      tall(tester);
      await tester.pumpWidget(localizedApp(const PurposeEditorPage(
          initial: {'id': 'a', 'name': 'b'})));
      await tester.pump();
      expect(applyButton(tester).onPressed, isNotNull);

      await tester.enterText(
          find.byKey(const ValueKey('purpose-editor-field')), '{"id": "a",');
      await tester.pump();
      expect(applyButton(tester).onPressed, isNull); // 改动中先锁
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('purpose-editor-issues')), findsOneWidget);
      expect(find.textContaining('JSON 写错了'), findsOneWidget);
      expect(applyButton(tester).onPressed, isNull);

      await tester.enterText(find.byKey(const ValueKey('purpose-editor-field')),
          '{"id": "a", "name": "b", "features": {"x": true}}');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('features.x · 第 1 行'), findsOneWidget);
      expect(applyButton(tester).onPressed, isNull);

      await tester.enterText(find.byKey(const ValueKey('purpose-editor-field')),
          '{"id": "a", "name": "b", "features": {"map": true}}');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('purpose-editor-issues')), findsNothing);
      expect(applyButton(tester).onPressed, isNotNull);
    });

    testWidgets('「应用」pop 出校验通过的 Map', (tester) async {
      tall(tester);
      Map<String, dynamic>? got;
      await tester.pumpWidget(localizedApp(Builder(
        builder: (context) => TextButton(
          onPressed: () async => got = await openPurposeEditor(context,
              initial: {'id': 'a', 'name': 'b'}),
          child: const Text('open'),
        ),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('purpose-editor-apply')));
      await tester.pumpAndSettle();
      expect(got, {'id': 'a', 'name': 'b'});
    });

    testWidgets('从分享码导入:填进编辑器', (tester) async {
      tall(tester);
      final code = encodePurposeCode({
        'id': 'imp',
        'name': '导进来的',
        'features': {'focus': true},
      });
      await tester.pumpWidget(localizedApp(const PurposeEditorPage()));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('purpose-editor-import')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('purpose-import-field')), 'lares-purpose:!!');
      await tester.pump();
      expect(find.textContaining('分享码不完整'), findsOneWidget);
      await tester.enterText(
          find.byKey(const ValueKey('purpose-import-field')), code);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('purpose-import-confirm')));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
          find.byKey(const ValueKey('purpose-editor-field')));
      expect(field.controller!.text, contains('"imp"'));
      expect(field.controller!.text, contains('导进来的'));
      expect(applyButton(tester).onPressed, isNotNull);
    });

    testWidgets('复制分享码:剪贴板里的码解出来和编辑器内容一致', (tester) async {
      tall(tester);
      const p = {
        'id': 'cp',
        'name': '复制 ✨',
        'features': {'map': false},
      };
      await tester.pumpWidget(localizedApp(const PurposeEditorPage(initial: p)));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('purpose-editor-copy')));
      await tester.pumpAndSettle();
      expect(clipboard, isNotNull);
      expect(decodePurposeCode(clipboard!), p);
      // 对话框里也把码亮出来
      expect(find.byKey(const ValueKey('purpose-code-text')), findsOneWidget);
    });
  });

  group('选择面板', () {
    testWidgets('四个选项,点「学习」返回 study;当前项高亮', (tester) async {
      tall(tester);
      String? got = 'unset';
      await tester.pumpWidget(localizedApp(Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                got = await showPurposePicker(context, current: 'chat'),
            child: const Text('pick'),
          ),
        ),
      )));
      await tester.tap(find.text('pick'));
      await tester.pumpAndSettle();
      for (final id in ['chat', 'study', 'meeting', kPurposeCustomId]) {
        expect(find.byKey(ValueKey('purpose-option-$id')), findsOneWidget);
      }
      expect(find.text('闲聊'), findsOneWidget);
      expect(find.text('自定义'), findsOneWidget);
      expect(
          tester
              .widget<ListTile>(find.byKey(const ValueKey('purpose-option-chat')))
              .selected,
          isTrue);
      await tester.tap(find.text('学习'));
      await tester.pumpAndSettle();
      expect(got, 'study');
    });
  });

  group('功能页', () {
    Future<(RoomController, FakeSignalingClient)> makeController() async {
      final settings = await SettingsStore.load(vault: InMemorySecretVault());
      final sig = FakeSignalingClient();
      final c = RoomController(
        signaling: sig,
        rtc: FakeRtcService(),
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '我',
        settings: settings,
      );
      await settings.saveOwnerKey('c_r', 'kk');
      c.circleInfo['c_r'] = (registered: true, e2ee: null, transcript: false);
      c.circleFeatures['c_r'] = CircleFeatures.fromJson({
        'captions': false,
        'transcript': false,
        'voiceNotes': true,
        'map': false,
        'recording': false,
        'plugins': false,
        'focus': false,
        'p2p': true,
        'devTools': false,
      });
      c.circlePurpose['c_r'] = const CirclePurposeInfo(
          id: 'chat', name: '闲聊', builtin: true, e2eeWarning: false);
      return (c, sig);
    }

    testWidgets('9 个开关;拨一下发 circle_features_set,等回执期间禁用,失败回退',
        (tester) async {
      tall(tester);
      final (c, sig) = await tester.runAsync(makeController) ??
          (throw StateError('setup'));
      addTearDown(c.dispose);
      await tester.pumpWidget(localizedApp(FeaturesScreen(
          controller: c, circleId: 'c_r', recordingAvailable: false)));
      await tester.pump();
      expect(find.byType(SwitchListTile), findsNWidgets(9));
      expect(find.text('💬 闲聊'), findsOneWidget);
      expect(find.textContaining('这个版本还没有录音'), findsOneWidget);

      SwitchListTile sw(String k) => tester
          .widget<SwitchListTile>(find.byKey(ValueKey('feature-switch-$k')));
      expect(sw('map').value, isFalse);

      await tester.tap(find.byKey(const ValueKey('feature-switch-map')));
      await tester.pump();
      final msg = sig.sent.last;
      expect(msg['t'], 'circle_features_set');
      expect(msg['circleId'], 'c_r');
      expect(msg['ownerKey'], 'kk');
      expect(msg['features'], {'map': true});
      expect(sw('map').value, isTrue); // 乐观
      expect(sw('map').onChanged, isNull); // 等回执

      sig.testInject({
        't': 'owner_error',
        'op': 'circle_features_set',
        'circleId': 'c_r',
        'reason': 'not_owner',
      });
      await tester.pump();
      await tester.pump();
      expect(sw('map').value, isFalse); // 回退
      expect(sw('map').onChanged, isNotNull);
      expect(find.textContaining('「位置地图」没改成'), findsOneWidget);

      // 成功:服务器 circle_settings 带回真值之后才算数;这里只验回执解锁
      await tester.tap(find.byKey(const ValueKey('feature-switch-p2p')));
      await tester.pump();
      expect(sig.sent.last['features'], {'p2p': false});
      sig.testInject(
          {'t': 'owner_ok', 'op': 'circle_features_set', 'circleId': 'c_r'});
      await tester.pump();
      await tester.pump();
      expect(sw('p2p').onChanged, isNotNull);
    });

    testWidgets('导入分享码:预览改什么,「应用」发 circle_purpose_apply', (tester) async {
      tall(tester);
      final (c, sig) = await tester.runAsync(makeController) ??
          (throw StateError('setup'));
      addTearDown(c.dispose);
      await tester.pumpWidget(
          localizedApp(FeaturesScreen(controller: c, circleId: 'c_r')));
      await tester.pump();
      final p = {
        'id': 'study-x',
        'name': '自习室',
        'icon': '📖',
        'features': {'focus': true, 'voiceNotes': false},
      };
      await tester.tap(find.byKey(const ValueKey('features-import')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('purpose-import-field')),
          encodePurposeCode(p));
      await tester.pump();
      expect(find.text('📖 自习室'), findsOneWidget);
      expect(find.text('打开:专注学习'), findsOneWidget);
      expect(find.text('关闭:语音便签'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('purpose-import-confirm')));
      await tester.pump();
      expect(sig.sent.last['t'], 'circle_purpose_apply');
      expect(sig.sent.last['purpose'], p);
      sig.testInject(
          {'t': 'owner_ok', 'op': 'circle_purpose_apply', 'circleId': 'c_r'});
      await tester.pumpAndSettle();
      expect(find.text('已换成「自习室」'), findsOneWidget);
    });

    testWidgets('用途应用失败:bad_purpose 带上服务器给的路径', (tester) async {
      tall(tester);
      final (c, sig) = await tester.runAsync(makeController) ??
          (throw StateError('setup'));
      addTearDown(c.dispose);
      await tester.pumpWidget(localizedApp(Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                applyPurposeWithFeedback(context, c, 'c_r', 'meeting'),
            child: const Text('go'),
          ),
        ),
      )));
      await tester.tap(find.text('go'));
      await tester.pump();
      expect(sig.sent.last['purpose'], 'meeting');
      sig.testInject({
        't': 'owner_error',
        'op': 'circle_purpose_apply',
        'circleId': 'c_r',
        'reason': 'bad_purpose',
        'detail': 'plugins[0].manifestUrl:invalid',
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('plugins[0].manifestUrl:invalid'),
          findsOneWidget);
    });

    testWidgets('一次性凭据:页面开着时弹 PluginSecretsDialog,关页还原回调',
        (tester) async {
      tall(tester);
      final (c, _) = await tester.runAsync(makeController) ??
          (throw StateError('setup'));
      addTearDown(c.dispose);
      var outer = 0;
      c.onPurposeSecrets = (_, _) => outer++;
      await tester.pumpWidget(
          localizedApp(FeaturesScreen(controller: c, circleId: 'c_r')));
      await tester.pump();
      c.onPurposeSecrets!('c_r', [
        {'pluginId': 'com.x.bot', 'token': 'tok-123', 'webhookSecret': 'sec-9'},
      ]);
      await tester.pumpAndSettle();
      expect(find.text('tok-123'), findsOneWidget);
      expect(outer, 0);
      await tester.pumpWidget(localizedApp(const SizedBox()));
      c.onPurposeSecrets!('c_r', const []);
      expect(outer, 1);
    });
  });

  group('建圈时挑的用途', () {
    test('登记好、拿到圈主身份后应用一次', () async {
      final settings = await SettingsStore.load(vault: InMemorySecretVault());
      final sig = FakeSignalingClient();
      final c = RoomController(
        signaling: sig,
        rtc: FakeRtcService(),
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '我',
        settings: settings,
      );
      addTearDown(c.dispose);
      await settings.saveOwnerKey('c_new', 'kk');
      String? result = 'unset';
      PendingPurposes.instance.schedule(c, 'c_new', 'study',
          onResult: (e, _) => result = e);
      expect(PendingPurposes.instance.pendingFor('c_new'), 'study');
      expect(sig.sent.where((m) => m['t'] == 'circle_purpose_apply'), isEmpty);

      c.circleInfo['c_new'] = (registered: true, e2ee: null, transcript: false);
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      c.notifyListeners();
      expect(PendingPurposes.instance.pendingFor('c_new'), isNull);
      final sent = sig.sent.where((m) => m['t'] == 'circle_purpose_apply');
      expect(sent.single['purpose'], 'study');
      sig.testInject(
          {'t': 'owner_ok', 'op': 'circle_purpose_apply', 'circleId': 'c_new'});
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(result, isNull);
      // 再通知也不会重发
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      c.notifyListeners();
      expect(sig.sent.where((m) => m['t'] == 'circle_purpose_apply'),
          hasLength(1));
    });
  });
}
