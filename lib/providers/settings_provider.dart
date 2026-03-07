// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/enrolled_card.dart';
import '../models/proxy_config.dart';
import '../models/signature_options.dart';
import '../models/tsa_config.dart';

/// Sentinel object used to distinguish "explicitly pass null" from "omitted"
/// in [AppSettings.copyWith].
const _unset = Object();

/// Application settings state.
class AppSettings {
  const AppSettings({
    this.locale = 'it',
    this.defaultPdfFormat = SignatureFormat.pades,
    this.defaultXmlFormat = SignatureFormat.xades,
    this.graphicPades = false,
    this.includeDate = true,
    this.includeLocation = false,
    this.includeReason = false,
    this.preservePdfA = false,
    this.alwaysTimestamp = false,
    this.openFolderAfterSign = true,
    this.destinationFolder,
    this.tsaConfig = const TsaConfig(),
    this.proxyConfig = const ProxyConfig(),
    this.validationType = ValidationType.ocspFirst,
    this.logLevel = LogLevel.off,
    this.enrolledCards = const [],
    this.uiScale = 1.0,
    this.themeMode = ThemeMode.system,
    this.oidcIssuer = 'https://idp.example/',
    this.oidcClientId = 'opencie-client',
    this.isLoaded = false,
  });

  final String locale;
  final SignatureFormat defaultPdfFormat;
  final SignatureFormat defaultXmlFormat;
  final bool graphicPades;
  final bool includeDate;
  final bool includeLocation;
  final bool includeReason;
  final bool preservePdfA;
  final bool alwaysTimestamp;
  final bool openFolderAfterSign;
  final String? destinationFolder;
  final TsaConfig tsaConfig;
  final ProxyConfig proxyConfig;
  final ValidationType validationType;
  final LogLevel logLevel;

  final List<EnrolledCard> enrolledCards;

  final double uiScale;
  final ThemeMode themeMode;
  final String oidcIssuer;
  final String oidcClientId;

  final bool isLoaded;

  bool get isEnrolled => enrolledCards.isNotEmpty;

  AppSettings copyWith({
    String? locale,
    SignatureFormat? defaultPdfFormat,
    SignatureFormat? defaultXmlFormat,
    bool? graphicPades,
    bool? includeDate,
    bool? includeLocation,
    bool? includeReason,
    bool? preservePdfA,
    bool? alwaysTimestamp,
    bool? openFolderAfterSign,
    // Use the [_unset] sentinel to allow clearing back to null:
    //   copyWith(destinationFolder: null)        → keeps existing value
    //   copyWith(destinationFolder: _unset)      → sets to null
    //   copyWith(destinationFolder: '/some/path') → sets to that path
    Object? destinationFolder = _unset,
    TsaConfig? tsaConfig,
    ProxyConfig? proxyConfig,
    ValidationType? validationType,
    LogLevel? logLevel,
    List<EnrolledCard>? enrolledCards,
    double? uiScale,
    ThemeMode? themeMode,
    String? oidcIssuer,
    String? oidcClientId,
    bool? isLoaded,
  }) {
    return AppSettings(
      locale: locale ?? this.locale,
      defaultPdfFormat: defaultPdfFormat ?? this.defaultPdfFormat,
      defaultXmlFormat: defaultXmlFormat ?? this.defaultXmlFormat,
      graphicPades: graphicPades ?? this.graphicPades,
      includeDate: includeDate ?? this.includeDate,
      includeLocation: includeLocation ?? this.includeLocation,
      includeReason: includeReason ?? this.includeReason,
      preservePdfA: preservePdfA ?? this.preservePdfA,
      alwaysTimestamp: alwaysTimestamp ?? this.alwaysTimestamp,
      openFolderAfterSign: openFolderAfterSign ?? this.openFolderAfterSign,
      destinationFolder: identical(destinationFolder, _unset)
          ? this.destinationFolder
          : destinationFolder as String?,
      tsaConfig: tsaConfig ?? this.tsaConfig,
      proxyConfig: proxyConfig ?? this.proxyConfig,
      validationType: validationType ?? this.validationType,
      logLevel: logLevel ?? this.logLevel,
      enrolledCards: enrolledCards ?? this.enrolledCards,
      uiScale: uiScale ?? this.uiScale,
      themeMode: themeMode ?? this.themeMode,
      oidcIssuer: oidcIssuer ?? this.oidcIssuer,
      oidcClientId: oidcClientId ?? this.oidcClientId,
      isLoaded: isLoaded ?? this.isLoaded,
    );
  }
}

enum ValidationType {
  ocspOnly,
  ocspFirst,
  crlOnly,
  crlFirst,
}

enum LogLevel {
  off,
  standard,
  debug,
}

List<EnrolledCard> _parseEnrolledCards(Map<String, dynamic> map) {
  final raw = map['enrolledCards'];
  if (raw is List) {
    return raw
        .whereType<Map<String, dynamic>>()
        .map(EnrolledCard.fromJson)
        .where((c) => c.pan.isNotEmpty)
        .toList();
  }
  final legacy = map['enrolledPan'] as String?;
  if (legacy != null && legacy.isNotEmpty) {
    return [EnrolledCard(pan: legacy)];
  }
  return const [];
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    Future.microtask(load);
    return const AppSettings();
  }

  static const _prefsKey = 'opencie_settings';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_prefsKey);
    if (json != null) {
      try {
        final map = jsonDecode(json) as Map<String, dynamic>;
        
        // Parse uiScale with clamping to valid values
        double parsedUiScale = 1.0;
        try {
          final rawScale = map['uiScale'] as num?;
          if (rawScale != null) {
            parsedUiScale = _clampUiScale(rawScale.toDouble());
          }
        } catch (_) {
          parsedUiScale = 1.0;
        }
        
        // Parse themeMode with fallback to system
        ThemeMode parsedThemeMode = ThemeMode.system;
        try {
          final themeModeStr = map['themeMode'] as String?;
          if (themeModeStr != null) {
            parsedThemeMode = ThemeMode.values.byName(themeModeStr);
          }
        } catch (_) {
          parsedThemeMode = ThemeMode.system;
        }
        
        state = AppSettings(
          locale: map['locale'] as String? ?? 'it',
          defaultPdfFormat: SignatureFormat.values.byName(
            map['defaultPdfFormat'] as String? ?? 'pades',
          ),
          defaultXmlFormat: SignatureFormat.values.byName(
            map['defaultXmlFormat'] as String? ?? 'xades',
          ),
          graphicPades: map['graphicPades'] as bool? ?? false,
          includeDate: map['includeDate'] as bool? ?? true,
          includeLocation: map['includeLocation'] as bool? ?? false,
          includeReason: map['includeReason'] as bool? ?? false,
          preservePdfA: map['preservePdfA'] as bool? ?? false,
          alwaysTimestamp: map['alwaysTimestamp'] as bool? ?? false,
          openFolderAfterSign: map['openFolderAfterSign'] as bool? ?? true,
          destinationFolder: map['destinationFolder'] as String?,
          tsaConfig: map['tsaConfig'] != null
              ? TsaConfig.fromJson(map['tsaConfig'] as Map<String, dynamic>)
              : const TsaConfig(),
          proxyConfig: map['proxyConfig'] != null
              ? ProxyConfig.fromJson(
                  map['proxyConfig'] as Map<String, dynamic>,
                )
              : const ProxyConfig(),
          validationType: ValidationType.values.byName(
            map['validationType'] as String? ?? 'ocspFirst',
          ),
          logLevel: LogLevel.values.byName(
            map['logLevel'] as String? ?? 'off',
          ),
          enrolledCards: _parseEnrolledCards(map),
          uiScale: parsedUiScale,
          themeMode: parsedThemeMode,
          oidcIssuer: map['oidcIssuer'] as String? ?? 'https://idp.example/',
          oidcClientId: map['oidcClientId'] as String? ?? 'opencie-client',
          isLoaded: true,
        );
        return;
      } catch (_) {
        // Corrupted prefs — fall through to defaults
      }
    }
    state = state.copyWith(isLoaded: true);
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final map = <String, dynamic>{
      'locale': state.locale,
      'defaultPdfFormat': state.defaultPdfFormat.name,
      'defaultXmlFormat': state.defaultXmlFormat.name,
      'graphicPades': state.graphicPades,
      'includeDate': state.includeDate,
      'includeLocation': state.includeLocation,
      'includeReason': state.includeReason,
      'preservePdfA': state.preservePdfA,
      'alwaysTimestamp': state.alwaysTimestamp,
      'openFolderAfterSign': state.openFolderAfterSign,
      'destinationFolder': state.destinationFolder,
      'tsaConfig': state.tsaConfig.toJson(),
      'proxyConfig': state.proxyConfig.toJson(),
      'validationType': state.validationType.name,
      'logLevel': state.logLevel.name,
      'enrolledCards': state.enrolledCards.map((c) => c.toJson()).toList(),
      'uiScale': state.uiScale,
      'themeMode': state.themeMode.name,
      'oidcIssuer': state.oidcIssuer,
      'oidcClientId': state.oidcClientId,
    };
    await prefs.setString(_prefsKey, jsonEncode(map));
  }

  void update(AppSettings Function(AppSettings) updater) {
    state = updater(state);
    _save();
  }

  void clearDestinationFolder() {
    state = state.copyWith(destinationFolder: _unset);
    _save();
  }

  void setUiScale(double scale) {
    state = state.copyWith(uiScale: scale);
    _save();
  }

  void setThemeMode(ThemeMode mode) {
    state = state.copyWith(themeMode: mode);
    _save();
  }

  static double _clampUiScale(double scale) {
    const validScales = [0.85, 1.0, 1.15, 1.30, 1.45];
    if (validScales.contains(scale)) {
      return scale;
    }
    // Find nearest valid scale
    double nearest = validScales[0];
    double minDiff = (scale - validScales[0]).abs();
    for (final validScale in validScales) {
      final diff = (scale - validScale).abs();
      if (diff < minDiff) {
        minDiff = diff;
        nearest = validScale;
      }
    }
    return nearest;
  }
}

final settingsProvider =
    NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
