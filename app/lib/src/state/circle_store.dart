import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一个圈子(本地登记;服务端按 circleId 动态建房间,无需注册)
class Circle {
  const Circle({required this.id, required this.name});

  final String id;
  final String name;

  String encode() => '$id\n$name';

  static Circle? decode(String s) {
    final i = s.indexOf('\n');
    if (i <= 0) return null;
    return Circle(id: s.substring(0, i), name: s.substring(i + 1));
  }
}

/// 多圈子管理(设计.md §2.2):本地持久化的圈子列表。
/// 默认圈 home 不可删。后续接真实账号后迁移到服务端。
///
/// 主圈子(§2.1-1「一键加入」):列表里被指定为「默认要进的那个圈」。
/// 主屏 Widget / QS Tile / 桌面托盘的一键入口都指向它。
/// 它是「圈子注册表」的一部分而非用户偏好,所以住在这里而不是 SettingsStore ——
/// 只有这里同时握着圈子列表,才能把「主圈子必须存在」这条不变量在一处守住。
class CircleStore extends ChangeNotifier {
  CircleStore._(this._circles, this._primaryCircleId, this._preferredPrimaryId);

  static const _key = 'lares.circles';
  static const _primaryKey = 'lares.primaryCircleId';
  static const defaultCircle = Circle(id: 'home', name: '我们的圈');

  final List<Circle> _circles;

  /// 用户显式指定的主圈子 id。可能为 null(从未指定),
  /// 也可能指向一个已被删除的圈子 —— 一律不要直接用,走 [primaryCircle]。
  String? _primaryCircleId;

  /// 打包期偏好(`--dart-define=LARES_CIRCLE`):用户没显式指定主圈子时的优先兜底。
  /// 常驻挂机机器靠它把一键入口钉在指定圈上;用户一旦手选,偏好即让位。
  final String? _preferredPrimaryId;

  List<Circle> get circles => List.unmodifiable(_circles);

  /// 存档里的原始值,仅供测试断言「自愈是否真的落盘」。
  @visibleForTesting
  String? get storedPrimaryCircleId => _primaryCircleId;

  /// 主圈子(自愈解析,永远不会返回一个不存在的圈子):
  /// 1. 显式指定且该圈仍在列表里 -> 用它;
  /// 2. 否则打包期偏好圈(`--dart-define=LARES_CIRCLE`)若在列表里 -> 用它;
  /// 3. 否则回落到最早登记的圈子(只有一个圈时,那个圈天然是主圈);
  /// 4. 列表为空 -> null,调用方(Widget/托盘)据此显示空状态。
  Circle? get primaryCircle {
    for (final id in [_primaryCircleId, _preferredPrimaryId]) {
      if (id == null) continue;
      for (final c in _circles) {
        if (c.id == id) return c;
      }
    }
    return _circles.isEmpty ? null : _circles.first;
  }

  String? get primaryCircleId => primaryCircle?.id;

  bool isPrimary(String circleId) => primaryCircleId == circleId;

  /// [preferredPrimaryId] 由调用方注入(通常是 `LaresConfig.defaultCircleId`),
  /// 保持本层不依赖 config,便于测试。
  static Future<CircleStore> load({String? preferredPrimaryId}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? [];
    final circles = raw.map(Circle.decode).whereType<Circle>().toList();
    if (circles.isEmpty) circles.add(defaultCircle);
    final store = CircleStore._(
      circles,
      prefs.getString(_primaryKey),
      preferredPrimaryId,
    );
    // 自愈:存档里的主圈子已不存在(换机/手改存档/旧版本残留)-> 清掉悬空引用
    await store._healPrimary();
    return store;
  }

  Future<void> add(Circle circle) async {
    if (_circles.any((c) => c.id == circle.id)) return;
    _circles.add(circle);
    notifyListeners();
    await _save();
  }

  Future<void> remove(String circleId) async {
    if (circleId == defaultCircle.id) return; // 默认圈不可删
    _circles.removeWhere((c) => c.id == circleId);
    // 删掉的正是主圈子:清掉显式指定,getter 自动回落到最早登记的圈,
    // 主屏 Widget 因此不会停留在一个已经不存在的圈名上。
    if (_primaryCircleId == circleId) _primaryCircleId = null;
    notifyListeners();
    await _save();
  }

  /// 设为主圈子。传入不存在的圈子 id 直接忽略(不制造悬空引用)。
  Future<void> setPrimaryCircle(String circleId) async {
    if (!_circles.any((c) => c.id == circleId)) return;
    if (_primaryCircleId == circleId) return;
    _primaryCircleId = circleId;
    notifyListeners();
    await _save();
  }

  Future<void> _healPrimary() async {
    final id = _primaryCircleId;
    if (id == null || _circles.any((c) => c.id == id)) return;
    _primaryCircleId = null;
    await _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _key, _circles.map((c) => c.encode()).toList());
    final id = _primaryCircleId;
    if (id == null) {
      await prefs.remove(_primaryKey);
    } else {
      await prefs.setString(_primaryKey, id);
    }
  }
}
