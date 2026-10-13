import 'package:flutter/material.dart';

/// AppleCast Design System & Theme
/// Designed for a premium dark desktop studio aesthetic with high-contrast streaming monitors.
class AppleCastTheme {
  AppleCastTheme._();

  // Color Palette
  static const Color darkBackground = Color(0xFF0F1117);
  static const Color darkSurface = Color(0xFF181B22);
  static const Color darkSurfaceElevated = Color(0xFF222631);
  static const Color darkBorder = Color(0xFF2C3240);

  static const Color appleBlue = Color(0xFF0A84FF);
  static const Color appleGreen = Color(0xFF30D158);
  static const Color appleYellow = Color(0xFFFFD60A);
  static const Color appleRed = Color(0xFFFF453A);
  static const Color applePurple = Color(0xFFBF5AF2);

  static const Color textPrimary = Color(0xFFF5F7FA);
  static const Color textSecondary = Color(0xFF8E95A5);
  static const Color textMuted = Color(0xFF5E6575);

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: darkBackground,
      colorScheme: const ColorScheme.dark(
        primary: appleBlue,
        secondary: appleGreen,
        surface: darkSurface,
        error: appleRed,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: textPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: darkSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
        ),
      ),
      cardTheme: CardThemeData(
        color: darkSurfaceElevated,
        elevation: 0,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: darkBorder, width: 1),
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: darkBorder,
        thickness: 1,
        space: 1,
      ),
      textTheme: const TextTheme(
        headlineMedium: TextStyle(
          color: textPrimary,
          fontSize: 24,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
        titleMedium: TextStyle(
          color: textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
        bodyMedium: TextStyle(
          color: textSecondary,
          fontSize: 14,
        ),
        bodySmall: TextStyle(
          color: textMuted,
          fontSize: 12,
        ),
      ),
    );
  }
}
