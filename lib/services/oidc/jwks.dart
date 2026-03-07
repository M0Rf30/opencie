// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Minimal JWK key representation for RSA/EC keys as returned by a JWKS
/// endpoint. Only surfaces what we need for ID token signature verification
/// via `dart_jsonwebtoken`.
class JwksKey {
  JwksKey({
    required this.kid,
    required this.kty,
    required this.alg,
    required this.use,
    this.n,
    this.e,
    this.x,
    this.y,
    this.crv,
    this.x5c,
    this.x5t,
    this.raw,
  });

  final String kid;
  final String kty;
  final String alg;
  final String? use;
  final String? n;
  final String? e;
  final String? x;
  final String? y;
  final String? crv;
  final List<String>? x5c;
  final String? x5t;
  final Map<String, Object?>? raw;

  factory JwksKey.fromJson(Map<String, Object?> json) {
    return JwksKey(
      kid: json['kid'] as String? ?? '',
      kty: json['kty'] as String? ?? '',
      alg: json['alg'] as String? ?? '',
      use: json['use'] as String?,
      n: json['n'] as String?,
      e: json['e'] as String?,
      x: json['x'] as String?,
      y: json['y'] as String?,
      crv: json['crv'] as String?,
      x5c: (json['x5c'] as List?)?.whereType<String>().toList(),
      x5t: json['x5t'] as String?,
      raw: json,
    );
  }
}

/// Fetches and caches a JWKS document. Keys are indexed by `kid`.
class JwksClient {
  JwksClient({http.Client? httpClient, Duration? ttl})
      : _http = httpClient ?? http.Client(),
        _ttl = ttl ?? const Duration(hours: 1);

  final http.Client _http;
  final Duration _ttl;
  final Map<String, _JwksCacheEntry> _cache = {};

  Future<List<JwksKey>> fetch(Uri jwksUri, {bool forceRefresh = false}) async {
    final key = jwksUri.toString();
    final cached = _cache[key];
    if (!forceRefresh &&
        cached != null &&
        DateTime.now().isBefore(cached.expiresAt)) {
      return cached.keys;
    }

    final res = await _http.get(
      jwksUri,
      headers: const {'Accept': 'application/json'},
    );
    if (res.statusCode != 200) {
      throw OidcJwksException('JWKS HTTP ${res.statusCode} at $jwksUri');
    }
    final body = json.decode(res.body);
    if (body is! Map<String, Object?>) {
      throw const OidcJwksException('JWKS body is not a JSON object');
    }
    final keysList = body['keys'];
    if (keysList is! List) {
      throw const OidcJwksException('JWKS missing "keys" array');
    }
    final keys = keysList
        .whereType<Map<String, Object?>>()
        .map(JwksKey.fromJson)
        .toList(growable: false);
    _cache[key] = _JwksCacheEntry(keys, DateTime.now().add(_ttl));
    return keys;
  }

  /// Returns the key matching [kid] or `null`.
  Future<JwksKey?> getKey(Uri jwksUri, String kid,
      {bool forceRefresh = false}) async {
    final keys = await fetch(jwksUri, forceRefresh: forceRefresh);
    return keys.cast<JwksKey?>().firstWhere(
          (k) => k?.kid == kid,
          orElse: () => null,
        );
  }

  void clearCache() => _cache.clear();
}

class _JwksCacheEntry {
  _JwksCacheEntry(this.keys, this.expiresAt);
  final List<JwksKey> keys;
  final DateTime expiresAt;
}

class OidcJwksException implements Exception {
  const OidcJwksException(this.message);
  final String message;
  @override
  String toString() => 'OidcJwksException: $message';
}
