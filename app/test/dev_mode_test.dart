import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/moderation/block_store.dart';
import 'package:lares_app/src/state/circle_store.dart';
import 'package:lares_app/src/state/dev_mode_store.dart';
import 'package:lares_app/src/state/settings_store.dart';
import 'package:lares_app/src/theme/theme.dart';
import 'package:lares_app/src/ui/settings_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/localized_app.dart';
import 'support/fake_room.dart';

/// 设置页是个底部弹层,里面有会自己跑的动画(UpdatePanel 的进度条等),
/// `pumpAndSettle` 有可能等到超时。一律用「定量 pump」把弹层动画走完。
Future<void> _pumpSheet(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 打开设置页。窗口调高,否则十来行设置在默认 600px 测试窗里会被滚动条藏掉,
/// 「找不到某一行」就成了碰运气而不是真结论。
Future<void> _openSettings(
  WidgetTester tester, {
  required SettingsStore settings,
  required DevModeStore? devMode,
  BlockStore? blocks,
}) async {
  tester.view
    ..physicalSize = const Size(1000, 2400)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final controller = fakeRoomController(tester);
  final circleStore = await CircleStore.load();

  await tester.pumpWidget(
    localizedApp(
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSettingsSheet(
              context,
              settings: settings,
              controller: controller,
              circleStore: circleStore,
              signalingUrl: 'ws://fake',
              blocks: blocks,
              devMode: devMode,
              // 不碰 package_info 的平台通道:测试里版本号是注入的
              versionReader: () async => '9.9.9 (42)',
            ),
            child: const Text('开设置'),
          ),
        ),
      ),
      theme: LaresTheme.dark(),
    ),
  );
  await tester.tap(find.text('开设置'));
  await _pumpSheet(tester);
}

/// 连点版本号 n 次。每一下之间 pump 一帧,模拟真实的连续点击。
Future<void> _tapVersion(WidgetTester tester, int times) async {
  for (var i = 0; i < times; i++) {
    await tester.tap(find.textContaining('${zhStrings().appTitle} v'));
    await _pumpSheet(tester);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 测试里不碰真实 Keychain —— 没有平台通道时它会**挂起**而不是报错,
  // 症状是整个测试套件超时且没有任何失败信息。
  debugUseInMemoryVault = true;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('DevModeStore 解锁计数', () {
    test('新装的设备:默认关闭', () async {
      final s = await DevModeStore.load();
      expect(s.enabled, isFalse);
      expect(s.tapsRemaining, DevModeStore.unlockTaps);
    });

    test('点 6 次不解锁,第 7 次才解锁', () async {
      final s = await DevModeStore.load();

      for (var i = 1; i <= 6; i++) {
        expect(s.registerTap(), isFalse, reason: '第 $i 下不该解锁');
        expect(s.enabled, isFalse, reason: '点了 $i 次,还不该开');
        expect(s.tapsRemaining, 7 - i);
      }

      // 第 7 下:返回 true(调用方据此弹一次「已开启」),状态立刻就是开的
      expect(s.registerTap(), isTrue);
      expect(s.enabled, isTrue);
      expect(s.tapsRemaining, 0);
    });

    test('解锁之后再点,不再重复报「刚刚解锁」', () async {
      final s = await DevModeStore.load();
      for (var i = 0; i < 7; i++) {
        s.registerTap();
      }
      expect(s.enabled, isTrue);
      // 已经开着:后续点击一律返回 false,免得每点一下都弹一次提示
      expect(s.registerTap(), isFalse);
      expect(s.registerTap(), isFalse);
      expect(s.enabled, isTrue);
    });

    test('点太慢不算数:超过连点窗口就从头数起', () async {
      final s = await DevModeStore.load();
      var now = DateTime(2026, 1, 1, 12);
      s.nowForTest = () => now;

      // 先快点 6 下
      for (var i = 0; i < 6; i++) {
        s.registerTap();
      }
      expect(s.enabled, isFalse);

      // 隔了很久才点第 7 下 —— 这不是「连点」,计数必须归零重来
      now = now.add(const Duration(minutes: 5));
      expect(s.registerTap(), isFalse);
      expect(s.enabled, isFalse, reason: '隔了 5 分钟的一下不该凑成解锁');
      expect(s.tapsRemaining, DevModeStore.unlockTaps - 1);

      // 从这一下开始重新连点,补满 7 下才开
      for (var i = 0; i < 5; i++) {
        now = now.add(const Duration(milliseconds: 200));
        expect(s.registerTap(), isFalse);
      }
      now = now.add(const Duration(milliseconds: 200));
      expect(s.registerTap(), isTrue);
      expect(s.enabled, isTrue);
    });

    test('解锁状态持久化:重新 load 出来还是开着的', () async {
      final s = await DevModeStore.load();
      for (var i = 0; i < 7; i++) {
        s.registerTap();
      }
      expect(s.enabled, isTrue);
      await s.pendingWrite; // 等落盘真的完成

      // 模拟重启:同一份 prefs 重新读一次
      final reloaded = await DevModeStore.load();
      expect(reloaded.enabled, isTrue, reason: '重启之后开发者模式该还开着');
    });

    test('关掉之后也持久化,并且计数被清空', () async {
      final s = await DevModeStore.load();
      for (var i = 0; i < 7; i++) {
        s.registerTap();
      }
      await s.pendingWrite;

      await s.disable();
      expect(s.enabled, isFalse);
      expect(
        s.tapsRemaining,
        DevModeStore.unlockTaps,
        reason: '关掉时残留的计数必须清空,否则下一下就又解锁了',
      );

      final reloaded = await DevModeStore.load();
      expect(reloaded.enabled, isFalse, reason: '关掉的状态也要存下去');
    });

    test('关掉之后还能再连点 7 次重新打开', () async {
      final s = await DevModeStore.load();
      await s.setEnabled(true);
      await s.disable();
      expect(s.enabled, isFalse);

      for (var i = 0; i < 6; i++) {
        expect(s.registerTap(), isFalse);
      }
      expect(s.registerTap(), isTrue);
      expect(s.enabled, isTrue);
    });

    test('状态变化会通知监听者(UI 靠它刷新)', () async {
      final s = await DevModeStore.load();
      var notified = 0;
      s.addListener(() => notified++);

      s.registerTap();
      expect(notified, 1, reason: '每一下点击都要通知,「还差 N 次」才跟得上');

      for (var i = 0; i < 6; i++) {
        s.registerTap();
      }
      expect(s.enabled, isTrue);
      expect(notified, 7);

      await s.disable();
      expect(notified, 8);
    });
  });

  group('设置页:未解锁时开发者选项完全不可见', () {
    testWidgets('默认状态:没有开发者区,技术项一个都看不到', (tester) async {
      final settings = await SettingsStore.load();
      final devMode = await DevModeStore.load();

      await _openSettings(tester, settings: settings, devMode: devMode);

      // 开发者区不该存在 —— 不是灰掉、不是折叠,是根本没渲染
      expect(find.text('开发者选项'), findsNothing);
      expect(find.text('状态'), findsNothing);
      expect(find.text('开发者模式'), findsNothing);

      // ⚠️ 但「服务器与口令」**是常规设置**,未解锁也必须看得到。
      // 自托管是产品的核心主张,藏在连点 7 次的彩蛋后面
      // 等于对普通用户不存在。2026-09-22 从开发者区移出来。
      expect(find.text('服务器与口令'), findsOneWidget);

      // 普通设置项照常在
      expect(find.text('仅 WiFi 下高音质'), findsOneWidget);
      expect(find.text('免打扰时段'), findsOneWidget);
      expect(find.text('社区内容规范'), findsOneWidget);
    });

    testWidgets('压根不传 devMode 时:版本号还在,但点不出任何东西', (tester) async {
      final settings = await SettingsStore.load();

      await _openSettings(tester, settings: settings, devMode: null);

      expect(find.textContaining('${zhStrings().appTitle} v'), findsOneWidget);
      expect(find.text('开发者选项'), findsNothing);

      // 点 10 次也不该解锁出什么来(没有 store,连计数都无从记起)
      await _tapVersion(tester, 10);
      expect(find.text('开发者选项'), findsNothing);
      // 服务器与口令是常规设置,不随开发者模式开关
      expect(find.text('服务器与口令'), findsOneWidget);
    });

    testWidgets('版本号如实显示注入的版本', (tester) async {
      final settings = await SettingsStore.load();
      final devMode = await DevModeStore.load();

      await _openSettings(tester, settings: settings, devMode: devMode);

      expect(find.text('${zhStrings().appTitle} v9.9.9 (42)'), findsOneWidget);
    });
  });

  group('设置页:连点版本号解锁', () {
    testWidgets('点 6 次:开发者区仍然不出现', (tester) async {
      final settings = await SettingsStore.load();
      final devMode = await DevModeStore.load();

      await _openSettings(tester, settings: settings, devMode: devMode);
      await _tapVersion(tester, 6);

      expect(devMode.enabled, isFalse);
      expect(find.text('开发者选项'), findsNothing);
      // 服务器与口令是常规设置,不随开发者模式开关
      expect(find.text('服务器与口令'), findsOneWidget);
    });

    testWidgets('点满 7 次:弹「开发者模式已开启」,开发者区当场出现', (tester) async {
      final settings = await SettingsStore.load();
      final devMode = await DevModeStore.load();

      await _openSettings(tester, settings: settings, devMode: devMode);
      await _tapVersion(tester, 7);

      expect(devMode.enabled, isTrue);
      // 明确的反馈:这一下到底有没有生效,不能让人猜
      expect(find.text('开发者模式已开启'), findsOneWidget);

      // 开发者区就地出现(设置页不必关掉重开)
      expect(find.text('开发者选项'), findsOneWidget);
      expect(find.text('服务器与口令'), findsOneWidget);
      expect(find.text('状态'), findsOneWidget);
      expect(find.text('开发者模式'), findsOneWidget);
    });

    testWidgets('解锁之后重开设置页:开发者区还在(状态真的存住了)', (tester) async {
      final settings = await SettingsStore.load();
      final devMode = await DevModeStore.load();

      await _openSettings(tester, settings: settings, devMode: devMode);
      await _tapVersion(tester, 7);
      await devMode.pendingWrite;

      // 关掉设置页
      await tester.tapAt(const Offset(10, 10));
      await _pumpSheet(tester);

      // 用**新 load 出来的** store 重开一次 —— 等于模拟重启 App
      final reloaded = await DevModeStore.load();
      expect(reloaded.enabled, isTrue);

      await _openSettings(tester, settings: settings, devMode: reloaded);
      expect(find.text('开发者选项'), findsOneWidget);
      expect(find.text('服务器与口令'), findsOneWidget);
    });
  });

  group('设置页:在开发者区里把它关掉', () {
    testWidgets('拨掉「开发者模式」开关:整块收起,普通项照旧', (tester) async {
      final settings = await SettingsStore.load();
      final devMode = await DevModeStore.load();
      await devMode.setEnabled(true);

      await _openSettings(tester, settings: settings, devMode: devMode);
      expect(find.text('开发者选项'), findsOneWidget);

      // 关掉它
      await tester.tap(find.widgetWithText(SwitchListTile, '开发者模式'));
      await _pumpSheet(tester);

      expect(devMode.enabled, isFalse);
      expect(find.text('开发者模式已关闭'), findsOneWidget);

      // 整块收起
      expect(find.text('开发者选项'), findsNothing);
      // 服务器与口令是常规设置,不随开发者模式开关
      expect(find.text('服务器与口令'), findsOneWidget);
      expect(find.text('状态'), findsNothing);

      // 普通设置一项都没少
      expect(find.text('仅 WiFi 下高音质'), findsOneWidget);
      expect(find.text('社区内容规范'), findsOneWidget);
      // 版本号还在(还能再连点解锁回来)
      expect(find.textContaining('${zhStrings().appTitle} v'), findsOneWidget);
    });

    testWidgets('关掉之后当场再连点 7 次:能重新打开', (tester) async {
      final settings = await SettingsStore.load();
      final devMode = await DevModeStore.load();
      await devMode.setEnabled(true);

      await _openSettings(tester, settings: settings, devMode: devMode);
      await tester.tap(find.widgetWithText(SwitchListTile, '开发者模式'));
      await _pumpSheet(tester);
      expect(find.text('开发者选项'), findsNothing);

      await _tapVersion(tester, 7);
      expect(devMode.enabled, isTrue);
      expect(find.text('开发者选项'), findsOneWidget);
    });
  });

  group('服务器设置属于常规设置(需求回归 2026-09-22)', () {
    // 这一组存在的理由:「服务器与口令」曾被放进开发者选项,
    // 理由是「不让默认用户误触」。那个判断是错的 ——
    // 自托管是产品的核心主张(隐私政策、官网、商店描述都写着
    // 「你可以跑在自己的机器上」),藏在连点 7 次的彩蛋后面
    // 等于这个承诺对普通用户不成立。
    //
    // 误触的代价是改回来;找不到的代价是功能等于不存在。
    testWidgets('全新用户(从未解锁开发者模式)就能看到并点开', (tester) async {
      final settings = await SettingsStore.load();
      final devMode = await DevModeStore.load();

      await _openSettings(tester, settings: settings, devMode: devMode);

      expect(devMode.enabled, isFalse, reason: '前提:没解锁过');
      expect(find.text('开发者选项'), findsNothing);
      expect(find.text('服务器与口令'), findsOneWidget,
          reason: '自托管不能藏在彩蛋后面');
    });

    testWidgets('它只出现一次 —— 不能在两个地方各渲染一份', (tester) async {
      // 从开发者区移出来时如果忘了删原处,解锁后会看到两个同名分组,
      // 而它们各自持有状态,改一个不影响另一个。
      final settings = await SettingsStore.load();
      final devMode = await DevModeStore.load();
      await devMode.setEnabled(true);

      await _openSettings(tester, settings: settings, devMode: devMode);

      expect(find.text('开发者选项'), findsOneWidget, reason: '前提:已解锁');
      expect(find.text('服务器与口令'), findsOneWidget,
          reason: '解锁后也只能有一份');
    });
  });

  group('设置页:合规项绝不进开发者模式', () {
    testWidgets('未解锁时,屏蔽名单与内容规范照样可达(指南 1.2)', (tester) async {
      final settings = await SettingsStore.load();
      final devMode = await DevModeStore.load();
      final blocks = await BlockStore.load();

      await _openSettings(
        tester,
        settings: settings,
        devMode: devMode,
        blocks: blocks,
      );

      // 审核员不会去连点版本号 —— 这两项必须在默认设置页里一眼看见
      expect(devMode.enabled, isFalse);
      expect(find.text('已屏蔽的人'), findsOneWidget);
      expect(find.text('社区内容规范'), findsOneWidget);
    });

    testWidgets('未解锁时,后台运行保障仍在普通设置里', (tester) async {
      final settings = await SettingsStore.load();
      final devMode = await DevModeStore.load();

      await _openSettings(tester, settings: settings, devMode: devMode);

      // 「挂机会掉线」是普通用户真的会遇到的毛病,不能藏
      expect(find.text('后台运行保障'), findsOneWidget);
    });
  });

  group('设置页:分组小标题', () {
    testWidgets('普通设置分三组,标题都在', (tester) async {
      final settings = await SettingsStore.load();
      final devMode = await DevModeStore.load();
      final blocks = await BlockStore.load();

      await _openSettings(
        tester,
        settings: settings,
        devMode: devMode,
        blocks: blocks,
      );

      expect(find.text('声音与打扰'), findsOneWidget);
      expect(find.text('这个圈子'), findsOneWidget);
      expect(find.text('待得住'), findsOneWidget);
    });
  });
}