// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Result of an OIDC provider discovery against `.well-known/openid-configuration`.
///
/// Fields cover the subset OpenCIE actually needs for the auth-code+PKCE
/// flow plus userinfo. Other fields from the discovery document are
/// preserved verbatim in [raw] so callers can inspect them without
/// re-parsing.
class OidcDiscovery {
  OidcDiscovery({
    required this.issuer,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    required this.jwksUri,
    required this.userinfoEndpoint,
    required this.endSessionEndpoint,
    required this.scopesSupported,
    required this.responseTypesSupported,
    required this.idTokenSigningAlgValuesSupported,
    required this.codeChallengeMethodsSupported,
    required this.raw,
  });

  /// Issuer URL — must match `iss` claim on returned ID tokens.
  final String issuer;

  /// Authorization endpoint (browser redirect target).
  final Uri authorizationEndpoint;

  /// Token endpoint (back-channel code → tokens).
  final Uri tokenEndpoint;

  /// JWKS URI (public keys for ID token verification).
  final Uri jwksUri;

  /// Optional userinfo endpoint.
  final Uri? userinfoEndpoint;

  /// Optional RP-initiated logout endpoint.
  final Uri? endSessionEndpoint;

  final List<String> scopesSupported;
  final List<String> responseTypesSupported;
  final List<String> idTokenSigningAlgValuesSupported;
  final List<String> codeChallengeMethodsSupported;

  /// Full raw discovery document for fields not surfaced as typed getters.
  final Map<String, Object?> raw;

  /// Returns `true` iff the provider advertises support for PKCE S256.
  bool get supportsPkceS256 =>
      codeChallengeMethodsSupported.contains('S256');

  /// Parses a decoded discovery JSON document.
  factory OidcDiscovery.fromJson(Map<String, Object?> json) {
    final issuer = json['issuer'];
    final authEp = json['authorization_endpoint'];
    final tokenEp = json['token_endpoint'];
    final jwksUri = json['jwks_uri'];
    if (issuer is! String || issuer.isEmpty) {
      throw const FormatException(
        'OIDC discovery: missing or invalid "issuer"',
      );
    }
    if (authEp is! String || authEp.isEmpty) {
      throw const FormatException(
        'OIDC discovery: missing or invalid "authorization_endpoint"',
      );
    }
    if (tokenEp is! String || tokenEp.isEmpty) {
      throw const FormatException(
        'OIDC discovery: missing or invalid "token_endpoint"',
      );
    }
    if (jwksUri is! String || jwksUri.isEmpty) {
      throw const FormatException(
        'OIDC discovery: missing or invalid "jwks_uri"',
      );
    }

    Uri? optUri(Object? v) =>
        v is String && v.isNotEmpty ? Uri.parse(v) : null;
    List<String> strList(Object? v) => v is List
        ? v.whereType<String>().toList(growable: false)
        : const <String>[];

    return OidcDiscovery(
      issuer: issuer,
      authorizationEndpoint: Uri.parse(authEp),
      tokenEndpoint: Uri.parse(tokenEp),
      jwksUri: Uri.parse(jwksUri),
      userinfoEndpoint: optUri(json['userinfo_endpoint']),
      endSessionEndpoint: optUri(json['end_session_endpoint']),
      scopesSupported: strList(json['scopes_supported']),
      responseTypesSupported: strList(json['response_types_supported']),
      idTokenSigningAlgValuesSupported:
          strList(json['id_token_signing_alg_values_supported']),
      codeChallengeMethodsSupported:
          strList(json['code_challenge_methods_supported']),
      raw: json,
    );
  }
}

/// Fetches and caches OIDC provider discovery documents.
///
/// Usage:
/// ```dart
/// final disc = await OidcDiscoveryClient.instance.fetch(
///   Uri.parse('https://idp.example/'),
/// );
/// ```
///
/// Cache is in-memory only (per process). For long-lived persistence,
/// callers may serialise [OidcDiscovery.raw] themselves.
class OidcDiscoveryClient {
  OidcDiscoveryClient({http.Client? httpClient, Duration? ttl})
      : _http = httpClient ?? http.Client(),
        _ttl = ttl ?? const Duration(hours: 1);

  static final OidcDiscoveryClient instance = OidcDiscoveryClient();

  final http.Client _http;
  final Duration _ttl;
  final Map<String, _CacheEntry> _cache = {};

  /// Resolves `<issuer>/.well-known/openid-configuration`, parses the
  /// document, and caches the result for [_ttl].
  ///
  /// [issuer] may be the bare issuer URL (recommended) or the full
  /// well-known path; trailing slashes are normalised either way.
  Future<OidcDiscovery> fetch(Uri issuer, {bool forceRefresh = false}) async {
    final wellKnown = _wellKnownUri(issuer);
    final key = wellKnown.toString();

    final cached = _cache[key];
    if (!forceRefresh &&
        cached != null &&
        DateTime.now().isBefore(cached.expiresAt)) {
      return cached.value;
    }

    final res = await _http.get(
      wellKnown,
      headers: const {'Accept': 'application/json'},
    );
    if (res.statusCode != 200) {
      throw OidcDiscoveryException(
        'Discovery HTTP ${res.statusCode} at $wellKnown',
      );
    }
    final body = json.decode(res.body);
    if (body is! Map<String, Object?>) {
      throw const OidcDiscoveryException(
        'Discovery body is not a JSON object',
      );
    }

    final disc = OidcDiscovery.fromJson(body);
    _cache[key] = _CacheEntry(disc, DateTime.now().add(_ttl));
    return disc;
  }

  /// Drops cached entries.
  void clearCache() => _cache.clear();

  static Uri _wellKnownUri(Uri issuer) {
    final path = issuer.path;
    if (path.endsWith('/.well-known/openid-configuration')) return issuer;
    final base = path.endsWith('/') ? path : '$path/';
    return issuer.replace(path: '$base.well-known/openid-configuration');
  }
}

class _CacheEntry {
  _CacheEntry(this.value, this.expiresAt);
  final OidcDiscovery value;
  final DateTime expiresAt;
}

class OidcDiscoveryException implements Exception {
  const OidcDiscoveryException(this.message);
  final String message;
  @override
  String toString() => 'OidcDiscoveryException: $message';
}
