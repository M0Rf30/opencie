// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/enrolled_card.dart';
import '../models/proxy_config.dart';
import '../models/signature_options.dart';
import '../models/tsa_config.dart';
import '../services/secure_store.dart';

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
    this.secureStorageUnavailable = false,
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

  /// True once, for the rest of the app session, a [SecureStore] read or
  /// write has failed because the platform secure store is unreachable
  /// (e.g. no Secret Service / gnome-keyring running on Linux). Drives a
  /// non-blocking warning in the settings UI; it is never cleared back to
  /// false so the warning stays visible even if a later save happens to
  /// succeed transiently.
  final bool secureStorageUnavailable;

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
    bool? secureStorageUnavailable,
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
      secureStorageUnavailable:
          secureStorageUnavailable ?? this.secureStorageUnavailable,
    );
  }
}

enum ValidationType { ocspOnly, ocspFirst, crlOnly, crlFirst }

enum LogLevel { off, standard, debug }

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

List<EnrolledCard> _decodeEnrolledCardsJson(String jsonStr) {
  try {
    final raw = jsonDecode(jsonStr);
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(EnrolledCard.fromJson)
        .where((c) => c.pan.isNotEmpty)
        .toList();
  } catch (_) {
    return const [];
  }
}

/// Reads enrolled cards from [SecureStore]. If none are stored yet but the
/// legacy plaintext [settingsMap] still has them (modern `enrolledCards`
/// list or the older single `enrolledPan` string), migrates them into
/// [SecureStore] once — [SettingsNotifier._save] strips the legacy copy
/// from the settings blob on its next write.
///
/// A [SecureStoreException] from the initial read means the store is
/// unavailable, not that it is empty: [unavailable] is reported so the
/// caller neither wipes the in-memory list nor attempts a migration write
/// that would only fail the same way.
Future<({List<EnrolledCard> list, bool migrated, bool unavailable})>
_loadEnrolledCards(Map<String, dynamic> settingsMap) async {
  String? stored;
  var unavailable = false;
  try {
    stored = await SecureStore.read(SettingsNotifier._enrolledCardsKey);
  } on SecureStoreException {
    unavailable = true;
  }
  if (stored != null && stored.isNotEmpty) {
    return (
      list: _decodeEnrolledCardsJson(stored),
      migrated: false,
      unavailable: false,
    );
  }

  final legacy = _parseEnrolledCards(settingsMap);
  if (legacy.isEmpty || unavailable) {
    // Either nothing to migrate, or the store is known unavailable: don't
    // attempt (and don't need) a migration write that would just fail again.
    return (list: legacy, migrated: false, unavailable: unavailable);
  }

  try {
    await SecureStore.write(
      SettingsNotifier._enrolledCardsKey,
      jsonEncode(legacy.map((c) => c.toJson()).toList()),
    );
    return (list: legacy, migrated: true, unavailable: false);
  } on SecureStoreException {
    // Secure storage unavailable; keep using the legacy cards this session
    // and retry the migration on the next load().
    return (list: legacy, migrated: false, unavailable: true);
  }
}

/// Reads a single secret string (TSA/proxy password) from [SecureStore],
/// migrating a plaintext [legacyValue] from the settings blob into the
/// secure store once. Mirrors [_loadEnrolledCards]'s availability handling:
/// a read failure means "unavailable", not "absent", so callers neither
/// discard the legacy plaintext value nor attempt a migration write that
/// would only fail the same way. The legacy plaintext value keeps being
/// used in-memory (and preserved in the settings blob by
/// [SettingsNotifier._save]) until a migration write actually succeeds.
Future<({String value, bool migrated, bool unavailable})> _loadSecret(
  String key,
  String legacyValue,
) async {
  String? stored;
  var unavailable = false;
  try {
    stored = await SecureStore.read(key);
  } on SecureStoreException {
    unavailable = true;
  }
  if (stored != null) {
    return (value: stored, migrated: false, unavailable: false);
  }

  if (legacyValue.isEmpty || unavailable) {
    return (value: legacyValue, migrated: false, unavailable: unavailable);
  }

  try {
    await SecureStore.write(key, legacyValue);
    return (value: legacyValue, migrated: true, unavailable: false);
  } on SecureStoreException {
    return (value: legacyValue, migrated: false, unavailable: true);
  }
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
  static const _enrolledCardsKey = 'opencie_enrolled_cards';
  static const _tsaPasswordKey = 'opencie_tsa_password';
  static const _proxyPasswordKey = 'opencie_proxy_password';

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

        final cards = await _loadEnrolledCards(map);
        final tsaJson = map['tsaConfig'] as Map<String, dynamic>?;
        final proxyJson = map['proxyConfig'] as Map<String, dynamic>?;
        final tsaSecret = await _loadSecret(
          _tsaPasswordKey,
          tsaJson?['password'] as String? ?? '',
        );
        final proxySecret = await _loadSecret(
          _proxyPasswordKey,
          proxyJson?['password'] as String? ?? '',
        );

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
          tsaConfig:
              (tsaJson != null
                      ? TsaConfig.fromJson(tsaJson)
                      : const TsaConfig())
                  .copyWith(password: tsaSecret.value),
          proxyConfig:
              (proxyJson != null
                      ? ProxyConfig.fromJson(proxyJson)
                      : const ProxyConfig())
                  .copyWith(password: proxySecret.value),
          validationType: ValidationType.values.byName(
            map['validationType'] as String? ?? 'ocspFirst',
          ),
          logLevel: LogLevel.values.byName(map['logLevel'] as String? ?? 'off'),
          enrolledCards: cards.list,
          uiScale: parsedUiScale,
          themeMode: parsedThemeMode,
          oidcIssuer: map['oidcIssuer'] as String? ?? 'https://idp.example/',
          oidcClientId: map['oidcClientId'] as String? ?? 'opencie-client',
          isLoaded: true,
          secureStorageUnavailable:
              cards.unavailable ||
              tsaSecret.unavailable ||
              proxySecret.unavailable,
        );
        if (cards.migrated || tsaSecret.migrated || proxySecret.migrated) {
          await _save();
        }
        return;
      } catch (_) {
        // Corrupted prefs — fall through to defaults
      }
    }
    state = state.copyWith(isLoaded: true);
  }

  /// Persists settings to [SharedPreferences] and enrolled cards / TSA and
  /// proxy passwords to [SecureStore]. Never throws: a
  /// [SecureStoreException] from any secure write is caught and turned
  /// into [AppSettings.secureStorageUnavailable] instead, and in that case
  /// any pre-existing legacy plaintext copy of the affected value already
  /// in [SharedPreferences] is preserved rather than being stripped by
  /// this write — it may be the only surviving record until the store
  /// comes back.
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
      'uiScale': state.uiScale,
      'themeMode': state.themeMode.name,
      'oidcIssuer': state.oidcIssuer,
      'oidcClientId': state.oidcClientId,
    };

    // Lazily-parsed snapshot of whatever is already on disk, reused as a
    // plaintext fallback source for every secret whose secure write fails
    // below (enrolled cards, TSA password, proxy password).
    final existingJson = prefs.getString(_prefsKey);
    Map<String, dynamic>? existing;
    if (existingJson != null) {
      try {
        existing = jsonDecode(existingJson) as Map<String, dynamic>;
      } catch (_) {
        existing = null; // Corrupted existing blob — nothing to preserve.
      }
    }

    var unavailable = false;

    try {
      await SecureStore.write(
        _enrolledCardsKey,
        jsonEncode(state.enrolledCards.map((c) => c.toJson()).toList()),
      );
    } on SecureStoreException {
      unavailable = true;
      if (existing?['enrolledCards'] != null) {
        map['enrolledCards'] = existing!['enrolledCards'];
      } else if (existing?['enrolledPan'] != null) {
        map['enrolledPan'] = existing!['enrolledPan'];
      }
    }

    try {
      await SecureStore.write(_tsaPasswordKey, state.tsaConfig.password);
    } on SecureStoreException {
      unavailable = true;
      final existingPassword =
          (existing?['tsaConfig'] as Map<String, dynamic>?)?['password']
              as String?;
      if (existingPassword != null) {
        (map['tsaConfig'] as Map<String, dynamic>)['password'] =
            existingPassword;
      }
    }

    try {
      await SecureStore.write(_proxyPasswordKey, state.proxyConfig.password);
    } on SecureStoreException {
      unavailable = true;
      final existingPassword =
          (existing?['proxyConfig'] as Map<String, dynamic>?)?['password']
              as String?;
      if (existingPassword != null) {
        (map['proxyConfig'] as Map<String, dynamic>)['password'] =
            existingPassword;
      }
    }

    try {
      await prefs.setString(_prefsKey, jsonEncode(map));
    } catch (_) {
      // Platform-level SharedPreferences failure (e.g. disk full/read-only
      // filesystem). No dedicated banner exists for this; reuse the same
      // "persistence unavailable" warning as the secure-store case rather
      // than fail silently.
      unavailable = true;
    }

    if (unavailable && !state.secureStorageUnavailable) {
      state = state.copyWith(secureStorageUnavailable: true);
    }
  }

  /// Marks the secure store as unavailable for the rest of this session.
  /// Called by callers of other [SecureStore]-backed persistence (e.g. the
  /// OIDC session) so a single warning covers both enrolled cards and
  /// sign-in tokens.
  void flagSecureStorageUnavailable() {
    if (!state.secureStorageUnavailable) {
      state = state.copyWith(secureStorageUnavailable: true);
    }
  }

  /// Applies [updater] and persists the result. Awaits the write so
  /// callers (and tests) observe persistence failures via
  /// [AppSettings.secureStorageUnavailable] instead of a fire-and-forget
  /// save racing the rest of the app.
  Future<void> update(AppSettings Function(AppSettings) updater) async {
    state = updater(state);
    await _save();
  }

  Future<void> clearDestinationFolder() async {
    state = state.copyWith(destinationFolder: _unset);
    await _save();
  }

  Future<void> setUiScale(double scale) async {
    state = state.copyWith(uiScale: scale);
    await _save();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    await _save();
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

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);
