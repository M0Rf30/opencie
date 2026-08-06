// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../secure_store.dart';
import 'id_token.dart';

/// High-level OIDC session state.
///
/// Holds the authenticated user's tokens and claims. Persisted encrypted via
/// [SecureStore] (OS keystore / Secret Service) — see [load] for the
/// one-shot migration away from the legacy plaintext [SharedPreferences]
/// blob this app used previously.
class OidcSession {
  OidcSession({
    required this.issuer,
    required this.clientId,
    required this.idToken,
    required this.accessToken,
    required this.tokenType,
    this.refreshToken,
    this.expiresAt,
    this.userinfoClaims,
    String? idTokenRaw,
  }) : _idTokenRaw = idTokenRaw;

  final String issuer;
  final String clientId;
  final IdToken idToken;
  final String accessToken;
  final String tokenType;
  final String? refreshToken;
  final DateTime? expiresAt;
  final Map<String, Object?>? userinfoClaims;
  final String? _idTokenRaw;

  /// The raw encoded ID token JWT, if one was issued for this session.
  ///
  /// Refresh-token grants often omit a new `id_token`; callers building a
  /// refreshed [OidcSession] should pass the prior session's [idTokenRaw]
  /// through so persistence (see [toJson]/[load]) keeps working.
  String? get idTokenRaw => _idTokenRaw;

  bool get isExpired => expiresAt != null && DateTime.now().isAfter(expiresAt!);

  /// Human-readable display name from userinfo or ID token claims.
  String? get displayName {
    final ui = userinfoClaims;
    if (ui != null) {
      return ui['name'] as String? ??
          ui['given_name'] as String? ??
          ui['preferred_username'] as String?;
    }
    final raw = idToken.raw;
    return raw?['name'] as String? ?? raw?['given_name'] as String?;
  }

  Map<String, dynamic> toJson() => {
    'issuer': issuer,
    'client_id': clientId,
    'id_token_raw': _idTokenRaw,
    'access_token': accessToken,
    'token_type': tokenType,
    if (refreshToken != null) 'refresh_token': refreshToken,
    if (expiresAt != null) 'expires_at': expiresAt!.millisecondsSinceEpoch,
    if (userinfoClaims != null) 'userinfo': userinfoClaims,
  };

  static Future<OidcSession?> load() async {
    var jsonStr = await SecureStore.read(_prefsKey);
    if (jsonStr == null || jsonStr.isEmpty) {
      // One-shot migration from the legacy plaintext SharedPreferences blob.
      final prefs = await SharedPreferences.getInstance();
      final legacy = prefs.getString(_prefsKey);
      if (legacy == null || legacy.isEmpty) return null;
      jsonStr = legacy;
      try {
        await SecureStore.write(_prefsKey, legacy);
        await prefs.remove(_prefsKey);
      } on SecureStoreException {
        // Secure storage unavailable (locked keyring, no Secret Service).
        // Use the legacy value for this run; migration retries next load().
      }
    }
    final map = json.decode(jsonStr) as Map<String, dynamic>;

    final idTokenRaw = map['id_token_raw'] as String?;
    if (idTokenRaw == null || idTokenRaw.isEmpty) return null;

    // We can't fully verify without network, but we can decode to get claims.
    final decoded = JWT.decode(idTokenRaw);
    final payload = decoded.payload as Map<String, dynamic>;
    final idToken = IdToken(
      issuer: payload['iss'] as String,
      subject: payload['sub'] as String,
      audience:
          (payload['aud'] is List
                  ? (payload['aud'] as List).first
                  : payload['aud'])
              as String,
      expiration: DateTime.fromMillisecondsSinceEpoch(
        ((payload['exp'] as num) * 1000).toInt(),
        isUtc: true,
      ),
      issuedAt: DateTime.fromMillisecondsSinceEpoch(
        ((payload['iat'] as num) * 1000).toInt(),
        isUtc: true,
      ),
      nonce: payload['nonce'] as String?,
      authTime: payload['auth_time'] is num
          ? DateTime.fromMillisecondsSinceEpoch(
              ((payload['auth_time'] as num) * 1000).toInt(),
              isUtc: true,
            )
          : null,
      acr: payload['acr'] as String?,
      raw: payload.cast<String, Object?>(),
    );

    return OidcSession(
      issuer: map['issuer'] as String,
      clientId: map['client_id'] as String,
      idToken: idToken,
      accessToken: map['access_token'] as String,
      tokenType: map['token_type'] as String,
      refreshToken: map['refresh_token'] as String?,
      expiresAt: map['expires_at'] is int
          ? DateTime.fromMillisecondsSinceEpoch(
              map['expires_at'] as int,
              isUtc: true,
            )
          : null,
      userinfoClaims: (map['userinfo'] as Map?)?.cast<String, Object?>(),
    );
  }

  static Future<void> save(OidcSession session) async {
    await SecureStore.write(_prefsKey, json.encode(session.toJson()));
  }

  static Future<void> clear() async {
    await SecureStore.delete(_prefsKey);
  }

  static const _prefsKey = 'opencie_oidc_session';
}
