import 'package:flutter/material.dart';

ThemeData buildAppTheme() {
  const seed = Color(0xFF1E847F);

  final colorScheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: Brightness.light,
    surface: const Color(0xFFF6F4EE),
  );

  return ThemeData(
    colorScheme: colorScheme,
    scaffoldBackgroundColor: const Color(0xFFF6F4EE),
    useMaterial3: true,
    appBarTheme: AppBarTheme(
      backgroundColor: colorScheme.surface,
      foregroundColor: colorScheme.onSurface,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    ),
  );
}
