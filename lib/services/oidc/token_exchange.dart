// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'discovery.dart';
import 'id_token.dart';
import 'jwks.dart';
import 'pkce.dart';

/// Result of the token exchange step.
class TokenResponse {
  TokenResponse({
    required this.accessToken,
    required this.tokenType,
    required this.idToken,
    this.refreshToken,
    this.expiresIn,
    this.scope,
    this.raw,
  });

  final String accessToken;
  final String tokenType;
  final IdToken idToken;
  final String? refreshToken;
  final int? expiresIn;
  final String? scope;

  /// Full token endpoint response for fields not surfaced as typed getters.
  final Map<String, Object?>? raw;
}

/// Exchanges an authorization code for tokens and verifies the ID token.
class TokenExchanger {
  TokenExchanger({http.Client? httpClient, JwksClient? jwks})
    : _http = httpClient ?? http.Client(),
      _jwks = jwks ?? JwksClient();

  final http.Client _http;
  final JwksClient _jwks;

  /// POSTs the code to the token endpoint, parses the response, and verifies
  /// the returned ID token.
  Future<TokenResponse> exchange({
    required OidcDiscovery discovery,
    required String clientId,
    required Uri redirectUri,
    required String code,
    required OidcPkce pkce,
    String? expectedNonce,
  }) async {
    final body = <String, String>{
      'grant_type': 'authorization_code',
      'client_id': clientId,
      'redirect_uri': redirectUri.toString(),
      'code': code,
      'code_verifier': pkce.codeVerifier,
    };

    final res = await _http.post(
      discovery.tokenEndpoint,
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Accept': 'application/json',
      },
      encoding: utf8,
      body: body,
    );

    if (res.statusCode != 200) {
      throw TokenExchangeException(
        'Token endpoint HTTP ${res.statusCode}: ${res.body}',
      );
    }

    final jsonBody = json.decode(res.body);
    if (jsonBody is! Map<String, Object?>) {
      throw const TokenExchangeException('Token body is not a JSON object');
    }

    final accessToken = jsonBody['access_token'];
    final idTokenStr = jsonBody['id_token'];
    final tokenType = jsonBody['token_type'];

    if (accessToken is! String || accessToken.isEmpty) {
      throw const TokenExchangeException('missing access_token');
    }
    if (idTokenStr is! String || idTokenStr.isEmpty) {
      throw const TokenExchangeException('missing id_token');
    }
    if (tokenType is! String || tokenType.isEmpty) {
      throw const TokenExchangeException('missing token_type');
    }

    final idToken = await IdToken.verify(
      tokenString: idTokenStr,
      jwks: _jwks,
      jwksUri: discovery.jwksUri,
      expectedIssuer: discovery.issuer,
      expectedClientId: clientId,
      expectedNonce: expectedNonce,
    );

    return TokenResponse(
      accessToken: accessToken,
      tokenType: tokenType,
      idToken: idToken,
      refreshToken: jsonBody['refresh_token'] as String?,
      expiresIn: jsonBody['expires_in'] is int
          ? jsonBody['expires_in'] as int
          : int.tryParse(jsonBody['expires_in'].toString()),
      scope: jsonBody['scope'] as String?,
      raw: jsonBody,
    );
  }

  /// Redeems a refresh token for a new access token per RFC 6749 §6.
  ///
  /// Mirrors [exchange]'s client authentication — `client_id` only, no
  /// secret or assertion, since that's the only mechanism this class's
  /// authorization-code path uses. Never sends `code_verifier`: PKCE has no
  /// meaning for this grant.
  ///
  /// The response MAY carry a new `refresh_token` (RFC 6749 §6) — when it
  /// does, [TokenRefreshResponse.refreshToken] is that new value and the
  /// one passed in must not be reused. On failure, throws
  /// [TokenRefreshException] classified terminal (`invalid_grant` — the
  /// refresh token is dead, only a full re-login recovers) or transient
  /// (network error, timeout, 5xx — safe to retry later).
  Future<TokenRefreshResponse> refresh({
    required OidcDiscovery discovery,
    required String clientId,
    required String refreshToken,
  }) async {
    final body = <String, String>{
      'grant_type': 'refresh_token',
      'client_id': clientId,
      'refresh_token': refreshToken,
    };

    http.Response res;
    try {
      res = await _http.post(
        discovery.tokenEndpoint,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Accept': 'application/json',
        },
        encoding: utf8,
        body: body,
      );
    } catch (e, st) {
      throw TokenRefreshException.transient(
        'Refresh request failed: $e',
        cause: e,
        stackTrace: st,
      );
    }

    Map<String, Object?>? jsonBody;
    try {
      final decoded = json.decode(res.body);
      if (decoded is Map<String, Object?>) jsonBody = decoded;
    } catch (_) {
      // Non-JSON error bodies fall through to the generic classification
      // below.
    }

    if (res.statusCode != 200) {
      if (jsonBody?['error'] == 'invalid_grant') {
        throw TokenRefreshException.terminal(
          'Refresh token rejected (invalid_grant): ${res.body}',
        );
      }
      throw TokenRefreshException.transient(
        'Token endpoint HTTP ${res.statusCode}: ${res.body}',
      );
    }

    if (jsonBody == null) {
      throw TokenRefreshException.transient(
        'Refresh body is not a JSON object',
      );
    }

    final accessToken = jsonBody['access_token'];
    final tokenType = jsonBody['token_type'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw TokenRefreshException.transient('missing access_token');
    }
    if (tokenType is! String || tokenType.isEmpty) {
      throw TokenRefreshException.transient('missing token_type');
    }

    return TokenRefreshResponse(
      accessToken: accessToken,
      tokenType: tokenType,
      refreshToken: jsonBody['refresh_token'] as String?,
      expiresIn: jsonBody['expires_in'] is int
          ? jsonBody['expires_in'] as int
          : int.tryParse(jsonBody['expires_in'].toString()),
      scope: jsonBody['scope'] as String?,
      raw: jsonBody,
    );
  }
}

class TokenExchangeException implements Exception {
  const TokenExchangeException(this.message);
  final String message;
  @override
  String toString() => 'TokenExchangeException: $message';
}

/// Result of a successful `refresh_token` grant (RFC 6749 §6).
///
/// No ID token: refresh responses aren't required to include one, and
/// callers should keep using the ID token from the original
/// authorization-code exchange.
class TokenRefreshResponse {
  TokenRefreshResponse({
    required this.accessToken,
    required this.tokenType,
    this.refreshToken,
    this.expiresIn,
    this.scope,
    this.raw,
  });

  final String accessToken;
  final String tokenType;

  /// New refresh token, when the server rotated it. Per RFC 6749 §6, when
  /// present this replaces the token that was redeemed — the old one must
  /// not be sent again.
  final String? refreshToken;
  final int? expiresIn;
  final String? scope;

  /// Full token endpoint response for fields not surfaced as typed getters.
  final Map<String, Object?>? raw;
}

/// Thrown by [TokenExchanger.refresh].
///
/// [isTerminal] separates a hard failure — the refresh token itself is
/// dead (`invalid_grant`), so only a full interactive re-login recovers —
/// from a soft/transient one (network error, timeout, 5xx) where the
/// caller may legitimately retry later. Collapsing the two into one error
/// is exactly the bug this type exists to prevent.
class TokenRefreshException implements Exception {
  TokenRefreshException.terminal(this.message, {this.cause, this.stackTrace})
    : isTerminal = true;

  TokenRefreshException.transient(this.message, {this.cause, this.stackTrace})
    : isTerminal = false;

  final String message;
  final bool isTerminal;
  final Object? cause;
  final StackTrace? stackTrace;

  @override
  String toString() =>
      'TokenRefreshException: $message '
      '(${isTerminal ? "terminal" : "transient"})';
}
