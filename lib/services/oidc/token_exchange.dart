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
}

class TokenExchangeException implements Exception {
  const TokenExchangeException(this.message);
  final String message;
  @override
  String toString() => 'TokenExchangeException: $message';
}
