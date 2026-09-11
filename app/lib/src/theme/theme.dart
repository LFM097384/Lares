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
    final scheme = ColorScheme(
      brightness: brightness,
      primary: LaresColors.ember,
      onPrimary: const Color(0xFF1A120C),
      secondary: LaresColors.statusEars,
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
