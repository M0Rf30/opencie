// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:http/http.dart' as http;

import '../discovery.dart';
import '../id_token.dart';
import '../jwks.dart';
import '../oidc_session.dart';
import '../pkce.dart';
import '../redirect_listener.dart';
import '../userinfo.dart';
import 'acr.dart';
import 'claims.dart';
import 'private_key_jwt.dart';
import 'request_object.dart';
import 'spid_session.dart';

/// Orchestrates the SPID/CIE OpenID Connect Federation flow.
class SpidAuthService {
  SpidAuthService({
    required this.profile,
    required this.level,
    required this.clientId,
    required this.redirectUri,
    required this.privateKey,
    required this.kid,
    required this.onLaunchUrl,
    required this.onListenForCallback,
    http.Client? httpClient,
  })  : _http = httpClient ?? http.Client(),
        _jwks = JwksClient(),
        _userInfo = UserInfoClient(httpClient: httpClient);

  final SpidProfile profile;
  final SpidLevel level;
  final String clientId;
  final String redirectUri;
  final RSAPrivateKey privateKey;
  final String kid;
  final Future<bool> Function(Uri url) onLaunchUrl;
  final Future<OidcCallback> Function(String redirectUri, String state)
      onListenForCallback;

  final http.Client _http;
  final JwksClient _jwks;
  final UserInfoClient _userInfo;

  /// Runs the full SPID/CIE flow against [issuer].
  ///
  /// Returns the authenticated [SpidSession] or throws [SpidAuthException].
  Future<SpidSession> authenticate({required String issuer}) async {
    try {
      // 1. Discovery
      final discovery =
          await OidcDiscoveryClient().fetch(Uri.parse(issuer));

      // 2. PKCE + state + nonce
      final pkce = await OidcPkce.generate();
      final state = OidcNonces.state();
      final nonce = OidcNonces.nonce();

      // 3. Build signed request_object
      final claimsRequest = _buildClaimsRequest();
      final requestObject = SpidRequestObject.build(
        iss: clientId,
        aud: discovery.issuer,
        clientId: clientId,
        scope: _defaultScope(),
        redirectUri: redirectUri,
        state: state,
        nonce: nonce,
        codeChallenge: pkce.codeChallenge,
        acrValue: level.acrValue,
        privateKey: privateKey,
        kid: kid,
        claimsRequest: claimsRequest,
      );

      // 4. Build authorize URL with request parameter
      final authUrl = discovery.authorizationEndpoint.replace(
        queryParameters: {
          ...discovery.authorizationEndpoint.queryParameters,
          'client_id': clientId,
          'response_type': 'code',
          'scope': _defaultScope(),
          'code_challenge': pkce.codeChallenge,
          'code_challenge_method': 'S256',
          'state': state,
          'nonce': nonce,
          'acr_values': level.acrValue,
          'request': requestObject,
        },
      );

      // 5. Launch browser & capture callback
      final launched = await onLaunchUrl(authUrl);
      if (!launched) {
        throw SpidAuthException('Failed to launch authorization URL');
      }

      final callback = await onListenForCallback(redirectUri, state);
      if (!callback.isSuccess) {
        throw SpidAuthException(
          'Authorization failed: ${callback.errorDescription ?? callback.error}',
        );
      }

      // 6. Token exchange with private_key_jwt
      final tokenResponse = await _exchangeToken(
        discovery: discovery,
        code: callback.code!,
        pkce: pkce,
        expectedNonce: nonce,
      );

      // 7. UserInfo
      Map<String, Object?>? userinfoClaims;
      if (discovery.userinfoEndpoint != null) {
        try {
          userinfoClaims = await _userInfo.fetch(
            discovery.userinfoEndpoint!,
            tokenResponse.accessToken,
          );
        } on Exception {
          // Silently ignore userinfo errors; attributes will be empty
        }
      }

      // 8. Parse attributes
      final attributes = SpidUserAttributes.fromUserinfo(
        userinfoClaims ?? {},
        profile: profile,
      );

      // 9. Build session
      final oidcSession = OidcSession(
        issuer: discovery.issuer,
        clientId: clientId,
        idToken: tokenResponse.idToken,
        accessToken: tokenResponse.accessToken,
        tokenType: tokenResponse.tokenType,
        refreshToken: tokenResponse.refreshToken,
        expiresAt: tokenResponse.expiresIn != null
            ? DateTime.now().add(Duration(seconds: tokenResponse.expiresIn!))
            : null,
        userinfoClaims: userinfoClaims,
        idTokenRaw: tokenResponse.raw?['id_token'] as String?,
      );

      final spidSession = SpidSession(
        session: oidcSession,
        profile: profile,
        level: SpidLevel.fromAcr(tokenResponse.idToken.acr),
        attributes: attributes,
      );

      return spidSession;
    } on SpidAuthException {
      rethrow;
    } on Exception catch (e, st) {
      throw SpidAuthException(
        'Authentication failed: $e',
        cause: e,
        stackTrace: st,
      );
    }
  }

  /// Exchanges authorization code for tokens using private_key_jwt.
  Future<_TokenResponse> _exchangeToken({
    required OidcDiscovery discovery,
    required String code,
    required OidcPkce pkce,
    required String expectedNonce,
  }) async {
    final clientAssertion = PrivateKeyJwt.build(
      clientId: clientId,
      tokenEndpoint: discovery.tokenEndpoint,
      privateKey: privateKey,
      kid: kid,
    );

    final body = <String, String>{
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': redirectUri,
      'client_id': clientId,
      'code_verifier': pkce.codeVerifier,
      'client_assertion_type': kClientAssertionType,
      'client_assertion': clientAssertion,
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
      throw SpidAuthException(
        'Token endpoint HTTP ${res.statusCode}: ${res.body}',
      );
    }

    final jsonBody = json.decode(res.body);
    if (jsonBody is! Map<String, Object?>) {
      throw SpidAuthException('Token body is not a JSON object');
    }

    final accessToken = jsonBody['access_token'];
    final idTokenStr = jsonBody['id_token'];
    final tokenType = jsonBody['token_type'];

    if (accessToken is! String || accessToken.isEmpty) {
      throw SpidAuthException('missing access_token');
    }
    if (idTokenStr is! String || idTokenStr.isEmpty) {
      throw SpidAuthException('missing id_token');
    }
    if (tokenType is! String || tokenType.isEmpty) {
      throw SpidAuthException('missing token_type');
    }

    final idToken = await IdToken.verify(
      tokenString: idTokenStr,
      jwks: _jwks,
      jwksUri: discovery.jwksUri,
      expectedIssuer: discovery.issuer,
      expectedClientId: clientId,
      expectedNonce: expectedNonce,
    );

    return _TokenResponse(
      accessToken: accessToken,
      tokenType: tokenType,
      idToken: idToken,
      refreshToken: jsonBody['refresh_token'] as String?,
      expiresIn: jsonBody['expires_in'] is int
          ? jsonBody['expires_in'] as int
          : int.tryParse(jsonBody['expires_in'].toString()),
      raw: jsonBody,
    );
  }

  String _defaultScope() {
    if (profile == SpidProfile.spid) {
      return 'openid';
    } else {
      return 'openid profile email';
    }
  }

  Map<String, Object?>? _buildClaimsRequest() {
    if (profile == SpidProfile.spid) {
      return {
        'userinfo': {
          SpidClaim.fiscalNumber: null,
          SpidClaim.name: null,
          SpidClaim.familyName: null,
          SpidClaim.dateOfBirth: null,
          SpidClaim.email: null,
        }
      };
    }
    // CIE: no explicit claims request needed (standard OIDC scopes)
    return null;
  }
}

/// Internal token response holder.
class _TokenResponse {
  _TokenResponse({
    required this.accessToken,
    required this.tokenType,
    required this.idToken,
    this.refreshToken,
    this.expiresIn,
    this.raw,
  });

  final String accessToken;
  final String tokenType;
  final IdToken idToken;
  final String? refreshToken;
  final int? expiresIn;
  final Map<String, Object?>? raw;
}

/// Thrown when a SPID/CIE flow step fails.
class SpidAuthException implements Exception {
  SpidAuthException(this.message, {this.cause, this.stackTrace});
  final String message;
  final Object? cause;
  final StackTrace? stackTrace;

  @override
  String toString() => 'SpidAuthException: $message';
}
