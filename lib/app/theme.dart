import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

const _jpSansFallback = <String>[
  'Hiragino Sans',
  'Yu Gothic',
  'Meiryo',
  'Noto Sans CJK JP',
  'sans-serif',
];

const _jpSerifFallback = <String>[
  'Hiragino Mincho ProN',
  'Yu Mincho',
  'Noto Serif CJK JP',
  'serif',
];

// ── Claude warm skin-tone palette ────────────────────────────
abstract final class AppColors {
  static const bg = Color(0xFFF5EDE0); // warm parchment — scaffold bg
  static const cream = Color(0xFFFDF7ED); // soft cream — card surfaces
  static const surface2 = Color(0xFFEDE0C8); // deeper cream — sub-surfaces
  static const ink = Color(0xFF2E1D0E); // warm cocoa — primary text
  static const ink2 = Color(0xFF6B4E33); // secondary text
  static const ink3 = Color(0xFFA8896C); // muted / caption text
  static const clay = Color(0xFFCA6E44); // Claude clay-orange accent
  static const claySoft = Color(0xFFF5DCCA); // accent container
  static const clayInk = Color(0xFF7A3418); // on accent container
  static const line = Color(0xFFE0CCA8); // border
  static const line2 = Color(0xFFCEBA90); // stronger border
  static const sage = Color(0xFF8E9A60); // tertiary — "want" green
  static const deep = Color(0xFF2E1D0E); // hero card bg
  static const onDeep = Color(0xFFF5EBD8); // text on hero bg
  static const onDeepMt = Color(0xFFC4A07A); // muted text on hero bg
}

ThemeData buildAppTheme() {
  final base = ColorScheme.fromSeed(
    seedColor: AppColors.clay,
    brightness: Brightness.light,
  );

  final cs = base.copyWith(
    primary: AppColors.clay,
    onPrimary: Colors.white,
    primaryContainer: AppColors.claySoft,
    onPrimaryContainer: AppColors.clayInk,
    secondary: AppColors.ink2,
    onSecondary: Colors.white,
    secondaryContainer: AppColors.surface2,
    onSecondaryContainer: AppColors.ink,
    tertiary: AppColors.sage,
    onTertiary: Colors.white,
    tertiaryContainer: const Color(0xFFDFE8C0),
    onTertiaryContainer: AppColors.ink,
    surface: AppColors.cream,
    onSurface: AppColors.ink,
    surfaceContainerLowest: AppColors.bg,
    surfaceContainerLow: AppColors.bg,
    surfaceContainer: AppColors.surface2,
    surfaceContainerHigh: AppColors.surface2,
    surfaceContainerHighest: AppColors.surface2,
    onSurfaceVariant: AppColors.ink2,
    outline: AppColors.line,
    outlineVariant: AppColors.line2,
    scrim: Colors.black,
    shadow: Colors.black,
    inverseSurface: AppColors.ink,
    onInverseSurface: AppColors.bg,
    inversePrimary: const Color(0xFFFFB68A),
  );

  final baseTextTheme = ThemeData.light().textTheme;
  final textTheme = baseTextTheme
      .apply(bodyColor: AppColors.ink, displayColor: AppColors.ink)
      .copyWith(
        bodyLarge: _withJapaneseSans(baseTextTheme.bodyLarge),
        bodyMedium: _withJapaneseSans(baseTextTheme.bodyMedium),
        bodySmall: _withJapaneseSans(baseTextTheme.bodySmall),
        displayLarge: _withJapaneseSans(baseTextTheme.displayLarge),
        displayMedium: _withJapaneseSans(baseTextTheme.displayMedium),
        displaySmall: _withJapaneseSans(baseTextTheme.displaySmall),
        headlineLarge: _withJapaneseSans(baseTextTheme.headlineLarge),
        headlineMedium: _withJapaneseSans(baseTextTheme.headlineMedium),
        headlineSmall: _withJapaneseSans(baseTextTheme.headlineSmall),
        titleLarge: _withJapaneseSans(baseTextTheme.titleLarge),
        titleMedium: _withJapaneseSans(baseTextTheme.titleMedium),
        titleSmall: _withJapaneseSans(baseTextTheme.titleSmall),
        labelLarge: _withJapaneseSans(baseTextTheme.labelLarge),
        labelMedium: _withJapaneseSans(baseTextTheme.labelMedium),
        labelSmall: _withJapaneseSans(baseTextTheme.labelSmall),
      );

  return ThemeData(
    colorScheme: cs,
    scaffoldBackgroundColor: AppColors.bg,
    useMaterial3: true,
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.bg,
      foregroundColor: AppColors.ink,
      elevation: 0,
      centerTitle: false,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      color: AppColors.cream,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.line),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.cream,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.clay, width: 2),
      ),
      labelStyle: const TextStyle(color: AppColors.ink2),
      floatingLabelStyle: const TextStyle(color: AppColors.clay),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.clay,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.clay,
        side: const BorderSide(color: AppColors.line2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: AppColors.clay),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: AppColors.surface2,
      selectedColor: AppColors.claySoft,
      side: const BorderSide(color: AppColors.line),
      labelStyle: const TextStyle(color: AppColors.ink2, fontSize: 12),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.line, thickness: 1),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.cream,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 68,
      indicatorColor: AppColors.claySoft,
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return const IconThemeData(color: AppColors.clay, size: 22);
        }
        return const IconThemeData(color: AppColors.ink3, size: 22);
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return const TextStyle(
            color: AppColors.clay,
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
          );
        }
        return const TextStyle(color: AppColors.ink3, fontSize: 10.5);
      }),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.cream,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.line),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.cream,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: AppColors.clay,
      foregroundColor: Colors.white,
      elevation: 3,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return AppColors.clay;
        return AppColors.ink3;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return AppColors.claySoft;
        return AppColors.surface2;
      }),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return AppColors.clay;
        return null;
      }),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: AppColors.bg,
        selectedBackgroundColor: AppColors.claySoft,
        selectedForegroundColor: AppColors.clayInk,
        foregroundColor: AppColors.ink2,
        side: const BorderSide(color: AppColors.line),
      ),
    ),
  );
}

TextStyle? _withJapaneseSans(TextStyle? style) {
  return style?.copyWith(
    fontFamily: defaultTargetPlatform == TargetPlatform.macOS
        ? 'Hiragino Sans'
        : null,
    fontFamilyFallback: _jpSansFallback,
  );
}

TextStyle japaneseSerifTextStyle({
  TextStyle? base,
  double? fontSize,
  FontWeight? fontWeight,
  Color? color,
  double? height,
  double? letterSpacing,
}) {
  return (base ?? const TextStyle()).copyWith(
    fontFamily: defaultTargetPlatform == TargetPlatform.macOS
        ? 'Hiragino Mincho ProN'
        : null,
    fontFamilyFallback: _jpSerifFallback,
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    height: height,
    letterSpacing: letterSpacing,
  );
}
