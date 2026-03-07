// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'discovery.dart';
import 'oidc_session.dart';
import 'pkce.dart';
import 'redirect_listener.dart';
import 'token_exchange.dart';
import 'userinfo.dart';

/// Orchestrates the complete OIDC authentication flow.
///
/// Extracted from the UI so the same logic can be used in integration tests.
class OidcAuthService {
  OidcAuthService({
    http.Client? httpClient,
    required this.onLaunchUrl,
    required this.onListenForCallback,
  })  : _exchanger = TokenExchanger(httpClient: httpClient),
        _userInfo = UserInfoClient(httpClient: httpClient);

  final TokenExchanger _exchanger;
  final UserInfoClient _userInfo;
  final Future<bool> Function(Uri url) onLaunchUrl;
  final Future<OidcCallback> Function(
    String redirectUri,
    String state,
  ) onListenForCallback;

  /// Runs the full OIDC + PKCE flow against [issuer].
  ///
  /// Returns the authenticated [OidcSession] or throws [OidcException].
  Future<OidcSession> authenticate({
    required String issuer,
    required String clientId,
    required String redirectUri,
    required String scope,
    List<String>? acrValues,
  }) async {
    try {
      // 1. Discovery
      final discovery =
          await OidcDiscoveryClient().fetch(Uri.parse(issuer));

      // 2. PKCE
      final pkce = await OidcPkce.generate();
      final state = OidcNonces.state();
      final nonce = OidcNonces.nonce();

      // 3. Authorize URL
      final authUrl = OidcAuthorizeRequest(
        authorizationEndpoint: discovery.authorizationEndpoint,
        clientId: clientId,
        redirectUri: Uri.parse(redirectUri),
        scopes: scope.split(' '),
        state: state,
        nonce: nonce,
        pkce: pkce,
        acrValues: acrValues,
      ).build();

      // 4. Launch browser & capture callback
      final launched = await onLaunchUrl(authUrl);
      if (!launched) {
        throw OidcException('Failed to launch authorization URL');
      }

      final callback = await onListenForCallback(redirectUri, state);
      if (!callback.isSuccess) {
        throw OidcException(
          'Authorization failed: ${callback.errorDescription ?? callback.error}',
        );
      }

      // 5. Token exchange (includes ID token verification)
      final tokenResponse = await _exchanger.exchange(
        discovery: discovery,
        clientId: clientId,
        redirectUri: Uri.parse(redirectUri),
        code: callback.code!,
        pkce: pkce,
        expectedNonce: nonce,
      );

      // 6. UserInfo
      Map<String, Object?>? userinfoClaims;
      if (discovery.userinfoEndpoint != null) {
        try {
          userinfoClaims = await _userInfo.fetch(
            discovery.userinfoEndpoint!,
            tokenResponse.accessToken,
          );
        } on Exception catch (e) {
          debugPrint('UserInfo fetch failed: $e');
        }
      }

      // 7. Session
      final session = OidcSession(
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

      return session;
    } on OidcException {
      rethrow;
    } on Exception catch (e, st) {
      throw OidcException('Authentication failed: $e', cause: e, stackTrace: st);
    }
  }
}

/// Thrown when an OIDC flow step fails.
class OidcException implements Exception {
  OidcException(this.message, {this.cause, this.stackTrace});
  final String message;
  final Object? cause;
  final StackTrace? stackTrace;

  @override
  String toString() => 'OidcException: $message';
}
