import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「哪些圈子开了 E2EE」的本地登记表(按圈可选,默认**关闭**)。
///
/// 与 [CircleStore] 分开住,而不是往 `Circle` 上加字段:
/// `Circle.encode()` 是 `'$id\n$name'` 这种位置式编码,往里塞第三段会让
/// **旧版本读新存档**时把开关值当成圈名的一部分 —— 一个安全开关不该有
/// 这种向下兼容的模糊地带。这里另起一个 key,存一份纯粹的 id 白名单:
/// 旧版本读不到它,行为就是「全关」,而全关是安全的那一侧。
///
/// 注意这里存的**只有开关**,没有任何密钥材料。密钥由圈口令现场派生
/// (见 `e2ee_key.dart`),从不落盘、从不上传。
class E2EEStore extends ChangeNotifier {
  E2EEStore._(this._enabled);

  static const _key = 'lares.e2eeCircles';

  /// 开了 E2EE 的圈子 id 集合。不在集合里 = 关闭(默认)。
  final Set<String> _enabled;

  /// 只读快照,供 UI/测试断言。
  Set<String> get enabledCircleIds => Set.unmodifiable(_enabled);

  static Future<E2EEStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? const <String>[];
    return E2EEStore._(raw.where((s) => s.isNotEmpty).toSet());
  }

  /// 测试/预览用:不碰 shared_preferences 直接造一个。
  @visibleForTesting
  factory E2EEStore.inMemory([Set<String>? enabled]) =>
      E2EEStore._({...?enabled});

  bool isEnabled(String circleId) => _enabled.contains(circleId);

  Future<void> setEnabled(String circleId, bool enabled) async {
    if (circleId.isEmpty) return;
    final changed =
        enabled ? _enabled.add(circleId) : _enabled.remove(circleId);
    if (!changed) return;
    notifyListeners();
    await _save();
  }

  Future<void> toggle(String circleId) =>
      setEnabled(circleId, !isEnabled(circleId));

  /// 圈子被删除时顺手清掉它的开关,不留悬空登记。
  Future<void> forget(String circleId) => setEnabled(circleId, false);

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, _enabled.toList()..sort());
  }
}
