import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/state/circle_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主圈子(§2.1-1「一键加入」):主屏小组件 / QS Tile / 桌面托盘一键进的那个圈。
/// 不变量:[CircleStore.primaryCircle] 永远不会返回一个不在列表里的圈子。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('主圈子默认:只有一个圈时它天然是主圈', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await CircleStore.load();

    expect(store.circles.single.id, 'home');
    expect(store.primaryCircleId, 'home');
    expect(store.isPrimary('home'), isTrue);
    // 从未显式指定:存档里不该留下任何值
    expect(store.storedPrimaryCircleId, isNull);
  });

  test('主圈子默认:多圈子且未指定时,取最早登记的那个', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await CircleStore.load();
    await store.add(const Circle(id: 'c_1', name: '家人'));
    await store.add(const Circle(id: 'c_2', name: '死党群'));

    expect(store.circles.length, 3);
    expect(store.primaryCircleId, 'home'); // 最早登记
    expect(store.isPrimary('c_2'), isFalse);
  });

  test('主圈子持久化:设定后重新加载仍是它', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await CircleStore.load();
    await store.add(const Circle(id: 'c_1', name: '家人'));
    await store.setPrimaryCircle('c_1');

    expect(store.primaryCircleId, 'c_1');
    expect(store.storedPrimaryCircleId, 'c_1');

    // 往返:重新 load 应读回同一个主圈子
    final reloaded = await CircleStore.load();
    expect(reloaded.primaryCircleId, 'c_1');
    expect(reloaded.primaryCircle!.name, '家人');
    expect(reloaded.isPrimary('home'), isFalse);
  });

  test('设主圈子会通知监听者(UI 标记与 Widget 推送靠它刷新)', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await CircleStore.load();
    await store.add(const Circle(id: 'c_1', name: '家人'));

    var notifications = 0;
    store.addListener(() => notifications++);

    await store.setPrimaryCircle('c_1');
    expect(notifications, 1);

    // 重复设同一个:不该再通知(避免无谓的 Widget 刷新)
    await store.setPrimaryCircle('c_1');
    expect(notifications, 1);
  });

  test('设主圈子:不存在的 id 被忽略,不制造悬空引用', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await CircleStore.load();

    await store.setPrimaryCircle('does_not_exist');
    expect(store.storedPrimaryCircleId, isNull);
    expect(store.primaryCircleId, 'home');
  });

  test('自愈:主圈子被删除后回落到剩下的圈,且落盘清掉旧值', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await CircleStore.load();
    await store.add(const Circle(id: 'c_1', name: '家人'));
    await store.setPrimaryCircle('c_1');
    expect(store.primaryCircleId, 'c_1');

    await store.remove('c_1');
    // 显式指定被清掉,getter 回落到最早登记的圈
    expect(store.storedPrimaryCircleId, isNull);
    expect(store.primaryCircleId, 'home');

    // 重新加载也不该复活已删除的主圈子
    final reloaded = await CircleStore.load();
    expect(reloaded.primaryCircleId, 'home');
  });

  test('自愈:存档里的主圈子 id 已不存在(换机/旧版残留)-> load 时清掉', () async {
    // 存档只有 home,但主圈子指向一个不存在的 ghost
    SharedPreferences.setMockInitialValues({
      'lares.circles': <String>['home\n我们的圈'],
      'lares.primaryCircleId': 'ghost',
    });

    final store = await CircleStore.load();
    expect(store.primaryCircleId, 'home'); // 自愈回落
    expect(store.storedPrimaryCircleId, isNull); // 悬空引用已清

    // 清理已落盘:再 load 一次仍然干净
    final reloaded = await CircleStore.load();
    expect(reloaded.storedPrimaryCircleId, isNull);
    expect(reloaded.primaryCircleId, 'home');
  });

  test('删除非主圈子:主圈子不受影响', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await CircleStore.load();
    await store.add(const Circle(id: 'c_1', name: '家人'));
    await store.add(const Circle(id: 'c_2', name: '死党群'));
    await store.setPrimaryCircle('c_2');

    await store.remove('c_1');
    expect(store.primaryCircleId, 'c_2');
    expect(store.storedPrimaryCircleId, 'c_2');
  });

  test('打包期偏好圈(--dart-define=LARES_CIRCLE):未显式指定时优先,手选后让位',
      () async {
    SharedPreferences.setMockInitialValues({
      // 注意 kiosk 圈不是最早登记的那个
      'lares.circles': <String>['home\n我们的圈', 'kiosk\n挂机圈'],
    });

    final store = await CircleStore.load(preferredPrimaryId: 'kiosk');
    expect(store.primaryCircleId, 'kiosk');

    // 用户手选 -> 偏好让位
    await store.setPrimaryCircle('home');
    expect(store.primaryCircleId, 'home');
  });

  test('打包期偏好圈不在列表里:回落到最早登记的圈,不报错', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await CircleStore.load(preferredPrimaryId: 'not_registered');
    expect(store.primaryCircleId, 'home');
  });
}
