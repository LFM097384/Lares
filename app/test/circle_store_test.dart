import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/state/circle_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('圈子列表:默认圈、增删、持久化', () async {
    SharedPreferences.setMockInitialValues({});

    // 空存储 -> 只有默认圈
    final store = await CircleStore.load();
    expect(store.circles.single.id, 'home');

    // 添加 + 持久化
    await store.add(const Circle(id: 'c_1', name: '家人'));
    await store.add(const Circle(id: 'c_1', name: '家人')); // 重复不加
    expect(store.circles.length, 2);

    final reloaded = await CircleStore.load();
    expect(reloaded.circles.length, 2);
    expect(reloaded.circles.last.name, '家人');

    // 删除;默认圈不可删
    await reloaded.remove('c_1');
    expect(reloaded.circles.single.id, 'home');
    await reloaded.remove('home');
    expect(reloaded.circles.single.id, 'home');
  });
}
