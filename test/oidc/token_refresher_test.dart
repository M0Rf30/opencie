// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opencie/services/oidc/discovery.dart';
import 'package:opencie/services/oidc/id_token.dart';
import 'package:opencie/services/oidc/oidc_session.dart';
import 'package:opencie/services/oidc/token_exchange.dart';
import 'package:opencie/services/oidc/token_refresher.dart';
import 'package:test/test.dart';

OidcDiscovery _discovery() => OidcDiscovery(
  issuer: 'https://idp.example',
  authorizationEndpoint: Uri.parse('https://idp.example/authorize'),
  tokenEndpoint: Uri.parse('https://idp.example/token'),
  jwksUri: Uri.parse('https://idp.example/jwks'),
  userinfoEndpoint: null,
  endSessionEndpoint: null,
  scopesSupported: const ['openid'],
  responseTypesSupported: const ['code'],
  idTokenSigningAlgValuesSupported: const ['RS256'],
  codeChallengeMethodsSupported: const ['S256'],
  raw: const {},
);

IdToken _idToken() => IdToken(
  issuer: 'https://idp.example',
  subject: 'user-1',
  audience: 'test-client',
  expiration: DateTime.now().add(const Duration(hours: 1)),
  issuedAt: DateTime.now(),
);

OidcSession _session({
  required IdToken idToken,
  String accessToken = 'old-access',
  String? refreshToken = 'old-refresh',
  DateTime? expiresAt,
  String? idTokenRaw = 'orig-id-token-raw',
}) => OidcSession(
  issuer: 'https://idp.example',
  clientId: 'test-client',
  idToken: idToken,
  idTokenRaw: idTokenRaw,
  accessToken: accessToken,
  tokenType: 'Bearer',
  refreshToken: refreshToken,
  expiresAt: expiresAt,
);

http.Response _tokenResponse(Map<String, Object?> body, {int status = 200}) =>
    http.Response(
      json.encode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

void main() {
  group('TokenExchanger.refresh', () {
    test('sends grant_type=refresh_token, client_id, refresh_token, '
        'and never code_verifier or a client secret/assertion', () async {
      late Map<String, String> sentFields;
      final client = MockClient((request) async {
        sentFields = request.bodyFields;
        return _tokenResponse({'access_token': 'a', 'token_type': 'Bearer'});
      });

      await TokenExchanger(httpClient: client).refresh(
        discovery: _discovery(),
        clientId: 'test-client',
        refreshToken: 'rt-1',
      );

      expect(sentFields['grant_type'], 'refresh_token');
      expect(sentFields['client_id'], 'test-client');
      expect(sentFields['refresh_token'], 'rt-1');
      expect(sentFields.containsKey('code_verifier'), isFalse);
      // Mirrors the authorization-code path in this file: client_id only.
      expect(sentFields.containsKey('client_secret'), isFalse);
      expect(sentFields.containsKey('client_assertion'), isFalse);
    });

    test('surfaces a rotated refresh_token in the typed response', () async {
      final client = MockClient((request) async {
        return _tokenResponse({
          'access_token': 'a',
          'token_type': 'Bearer',
          'refresh_token': 'rt-2',
        });
      });

      final res = await TokenExchanger(httpClient: client).refresh(
        discovery: _discovery(),
        clientId: 'test-client',
        refreshToken: 'rt-1',
      );

      expect(res.refreshToken, 'rt-2');
    });

    test('classifies invalid_grant as terminal, a 5xx as transient', () async {
      final invalidGrant = MockClient((request) async {
        return _tokenResponse({'error': 'invalid_grant'}, status: 400);
      });
      await expectLater(
        TokenExchanger(httpClient: invalidGrant).refresh(
          discovery: _discovery(),
          clientId: 'test-client',
          refreshToken: 'rt-1',
        ),
        throwsA(
          isA<TokenRefreshException>().having(
            (e) => e.isTerminal,
            'isTerminal',
            isTrue,
          ),
        ),
      );

      final serverError = MockClient((request) async {
        return http.Response('boom', 503);
      });
      await expectLater(
        TokenExchanger(httpClient: serverError).refresh(
          discovery: _discovery(),
          clientId: 'test-client',
          refreshToken: 'rt-1',
        ),
        throwsA(
          isA<TokenRefreshException>().having(
            (e) => e.isTerminal,
            'isTerminal',
            isFalse,
          ),
        ),
      );
    });

    test('a thrown network error is transient, not terminal', () async {
      final client = MockClient((request) async {
        throw const SocketExceptionStub();
      });

      await expectLater(
        TokenExchanger(httpClient: client).refresh(
          discovery: _discovery(),
          clientId: 'test-client',
          refreshToken: 'rt-1',
        ),
        throwsA(
          isA<TokenRefreshException>().having(
            (e) => e.isTerminal,
            'isTerminal',
            isFalse,
          ),
        ),
      );
    });
  });

  group('TokenRefresher', () {
    test(
      'an expired access token refreshes before the wrapped request runs',
      () async {
        final events = <String>[];
        final client = MockClient((request) async {
          events.add('refresh');
          return _tokenResponse({
            'access_token': 'new-access',
            'token_type': 'Bearer',
            'expires_in': 3600,
          });
        });
        final idToken = _idToken();

        final refresher = TokenRefresher(
          session: _session(
            idToken: idToken,
            expiresAt: DateTime.now().subtract(const Duration(minutes: 5)),
          ),
          discovery: _discovery(),
          exchanger: TokenExchanger(httpClient: client),
        );

        final result = await refresher.withFreshToken((accessToken) async {
          events.add('request');
          return accessToken;
        });

        expect(events, ['refresh', 'request']);
        expect(result, 'new-access');
        expect(refresher.session.accessToken, 'new-access');
        // idToken is carried forward unchanged across a refresh.
        expect(identical(refresher.session.idToken, idToken), isTrue);
        // idTokenRaw is carried forward too, so persistence keeps working
        // even though this refresh response had no new id_token.
        expect(refresher.session.idTokenRaw, 'orig-id-token-raw');
      },
    );

    test('a 401 triggers exactly one refresh and one retry; '
        'a second 401 does not loop', () async {
      var refreshCalls = 0;
      final client = MockClient((request) async {
        refreshCalls++;
        return _tokenResponse({
          'access_token': 'new-access',
          'token_type': 'Bearer',
          'expires_in': 3600,
        });
      });

      final refresher = TokenRefresher(
        session: _session(
          idToken: _idToken(),
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
        ),
        discovery: _discovery(),
        exchanger: TokenExchanger(httpClient: client),
      );

      var requestCalls = 0;
      await expectLater(
        refresher.withFreshToken<String>((accessToken) async {
          requestCalls++;
          throw const UnauthorizedException();
        }),
        throwsA(isA<UnauthorizedException>()),
      );

      expect(refreshCalls, 1);
      // Initial attempt + exactly one retry — a persistently-401 endpoint
      // must not trigger a second refresh or a further retry.
      expect(requestCalls, 2);
    });

    test('N concurrent callers during one in-flight refresh hit the '
        'token endpoint exactly once and all N receive a result', () async {
      var tokenCalls = 0;
      final gate = Completer<void>();
      final client = MockClient((request) async {
        tokenCalls++;
        await gate.future;
        return _tokenResponse({
          'access_token': 'new-access',
          'token_type': 'Bearer',
          'expires_in': 3600,
        });
      });

      final refresher = TokenRefresher(
        session: _session(
          idToken: _idToken(),
          expiresAt: DateTime.now().subtract(const Duration(minutes: 5)),
        ),
        discovery: _discovery(),
        exchanger: TokenExchanger(httpClient: client),
      );

      final futures = List.generate(
        5,
        (_) => refresher.withFreshToken((accessToken) async => accessToken),
      );

      // Drain pending microtasks so every concurrent caller has reached
      // either the token endpoint or the shared in-flight future before
      // the mock response is released.
      await Future<void>.delayed(Duration.zero);
      expect(tokenCalls, 1);

      gate.complete();
      final results = await Future.wait(futures);

      expect(results, List.filled(5, 'new-access'));
      expect(tokenCalls, 1);
    });

    test('a rotated refresh_token replaces the old one; the old one is '
        'never sent again', () async {
      final seenRefreshTokens = <String?>[];
      var call = 0;
      final client = MockClient((request) async {
        call++;
        seenRefreshTokens.add(request.bodyFields['refresh_token']);
        if (call == 1) {
          return _tokenResponse({
            'access_token': 'access-1',
            'token_type': 'Bearer',
            'refresh_token': 'rotated-refresh-1',
            'expires_in': 3600,
          });
        }
        return _tokenResponse({
          'access_token': 'access-2',
          'token_type': 'Bearer',
          'expires_in': 3600,
        });
      });

      final refresher = TokenRefresher(
        session: _session(
          idToken: _idToken(),
          refreshToken: 'old-refresh',
          expiresAt: DateTime.now().subtract(const Duration(minutes: 5)),
        ),
        discovery: _discovery(),
        exchanger: TokenExchanger(httpClient: client),
      );

      // First refresh: proactive, session started expired.
      await refresher.withFreshToken((accessToken) async => accessToken);
      expect(refresher.session.refreshToken, 'rotated-refresh-1');

      // Second refresh: reactive, forced via a 401 so we can observe
      // which refresh token this redemption actually sends.
      var attempt = 0;
      await refresher.withFreshToken((accessToken) async {
        attempt++;
        if (attempt == 1) throw const UnauthorizedException();
        return accessToken;
      });

      expect(seenRefreshTokens, ['old-refresh', 'rotated-refresh-1']);
    });

    test(
      'invalid_grant is a terminal outcome, distinct from a transient one',
      () async {
        final client = MockClient((request) async {
          return _tokenResponse({'error': 'invalid_grant'}, status: 400);
        });

        final refresher = TokenRefresher(
          session: _session(
            idToken: _idToken(),
            expiresAt: DateTime.now().subtract(const Duration(minutes: 5)),
          ),
          discovery: _discovery(),
          exchanger: TokenExchanger(httpClient: client),
        );

        await expectLater(
          refresher.withFreshToken((accessToken) async => accessToken),
          throwsA(
            isA<TokenRefreshException>().having(
              (e) => e.isTerminal,
              'isTerminal',
              isTrue,
            ),
          ),
        );
      },
    );

    test('a transient failure (5xx) is distinct from invalid_grant and '
        'is not terminal', () async {
      final client = MockClient((request) async {
        return http.Response('server exploded', 503);
      });

      final refresher = TokenRefresher(
        session: _session(
          idToken: _idToken(),
          expiresAt: DateTime.now().subtract(const Duration(minutes: 5)),
        ),
        discovery: _discovery(),
        exchanger: TokenExchanger(httpClient: client),
      );

      await expectLater(
        refresher.withFreshToken((accessToken) async => accessToken),
        throwsA(
          isA<TokenRefreshException>().having(
            (e) => e.isTerminal,
            'isTerminal',
            isFalse,
          ),
        ),
      );
    });

    test('invalid_grant fails every queued waiter of a shared in-flight '
        'refresh instead of hanging', () async {
      final client = MockClient((request) async {
        return _tokenResponse({'error': 'invalid_grant'}, status: 400);
      });

      final refresher = TokenRefresher(
        session: _session(
          idToken: _idToken(),
          expiresAt: DateTime.now().subtract(const Duration(minutes: 5)),
        ),
        discovery: _discovery(),
        exchanger: TokenExchanger(httpClient: client),
      );

      final futures = List.generate(
        5,
        (_) => refresher.withFreshToken((accessToken) async => accessToken),
      );

      final outcomes = await Future.wait(
        futures.map(
          (f) => f.then<Object?>((v) => v).catchError((Object e) => e),
        ),
      );

      expect(outcomes, hasLength(5));
      for (final outcome in outcomes) {
        expect(outcome, isA<TokenRefreshException>());
        expect((outcome as TokenRefreshException).isTerminal, isTrue);
      }
    });
  });
}

/// Minimal stand-in for a `SocketException`-style transport failure: the
/// refresher only needs to see the `http.Client` call throw, not any
/// specific exception type.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
  @override
  String toString() => 'SocketExceptionStub';
}
