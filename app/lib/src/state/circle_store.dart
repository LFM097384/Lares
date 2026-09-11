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
class CircleStore extends ChangeNotifier {
  CircleStore._(this._circles);

  static const _key = 'lares.circles';
  static const defaultCircle = Circle(id: 'home', name: '我们的圈');

  final List<Circle> _circles;

  List<Circle> get circles => List.unmodifiable(_circles);

  static Future<CircleStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? [];
    final circles = raw.map(Circle.decode).whereType<Circle>().toList();
    if (circles.isEmpty) circles.add(defaultCircle);
    return CircleStore._(circles);
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
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _key, _circles.map((c) => c.encode()).toList());
  }
}
