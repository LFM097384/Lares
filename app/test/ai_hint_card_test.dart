// 点 AI 座位的说明卡:按配置(名字 / 别的叫法 / 触发方式)说怎么叫它、隐私一行;
// ptt 只说「@AI」、隐私改成只发文字;处置菜单里仍有关掉说明与屏蔽 / 举报。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/moderation/block_store.dart';
import 'package:lares_app/src/state/settings_store.dart';
import 'package:lares_app/src/plugins/ai_voice_settings.dart';
import 'package:lares_app/src/plugins/plugin_models.dart';
import 'package:lares_app/src/plugins/plugin_service.dart';
import 'package:lares_app/src/state/ai_state.dart';
import 'package:lares_app/src/state/room_controller.dart';
import 'package:lares_app/src/theme/theme.dart';
import 'package:lares_app/src/ui/ai_hint_card.dart';
import 'package:lares_app/src/ui/room_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/localized_app.dart';
import 'room_screen_test.dart' as rs show FakeRtcService, FakeSignalingClient;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  debugUseInMemoryVault = true;
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('aiVoiceExtraWakeWords:与服务端同样的分隔符,去重去空去名字', () {
    expect(
      aiVoiceExtraWakeWords(
          {'name': '阿福', 'wakeWords': '阿福,小福，福仔、 ;老福；\n小福'}),
      ['小福', '福仔', '老福'],
    );
    expect(aiVoiceExtraWakeWords({'name': '阿福', 'wakeWords': ''}), isEmpty);
    // 缺省:默认名字「小助手」,默认别的叫法
    expect(aiVoiceExtraWakeWords(const {}), isNot(contains('小助手')));
  });

  Future<void> card(WidgetTester tester, Map<String, dynamic> cfg,
      {ThemeData? theme}) async {
    tester.view
      ..physicalSize = const Size(360, 640)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(localizedApp(
        Scaffold(body: SingleChildScrollView(child: AiHintCard(config: cfg))),
        theme: theme));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  String textOf(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(ValueKey(key))).data!;

  testWidgets('叫名字模式:叫它「名字」、别的叫法、聊天 @AI、隐私说语音', (tester) async {
    await card(tester, {'name': '阿福', 'wakeWords': '小福、福仔', 'trigger': 'wake'});
    expect(find.byKey(const ValueKey('ai-hint-card')), findsOneWidget);
    expect(find.text('叫它「阿福」就能提问'), findsOneWidget);
    expect(textOf(tester, 'ai-hint-also'), '也可以叫它:小福、福仔');
    expect(find.byKey(const ValueKey('ai-hint-chat')), findsOneWidget);
    expect(textOf(tester, 'ai-hint-mode'), contains('叫名字'));
    expect(textOf(tester, 'ai-hint-privacy'), contains('它会把语音发到阿里云处理'));
  });

  testWidgets('一直听模式', (tester) async {
    await card(tester, {'name': '阿福', 'wakeWords': '', 'trigger': 'always'});
    expect(textOf(tester, 'ai-hint-ask'), '直接说就行,它一直在听');
    expect(find.byKey(const ValueKey('ai-hint-also')), findsNothing);
    expect(textOf(tester, 'ai-hint-mode'), contains('一直听'));
    expect(textOf(tester, 'ai-hint-privacy'), contains('它会把语音发到阿里云处理'));
  });

  testWidgets('ptt:在聊天里 @AI 提问;隐私只说文字', (tester) async {
    await card(tester, {'name': '阿福', 'wakeWords': '小福', 'trigger': 'ptt'},
        theme: LaresTheme.light());
    expect(textOf(tester, 'ai-hint-ask'), '在聊天里 @AI 提问');
    expect(textOf(tester, 'ai-hint-also'), '@阿福、@小福 也行');
    expect(find.byKey(const ValueKey('ai-hint-chat')), findsNothing);
    expect(textOf(tester, 'ai-hint-mode'), contains('只回 @它'));
    final privacy = textOf(tester, 'ai-hint-privacy');
    expect(privacy, contains('不听语音'));
    expect(privacy, isNot(contains('把语音发到')));
  });

  testWidgets('配置还没到:按默认「小助手」/ 叫名字说', (tester) async {
    await card(tester, const {});
    expect(find.text('叫它「小助手」就能提问'), findsOneWidget);
  });

  group('房间里点 AI 座位', () {
    Future<(RoomController, PluginService, StreamController<Map<String, dynamic>>)>
        pumpRoom(WidgetTester tester,
            {required Map<String, dynamic> config, BlockStore? blocks}) async {
      tester.view
        ..physicalSize = const Size(360, 780)
        ..devicePixelRatio = 1;
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
          {'userId': 'u_ai_c1', 'name': '阿福', 'status': 'free'},
        ],
      });
      await controller.testInjectToken('wss://fake', 'tok');
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
          {
            'id': aiVoicePluginId,
            'name': 'AI 助手',
            'version': '1.0.0',
            'author': 'Lares',
            'permissions': ['audio:read'],
            'enabled': true,
            'builtin': true,
            'rev': 0,
            'config': config,
          },
        ],
      });
      await tester.pumpWidget(localizedApp(
        MediaQuery(
          data: const MediaQueryData(
              size: Size(360, 780), disableAnimations: true),
          child: RoomScreen(
            controller: controller,
            circleName: '我们的圈',
            plugins: plugins,
            blocks: blocks,
          ),
        ),
        theme: LaresTheme.dark(),
      ));
      await tester.pump();
      return (controller, plugins, msgs);
    }

    Future<void> close(WidgetTester tester,
        (RoomController, PluginService, StreamController<Map<String, dynamic>>) r) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      r.$2.dispose();
      await r.$3.close();
      r.$1.dispose();
      await tester.pump(const Duration(minutes: 6));
    }

    testWidgets('ptt 没帧:座位静止;点开是说明卡(没接屏蔽名单也能点)', (tester) async {
      final r = await pumpRoom(tester,
          config: {'name': '阿福', 'trigger': 'ptt'});
      expect(find.byKey(const ValueKey('ai-orb-idle')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ai-orb-idle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('ai-hint-card')), findsOneWidget);
      expect(find.text('在聊天里 @AI 提问'), findsOneWidget);
      expect(find.byKey(const ValueKey('moderation-ai-hint')), findsOneWidget);
      await close(tester, r);
    });

    testWidgets('叫名字 + 屏蔽名单:说明卡在上,处置行照旧', (tester) async {
      final blocks = await BlockStore.load();
      final r = await pumpRoom(tester,
          config: {'name': '阿福', 'wakeWords': '小福', 'trigger': 'wake'},
          blocks: blocks);
      expect(find.byKey(const ValueKey('ai-orb-listening')), findsOneWidget);
      // 截图替身:钉住状态
      r.$1.debugSetAiState('u_ai_c1', AiActivity.thinking);
      await tester.pump();
      expect(find.byKey(const ValueKey('ai-orb-thinking')), findsOneWidget);
      expect(find.text('在想…'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ai-orb-thinking')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('ai-hint-card')), findsOneWidget);
      expect(find.text('叫它「阿福」就能提问'), findsOneWidget);
      expect(find.byKey(const ValueKey('moderation-ai-hint')), findsOneWidget);
      expect(find.text('屏蔽这个人'), findsOneWidget);
      expect(find.text('举报'), findsOneWidget);
      r.$1.debugSetAiState('u_ai_c1', null);
      await close(tester, r);
      blocks.dispose();
    });
  });
}
