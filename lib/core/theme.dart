import 'package:flutter/material.dart';

import 'sounds.dart';

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

  final theme = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        enableFeedback: false,
        minimumSize: const Size.fromHeight(74), // large POS touch targets (+15%)
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        enableFeedback: false,
        minimumSize: const Size.fromHeight(69),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        enableFeedback: false,
        minimumSize: const Size.fromHeight(52),
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(enableFeedback: false),
    ),
    listTileTheme: const ListTileThemeData(enableFeedback: false),
  );
  // Every InkWell and Material button splashes on press, including the numpad
  // and the hub cards. One factory covers them without wiring each onTap.
  return theme.copyWith(splashFactory: _ButtonSoundSplash(theme.splashFactory));
}

class _ButtonSoundSplash extends InteractiveInkFeatureFactory {
  const _ButtonSoundSplash(this._delegate);

  final InteractiveInkFeatureFactory _delegate;

  @override
  InteractiveInkFeature create({
    required MaterialInkController controller,
    required RenderBox referenceBox,
    required Offset position,
    required Color color,
    required TextDirection textDirection,
    bool containedInkWell = false,
    RectCallback? rectCallback,
    BorderRadius? borderRadius,
    ShapeBorder? customBorder,
    double? radius,
    VoidCallback? onRemoved,
  }) {
    AppSounds.play(AppSound.button);
    return _delegate.create(
      controller: controller,
      referenceBox: referenceBox,
      position: position,
      color: color,
      textDirection: textDirection,
      containedInkWell: containedInkWell,
      rectCallback: rectCallback,
      borderRadius: borderRadius,
      customBorder: customBorder,
      radius: radius,
      onRemoved: onRemoved,
    );
  }
}
