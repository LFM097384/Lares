// AI 语音助手(lares.ai-voice)的客户端:圈主表单、「更多」里的说明格、
// 座位徽标、人数不算 AI、用途「开会 + AI」、隐私告知一行。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/captions/caption_controller.dart';
import 'package:lares_app/src/net/secret_vault.dart';
import 'package:lares_app/src/plugins/ai_voice_settings.dart';
import 'package:lares_app/src/plugins/plugin_models.dart';
import 'package:lares_app/src/plugins/plugin_owner_section.dart';
import 'package:lares_app/src/plugins/plugin_service.dart';
import 'package:lares_app/src/privacy/privacy_sheet.dart';
import 'package:lares_app/src/privacy/privacy_summary.dart';
import 'package:lares_app/src/purpose/features_screen.dart';
import 'package:lares_app/src/purpose/purpose_picker.dart';
import 'package:lares_app/src/state/ai_member.dart';
import 'package:lares_app/src/state/circle_features.dart';
import 'package:lares_app/src/state/room_controller.dart';
import 'package:lares_app/src/state/settings_store.dart';
import 'package:lares_app/src/theme/theme.dart';
import 'package:lares_app/src/ui/room_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/caption_fakes.dart';
import 'helpers/localized_app.dart';
import 'room_screen_test.dart' as rs show FakeRtcService, FakeSignalingClient;
import 'support/fake_room.dart';

class _FakeSignaling {
  final sent = <Map<String, dynamic>>[];
  final ctrl = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  void inject(Map<String, dynamic> m) => ctrl.add(m);
}

Map<String, dynamic> _aiView({
  bool enabled = true,
  Map<String, dynamic> config = const {},
}) =>
    {
      'id': aiVoicePluginId,
      'name': 'AI 助手',
      'version': '1.0.0',
      'author': 'Lares',
      'permissions': ['audio:read'],
      'enabled': enabled,
      'builtin': true,
      'rev': 0,
      'config': config,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  debugUseInMemoryVault = true;
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  void tall(WidgetTester tester) {
    tester.view
      ..physicalSize = const Size(1000, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  test('isAiMemberId / humanMemberCount', () {
    expect(isAiMemberId('u_ai_x'), isTrue);
    expect(isAiMemberId('u_x'), isFalse);
    expect(kAiVoicePluginId, aiVoicePluginId);
  });

  group('圈主表单', () {
    late _FakeSignaling sig;
    late PluginService s;

    setUp(() {
      sig = _FakeSignaling();
      s = PluginService(
        send: sig.sent.add,
        messages: sig.ctrl.stream,
        ownerKeyFor: (_) => 'ok-1',
        timeout: const Duration(seconds: 5),
      );
    });

    Future<void> openSettings(WidgetTester tester, {bool e2ee = false}) async {
      tall(tester);
      await tester.pumpWidget(localizedApp(
          PluginsScreen(service: s, circleId: 'c1', e2ee: e2ee)));
      await tester.pump();
      sig.inject({
        't': 'plugins',
        'circleId': 'c1',
        'items': [
          _aiView(config: {'name': '阿福', 'voice': 'Weird', 'trigger': 'ptt'}),
        ],
      });
      await tester.pump();
    }

    testWidgets('渲染:隐私说明、字段、未知音色保留;范围校验;存下发 plugin_config_set',
        (tester) async {
      await openSettings(tester);
      await tester.tap(find.byKey(ValueKey('plugin-settings-$aiVoicePluginId')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('ai-voice-privacy')), findsOneWidget);
      expect(find.textContaining('DashScope'), findsWidgets);
      expect(find.byKey(const ValueKey('ai-voice-e2ee')), findsNothing);
      expect(find.text('阿福'), findsOneWidget);
      expect(find.text('Weird'), findsOneWidget); // 不认识的音色照样列着
      expect(find.text('不听语音,只回答聊天里 @阿福 开头的文字'), findsOneWidget);

      // 人设恢复默认
      await tester.enterText(
          find.byKey(const ValueKey('ai-voice-persona')), '你是海盗');
      await tester.tap(find.byKey(const ValueKey('ai-voice-persona-reset')));
      await tester.pump();
      expect(find.text(kAiVoiceDefaultPersona), findsOneWidget);

      // 触发方式
      await tester.tap(find.byKey(const ValueKey('ai-voice-trigger-wake')));
      await tester.pump();
      expect(find.text('有人叫它的名字或别的叫法,它才回答'), findsOneWidget);

      // 高级:越界 → 不发
      await tester.tap(find.byKey(const ValueKey('ai-voice-advanced')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('ai-voice-maxReplyChars')), '5');
      final before = sig.sent.length;
      await tester.ensureVisible(find.byKey(const ValueKey('ai-voice-save')));
      await tester.tap(find.byKey(const ValueKey('ai-voice-save')));
      await tester.pump();
      expect(find.text('要在 20 到 400 之间'), findsOneWidget);
      expect(sig.sent.length, before);

      await tester.enterText(
          find.byKey(const ValueKey('ai-voice-maxReplyChars')), '200');
      await tester.enterText(
          find.byKey(const ValueKey('ai-voice-maxTurnsPerDay')), '3000');
      await tester.tap(find.byKey(const ValueKey('ai-voice-save')));
      await tester.pump();
      expect(find.text('要在 1 到 2000 之间'), findsOneWidget);
      expect(sig.sent.length, before);

      await tester.enterText(
          find.byKey(const ValueKey('ai-voice-maxTurnsPerDay')), '50');
      await tester.tap(find.byKey(const ValueKey('ai-voice-save')));
      await tester.pump();
      final msg = sig.sent.last;
      expect(msg['t'], 'plugin_config_set');
      expect(msg['circleId'], 'c1');
      expect(msg['ownerKey'], 'ok-1');
      expect(msg['pluginId'], aiVoicePluginId);
      expect(msg['config'], {
        'name': '阿福',
        'wakeWords': '小助手',
        'persona': kAiVoiceDefaultPersona,
        'trigger': 'wake',
        'voice': 'Weird',
        'model': 'qwen-flash',
        'maxReplyChars': 200,
        'maxTurnsPerHour': 30,
        'maxTurnsPerDay': 50,
        'interrupt': true,
      });
      sig.inject({'t': 'owner_ok', 'op': 'plugin_config_set', 'circleId': 'c1'});
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-voice-settings')), findsNothing);
      expect(s.plugin('c1', aiVoicePluginId)!.config['maxTurnsPerDay'], 50);
    });

    testWidgets('添加:内置 AI 助手一项,点了发 plugin_install', (tester) async {
      tall(tester);
      await tester.pumpWidget(
          localizedApp(PluginsScreen(service: s, circleId: 'c1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('plugin-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('plugin-add-ai')));
      await tester.pump();
      expect(sig.sent.last['t'], 'plugin_install');
      expect(sig.sent.last['pluginId'], aiVoicePluginId);
      sig.inject({'t': 'owner_ok', 'op': 'plugin_install', 'circleId': 'c1'});
      await tester.pumpAndSettle();
    });

    testWidgets('E2EE 圈:不能装、不能开,并说明原因', (tester) async {
      await openSettings(tester, e2ee: true);
      // 已装但停用 → 开关不可拨
      sig.inject({
        't': 'plugins',
        'circleId': 'c1',
        'items': [_aiView(enabled: false)],
      });
      await tester.pump();
      final sw = tester.widget<SwitchListTile>(
          find.byKey(ValueKey('plugin-switch-$aiVoicePluginId')));
      expect(sw.onChanged, isNull);
      expect(find.byKey(const ValueKey('plugin-ai-e2ee-note')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('plugin-add')));
      await tester.pumpAndSettle();
      final add = tester
          .widget<ListTile>(find.byKey(const ValueKey('plugin-add-ai')));
      expect(add.enabled, isFalse);
    });

    testWidgets('表单在 E2EE 圈里显示原因', (tester) async {
      tall(tester);
      await tester.pumpWidget(localizedApp(Scaffold(
        body: SingleChildScrollView(
          child: AiVoiceSettingsForm(
            config: const {},
            e2ee: true,
            onSave: (_) async => const PluginOpResult(),
          ),
        ),
      )));
      await tester.pump();
      expect(find.byKey(const ValueKey('ai-voice-e2ee')), findsOneWidget);
      expect(find.text('小助手'), findsWidgets); // 缺省补默认
    });
  });

  group('房间', () {
    Future<(RoomController, PluginService, StreamController<Map<String, dynamic>>, CaptionController)>
        pumpRoom(WidgetTester tester, {required bool aiEnabled}) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final signaling = rs.FakeSignalingClient();
      final controller = RoomController(
        signaling: signaling,
        rtc: rs.FakeRtcService(),
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '我',
      );
      unawaited(controller.join('c1').catchError((Object _) {}));
      signaling.testInject({
        't': 'room',
        'circleId': 'c1',
        'members': [
          {'userId': 'u_me', 'name': '我', 'status': 'free'},
          {'userId': 'u1', 'name': '小鹿', 'status': 'free'},
          {'userId': 'u_ai_c1', 'name': '小助手', 'status': 'free'},
        ],
      });
      await controller.testInjectToken('wss://fake', 'tok');
      final captions = CaptionController(
        transcriberFactory: ({
          required onPartial,
          required onFinal,
          required onFatal,
        }) =>
            FakeTranscriber(onPartial, onFinal, onFatal),
      );
      final msgs = StreamController<Map<String, dynamic>>.broadcast(sync: true);
      final plugins = PluginService(
        send: (_) {},
        messages: msgs.stream,
        ownerKeyFor: (_) => null,
      );
      msgs.add({
        't': 'plugins',
        'circleId': 'c1',
        'items': [
          _aiView(enabled: aiEnabled, config: {'name': '小助手', 'trigger': 'wake'}),
        ],
      });
      // 所有可选功能关掉:「更多」里只可能剩 AI 格(它不受「插件」开关影响)
      signaling.testInject({
        't': 'circle_settings',
        'circle': {
          'id': 'c1',
          'registered': true,
          'transcript': false,
          'features': {
            'captions': false,
            'transcript': false,
            'voiceNotes': false,
            'map': false,
            'recording': false,
            'plugins': false,
            'focus': false,
            'p2p': false,
            'devTools': false,
          },
        },
      });
      await tester.pumpWidget(localizedApp(
        RoomScreen(
          controller: controller,
          circleName: '我们的圈',
          captions: captions,
          plugins: plugins,
        ),
        theme: LaresTheme.dark(),
      ));
      await tester.pump();
      return (controller, plugins, msgs, captions);
    }

    Future<void> close(
        WidgetTester tester,
        (RoomController, PluginService, StreamController<Map<String, dynamic>>, CaptionController) r) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      r.$2.dispose();
      await r.$3.close();
      r.$4.dispose();
      r.$1.dispose();
      await tester.pump(const Duration(minutes: 6));
    }

    testWidgets('AI 座位有徽标、没有人的状态;人数不算它;「更多」出 AI 格', (tester) async {
      final r = await pumpRoom(tester, aiEnabled: true);
      expect(find.byKey(const ValueKey('seat-ai-badge')), findsOneWidget);
      expect(find.text('AI 助手'), findsWidgets);
      expect(find.text('2 个人在'), findsOneWidget);
      expect(find.text('3 个人在'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('room-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('more-ai')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('room-ai')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('ai-info-sheet')), findsOneWidget);
      expect(find.text('叫「小助手」再说问题'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-info-privacy')), findsOneWidget);
      await close(tester, r);
    });

    testWidgets('AI 停用:「更多」里没有 AI 格(全关时整个「更多」都不出现)',
        (tester) async {
      final r = await pumpRoom(tester, aiEnabled: false);
      expect(find.byKey(const ValueKey('room-more')), findsNothing);
      expect(find.byKey(const ValueKey('more-ai')), findsNothing);
      await close(tester, r);
    });
  });

  testWidgets('说明面板按触发方式说怎么叫', (tester) async {
    for (final (cfg, want) in [
      ({'name': '阿福', 'trigger': 'always'}, '说完它就会回答'),
      ({'name': '阿福', 'trigger': 'ptt'}, '在聊天里 @阿福'),
      (<String, dynamic>{}, '叫「小助手」再说问题'),
    ]) {
      await tester.pumpWidget(localizedApp(
          Scaffold(body: AiVoiceInfoSheet(config: cfg))));
      expect(find.text(want), findsOneWidget);
    }
  });

  group('用途:开会 + AI', () {
    Future<(RoomController, FakeSignalingClient)> makeController(
        {bool? e2ee}) async {
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
      c.circleInfo['c_r'] = (registered: true, e2ee: e2ee, transcript: false);
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

    testWidgets('选开会 + 打开 AI 开关 → 发完整对象,带 lares.ai-voice', (tester) async {
      tall(tester);
      final (c, sig) = await tester.runAsync(makeController) ??
          (throw StateError('setup'));
      addTearDown(c.dispose);
      await tester.pumpWidget(
          localizedApp(FeaturesScreen(controller: c, circleId: 'c_r')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('features-purpose-tile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('purpose-option-meeting')));
      await tester.pumpAndSettle();
      final sw = tester.widget<SwitchListTile>(
          find.byKey(const ValueKey('purpose-meeting-ai-switch')));
      expect(sw.value, isFalse); // 默认关
      await tester.tap(find.byKey(const ValueKey('purpose-meeting-ai-switch')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('purpose-meeting-confirm')));
      await tester.pumpAndSettle();
      // 开会带 e2eeWarning:可能先问一句;有就确认
      final confirm = find.byKey(const ValueKey('purpose-e2ee-confirm'));
      if (confirm.evaluate().isNotEmpty) {
        await tester.tap(confirm);
        await tester.pumpAndSettle();
      }
      final msg = sig.sent.lastWhere((m) => m['t'] == 'circle_purpose_apply');
      final p = msg['purpose'] as Map;
      expect(p['id'], 'meeting');
      expect(p['name'], '开会');
      expect((p['features'] as Map)['transcript'], isTrue);
      expect(p['plugins'], [
        {'id': 'lares.ai-voice', 'enabled': true},
      ]);
      sig.testInject(
          {'t': 'owner_ok', 'op': 'circle_purpose_apply', 'circleId': 'c_r'});
      await tester.pumpAndSettle();
      expect(find.text('已换成「开会」'), findsOneWidget);
    });

    testWidgets('开关不拨 → 照旧发字符串 meeting', (tester) async {
      tall(tester);
      String? got;
      await tester.pumpWidget(localizedApp(Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => got = await showPurposePicker(context),
            child: const Text('pick'),
          ),
        ),
      )));
      await tester.tap(find.text('pick'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('purpose-option-meeting')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('purpose-meeting-confirm')));
      await tester.pumpAndSettle();
      expect(got, 'meeting');
    });

    testWidgets('E2EE 圈:AI 开关不可拨', (tester) async {
      tall(tester);
      await tester.pumpWidget(localizedApp(Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showPurposePicker(context, aiUnavailable: true),
            child: const Text('pick'),
          ),
        ),
      )));
      await tester.tap(find.text('pick'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('purpose-option-meeting')));
      await tester.pumpAndSettle();
      final sw = tester.widget<SwitchListTile>(
          find.byKey(const ValueKey('purpose-meeting-ai-switch')));
      expect(sw.onChanged, isNull);
      expect(find.text('这个圈开着端到端加密,用不了 AI 助手'), findsOneWidget);
    });
  });

  group('隐私', () {
    test('AI 开改变哈希;没开时与旧版结构一致', () {
      const off = CirclePrivacySummary(circleId: 'c');
      const on = CirclePrivacySummary(circleId: 'c', ai: true);
      expect(on.privacyHash(), isNot(off.privacyHash()));
      expect(off.canonical().containsKey('ai'), isFalse);
      expect(on.canonical()['ai'], isTrue);
      expect(on.hasNotable, isTrue);
    });

    testWidgets('从圈信息拼摘要:AI 单独一行,不进通用插件列表', (tester) async {
      final sig = FakeSignalingClient();
      final c = RoomController(
        signaling: sig,
        rtc: FakeRtcService(),
        userId: 'u_me',
        deviceId: 'd_1',
        userName: '我',
      );
      addTearDown(c.dispose);
      sig.testInject({
        't': 'circle_settings',
        'circle': {
          'id': 'c1',
          'registered': true,
          'e2ee': false,
          'transcript': false,
          'features': {
            'captions': false,
            'transcript': false,
            'voiceNotes': true,
            'map': false,
            'recording': false,
            'plugins': true,
            'focus': false,
            'p2p': false,
            'devTools': false,
          },
          'plugins': [
            {
              'id': 'lares.ai-voice',
              'enabled': true,
              'permissions': ['audio:read'],
            },
          ],
        },
      });
      await tester.pump();
      final s = buildCirclePrivacySummary(c, 'c1');
      expect(s.ai, isTrue);
      expect(s.plugins, isEmpty);

      await tester.pumpWidget(localizedApp(Scaffold(
          body: SingleChildScrollView(
              child: CirclePrivacySheet(summary: s, circleName: '圈')))));
      expect(find.byKey(const ValueKey('privacy-ai')), findsOneWidget);
      expect(find.byKey(const ValueKey('privacy-plugins')), findsNothing);
      expect(find.byKey(const ValueKey('privacy-nothing')), findsNothing);
      expect(find.textContaining('AI 助手开'), findsOneWidget);
    });
  });
}
