import 'package:flutter/material.dart';

import 'tokens.dart';

/// 由 token 构建明暗两套主题。暗色为默认(见 LaresApp)。
abstract final class LaresTheme {
  static ThemeData dark() => _base(
        brightness: Brightness.dark,
        bg: LaresColors.bgDark,
        surface: LaresColors.surfaceDark,
        surfaceHigh: LaresColors.surfaceHighDark,
        textPrimary: LaresColors.textPrimaryDark,
        textSecondary: LaresColors.textSecondaryDark,
      );

  static ThemeData light() => _base(
        brightness: Brightness.light,
        bg: LaresColors.bgLight,
        surface: LaresColors.surfaceLight,
        surfaceHigh: LaresColors.surfaceHighLight,
        textPrimary: LaresColors.textPrimaryLight,
        textSecondary: LaresColors.textSecondaryLight,
      );

  static ThemeData _base({
    required Brightness brightness,
    required Color bg,
    required Color surface,
    required Color surfaceHigh,
    required Color textPrimary,
    required Color textSecondary,
  }) {
    // ⚠️ 这里每一项都必须显式给值。曾经的 bug:只给了 secondary 而漏掉
    // secondaryContainer,Flutter 的 ColorScheme 会**静默回退**
    // (SDK color_scheme.dart:`_secondaryContainer ?? secondary`),
    // 于是 IconButton.filledTonal 和 SegmentedButton 选中态一起吃到了
    // secondary 的值 —— 而 secondary 当时被赋成 statusEars(presence 蓝)。
    // 结果:挂断键是浅蓝的、底部切换器是亮蓝描边的,而品牌色一次都没出现。
    // 一个 token 缺口同时毁掉两处视觉,且没有任何报错。
    //
    // 另一条纪律:**presence 状态色不得进 ColorScheme**。
    // 那四个色(随时聊/在忙/耳朵在/有事先走)是「人的状态」的语义色,
    // 一旦进了 scheme 就会被 Material 组件在无关场景里拿去用。
    final scheme = ColorScheme(
      brightness: brightness,
      // 主色 = 品牌余烬橙。全屏唯一的实心色块(主按钮)靠它。
      primary: LaresColors.ember,
      onPrimary: const Color(0xFF1A120C),
      primaryContainer: LaresColors.emberSoft,
      onPrimaryContainer: LaresColors.ember,
      // 次色 = 同族暖色的低饱和版,不是另一个色相。
      // 用暖中性而非蓝:次要按钮应当"退后"而不是"另起一个话题"。
      secondary: surfaceHigh,
      onSecondary: textPrimary,
      secondaryContainer: surfaceHigh,
      onSecondaryContainer: textPrimary,
      tertiary: LaresColors.ember,
      onTertiary: const Color(0xFF1A120C),
      error: const Color(0xFFE06C6C),
      onError: textPrimary,
      errorContainer: const Color(0xFF3B1F1F),
      onErrorContainer: const Color(0xFFE06C6C),
      surface: surface,
      onSurface: textPrimary,
      surfaceContainerHighest: surfaceHigh,
      onSurfaceVariant: textSecondary,
      outline: textSecondary,
      outlineVariant: surfaceHigh,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      splashFactory: InkSparkle.splashFactory,
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
          backgroundColor: LaresColors.ember,
          foregroundColor: const Color(0xFF1A120C),
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
}
