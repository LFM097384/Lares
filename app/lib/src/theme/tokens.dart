import 'package:flutter/material.dart';

/// Lares 设计系统 token —— 所有颜色/圆角/间距/字阶的唯一数据源。
/// 纪律(设计.md §8.2):任何页面不得硬编码数值,一律引用本文件。
///
/// 设计语言:陪伴感 = 深夜暖调、低饱和、柔和发光。
/// 暗色是一等公民(挂机场景多在夜间),亮色做适配。
abstract final class LaresColors {
  // ── 暗色基调 ──
  static const Color bgDark = Color(0xFF121016); // 深暖灰紫,不是死黑
  static const Color surfaceDark = Color(0xFF1C1922);
  static const Color surfaceHighDark = Color(0xFF26222E);

  // ── 亮色基调 ──
  static const Color bgLight = Color(0xFFF7F4F0);
  static const Color surfaceLight = Color(0xFFFFFFFF);
  static const Color surfaceHighLight = Color(0xFFEFEAE4);

  // ── 品牌色:余烬暖橙(语音波纹/主按钮)──
  static const Color ember = Color(0xFFFF8A5C);
  static const Color emberSoft = Color(0x33FF8A5C);

  // ── 轻状态色(presence ring)──
  static const Color statusFree = Color(0xFF6FD08C); // 随时聊
  static const Color statusBusy = Color(0xFFE8B45A); // 在忙
  static const Color statusEars = Color(0xFF6FA8D0); // 耳朵在
  static const Color statusAway = Color(0xFF6E6878); // 有事先走

  // ── 文字 ──
  static const Color textPrimaryDark = Color(0xFFF2EEE9);
  static const Color textSecondaryDark = Color(0xFF9A93A3);
  static const Color textPrimaryLight = Color(0xFF241F2B);
  static const Color textSecondaryLight = Color(0xFF7A7382);
}

abstract final class LaresRadii {
  static const double sm = 10;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const BorderRadius cardRadius =
      BorderRadius.all(Radius.circular(lg));
}

abstract final class LaresSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 40;
}

/// 桌面/移动布局断点(设计.md §8.2-5)
abstract final class LaresBreakpoints {
  static const double desktop = 840;
}
