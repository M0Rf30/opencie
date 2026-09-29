// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opencie/services/oidc/discovery.dart';
import 'package:test/test.dart';

http.Response _discoveryResponse(
  Map<String, Object?> body, {
  int status = 200,
}) => http.Response(
  json.encode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, Object?> _doc({
  String issuer = 'https://idp.example',
  String authorizationEndpoint = 'https://idp.example/authorize',
  String tokenEndpoint = 'https://idp.example/token',
  String jwksUri = 'https://idp.example/jwks',
}) => {
  'issuer': issuer,
  'authorization_endpoint': authorizationEndpoint,
  'token_endpoint': tokenEndpoint,
  'jwks_uri': jwksUri,
};

void main() {
  group('OidcDiscoveryClient.fetch', () {
    test('matching issuer + HTTPS + same-origin endpoints parses', () async {
      final client = MockClient((request) async {
        expect(
          request.url.toString(),
          'https://idp.example/.well-known/openid-configuration',
        );
        return _discoveryResponse(_doc());
      });
      final disc = await OidcDiscoveryClient(
        httpClient: client,
      ).fetch(Uri.parse('https://idp.example'));

      expect(disc.issuer, 'https://idp.example');
      expect(
        disc.authorizationEndpoint.toString(),
        'https://idp.example/authorize',
      );
      expect(disc.tokenEndpoint.toString(), 'https://idp.example/token');
      expect(disc.jwksUri.toString(), 'https://idp.example/jwks');
    });

    test('document declaring a different issuer throws naming both', () async {
      final client = MockClient(
        (request) async =>
            _discoveryResponse(_doc(issuer: 'https://attacker.example')),
      );
      await expectLater(
        OidcDiscoveryClient(
          httpClient: client,
        ).fetch(Uri.parse('https://idp.example')),
        throwsA(
          isA<OidcDiscoveryException>()
              .having(
                (e) => e.message,
                'message',
                contains('https://idp.example'),
              )
              .having(
                (e) => e.message,
                'message',
                contains('https://attacker.example'),
              ),
        ),
      );
    });

    test('http:// issuer throws before any request is made', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return _discoveryResponse(_doc(issuer: 'http://idp.example'));
      });
      await expectLater(
        OidcDiscoveryClient(
          httpClient: client,
        ).fetch(Uri.parse('http://idp.example')),
        throwsA(isA<OidcDiscoveryException>()),
      );
      expect(calls, 0);
    });

    test('http://localhost:PORT is allowed', () async {
      final client = MockClient(
        (request) async => _discoveryResponse(
          _doc(
            issuer: 'http://localhost:8080',
            authorizationEndpoint: 'http://localhost:8080/authorize',
            tokenEndpoint: 'http://localhost:8080/token',
            jwksUri: 'http://localhost:8080/jwks',
          ),
        ),
      );
      final disc = await OidcDiscoveryClient(
        httpClient: client,
      ).fetch(Uri.parse('http://localhost:8080'));
      expect(disc.issuer, 'http://localhost:8080');
    });

    test('http://localhost.evil.com is not treated as loopback', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return _discoveryResponse(_doc(issuer: 'http://localhost.evil.com'));
      });
      await expectLater(
        OidcDiscoveryClient(
          httpClient: client,
        ).fetch(Uri.parse('http://localhost.evil.com')),
        throwsA(isA<OidcDiscoveryException>()),
      );
      expect(calls, 0);
    });

    test('jwks_uri on a different HTTPS host is allowed (OC-36)', () async {
      // Real providers (e.g. Google) legitimately publish jwks_uri on a
      // different host/domain from the issuer; same-origin is not an
      // OIDC/RFC 8414 requirement, only HTTPS is.
      final client = MockClient(
        (request) async =>
            _discoveryResponse(_doc(jwksUri: 'https://attacker.example/jwks')),
      );
      final disc = await OidcDiscoveryClient(
        httpClient: client,
      ).fetch(Uri.parse('https://idp.example'));
      expect(disc.jwksUri, Uri.parse('https://attacker.example/jwks'));
    });

    test('jwks_uri on a different HTTPS port is allowed (OC-36)', () async {
      final client = MockClient(
        (request) async =>
            _discoveryResponse(_doc(jwksUri: 'https://idp.example:8443/jwks')),
      );
      final disc = await OidcDiscoveryClient(
        httpClient: client,
      ).fetch(Uri.parse('https://idp.example'));
      expect(disc.jwksUri, Uri.parse('https://idp.example:8443/jwks'));
    });

    test('jwks_uri on a non-HTTPS scheme still throws', () async {
      final client = MockClient(
        (request) async =>
            _discoveryResponse(_doc(jwksUri: 'http://idp.example/jwks')),
      );
      await expectLater(
        OidcDiscoveryClient(
          httpClient: client,
        ).fetch(Uri.parse('https://idp.example')),
        throwsA(
          isA<OidcDiscoveryException>().having(
            (e) => e.message,
            'message',
            contains('jwks_uri'),
          ),
        ),
      );
    });

    test('authorization_endpoint on a different HTTPS host is allowed '
        '(OC-36)', () async {
      final client = MockClient(
        (request) async => _discoveryResponse(
          _doc(authorizationEndpoint: 'https://login.example/authorize'),
        ),
      );
      final disc = await OidcDiscoveryClient(
        httpClient: client,
      ).fetch(Uri.parse('https://idp.example'));
      expect(
        disc.authorizationEndpoint,
        Uri.parse('https://login.example/authorize'),
      );
    });

    test(
      'token_endpoint on a different HTTPS host is allowed (OC-36)',
      () async {
        final client = MockClient(
          (request) async => _discoveryResponse(
            _doc(tokenEndpoint: 'https://token.example/token'),
          ),
        );
        final disc = await OidcDiscoveryClient(
          httpClient: client,
        ).fetch(Uri.parse('https://idp.example'));
        expect(disc.tokenEndpoint, Uri.parse('https://token.example/token'));
      },
    );

    test('authorization_endpoint on a non-HTTPS scheme still throws', () async {
      final client = MockClient(
        (request) async => _discoveryResponse(
          _doc(authorizationEndpoint: 'http://idp.example/authorize'),
        ),
      );
      await expectLater(
        OidcDiscoveryClient(
          httpClient: client,
        ).fetch(Uri.parse('https://idp.example')),
        throwsA(
          isA<OidcDiscoveryException>().having(
            (e) => e.message,
            'message',
            contains('authorization_endpoint'),
          ),
        ),
      );
    });

    test('a rejected document is never cached', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return _discoveryResponse(_doc(issuer: 'https://attacker.example'));
      });
      final discoveryClient = OidcDiscoveryClient(httpClient: client);
      final issuer = Uri.parse('https://idp.example');

      await expectLater(
        discoveryClient.fetch(issuer),
        throwsA(isA<OidcDiscoveryException>()),
      );
      await expectLater(
        discoveryClient.fetch(issuer),
        throwsA(isA<OidcDiscoveryException>()),
      );
      expect(calls, 2);
    });

    test('a full well-known path issuer still works', () async {
      final client = MockClient((request) async {
        expect(
          request.url.toString(),
          'https://idp.example/.well-known/openid-configuration',
        );
        return _discoveryResponse(_doc());
      });
      final disc = await OidcDiscoveryClient(httpClient: client).fetch(
        Uri.parse('https://idp.example/.well-known/openid-configuration'),
      );
      expect(disc.issuer, 'https://idp.example');
    });
  });
}
