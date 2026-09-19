import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/state/circle_store.dart';
import 'package:lares_app/src/state/room_controller.dart';
import 'package:lares_app/src/ui/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/localized_app.dart';
import 'support/fake_room.dart';

/// 「我有空」挑选圈子的 UI 测试。
///
/// 重点不是渲染好不好看,而是两件会真正出错的事:
///   1. 选择结果必须**原样**传给 controller(选了哪几个就挂哪几个)
///   2. 一个都不选时不能提交 —— 那等于挂了个没人看得见的空状态
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// 造一个带三个圈子的首页,并返回 controller 便于断言。
  Future<(RoomController, FakeSignalingClient)> pump(WidgetTester t) async {
    final signaling = FakeSignalingClient();
    final c = RoomController(
      signaling: signaling,
      rtc: FakeRtcService(),
      userId: 'u_me',
      deviceId: 'd_1',
      userName: '我',
    );
    addTearDown(c.dispose);

    // 注意:load() 会自带一个默认圈(home),测试里如实接受它 ——
    // 改代码去迁就测试是本末倒置。
    final store = await CircleStore.load();
    await store.add(const Circle(id: 'jia', name: '家里'));
    await store.add(const Circle(id: 'yi', name: '同事'));
    await store.add(const Circle(id: 'bing', name: '球友'));

    await t.pumpWidget(
      localizedApp(
        Scaffold(
          body: ListView(
            children: [AvailableToggle(controller: c, circleStore: store)],
          ),
        ),
      ),
    );
    return (c, signaling);
  }

  testWidgets('打开开关:默认对所有圈子可见', (t) async {
    final (c, _) = await pump(t);
    await t.tap(find.byType(Switch));
    await t.pump();
    expect(
      c.myAvailableCircles.toSet(),
      containsAll(<String>['jia', 'yi', 'bing']),
    );
    // 4 = 默认的 home + 我们加的三个
    expect(c.myAvailableCircles, hasLength(4));
  });

  testWidgets('长按打开挑选对话框,默认全选', (t) async {
    await pump(t);
    await t.longPress(find.text('我有空'));
    await t.pumpAndSettle();
    expect(find.text('对哪几个圈子可见'), findsOneWidget);
    // 三个圈子都在,且都勾上
    for (final w in t.widgetList<CheckboxListTile>(
      find.byType(CheckboxListTile),
    )) {
      expect(w.value, isTrue, reason: '没挂着时默认全选');
    }
  });

  testWidgets('取消勾选后提交,只挂选中的那几个', (t) async {
    final (c, _) = await pump(t);
    await t.longPress(find.text('我有空'));
    await t.pumpAndSettle();

    // 取消「同事」
    await t.tap(find.widgetWithText(CheckboxListTile, '同事'));
    await t.pumpAndSettle();
    await t.tap(find.text('就这几个'));
    await t.pumpAndSettle();

    expect(c.myAvailableCircles, isNot(contains('yi')));
    expect(c.myAvailableCircles.toSet(), containsAll(<String>['jia', 'bing']));
    expect(c.myAvailableCircles, isNot(contains('yi')));
  });

  testWidgets('一个都不选时提交键是灰的 —— 空挂着没有意义', (t) async {
    await pump(t);
    await t.longPress(find.text('我有空'));
    await t.pumpAndSettle();

    // 逐个取消,直到一个不剩。不写死名字 ——
    // CircleStore.load() 自带一个默认圈,它叫什么不该由这个测试来假设。
    final n = t.widgetList(find.byType(CheckboxListTile)).length;
    for (var i = 0; i < n; i++) {
      await t.tap(find.byType(CheckboxListTile).at(i));
      await t.pumpAndSettle();
    }
    final btn = t.widget<FilledButton>(find.byType(FilledButton));
    expect(btn.onPressed, isNull, reason: '一个都没选就不该能提交');
  });

  testWidgets('点「算了」不改变现状', (t) async {
    final (c, _) = await pump(t);
    c.setAvailable(['jia']);
    await t.pump();

    await t.longPress(find.text('我有空'));
    await t.pumpAndSettle();
    await t.tap(find.text('算了'));
    await t.pumpAndSettle();

    expect(c.myAvailableCircles, ['jia'], reason: '取消不该动已有选择');
  });

  testWidgets('已经挂着时再长按,沿用当前选择而不是重新全选', (t) async {
    final (c, _) = await pump(t);
    c.setAvailable(['jia']);
    await t.pump();

    await t.longPress(find.text('我有空'));
    await t.pumpAndSettle();

    final tiles = t
        .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
        .toList();
    // 三个里只有「家里」是勾上的
    expect(tiles.where((w) => w.value == true), hasLength(1));
  });
}
