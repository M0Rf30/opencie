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
  bool get supportsPkceS256 => codeChallengeMethodsSupported.contains('S256');

  /// Parses a decoded discovery JSON document.
  ///
  /// Performs structural validation only (presence/type of required
  /// fields). It does NOT verify that [issuer] matches the URL the
  /// document was requested from, that HTTPS was used, or that
  /// [authorizationEndpoint]/[tokenEndpoint]/[jwksUri] share the issuer's
  /// origin — those security checks require the request context and are
  /// enforced by [OidcDiscoveryClient.fetch], not here. Callers that build
  /// an [OidcDiscovery] directly via this constructor bypass those checks.
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

    Uri? optUri(Object? v) => v is String && v.isNotEmpty ? Uri.parse(v) : null;
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
      idTokenSigningAlgValuesSupported: strList(
        json['id_token_signing_alg_values_supported'],
      ),
      codeChallengeMethodsSupported: strList(
        json['code_challenge_methods_supported'],
      ),
      raw: json,
    );
  }
}

/// Fetches, validates and caches OIDC provider discovery documents.
///
/// Usage:
/// ```dart
/// final disc = await OidcDiscoveryClient.instance.fetch(
///   Uri.parse('https://idp.example/'),
/// );
/// ```
///
/// [fetch] enforces the issuer, transport and origin checks documented on
/// it; [OidcDiscovery.fromJson] alone does not. Cache is in-memory only
/// (per process), and only ever holds documents that passed those checks.
/// For long-lived persistence, callers may serialise [OidcDiscovery.raw]
/// themselves.
class OidcDiscoveryClient {
  OidcDiscoveryClient({http.Client? httpClient, Duration? ttl})
    : _http = httpClient ?? http.Client(),
      _ttl = ttl ?? const Duration(hours: 1);

  static final OidcDiscoveryClient instance = OidcDiscoveryClient();

  final http.Client _http;
  final Duration _ttl;
  final Map<String, _CacheEntry> _cache = {};

  /// Resolves `<issuer>/.well-known/openid-configuration`, fetches and
  /// validates the document, and caches the result for [_ttl].
  ///
  /// [issuer] may be the bare issuer URL (recommended) or the full
  /// well-known path; trailing slashes are normalised either way.
  ///
  /// Beyond the structural checks in [OidcDiscovery.fromJson], this method
  /// enforces the security properties a discovery document must satisfy
  /// before it can be trusted:
  ///
  ///  * [issuer] must be `https://`, except for the loopback hosts
  ///    (`localhost`, `127.0.0.1`, `[::1]`) used by the bundled mock
  ///    authorization server in development.
  ///  * the document's `issuer` must exactly match the requested issuer
  ///    (RFC 8414 §3.3), so a hostile document cannot vouch for itself.
  ///  * `authorization_endpoint`, `token_endpoint` and `jwks_uri` must
  ///    share the issuer's origin (scheme, host, port), so a hostile
  ///    document cannot redirect key or token retrieval elsewhere.
  ///
  /// A document that fails any of these checks is never cached.
  ///
  /// Full OpenID Federation trust-chain validation is not implemented.
  Future<OidcDiscovery> fetch(Uri issuer, {bool forceRefresh = false}) async {
    _requireHttps(issuer);

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
      throw const OidcDiscoveryException('Discovery body is not a JSON object');
    }

    final disc = OidcDiscovery.fromJson(body);
    _requireMatchingIssuer(issuer, disc.issuer);
    _requireSameOrigin(issuer, disc);
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

  static void _requireHttps(Uri issuer) {
    if (issuer.scheme == 'https') return;
    if (issuer.scheme == 'http' && _isLoopbackHost(issuer.host)) return;
    throw OidcDiscoveryException(
      'OIDC discovery requires HTTPS (loopback http is allowed only for '
      'the bundled mock authorization server); got "$issuer"',
    );
  }

  static bool _isLoopbackHost(String host) =>
      host == 'localhost' || host == '127.0.0.1' || host == '::1';

  static void _requireMatchingIssuer(Uri requestedIssuer, String docIssuer) {
    final expected = _stripTrailingSlash(_expectedIssuer(requestedIssuer));
    final actual = _stripTrailingSlash(docIssuer);
    if (expected != actual) {
      throw OidcDiscoveryException(
        'OIDC discovery issuer mismatch: requested "$expected", '
        'document declared "$actual" (RFC 8414 §3.3)',
      );
    }
  }

  /// The issuer identifier [issuer] should have declared, per RFC 8414
  /// §3.3: the requested issuer with any well-known suffix removed.
  static String _expectedIssuer(Uri issuer) {
    const suffix = '/.well-known/openid-configuration';
    final path = issuer.path;
    if (!path.endsWith(suffix)) return issuer.toString();
    final basePath = path.substring(0, path.length - suffix.length);
    return issuer.replace(path: basePath).toString();
  }

  static String _stripTrailingSlash(String s) =>
      s.endsWith('/') ? s.substring(0, s.length - 1) : s;

  static void _requireSameOrigin(Uri issuer, OidcDiscovery disc) {
    _requireSameOriginAs(
      issuer,
      disc.authorizationEndpoint,
      'authorization_endpoint',
    );
    _requireSameOriginAs(issuer, disc.tokenEndpoint, 'token_endpoint');
    _requireSameOriginAs(issuer, disc.jwksUri, 'jwks_uri');
  }

  static void _requireSameOriginAs(Uri issuer, Uri endpoint, String field) {
    if (endpoint.scheme == issuer.scheme &&
        endpoint.host == issuer.host &&
        endpoint.port == issuer.port) {
      return;
    }
    throw OidcDiscoveryException(
      'OIDC discovery "$field" origin ($endpoint) does not match the '
      'issuer origin ($issuer)',
    );
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
