// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

/// Color scheme tokens for the app theme.
///
/// Exposes [OcColors] for direct gradient/accent use and [ColorSchemes]
/// for Material 3 light/dark `ColorScheme` instances.
class ColorSchemes {
  ColorSchemes._();

  // ---------------------------------------------------------------------------
  // Dark palette
  // ---------------------------------------------------------------------------

  static const _darkBg = Color(0xFF0F1115);
  static const _darkSurface = Color(0xFF181A21);
  static const _darkSurfaceHi = Color(0xFF21242D);
  static const _darkBorder = Color(0x14FFFFFF); // ~ rgba(255,255,255,0.08)
  static const _darkText = Color(0xFFF5F6F8);
  static const _darkTextSoft = Color(0xFF9097A6);

  // ---------------------------------------------------------------------------
  // Light palette
  // ---------------------------------------------------------------------------

  static const _lightBg = Color(0xFFF7F8FB);
  static const _lightSurface = Color(0xFFFFFFFF);
  static const _lightSurfaceHi = Color(0xFFF0F2F7);
  static const _lightBorder = Color(0x14111827); // ~ rgba(17,24,39,0.08)
  static const _lightText = Color(0xFF111827);
  static const _lightTextSoft = Color(0xFF5B6172);

  // ---------------------------------------------------------------------------
  // Brand accents (shared across modes)
  // ---------------------------------------------------------------------------

  /// Primary brand blue.
  static const primary = Color(0xFF5B9DFF);

  /// Deep blue for gradients and accents.
  static const primaryDeep = Color(0xFF1A4B8E);

  /// Teal accent.
  static const teal = Color(0xFF00897B);

  /// Warm orange accent.
  static const accent = Color(0xFFFFAB40);

  /// Valid signature green.
  static const valid = Color(0xFF5DD993);

  /// Invalid signature red.
  static const invalid = Color(0xFFFF6B6B);

  /// Gradient ramp for the primary CTA and NFC chip.
  static const ctaGradient = [primary, Color(0xFF3F7BD9)];
  static const chipGradient = [primary, primaryDeep];
  static const cieCardGradient = [Color(0xFF0D2B55), primaryDeep, teal];
  static const cieChipGradient = [Color(0xFFFFD600), Color(0xFFFF6F00)];

  // ---------------------------------------------------------------------------
  // Material ColorScheme — dark
  // ---------------------------------------------------------------------------

  static final dark = ColorScheme(
    brightness: Brightness.dark,
    primary: primary,
    onPrimary: const Color(0xFF071025),
    primaryContainer: primaryDeep,
    onPrimaryContainer: _darkText,
    secondary: teal,
    onSecondary: Colors.white,
    secondaryContainer: const Color(0xFF003731),
    onSecondaryContainer: _darkText,
    tertiary: accent,
    onTertiary: const Color(0xFF4E2600),
    tertiaryContainer: const Color(0xFF6E3B00),
    onTertiaryContainer: _darkText,
    error: invalid,
    onError: const Color(0xFF300505),
    errorContainer: const Color(0xFF60181A),
    onErrorContainer: _darkText,
    surface: _darkBg,
    onSurface: _darkText,
    onSurfaceVariant: _darkTextSoft,
    surfaceContainerLowest: const Color(0xFF0A0C10),
    surfaceContainerLow: const Color(0xFF13161B),
    surfaceContainer: _darkSurface,
    surfaceContainerHigh: _darkSurfaceHi,
    surfaceContainerHighest: const Color(0xFF2A2D36),
    inverseSurface: _lightBg,
    onInverseSurface: _lightText,
    inversePrimary: primaryDeep,
    outline: _darkBorder,
    outlineVariant: _darkBorder,
    shadow: Colors.black,
    scrim: Colors.black54,
    surfaceTint: primary,
  );

  // ---------------------------------------------------------------------------
  // Material ColorScheme — light
  // ---------------------------------------------------------------------------

  static final light = ColorScheme(
    brightness: Brightness.light,
    primary: primary,
    onPrimary: Colors.white,
    primaryContainer: const Color(0xFFE3EEFF),
    onPrimaryContainer: primaryDeep,
    secondary: teal,
    onSecondary: Colors.white,
    secondaryContainer: const Color(0xFFCDEEEA),
    onSecondaryContainer: const Color(0xFF003731),
    tertiary: const Color(0xFFE65100),
    onTertiary: Colors.white,
    tertiaryContainer: const Color(0xFFFFE0B2),
    onTertiaryContainer: const Color(0xFF4E2600),
    error: const Color(0xFFC62828),
    onError: Colors.white,
    errorContainer: const Color(0xFFFFE6E6),
    onErrorContainer: const Color(0xFF690005),
    surface: _lightBg,
    onSurface: _lightText,
    onSurfaceVariant: _lightTextSoft,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: _lightSurface,
    surfaceContainer: _lightSurface,
    surfaceContainerHigh: _lightSurfaceHi,
    surfaceContainerHighest: const Color(0xFFE7E9EF),
    inverseSurface: _darkBg,
    onInverseSurface: _darkText,
    inversePrimary: const Color(0xFFB7CDF7),
    outline: _lightBorder,
    outlineVariant: _lightBorder,
    shadow: Colors.black,
    scrim: Colors.black54,
    surfaceTint: primary,
  );

}
