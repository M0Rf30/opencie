// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import '../core/constants/app_constants.dart';

/// Configuration for a Time Stamp Authority.
class TsaConfig {
  const TsaConfig({
    this.serverUrl = AppConstants.defaultTsaUrl,
    this.fallbackUrl = AppConstants.defaultTsaUrlFallback,
    this.username = '',
    this.password = '',
    this.policyOid = '',
    this.autoSummerTime = true,
  });

  final String serverUrl;
  final String fallbackUrl;
  final String username;
  final String password;
  final String policyOid;
  final bool autoSummerTime;

  /// Whether this is using the default non-qualified FreeTSA.
  bool get isFreeTsa => serverUrl.contains('freetsa.org');

  /// Whether credentials are configured (required for qualified TSPs).
  bool get hasCredentials => username.isNotEmpty && password.isNotEmpty;

  TsaConfig copyWith({
    String? serverUrl,
    String? fallbackUrl,
    String? username,
    String? password,
    String? policyOid,
    bool? autoSummerTime,
  }) {
    return TsaConfig(
      serverUrl: serverUrl ?? this.serverUrl,
      fallbackUrl: fallbackUrl ?? this.fallbackUrl,
      username: username ?? this.username,
      password: password ?? this.password,
      policyOid: policyOid ?? this.policyOid,
      autoSummerTime: autoSummerTime ?? this.autoSummerTime,
    );
  }

  /// Deliberately omits [password]: TSA credentials are persisted
  /// separately in [SecureStore] (OC-19), not in the plaintext settings
  /// blob. [SettingsNotifier._save] preserves any pre-existing legacy
  /// plaintext password on a secure-write failure.
  Map<String, dynamic> toJson() => {
    'serverUrl': serverUrl,
    'fallbackUrl': fallbackUrl,
    'username': username,
    'policyOid': policyOid,
    'autoSummerTime': autoSummerTime,
  };

  factory TsaConfig.fromJson(Map<String, dynamic> json) => TsaConfig(
    serverUrl: json['serverUrl'] as String? ?? AppConstants.defaultTsaUrl,
    fallbackUrl:
        json['fallbackUrl'] as String? ?? AppConstants.defaultTsaUrlFallback,
    username: json['username'] as String? ?? '',
    password: json['password'] as String? ?? '',
    policyOid: json['policyOid'] as String? ?? '',
    autoSummerTime: json['autoSummerTime'] as bool? ?? true,
  );
}

/// TSA providers offered in the UI: FreeTSA first, then the qualified TSPs.
List<MapEntry<String, String>> tsaProviderEntries() => [
  const MapEntry('FreeTSA', AppConstants.defaultTsaUrl),
  ...AppConstants.qualifiedTsaProviders.entries,
];

/// Display name for the TSA at [serverUrl]: the provider's name when it is
/// one of [tsaProviderEntries], otherwise the URL's host (or the raw string
/// when it does not parse as a URL).
String tsaDisplayName(String serverUrl) {
  final url = serverUrl.trim();
  for (final e in tsaProviderEntries()) {
    if (e.value == url) return e.key;
  }
  final host = Uri.tryParse(url)?.host ?? '';
  return host.isNotEmpty ? host : url;
}
