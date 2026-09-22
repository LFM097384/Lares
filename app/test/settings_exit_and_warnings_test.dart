/// 设置页的出口,以及两个「会影响别人」的开关的护栏。
///
/// ## 这一组防的是什么
///
/// 三个 bug,共同点是「界面看起来没问题,但用户被坑了」:
///
/// 1. **设置页关不掉**(iOS)。`isScrollControlled: true` 把弹层撑到几乎整屏,
///    遮罩小到点不中;iOS 又没有系统返回键;下滑手势被里面的
///    SingleChildScrollView 吃掉。于是进得去出不来。
///    ——> 断言:关闭按钮常驻,**滚到底也还在**,按下去弹层真的没了。
///
/// 2. **单方面开端到端加密**。E2EEStore 是纯本地的,不通知服务器也不通知
///    圈里任何人。只有你开 = 你和别人互相听不见,而开关看上去只是「开」了。
///    ——> 断言:开之前必须确认且警告在场;点「算了」之后**仍然是关的**;
///    关的方向不拦(那个方向永远安全)。
///
/// 3. **敲门模式是全圈共享的**。服务端 `knock_mode_set` 校验了握手、圈子
///    授权范围和在场成员身份,但**没有角色系统**(grep `owner|role|admin`
///    零命中),所以任何在场成员都能替所有人改。
///    ——> 断言:警告在场、要确认;点「算了」时**一帧都不许发出去**。
///
/// 4. 另外钉一根回归钉:设置页里改昵称的行**只能有一个**。
///    它曾经有两个(两个同名分组各带一行,两套长度上限、两条保存路径)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/l10n/gen/app_localizations.dart';
import 'package:lares_app/src/e2ee/e2ee_controller.dart';
import 'package:lares_app/src/e2ee/e2ee_store.dart';
import 'package:lares_app/src/state/circle_store.dart';
import 'package:lares_app/src/state/identity.dart';
import 'package:lares_app/src/state/room_controller.dart';
import 'package:lares_app/src/state/settings_store.dart';
import 'package:lares_app/src/theme/theme.dart';
import 'package:lares_app/src/ui/home_screen.dart';
import 'package:lares_app/src/ui/settings_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/localized_app.dart';
import 'support/fake_room.dart';

/// 设置页里有会自己跑的动画(UpdatePanel 的进度条),`pumpAndSettle` 会超时。
/// 与 dev_mode_test.dart 同款的「定量 pump」。
Future<void> _pumpSheet(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 打开设置页,返回那个 controller 以便断言。
///
/// [height] 默认给得很矮(800),因为本组里最要紧的那条用例恰恰需要
/// 内容**装不下**、必须真的滚起来 —— 调高窗口会让「滚到底」变成空操作,
/// 断言就测不到东西了。
Future<void> _openSettings(
  WidgetTester tester, {
  required SettingsStore settings,
  double height = 800,
}) async {
  tester.view
    ..physicalSize = Size(1000, height)
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
              // 不碰 package_info 的平台通道
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

/// 挂一个首页,长按圈子把那个菜单调出来。
///
/// 加密开关与敲门模式都只活在这个长按菜单里,没有更短的路径能挂到它们。
///
/// 返回那条假信令 —— 敲门模式那组要断言的是「发没发出去」,
/// 而 `RoomController` 不暴露内部的 signaling,只能在这里自己攥着。
Future<FakeSignalingClient> _openCircleMenu(
  WidgetTester tester, {
  required SettingsStore settings,
  E2EEController? e2ee,
}) async {
  tester.view
    ..physicalSize = const Size(1000, 2400)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final signaling = FakeSignalingClient();
  final controller = RoomController(
    signaling: signaling,
    rtc: FakeRtcService(),
    userId: 'u_me',
    deviceId: 'd_1',
    userName: '我',
  );
  addTearDown(controller.dispose);
  final circleStore = await CircleStore.load();

  await tester.pumpWidget(
    localizedApp(
      HomeScreen(
        controller: controller,
        circleStore: circleStore,
        settings: settings,
        e2ee: e2ee,
      ),
      theme: LaresTheme.dark(),
    ),
  );
  await tester.pump();

  await tester.longPress(find.text(circleStore.circles.first.name).first);
  await _pumpSheet(tester);
  return signaling;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 测试里不碰真实 Keychain —— 没有平台通道时它会**挂起**而不是报错,
  // 症状是整个套件超时、且不给任何失败信息(与 dev_mode_test 同一个坑)。
  debugUseInMemoryVault = true;

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  final AppLocalizations t = zhStrings();

  group('设置页必须关得掉', () {
    testWidgets('关闭按钮滚到底也还在,按下去弹层就没了', (WidgetTester tester) async {
      final SettingsStore settings = await SettingsStore.load();
      await _openSettings(tester, settings: settings);

      // 标题与关闭按钮都在头部 —— 这是 iOS 上唯一可靠的出口。
      expect(find.text(t.settingsTitle), findsOneWidget);
      final Finder close = find.byIcon(Icons.close_rounded);
      expect(close, findsOneWidget);

      // 滚到最底下。用 dragUntilVisible 会依赖某个具体控件,这里只要
      // 「狠狠往上推几把」就够了:目的就是把内容滚过去。
      final Finder scroller = find.byType(SingleChildScrollView).first;
      for (var i = 0; i < 6; i++) {
        await tester.drag(scroller, const Offset(0, -600));
        await _pumpSheet(tester);
      }

      // 关键断言:滚到底之后,出口**还在原处**。
      // 一个滚到底的人和刚打开的人一样需要它 ——
      // 出口若跟着滚走,「能不能退出去」就成了「你现在滚到哪儿了」。
      expect(
        find.byIcon(Icons.close_rounded),
        findsOneWidget,
        reason: '头部不跟着滚,滚到底也必须还能找到关闭按钮',
      );

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();

      expect(find.text(t.settingsTitle), findsNothing,
          reason: '按下关闭之后弹层必须真的退掉');
    });

    testWidgets('改昵称的行只有一个 —— 防止合并过的两个「我」分组卷土重来',
        (WidgetTester tester) async {
      final SettingsStore settings = await SettingsStore.load();
      await _openSettings(tester, settings: settings, height: 2400);

      // 曾经有两个同名分组(settingsGroupMe / settingsGroupIdentity,
      // 中文都叫「我」),各自带一行「我的名字」,各自一套长度上限和
      // 保存路径。合并之后必须**恰好一行**。
      expect(
        find.text(t.settingsMyName),
        findsOneWidget,
        reason: '两个改名入口 = 两套上限 + 两条保存路径,迟早漂移',
      );
      // 跨设备身份那一行在同一组里活着(它是被保留下来的那部分)。
      expect(find.text(t.settingsSameIdentity), findsOneWidget);
    });
  });

  group('端到端加密:开之前要说清楚', () {
    testWidgets('开的方向要确认,点「算了」之后仍然是关的', (WidgetTester tester) async {
      final SettingsStore settings = await SettingsStore.load();
      final E2EEStore store = E2EEStore.inMemory();
      final E2EEController e2ee = E2EEController(
        store: store,
        settings: settings,
        platformProbe: () => true,
      );
      await _openCircleMenu(tester, settings: settings, e2ee: e2ee);

      final String circleId = CircleStore.defaultCircle.id;
      expect(store.isEnabled(circleId), isFalse, reason: '前提:默认是关的');

      // 警告必须常驻在开关旁边,不是只在对话框里出现一次。
      expect(find.textContaining(t.e2eeEveryoneNotice), findsOneWidget);

      await tester.tap(find.byType(SwitchListTile).first);
      await _pumpSheet(tester);

      // 确认框到场,而且把后果说明白了。
      expect(find.text(t.e2eeConfirmTitle), findsOneWidget);
      expect(find.text(t.e2eeConfirmBody), findsOneWidget);

      await tester.tap(find.text(t.commonCancel));
      await _pumpSheet(tester);

      expect(
        store.isEnabled(circleId),
        isFalse,
        reason: '点了「算了」就不许生效 —— 这个方向上「没答应」必须等于「不开」',
      );
    });

    testWidgets('关的方向不拦:那个方向永远是安全的', (WidgetTester tester) async {
      final SettingsStore settings = await SettingsStore.load();
      final String circleId = CircleStore.defaultCircle.id;
      final E2EEStore store = E2EEStore.inMemory({circleId});
      final E2EEController e2ee = E2EEController(
        store: store,
        settings: settings,
        platformProbe: () => true,
      );
      await _openCircleMenu(tester, settings: settings, e2ee: e2ee);
      expect(store.isEnabled(circleId), isTrue, reason: '前提:这一把是开着的');

      await tester.tap(find.byType(SwitchListTile).first);
      await _pumpSheet(tester);

      // 关掉是把互通性还回来,没有需要犹豫的后果,所以不该弹任何东西。
      expect(find.text(t.e2eeConfirmTitle), findsNothing,
          reason: '关掉不需要确认');
      expect(store.isEnabled(circleId), isFalse, reason: '一下就关掉,不多问');
    });
  });

  group('敲门模式:改的是所有人的', () {
    testWidgets('警告在场、要确认;点「算了」时一帧都不发', (WidgetTester tester) async {
      final SettingsStore settings = await SettingsStore.load();
      final FakeSignalingClient signaling =
          await _openCircleMenu(tester, settings: settings);

      // 副标题里必须写明这是全圈共享的设置,而不是个人偏好。
      expect(find.textContaining(t.homeKnockModeEveryoneNotice), findsOneWidget);

      await tester.tap(find.text(t.homeKnockModeOff));
      await _pumpSheet(tester);

      expect(find.text(t.homeKnockModeConfirmTitle), findsOneWidget);
      expect(find.text(t.homeKnockModeConfirmBody), findsOneWidget);

      await tester.tap(find.text(t.commonCancel));
      await _pumpSheet(tester);

      // 最硬的那条断言:不是「界面没变」,是**线上一帧都没发出去**。
      // 这个设置活在服务端,界面状态说明不了任何事。
      expect(
        signaling.sent.where((Map<String, dynamic> m) =>
            m['t'] == 'knock_mode_set'),
        isEmpty,
        reason: '点了「算了」就不许给服务器发 knock_mode_set —— 那会改掉所有人的',
      );
    });

    testWidgets('确认之后才真的发出去', (WidgetTester tester) async {
      final SettingsStore settings = await SettingsStore.load();
      final FakeSignalingClient signaling =
          await _openCircleMenu(tester, settings: settings);

      await tester.tap(find.text(t.homeKnockModeOff));
      await _pumpSheet(tester);
      await tester.tap(find.text(t.homeKnockModeConfirmYes));
      await _pumpSheet(tester);

      final Iterable<Map<String, dynamic>> frames = signaling.sent
          .where((Map<String, dynamic> m) => m['t'] == 'knock_mode_set');
      expect(frames.length, 1, reason: '确认一次就发一帧,不多不少');
      expect(frames.single['enabled'], isTrue);
    });
  });

  group('导入身份码:老实说要重启', () {
    testWidgets('导入成功后给出重启提示,而不是假装已经切过去了',
        (WidgetTester tester) async {
      final SettingsStore settings = await SettingsStore.load();
      await _openSettings(tester, settings: settings, height: 2400);

      await tester.tap(find.text(t.settingsSameIdentity));
      await _pumpSheet(tester);

      // 造一个货真价实的身份码(用同一套 exportCode,不手搓字符串 ——
      // 手搓的话这个用例会在格式变化时静默失效)。
      final String code = Identity(
        userId: 'u_other',
        deviceId: 'd_other',
        name: '另一台',
      ).exportCode();
      await tester.enterText(find.byType(TextField).last, code);
      await tester.tap(find.text(t.settingsIdentityImportAction));
      await _pumpSheet(tester);

      // 关键:提示的是「要重开一次」。
      //
      // userId 在启动时就分发给了信令/房间/直连/跨服在线等多个长生命周期
      // 对象,而且已经算进了这条连接的鉴权证明、进了服务端按 userId 建的
      // 成员表。热切换做不干净,所以这里**只承诺落盘**,并如实说要重启。
      // 若哪天真做成了热切换,这条用例会失败 —— 那时该改的是这条断言,
      // 而不是把提示悄悄删掉。
      expect(
        find.text(t.settingsIdentityImportRestart),
        findsOneWidget,
        reason: '没真正热切换就不许暗示已经生效',
      );

      // 落盘是真的:下次启动一定是新身份。
      final Identity reloaded = await Identity.load();
      expect(reloaded.userId, 'u_other');
      expect(
        reloaded.deviceId,
        isNot('d_other'),
        reason: 'deviceId 不跟着走 —— 两台设备共用它会互相挤掉线',
      );
    });

    testWidgets('一串乱码不会被当成身份码', (WidgetTester tester) async {
      final SettingsStore settings = await SettingsStore.load();
      await _openSettings(tester, settings: settings, height: 2400);
      final Identity before = await Identity.load();

      await tester.tap(find.text(t.settingsSameIdentity));
      await _pumpSheet(tester);
      await tester.enterText(find.byType(TextField).last, '这不是身份码');
      await tester.tap(find.text(t.settingsIdentityImportAction));
      await _pumpSheet(tester);

      expect(find.text(t.settingsIdentityImportBad), findsOneWidget);
      expect(find.text(t.settingsIdentityImportRestart), findsNothing,
          reason: '没导进去就不该出现重启提示');
      final Identity after = await Identity.load();
      expect(after.userId, before.userId, reason: '坏输入不许动到本地身份');
    });
  });
}
