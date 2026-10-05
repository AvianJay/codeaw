import 'package:flutter/material.dart';

/// Shared neutral surfaces and restrained indigo accents, for all app screens.
ThemeData codeawTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF5964E8),
        brightness: brightness,
      ).copyWith(
        surface: dark ? const Color(0xFF151820) : const Color(0xFFFCFCFE),
        surfaceContainerLowest: dark ? const Color(0xFF101218) : Colors.white,
        surfaceContainerLow: dark
            ? const Color(0xFF1A1D27)
            : const Color(0xFFF5F6FA),
        surfaceContainer: dark
            ? const Color(0xFF202431)
            : const Color(0xFFEEF0F6),
        surfaceContainerHigh: dark
            ? const Color(0xFF272C3A)
            : const Color(0xFFE8EBF3),
        surfaceContainerHighest: dark
            ? const Color(0xFF303646)
            : const Color(0xFFE1E5EE),
        outlineVariant: dark
            ? const Color(0xFF343A4B)
            : const Color(0xFFDDE1EC),
      );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  final rounded = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(14),
  );
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
    ),
    iconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 22),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: .65),
      thickness: .7,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: rounded,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(shape: rounded),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      elevation: 2,
      shape: rounded,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 3),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: const StadiumBorder(),
      side: BorderSide(color: scheme.outlineVariant),
      labelStyle: base.textTheme.labelMedium,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: rounded,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.surfaceContainerHighest,
    ),
    textTheme: base.textTheme.copyWith(
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
      ),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.45),
      labelLarge: base.textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
