import 'dart:ui';

/// 炉火之灵原型 —— 设计 token。
///
/// 注意:这是 `app/lib/src/theme/tokens.dart` 的**副本**,不是引用。
/// 原型必须与主 app 解耦(约束:不得修改也不得依赖 lib/),
/// 因此这里复制一份,值保持一致。合入主 app 时应改回引用 LaresColors。
abstract final class HearthColors {
  // ── 基调 ──
  static const Color bg = Color(0xFF121016); // 深暖灰紫,不是死黑
  static const Color surface = Color(0xFF1C1922);
  static const Color surfaceHigh = Color(0xFF26222E);

  // ── 火 ──
  static const Color ember = Color(0xFFFF8A5C); // 品牌余烬橙
  static const Color emberDeep = Color(0xFFFF5A2A); // 火心
  static const Color emberAsh = Color(0xFF8C3A1E); // 将熄的炭

  // ── 文字 ──
  static const Color textPrimary = Color(0xFFF2EEE9);
  static const Color textSecondary = Color(0xFF9A93A3);

  // ── 轻状态色(presence ring)──
  static const Color statusFree = Color(0xFF6FD08C); // 随时聊
  static const Color statusBusy = Color(0xFFE8B45A); // 在忙
  static const Color statusEars = Color(0xFF6FA8D0); // 耳朵在
  static const Color statusAway = Color(0xFF6E6878); // 有事先走
}

abstract final class HearthSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 40;
}

abstract final class HearthRadii {
  static const double sm = 10;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
}
