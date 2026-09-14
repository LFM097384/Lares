import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 开发者模式的开关状态与解锁计数,本地持久化。
///
/// 为什么单独一个 store 而不是塞进 [SettingsStore]:
/// 这里存的不是「用户的偏好」,而是「这台设备要不要露出技术面」——
/// 语义上是另一回事,而且设置页里只有它需要在**未解锁时整块不渲染**。
/// 分开之后,不传这个 store 的调用方(以及所有老测试)天然看不到开发者选项。
///
/// 解锁交互沿用 Android 的老规矩:连点版本号 7 次。
/// 计数逻辑放在 store 里而不是 widget 的 setState 里,是为了能被纯单元测试
/// 直接验证(点 6 次不开、第 7 次才开),不必每次都去 pump 一棵组件树。
class DevModeStore extends ChangeNotifier {
  DevModeStore._();

  static const _kEnabled = 'lares.devMode';

  /// 解锁需要的点击次数。7 次是 Android「关于手机 → 版本号」的老规矩,
  /// 用户手上有肌肉记忆;也足够长到不会被误触打开。
  static const int unlockTaps = 7;

  /// 连点的最大间隔。超过这个时间没有下一下,计数归零 ——
  /// 否则「今天点一下、明天点一下」攒够 7 次也会解锁,那是误开。
  static const Duration tapWindow = Duration(seconds: 3);

  /// 注入时钟:让连点超时能在单元测试里精确验证,不必真的 sleep。
  DateTime Function() _now = DateTime.now;

  /// 仅供测试替换时钟。
  @visibleForTesting
  set nowForTest(DateTime Function() fn) => _now = fn;

  bool _enabled = false;

  /// 开发者模式是否已开启。未开启时设置页**完全不渲染**开发者区。
  bool get enabled => _enabled;

  int _taps = 0;
  DateTime? _lastTapAt;

  /// 最近一次落盘操作;[registerTap] 是同步的,测试要确认「真的存下去了」
  /// 时 await 它即可,不必猜要 pump 多少次。
  Future<void> _pending = Future<void>.value();

  /// 等待最近一次持久化完成(测试用;生产代码不必关心)。
  @visibleForTesting
  Future<void> get pendingWrite => _pending;

  /// 当前连点进度(已解锁时恒为 0)。用来驱动「还差 N 次」的提示。
  int get tapProgress => _enabled ? 0 : _taps;

  /// 还差几次解锁;已解锁时为 0。
  int get tapsRemaining => _enabled ? 0 : unlockTaps - _taps;

  static Future<DevModeStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = DevModeStore._();
    s._enabled = prefs.getBool(_kEnabled) ?? false;
    return s;
  }

  /// 记一次版本号点击。
  ///
  /// 返回值是这一下**是否刚好把开发者模式点开了** —— 调用方据此弹「已开启」的
  /// 反馈,而不是每次点击都弹。已经开启时一律返回 false(不会重复提示)。
  ///
  /// 落盘是异步的,但 [enabled] 在返回前就已经是新值:UI 不必等 I/O 才刷新。
  bool registerTap() {
    if (_enabled) return false;

    final now = _now();
    final last = _lastTapAt;
    // 距上一下太久 = 这是新的一轮,从 1 重新数起
    if (last != null && now.difference(last) > tapWindow) {
      _taps = 0;
    }
    _lastTapAt = now;
    _taps++;

    if (_taps < unlockTaps) {
      notifyListeners(); // 让「还差 N 次」的提示能跟着走
      return false;
    }

    _taps = 0;
    _lastTapAt = null;
    _enabled = true;
    notifyListeners();
    _pending = _persist(true);
    unawaited(_pending);
    return true;
  }

  /// 关掉开发者模式(开发者区里那个开关)。顺手清空连点计数,
  /// 免得关掉之后残留的计数让下一下就又解锁了。
  Future<void> disable() => setEnabled(false);

  /// 直接置位(测试与将来可能的调试入口用)。
  @visibleForTesting
  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    _taps = 0;
    _lastTapAt = null;
    notifyListeners();
    _pending = _persist(value);
    await _pending;
  }

  Future<void> _persist(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, value);
  }
}
