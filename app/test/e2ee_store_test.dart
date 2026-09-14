import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/e2ee/e2ee_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('E2EE 开关持久化', () {
    test('默认全关 —— 空存档不许有任何圈子是开着的', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await E2EEStore.load();
      expect(store.enabledCircleIds, isEmpty);
      expect(store.isEnabled('home'), isFalse);
    });

    test('开启 -> 落盘 -> 重新加载仍然是开的', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await E2EEStore.load();
      await store.setEnabled('home', true);
      expect(store.isEnabled('home'), isTrue);

      final reloaded = await E2EEStore.load();
      expect(reloaded.isEnabled('home'), isTrue);
      expect(reloaded.isEnabled('work'), isFalse);
    });

    test('按圈独立:开一个不影响另一个', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await E2EEStore.load();
      await store.setEnabled('home', true);
      await store.setEnabled('work', false);
      final reloaded = await E2EEStore.load();
      expect(reloaded.isEnabled('home'), isTrue);
      expect(reloaded.isEnabled('work'), isFalse);
    });

    test('关闭 -> 落盘 -> 重新加载是关的', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await E2EEStore.load();
      await store.setEnabled('home', true);
      await store.setEnabled('home', false);
      expect((await E2EEStore.load()).isEnabled('home'), isFalse);
    });

    test('toggle 与 forget', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await E2EEStore.load();
      await store.toggle('home');
      expect(store.isEnabled('home'), isTrue);
      await store.forget('home');
      expect(store.isEnabled('home'), isFalse);
      expect((await E2EEStore.load()).isEnabled('home'), isFalse);
    });

    test('变更会通知监听者(UI 据此刷新锁标)', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await E2EEStore.load();
      var notified = 0;
      store.addListener(() => notified++);
      await store.setEnabled('home', true);
      expect(notified, 1);
      // 没有实际变化就不该通知,免得 UI 白刷
      await store.setEnabled('home', true);
      expect(notified, 1);
    });

    test('空 circleId 直接忽略,不制造一条脏登记', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await E2EEStore.load();
      await store.setEnabled('', true);
      expect(store.enabledCircleIds, isEmpty);
    });

    test('旧版本存档(没有这个 key)一律视为全关 —— 默认落在安全的那一侧', () async {
      SharedPreferences.setMockInitialValues({
        'lares.circles': ['home\n我们的圈'],
      });
      final store = await E2EEStore.load();
      expect(store.isEnabled('home'), isFalse);
    });
  });
}
