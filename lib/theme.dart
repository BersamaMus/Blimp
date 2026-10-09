import 'package:flutter/material.dart';

/// Blimp's palette: black surfaces with a yellow accent (the buttons,
/// highlights and the playing song).
abstract final class AppColors {
  static const background = Color(0xFF000000);
  static const surface = Color(0xFF0F0F0F);
  static const surfaceHigh = Color(0xFF1C1C1C);
  static const sheet = Color(0xFF141414);
  static const accent = Color(0xFFFACC15);

  /// Text and icons on the accent colour.
  static const onAccent = Color(0xFF1F1A00);

  /// Accent-tinted fill for secondary buttons and selected states.
  static const accentSoft = Color(0x2EFACC15);

  /// The playing song's row.
  static const accentFaint = Color(0x14FACC15);
  static const favourite = Color(0xFFFF6B8B);
  static const danger = Color(0xFFF05252);
  static const textSecondary = Color(0xFFADADAD);
  /// Hints and recessive labels: still 4.5:1 on the darkest surfaces, as
  /// small text needs.
  static const textTertiary = Color(0xFF858585);
  static const divider = Color(0x14FFFFFF);
  static const outline = Color(0x26FFFFFF);
}

/// Corner radii, from small list artwork up to the player's cover.
abstract final class AppRadius {
  static const art = 12.0;
  static const card = 16.0;
  static const large = 24.0;
}

ThemeData buildTheme() {
  final scheme = ColorScheme.dark(
    primary: AppColors.accent,
    onPrimary: AppColors.onAccent,
    secondary: AppColors.accent,
    onSecondary: AppColors.onAccent,
    surface: AppColors.background,
    onSurface: Colors.white,
    onSurfaceVariant: AppColors.textSecondary,
    surfaceContainerLowest: AppColors.background,
    surfaceContainerLow: AppColors.surface,
    surfaceContainer: AppColors.surface,
    surfaceContainerHigh: AppColors.surfaceHigh,
    surfaceContainerHighest: AppColors.surfaceHigh,
    outline: AppColors.outline,
    outlineVariant: AppColors.divider,
    error: AppColors.danger,
  );

  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  final text = base.textTheme.apply(bodyColor: Colors.white, displayColor: Colors.white);
  const stadium = StadiumBorder();
  RoundedRectangleBorder rounded(double r) => RoundedRectangleBorder(borderRadius: BorderRadius.circular(r));

  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    canvasColor: AppColors.background,
    textTheme: text.copyWith(
      displaySmall: text.displaySmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1),
      headlineMedium: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5),
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, fontSize: 20, letterSpacing: -0.2),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      bodyLarge: text.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
      bodyMedium: text.bodyMedium?.copyWith(color: AppColors.textSecondary),
      bodySmall: text.bodySmall?.copyWith(color: AppColors.textSecondary),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: Colors.white,
      titleTextStyle: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5, color: Colors.white),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.surfaceHigh,
      surfaceTintColor: Colors.transparent,
      indicatorColor: AppColors.accentSoft,
      indicatorShape: stadium,
      height: 64,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: states.contains(WidgetState.selected) ? AppColors.accent : AppColors.textSecondary,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 24,
          color: states.contains(WidgetState.selected) ? AppColors.accent : AppColors.textSecondary,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: AppColors.onAccent,
        shape: stadium,
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.accent,
        shape: stadium,
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.sheet,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: AppColors.textTertiary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.large))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.sheet,
      surfaceTintColor: Colors.transparent,
      shape: rounded(AppRadius.large),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.surfaceHigh,
      surfaceTintColor: Colors.transparent,
      shape: rounded(AppRadius.card),
      textStyle: const TextStyle(fontSize: 15, color: Colors.white),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: AppColors.accent,
      inactiveTrackColor: Color(0x26FFFFFF),
      thumbColor: Colors.white,
      overlayColor: AppColors.accent.withValues(alpha: 0.16),
      trackHeight: 4,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
      overlayShape: RoundSliderOverlayShape(overlayRadius: 16),
      trackShape: RoundedRectSliderTrackShape(),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? AppColors.onAccent : AppColors.textSecondary,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? AppColors.accent : AppColors.surfaceHigh,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    radioTheme: RadioThemeData(fillColor: WidgetStatePropertyAll(AppColors.accent)),
    listTileTheme: ListTileThemeData(
      iconColor: AppColors.textSecondary,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      shape: rounded(AppRadius.card),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.surfaceHigh,
      contentTextStyle: const TextStyle(color: Colors.white),
      actionTextColor: AppColors.accent,
      shape: rounded(AppRadius.card),
    ),
    tabBarTheme: TabBarThemeData(
      indicatorColor: AppColors.accent,
      labelColor: AppColors.accent,
      unselectedLabelColor: AppColors.textTertiary,
      dividerColor: AppColors.divider,
    ),
    dividerTheme: const DividerThemeData(color: AppColors.divider, space: 1),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: AppColors.accent),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: AppColors.accent,
      selectionHandleColor: AppColors.accent,
    ),
  );
}

/// A dark, slightly desaturated version of [color] for backgrounds tinted by
/// a cover, so white text stays readable on any artwork.
Color backdropColor(Color? color) {
  if (color == null) return AppColors.surfaceHigh;
  final hsl = HSLColor.fromColor(color);
  return hsl.withLightness(hsl.lightness.clamp(0.18, 0.32)).withSaturation(hsl.saturation.clamp(0.0, 0.6)).toColor();
}
