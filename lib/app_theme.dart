import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_haptics.dart';

abstract final class AppTheme {
  static final light = _theme(Brightness.light);
  static final dark = _theme(Brightness.dark);
  static const seedColors = <String, (String, Color)>{
    'coral': ('珊瑚红', Color(0xFFFF664F)),
    'orange': ('活力橙', Color(0xFFFF8200)),
    'blue': ('极光蓝', Color(0xFF1976D2)),
    'green': ('翡翠绿', Color(0xFF2E7D32)),
    'purple': ('优雅紫', Color(0xFF7B1FA2)),
    'pink': ('樱花粉', Color(0xFFE91E63)),
    'teal': ('青碧色', Color(0xFF00897B)),
    'slate': ('石板灰', Color(0xFF455A64)),
  };

  static ThemeData lightFor({
    String seed = 'coral',
    ColorScheme? dynamicScheme,
    int fontWeightAdjustment = 0,
  }) => _theme(Brightness.light, seed, dynamicScheme, fontWeightAdjustment);

  static ThemeData darkFor({
    String seed = 'coral',
    ColorScheme? dynamicScheme,
    int fontWeightAdjustment = 0,
  }) => _theme(Brightness.dark, seed, dynamicScheme, fontWeightAdjustment);

  static ThemeMode mode(String preference) => switch (preference) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static String label(String preference) => switch (preference) {
    'light' => '浅色',
    'dark' => '深色',
    _ => '跟随系统',
  };

  static SystemUiOverlayStyle systemBars(Brightness brightness) {
    final icons = brightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: icons,
      statusBarBrightness: brightness,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: icons,
      systemNavigationBarContrastEnforced: false,
    );
  }

  static FontWeight adjustWeight(FontWeight weight, int adjustment) {
    final index = (weight.value ~/ 100 - 1 + adjustment ~/ 100).clamp(0, 8);
    return FontWeight.values[index];
  }

  static TextTheme _adjustTextTheme(TextTheme theme, int adjustment) {
    TextStyle? adjust(TextStyle? style) => style?.copyWith(
      fontWeight: adjustWeight(style.fontWeight ?? FontWeight.w400, adjustment),
      letterSpacing: 0,
    );
    return theme.copyWith(
      displayLarge: adjust(theme.displayLarge),
      displayMedium: adjust(theme.displayMedium),
      displaySmall: adjust(theme.displaySmall),
      headlineLarge: adjust(theme.headlineLarge),
      headlineMedium: adjust(theme.headlineMedium),
      headlineSmall: adjust(theme.headlineSmall),
      titleLarge: adjust(theme.titleLarge),
      titleMedium: adjust(theme.titleMedium),
      titleSmall: adjust(theme.titleSmall),
      bodyLarge: adjust(theme.bodyLarge),
      bodyMedium: adjust(theme.bodyMedium),
      bodySmall: adjust(theme.bodySmall),
      labelLarge: adjust(theme.labelLarge),
      labelMedium: adjust(theme.labelMedium),
      labelSmall: adjust(theme.labelSmall),
    );
  }

  static ThemeData _theme(
    Brightness brightness, [
    String seed = 'coral',
    ColorScheme? dynamicScheme,
    int fontWeightAdjustment = 0,
  ]) {
    final dark = brightness == Brightness.dark;
    final scheme =
        dynamicScheme ??
        ColorScheme.fromSeed(
          seedColor: seedColors[seed]?.$2 ?? seedColors['coral']!.$2,
          brightness: brightness,
        );
    final background = scheme.surface;
    final typography = Typography.material2021();
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      splashFactory: const AppHapticSplashFactory(),
      textTheme: _adjustTextTheme(
        dark ? typography.white : typography.black,
        fontWeightAdjustment,
      ),
      scaffoldBackgroundColor: background,
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: scheme.onSurface,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        systemOverlayStyle: systemBars(brightness),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: background,
        useIndicator: false,
        selectedIconTheme: IconThemeData(color: scheme.primary),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
        selectedLabelTextStyle: TextStyle(
          color: scheme.primary,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainer,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
