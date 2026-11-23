import 'package:flutter/material.dart';

/// App backgrounds. The native launch screens use the same colors (Android
/// res/values*/colors.xml, iOS LaunchBackground.colorset).
const codeawSurfaceLight = Color(0xFFFCFCFE);
const codeawSurfaceDark = Color(0xFF151820);

/// Corner radii, from tags to sheets. Nested shapes step down one size.
abstract final class CodeawRadii {
  /// Tags, badges and inline chips.
  static const xs = 6.0;

  /// Code, diffs and controls inside a card.
  static const sm = 8.0;

  /// Cards, tool rows, fields and buttons.
  static const md = 12.0;

  /// Panels and the files shared into a chat.
  static const lg = 16.0;

  /// Message bubbles, sheets and dialogs.
  static const xl = 24.0;
}

/// Status colors that read on both the light and the dark surfaces.
extension CodeawColors on ColorScheme {
  bool get _dark => brightness == Brightness.dark;

  /// Done, allowed, added.
  Color get success => _dark ? const Color(0xFF5BD28A) : const Color(0xFF1B8044);

  /// Waiting for the user: approvals and questions.
  Color get warning => _dark ? const Color(0xFFF4AE4A) : const Color(0xFFB45A09);

  /// The user's own messages.
  Color get userBubble => _dark ? const Color(0xFF30355A) : primaryContainer;
}

/// Material's type scale adds up to 0.5 px between letters. The platform fonts
/// are already spaced for reading, and Chinese text looks split apart with more.
TextTheme _untracked(TextTheme t) {
  TextStyle? plain(TextStyle? style) => style?.copyWith(letterSpacing: 0);
  return TextTheme(
    displayLarge: plain(t.displayLarge),
    displayMedium: plain(t.displayMedium),
    displaySmall: plain(t.displaySmall),
    headlineLarge: plain(t.headlineLarge),
    headlineMedium: plain(t.headlineMedium),
    headlineSmall: plain(t.headlineSmall),
    titleLarge: plain(t.titleLarge),
    titleMedium: plain(t.titleMedium),
    titleSmall: plain(t.titleSmall),
    bodyLarge: plain(t.bodyLarge),
    bodyMedium: plain(t.bodyMedium),
    bodySmall: plain(t.bodySmall),
    labelLarge: plain(t.labelLarge),
    labelMedium: plain(t.labelMedium),
    labelSmall: plain(t.labelSmall),
  );
}

/// Shared neutral surfaces and restrained indigo accents, for all app screens.
///
/// [fontFamily] and [fontFamilyFallback] override the platform fonts (the
/// screenshot test loads its own).
ThemeData codeawTheme(
  Brightness brightness, {
  String? fontFamily,
  List<String>? fontFamilyFallback,
}) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF5964E8),
        brightness: brightness,
      ).copyWith(
        surface: dark ? codeawSurfaceDark : codeawSurfaceLight,
        surfaceDim: dark ? const Color(0xFF101218) : const Color(0xFFDCDFE8),
        surfaceBright: dark ? const Color(0xFF2B303F) : Colors.white,
        surfaceContainerLowest: dark ? const Color(0xFF101218) : Colors.white,
        surfaceContainerLow: dark
            ? const Color(0xFF1A1D27)
            : const Color(0xFFF5F6FA),
        surfaceContainer: dark
            ? const Color(0xFF1F2330)
            : const Color(0xFFEEF0F6),
        surfaceContainerHigh: dark
            ? const Color(0xFF262B39)
            : const Color(0xFFE8EBF3),
        surfaceContainerHighest: dark
            ? const Color(0xFF2E3444)
            : const Color(0xFFE1E5EE),
        // Cool neutrals for secondary text and lines, matching the surfaces.
        onSurfaceVariant: dark
            ? const Color(0xFFC3C7D4)
            : const Color(0xFF454857),
        outline: dark ? const Color(0xFF8B91A3) : const Color(0xFF737786),
        outlineVariant: dark
            ? const Color(0xFF313748)
            : const Color(0xFFDDE1EC),
      );
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
  );
  final text = _untracked(base.textTheme);
  RoundedRectangleBorder rounded(double radius) =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));
  OutlineInputBorder field(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(CodeawRadii.md),
        borderSide: BorderSide(color: color, width: width),
      );
  const buttonPadding = EdgeInsets.symmetric(horizontal: 18, vertical: 10);
  const buttonSize = Size(64, 42);
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    primaryTextTheme: _untracked(base.primaryTextTheme),
    textTheme: text.copyWith(
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      bodyLarge: text.bodyLarge?.copyWith(height: 1.45),
      bodyMedium: text.bodyMedium?.copyWith(height: 1.45),
      labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      labelMedium: text.labelMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      iconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 22),
      actionsIconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 22),
      titleTextStyle: text.titleLarge?.copyWith(
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
    ),
    iconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 22),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: dark ? .8 : .7),
      thickness: .7,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      hintStyle: TextStyle(color: scheme.outline),
      border: field(scheme.outlineVariant),
      enabledBorder: field(scheme.outlineVariant),
      disabledBorder: field(scheme.outlineVariant.withValues(alpha: .5)),
      focusedBorder: field(scheme.primary, 1.5),
      errorBorder: field(scheme.error),
      focusedErrorBorder: field(scheme.error, 1.5),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: rounded(CodeawRadii.md),
        elevation: 0,
        minimumSize: buttonSize,
        padding: buttonPadding,
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: rounded(CodeawRadii.md),
        minimumSize: buttonSize,
        padding: buttonPadding,
        side: BorderSide(color: scheme.outlineVariant),
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: rounded(CodeawRadii.sm),
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: scheme.secondaryContainer,
        selectedForegroundColor: scheme.onSecondaryContainer,
        side: BorderSide(color: scheme.outlineVariant),
        shape: rounded(CodeawRadii.md),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      elevation: 3,
      focusElevation: 3,
      hoverElevation: 4,
      highlightElevation: 2,
      shape: rounded(CodeawRadii.lg),
      extendedTextStyle: text.labelLarge?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      minLeadingWidth: 24,
      subtitleTextStyle: text.bodyMedium?.copyWith(
        fontSize: 13,
        height: 1.4,
        color: scheme.onSurfaceVariant,
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: const StadiumBorder(),
      // Per-state colors, so a chip's own backgroundColor still wins.
      selectedColor: scheme.secondaryContainer,
      side: WidgetStateBorderSide.resolveWith(
        (states) => BorderSide(
          color: states.contains(WidgetState.selected)
              ? Colors.transparent
              : scheme.outlineVariant,
        ),
      ),
      labelStyle: text.labelLarge?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: rounded(CodeawRadii.md),
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: text.bodyMedium?.copyWith(
        color: scheme.onInverseSurface,
        height: 1.4,
      ),
      actionTextColor: scheme.inversePrimary,
      elevation: 4,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: scheme.inverseSurface.withValues(alpha: .94),
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: text.bodySmall?.copyWith(color: scheme.onInverseSurface),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      modalBackgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      modalElevation: 0,
      dragHandleColor: scheme.outline.withValues(alpha: .45),
      dragHandleSize: const Size(36, 4),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(CodeawRadii.xl),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: rounded(CodeawRadii.xl),
      titleTextStyle: text.titleLarge?.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      contentTextStyle: text.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
        height: 1.5,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 3,
      shape: rounded(CodeawRadii.md),
      menuPadding: const EdgeInsets.symmetric(vertical: 6),
      textStyle: text.bodyLarge?.copyWith(fontSize: 15, color: scheme.onSurface),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: scheme.secondaryContainer,
      selectedIconTheme: IconThemeData(color: scheme.onSecondaryContainer),
      unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      selectedLabelTextStyle: text.labelMedium?.copyWith(
        color: scheme.onSurface,
      ),
      unselectedLabelTextStyle: text.labelMedium?.copyWith(
        color: scheme.onSurfaceVariant,
        fontWeight: FontWeight.w500,
      ),
    ),
    switchTheme: SwitchThemeData(
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.transparent
            : scheme.outline.withValues(alpha: .6),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.surfaceContainerHighest,
      circularTrackColor: Colors.transparent,
    ),
    scrollbarTheme: ScrollbarThemeData(
      radius: const Radius.circular(8),
      thickness: const WidgetStatePropertyAll(4),
      thumbColor: WidgetStatePropertyAll(scheme.outline.withValues(alpha: .4)),
    ),
  );
}
