import 'package:flutter/material.dart';

/// Palette ported from the webapp (`src/styles/theme.ts`): dark background with the
/// LaWallet green accent.
class AppColors {
  static const background = Color(0xFF1C1C1C);
  static const surface = Color(0xFF272727);
  static const primary = Color(0xFF56B68C);
  static const error = Color(0xFFE95053);
  static const onDark = Color(0xFFFFFFFF);
  static const muted = Color(0xFF9A9A9A);
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.primary,
    brightness: Brightness.dark,
  ).copyWith(
    primary: AppColors.primary,
    surface: AppColors.surface,
    error: AppColors.error,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(56), // large POS touch targets
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
    ),
  );
}
