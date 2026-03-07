// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import 'color_schemes.dart';

/// Material 3 theme builder. Inter for UI text, JetBrains Mono for
/// technical/data labels via the helpers below.
class AppTheme {
  AppTheme._();

  // Helper functions for local fonts
  static TextStyle _inter({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? letterSpacing,
    double? height,
  }) =>
      TextStyle(
        fontFamily: 'Inter',
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
        letterSpacing: letterSpacing,
        height: height,
      );

  static TextStyle _jetBrainsMono({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? letterSpacing,
    double? height,
  }) =>
      TextStyle(
        fontFamily: 'JetBrainsMono',
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
        letterSpacing: letterSpacing,
        height: height,
      );

  // ---------------------------------------------------------------------------
  // Light theme
  // ---------------------------------------------------------------------------

  static ThemeData get light => _build(ColorSchemes.light);

  // ---------------------------------------------------------------------------
  // Dark theme
  // ---------------------------------------------------------------------------

  static ThemeData get dark => _build(ColorSchemes.dark);

  // ---------------------------------------------------------------------------
  // Builder
  // ---------------------------------------------------------------------------

  static ThemeData _build(ColorScheme cs) {
    return ThemeData(
      useMaterial3: true,
      brightness: cs.brightness,
      colorScheme: cs,
      scaffoldBackgroundColor: cs.surface,
      canvasColor: cs.surface,
      textTheme: _textTheme(cs),
      appBarTheme: _appBarTheme(cs),
      cardTheme: _cardTheme(cs),
      navigationRailTheme: _navRailTheme(cs),
      navigationBarTheme: _navBarTheme(cs),
      inputDecorationTheme: _inputTheme(cs),
      elevatedButtonTheme: _elevatedButtonTheme(cs),
      filledButtonTheme: _filledButtonTheme(cs),
      outlinedButtonTheme: _outlinedButtonTheme(cs),
      textButtonTheme: _textButtonTheme(cs),
      chipTheme: _chipTheme(cs),
      switchTheme: _switchTheme(cs),
      dividerTheme: DividerThemeData(
        color: cs.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        backgroundColor: cs.surfaceContainerHigh,
        contentTextStyle: _inter(color: cs.onSurface),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        backgroundColor: cs.surfaceContainer,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: cs.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      iconTheme: IconThemeData(color: cs.onSurface, size: 22),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cs.outlineVariant),
        ),
        textStyle: _inter(color: cs.onSurface, fontSize: 12),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Typography
  // ---------------------------------------------------------------------------

  /// Bold display (28/800 -0.6ls) used by the Sign / Verify / Identity titles.
  static TextStyle displayBold(ColorScheme cs) => _inter(
        color: cs.onSurface,
        fontSize: 28,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.6,
        height: 1.15,
      );

  /// Headline 26/800 used in section heroes.
  static TextStyle headlineBold(ColorScheme cs) => _inter(
        color: cs.onSurface,
        fontSize: 26,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.4,
        height: 1.2,
      );

  /// Mono caption 11/0.4ls — "RAPPORTO DI VERIFICA", "FIRMA · 1 / 4", etc.
  static TextStyle monoCaption(ColorScheme cs, {Color? color}) =>
      _jetBrainsMono(
        color: color ?? cs.onSurfaceVariant,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
        height: 1.2,
      );

  /// Mono body 12 — diagnostics rows, paths, hashes.
  static TextStyle monoBody(ColorScheme cs, {Color? color}) =>
      _jetBrainsMono(
        color: color ?? cs.onSurface,
        fontSize: 12,
        fontWeight: FontWeight.w500,
        height: 1.4,
      );

  /// Mono label 10/0.6ls — settings section captions ("AUTORITÀ DI MARCATURA").
  static TextStyle monoSection(ColorScheme cs, {Color? color}) =>
      _jetBrainsMono(
        color: color ?? cs.onSurfaceVariant,
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.4,
      );

  // ---------------------------------------------------------------------------
  // Component themes
  // ---------------------------------------------------------------------------

  static TextTheme _textTheme(ColorScheme cs) {
    return TextTheme(
      displayLarge: _inter(
          color: cs.onSurface, fontWeight: FontWeight.w800, letterSpacing: -0.8),
      displayMedium: _inter(
          color: cs.onSurface, fontWeight: FontWeight.w800, letterSpacing: -0.6),
      displaySmall: _inter(
          color: cs.onSurface, fontWeight: FontWeight.w700, letterSpacing: -0.4),
      headlineLarge: _inter(
          color: cs.onSurface, fontWeight: FontWeight.w700, letterSpacing: -0.2),
      headlineMedium: _inter(
          color: cs.onSurface, fontWeight: FontWeight.w700),
      headlineSmall: _inter(
          color: cs.onSurface, fontWeight: FontWeight.w600),
      titleLarge: _inter(
          color: cs.onSurface, fontWeight: FontWeight.w700, fontSize: 18),
      titleMedium: _inter(
          color: cs.onSurface, fontWeight: FontWeight.w600, fontSize: 15),
      titleSmall: _inter(
          color: cs.onSurface, fontWeight: FontWeight.w600, fontSize: 13),
      bodyLarge: _inter(color: cs.onSurface, fontSize: 15),
      bodyMedium: _inter(color: cs.onSurface, fontSize: 14),
      bodySmall: _inter(color: cs.onSurfaceVariant, fontSize: 12),
      labelLarge: _inter(
          color: cs.onSurface, fontWeight: FontWeight.w600, fontSize: 14),
      labelMedium: _inter(
          color: cs.onSurface, fontWeight: FontWeight.w500, fontSize: 12),
      labelSmall: _inter(
          color: cs.onSurfaceVariant, fontWeight: FontWeight.w500, fontSize: 11),
    );
  }

  static AppBarTheme _appBarTheme(ColorScheme cs) => AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: cs.surface,
        foregroundColor: cs.onSurface,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: _inter(
          color: cs.onSurface,
          fontWeight: FontWeight.w700,
          fontSize: 17,
        ),
      );

  static CardThemeData _cardTheme(ColorScheme cs) => CardThemeData(
        elevation: 0,
        color: cs.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: cs.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
      );

  static NavigationRailThemeData _navRailTheme(ColorScheme cs) =>
      NavigationRailThemeData(
        backgroundColor: cs.surface,
        indicatorColor: cs.surfaceContainerHigh,
        useIndicator: true,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        selectedIconTheme: IconThemeData(color: cs.primary, size: 22),
        unselectedIconTheme:
            IconThemeData(color: cs.onSurfaceVariant, size: 22),
        selectedLabelTextStyle: _inter(
          color: cs.onSurface,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
        unselectedLabelTextStyle: _inter(
          color: cs.onSurfaceVariant,
          fontSize: 12,
        ),
      );

  static NavigationBarThemeData _navBarTheme(ColorScheme cs) =>
      NavigationBarThemeData(
        backgroundColor: cs.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        indicatorColor: cs.surfaceContainerHigh,
        elevation: 0,
        height: 72,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return _inter(
            color: selected ? cs.onSurface : cs.onSurfaceVariant,
            fontSize: 11,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? cs.primary : cs.onSurfaceVariant,
            size: 22,
          );
        }),
      );

  static InputDecorationTheme _inputTheme(ColorScheme cs) =>
      InputDecorationTheme(
        filled: true,
        fillColor: cs.surfaceContainer,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cs.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cs.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cs.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cs.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cs.error, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      );

  static ElevatedButtonThemeData _elevatedButtonTheme(ColorScheme cs) =>
      ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: _inter(
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
      );

  static FilledButtonThemeData _filledButtonTheme(ColorScheme cs) =>
      FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: cs.primary,
          foregroundColor: cs.onPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: _inter(
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
      );

  static OutlinedButtonThemeData _outlinedButtonTheme(ColorScheme cs) =>
      OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: cs.onSurface,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
          side: BorderSide(color: cs.outlineVariant),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: _inter(
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
      );

  static TextButtonThemeData _textButtonTheme(ColorScheme cs) =>
      TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: cs.primary,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: _inter(
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
      );

  static ChipThemeData _chipTheme(ColorScheme cs) => ChipThemeData(
        backgroundColor: cs.surfaceContainerHigh,
        selectedColor: cs.primary.withValues(alpha: 0.18),
        labelStyle: _inter(
          color: cs.onSurface,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
        side: BorderSide(color: cs.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      );

  static SwitchThemeData _switchTheme(ColorScheme cs) => SwitchThemeData(
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.transparent;
          return cs.outlineVariant;
        }),
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.white;
          return cs.onSurfaceVariant;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return cs.primary;
          return cs.surfaceContainerHigh;
        }),
      );
}
