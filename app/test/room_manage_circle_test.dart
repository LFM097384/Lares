// 圈主在房间里也能打开「管理圈子」:头部齿轮 + 「更多」顶上一行,
// 打开的是与首页长按同一份面板;在房里改的功能当场生效;
// 圈子被解散时,压在房间上的面板一并收掉。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/l10n/gen/app_localizations.dart';
import 'package:lares_app/src/net/secret_vault.dart';
import 'package:lares_app/src/state/circle_store.dart';
import 'package:lares_app/src/state/location_share_stub.dart'
    if (dart.library.io) 'package:lares_app/src/state/location_share.dart';
import 'package:lares_app/src/state/models.dart';
import 'package:lares_app/src/state/room_controller.dart';
import 'package:lares_app/src/state/settings_store.dart';
import 'package:lares_app/src/theme/theme.dart';
import 'package:lares_app/src/ui/home_screen.dart';
import 'package:lares_app/src/ui/room_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/localized_app.dart';
import 'support/fake_room.dart';

const _cid = 'c_manage';
const _name = '周末合唱';

class _Room {
  _Room(this.signaling, this.controller, this.location);

  final FakeSignalingClient signaling;
  final RoomController controller;
  final LocationShareService location;

  void settings(Map<String, bool> features) => signaling.testInject({
    't': 'circle_settings',
    'circle': {
      'id': _cid,
      'registered': true,
      'features': features,
      'transcript': false,
    },
  });

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await location.dispose();
    controller.dispose();
    await tester.pump(const Duration(minutes: 6));
  }
}

const _features = {
  'captions': false,
  'transcript': false,
  'voiceNotes': false,
  'map': true,
  'recording': false,
  'plugins': false,
  'focus': false,
  'p2p': false,
  'devTools': false,
};

final AppLocalizations t = zhStrings();

Future<_Room> _pump(
  WidgetTester tester, {
  required bool owner,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final settings = await SettingsStore.load(vault: InMemorySecretVault());
  if (owner) await settings.saveOwnerKey(_cid, 'kk');
  final circleStore = await CircleStore.load();
  await circleStore.add(const Circle(id: _cid, name: _name));

  final signaling = FakeSignalingClient();
  final controller = RoomController(
    signaling: signaling,
    rtc: FakeRtcService(),
    userId: 'u_me',
    deviceId: 'd_1',
    userName: '我',
    settings: settings,
  );
  unawaited(controller.join(_cid).catchError((Object _) {}));
  signaling.testInject({
    't': 'room',
    'circleId': _cid,
    'members': [
      {'userId': 'u_me', 'name': '我', 'status': 'free'},
      {'userId': 'u1', 'name': '小鹿', 'status': 'free'},
    ],
  });
  await controller.testInjectToken('wss://fake', 'tok');
  final location = LocationShareService(room: controller);
  final room = _Room(signaling, controller, location)..settings(_features);

  await tester.pumpWidget(
    localizedApp(
      RoomScreen(
        controller: controller,
        circleName: _name,
        settings: settings,
        circleStore: circleStore,
        locationShare: location,
      ),
      theme: LaresTheme.dark(),
    ),
  );
  await tester.pump();
  return room;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _openMore(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('room-more')));
  await _settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('圈主:头部有齿轮,「更多」顶上有「管理圈子」', (tester) async {
    final room = await _pump(tester, owner: true);
    expect(find.byKey(const ValueKey('room-manage')), findsOneWidget);
    await _openMore(tester);
    expect(find.byKey(const ValueKey('more-manage')), findsOneWidget);
    expect(find.text(t.roomManageCircle), findsOneWidget);
    // 在最上面:比地图格靠上
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('more-manage'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('more-map'))).dy),
    );
    await room.close(tester);
  });

  testWidgets('普通成员:没有齿轮,「更多」里也没有「管理圈子」', (tester) async {
    final room = await _pump(tester, owner: false);
    expect(find.byKey(const ValueKey('room-manage')), findsNothing);
    await _openMore(tester);
    expect(find.byKey(const ValueKey('more-map')), findsOneWidget);
    expect(find.byKey(const ValueKey('more-manage')), findsNothing);
    expect(find.text(t.roomManageCircle), findsNothing);
    await room.close(tester);
  });

  testWidgets('圈主把功能全关了,「更多」仍在 —— 否则没处再打开', (tester) async {
    final room = await _pump(tester, owner: true);
    room.settings({..._features, 'map': false});
    await tester.pump();
    expect(find.byKey(const ValueKey('room-more')), findsOneWidget);
    await _openMore(tester);
    expect(find.byKey(const ValueKey('more-manage')), findsOneWidget);
    await room.close(tester);
  });

  testWidgets('齿轮打开管理面板:圈主工具都在,没有「从本机删除」', (tester) async {
    final room = await _pump(tester, owner: true);
    await tester.tap(find.byKey(const ValueKey('room-manage')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('circle-manage-sheet')), findsOneWidget);
    expect(find.text(t.roomManageCircleTitle(_name)), findsOneWidget);
    expect(find.byKey(const ValueKey('owner-features-tile')), findsOneWidget);
    expect(find.byKey(const ValueKey('owner-purpose-tile')), findsOneWidget);
    expect(find.text(t.homeInviteFriends), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text(t.homeDissolveCircle),
      200,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('circle-manage-sheet')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.text(t.homeDissolveCircle), findsOneWidget);
    expect(find.text(t.homeDeleteCircle), findsNothing);
    await room.close(tester);
  });

  testWidgets('管理面板分组:常用 → 怎么用 → 进圈与安全 → 危险操作', (tester) async {
    final room = await _pump(tester, owner: true);
    await tester.tap(find.byKey(const ValueKey('room-manage')));
    await _settle(tester);
    final Finder scroll = find.descendant(
      of: find.byKey(const ValueKey('circle-manage-sheet')),
      matching: find.byType(Scrollable),
    );
    double y(String id) {
      final f = find.byKey(ValueKey('manage-section-$id'));
      expect(f, findsOneWidget, reason: '缺 $id 组');
      return tester.getTopLeft(f).dy;
    }

    final common = y('common');
    final use = y('use');
    expect(common, lessThan(use));
    // 邀请在「常用」,功能在「怎么用」
    expect(
      tester.getTopLeft(find.text(t.homeInviteFriends)).dy,
      inExclusiveRange(common, use),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('owner-features-tile'))).dy,
      greaterThan(use),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('manage-section-danger')),
      200,
      scrollable: scroll,
    );
    final safety = y('safety');
    final danger = y('danger');
    expect(safety, lessThan(danger));
    expect(
      tester.getTopLeft(find.text(t.homeDissolveCircle)).dy,
      greaterThan(danger),
    );
    await room.close(tester);
  });

  testWidgets('「更多」那一行也打开同一份面板', (tester) async {
    final room = await _pump(tester, owner: true);
    await _openMore(tester);
    await tester.tap(find.byKey(const ValueKey('more-manage')));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('more-map')),
      findsNothing,
      reason: '「更多」先收起',
    );
    expect(find.byKey(const ValueKey('circle-manage-sheet')), findsOneWidget);
    expect(find.byKey(const ValueKey('owner-features-tile')), findsOneWidget);
    await room.close(tester);
  });

  testWidgets('在房里关掉地图:回执 + circle_settings 一到,「更多」当场少了地图', (tester) async {
    final room = await _pump(tester, owner: true);
    await tester.tap(find.byKey(const ValueKey('room-manage')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('owner-features-tile')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('feature-switch-map')));
    await tester.pump();
    final req = room.signaling.sent.lastWhere(
      (m) => m['t'] == 'circle_features_set',
    );
    expect(req['circleId'], _cid);
    expect(req['features'], {'map': false});
    // 服务器:回执 + 全圈广播
    room.signaling.testInject({
      't': 'owner_ok',
      'op': 'circle_features_set',
      'circleId': _cid,
    });
    room.settings({..._features, 'map': false});
    await _settle(tester);
    expect(find.byKey(const ValueKey('feature-switch-map')), findsOneWidget);
    // 回到房间(功能页是压在房间上的一页)
    Navigator.of(
      tester.element(find.byKey(const ValueKey('feature-switch-map'))),
    ).pop();
    await _settle(tester);
    expect(find.byType(RoomScreen), findsOneWidget);
    await _openMore(tester);
    expect(find.byKey(const ValueKey('more-map')), findsNothing);
    expect(find.byKey(const ValueKey('more-manage')), findsOneWidget);

    // 「更多」开着时再打开:广播一到,格子当场出现
    room.settings(_features);
    await _settle(tester);
    expect(find.byKey(const ValueKey('more-map')), findsOneWidget);
    await room.close(tester);
  });

  testWidgets('面板开着时圈子被解散:面板收起,通话结束', (tester) async {
    final room = await _pump(tester, owner: true);
    await tester.tap(find.byKey(const ValueKey('room-manage')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('circle-manage-sheet')), findsOneWidget);
    room.signaling.testInject({'t': 'circle_deleted', 'circleId': _cid});
    await _settle(tester);
    expect(room.controller.dissolvedCircleId, _cid);
    expect(room.controller.phase, isNot(RoomPhase.inRoom));
    // 收起有一段退场动画
    await _settle(tester);
    expect(find.byKey(const ValueKey('circle-manage-sheet')), findsNothing);
    await room.close(tester);
  });

  testWidgets('360 宽:齿轮在,圈名不溢出', (tester) async {
    final room = await _pump(tester, owner: true, size: const Size(360, 640));
    expect(find.byKey(const ValueKey('room-manage')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await room.close(tester);
  });

  testWidgets('首页长按打开的也是这一份面板', (tester) async {
    tester.view
      ..physicalSize = const Size(1000, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final settings = await SettingsStore.load(vault: InMemorySecretVault());
    final controller = RoomController(
      signaling: FakeSignalingClient(),
      rtc: FakeRtcService(),
      userId: 'u_me',
      deviceId: 'd_1',
      userName: '我',
      settings: settings,
    );
    addTearDown(controller.dispose);
    final circleStore = await CircleStore.load();
    final id = circleStore.circles.first.id;
    controller.circleInfo[id] = (
      registered: true,
      e2ee: null,
      transcript: false,
    );
    await settings.saveOwnerKey(id, 'kk');
    await tester.pumpWidget(
      localizedApp(
        HomeScreen(
          controller: controller,
          circleStore: circleStore,
          settings: settings,
        ),
        theme: LaresTheme.dark(),
      ),
    );
    await tester.pump();
    await tester.longPress(find.text(circleStore.circles.first.name).first);
    await _settle(tester);
    expect(find.byKey(const ValueKey('circle-manage-sheet')), findsOneWidget);
    expect(find.byKey(const ValueKey('owner-features-tile')), findsOneWidget);
    // 首页不带房间标题
    expect(find.byKey(const ValueKey('circle-manage-title')), findsNothing);
  });
}
