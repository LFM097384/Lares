// 由一套 Palette 构建 ThemeData —— 结构逐行对照 lib/src/theme/theme.dart。
//
// 为什么要复制一份而不是直接调 LaresTheme.dark():
// LaresTheme 从 LaresColors 里读**编译期常量**,没有任何注入口子。
// 要在同一次运行里渲染 5 套配色,只能把同样的构建逻辑参数化一遍。
// 本文件是「同构副本」,不是新设计:字阶、圆角、间距、各处颜色的去向
// 全部与 theme.dart 保持一致,改动仅限于颜色来源。
//
// 注意:间距/圆角仍然直接 import lib 的 token,不重复定义 ——
// 那部分没有被配色方案改变,复制只会引入漂移。

import 'package:flutter/material.dart';
import 'package:lares_app/src/theme/tokens.dart';

import 'palettes.dart';

Color _c(int argb) => Color(argb);

ThemeData themeFor(Palette p) {
  final Color bg = _c(p.bg);
  final Color surface = _c(p.surface);
  final Color surfaceHigh = _c(p.surfaceHigh);
  final Color textPrimary = _c(p.textPrimary);
  final Color textSecondary = _c(p.textSecondary);
  final Color brand = _c(p.brand);

  final ColorScheme scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: brand,
    onPrimary: _c(p.onBrand),
    secondary: _c(p.statusEars),
    onSecondary: textPrimary,
    error: const Color(0xFFE06C6C),
    onError: textPrimary,
    surface: surface,
    onSurface: textPrimary,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    // 测试环境下用自己加载的字体族(见 fonts.dart)
    fontFamily: kUiFontFamily,
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: LaresRadii.cardRadius),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
      ),
    ),
    textTheme: TextTheme(
      headlineMedium: TextStyle(
        color: textPrimary,
        fontSize: 28,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
      ),
      titleLarge: TextStyle(
        color: textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: TextStyle(color: textPrimary, fontSize: 16, height: 1.5),
      bodyMedium: TextStyle(color: textSecondary, fontSize: 14, height: 1.5),
      labelLarge: TextStyle(
        color: textPrimary,
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: brand,
        foregroundColor: _c(p.onBrand),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LaresRadii.md),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: LaresSpacing.lg,
          vertical: LaresSpacing.md,
        ),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    iconTheme: IconThemeData(color: textSecondary),
    dividerTheme: DividerThemeData(
      color: surfaceHigh,
      thickness: 1,
      space: 1,
    ),
  );
}

/// 渲染用字体族名。真机上跟随系统字体,这里必须显式加载,
/// 否则 flutter_test 默认字体会把所有字渲染成方框。
const String kUiFontFamily = 'LaresRenderUI';
