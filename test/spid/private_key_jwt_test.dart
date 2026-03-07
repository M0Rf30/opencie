// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/services/oidc/spid/private_key_jwt.dart';
import 'package:opencie/services/oidc/as/key_pair.dart';

void main() {
  group('PrivateKeyJwt', () {
    late MockIdpKeyPair keyPair;

    setUpAll(() {
      keyPair = MockIdpKeyPair.generate();
    });

    test('builds a valid client assertion JWT', () {
      final assertion = PrivateKeyJwt.build(
        clientId: 'https://sp.example.it',
        tokenEndpoint: Uri.parse('https://idp.example.it/token'),
        privateKey: keyPair.privateKey,
        kid: keyPair.kid,
      );

      expect(assertion, isNotEmpty);
      expect(assertion.split('.').length, 3); // JWT format
    });

    test('decodes and verifies JWT structure', () {
      final assertion = PrivateKeyJwt.build(
        clientId: 'https://sp.example.it',
        tokenEndpoint: Uri.parse('https://idp.example.it/token'),
        privateKey: keyPair.privateKey,
        kid: keyPair.kid,
      );

      final decoded = JWT.decode(assertion);
      final header = decoded.header;
      final payload = decoded.payload as Map<String, dynamic>;

      // Verify header
      expect(header?['alg'], 'RS256');
      expect(header?['typ'], 'JWT');
      expect(header?['kid'], keyPair.kid);

      // Verify payload claims
      expect(payload['iss'], 'https://sp.example.it');
      expect(payload['sub'], 'https://sp.example.it');
      expect(payload['aud'], 'https://idp.example.it/token');
      expect(payload['jti'], isNotNull);
      expect(payload['iat'], isNotNull);
      expect(payload['exp'], isNotNull);
    });

    test('iss equals sub', () {
      final assertion = PrivateKeyJwt.build(
        clientId: 'https://sp.example.it',
        tokenEndpoint: Uri.parse('https://idp.example.it/token'),
        privateKey: keyPair.privateKey,
        kid: keyPair.kid,
      );

      final decoded = JWT.decode(assertion);
      final payload = decoded.payload as Map<String, dynamic>;

      expect(payload['iss'], payload['sub']);
    });

    test('exp is greater than iat', () {
      final assertion = PrivateKeyJwt.build(
        clientId: 'https://sp.example.it',
        tokenEndpoint: Uri.parse('https://idp.example.it/token'),
        privateKey: keyPair.privateKey,
        kid: keyPair.kid,
      );

      final decoded = JWT.decode(assertion);
      final payload = decoded.payload as Map<String, dynamic>;

      expect(payload['exp'] > payload['iat'], true);
    });

    test('jti is unique across calls', () {
      final assertion1 = PrivateKeyJwt.build(
        clientId: 'https://sp.example.it',
        tokenEndpoint: Uri.parse('https://idp.example.it/token'),
        privateKey: keyPair.privateKey,
        kid: keyPair.kid,
      );

      final assertion2 = PrivateKeyJwt.build(
        clientId: 'https://sp.example.it',
        tokenEndpoint: Uri.parse('https://idp.example.it/token'),
        privateKey: keyPair.privateKey,
        kid: keyPair.kid,
      );

      final decoded1 = JWT.decode(assertion1);
      final decoded2 = JWT.decode(assertion2);
      final payload1 = decoded1.payload as Map<String, dynamic>;
      final payload2 = decoded2.payload as Map<String, dynamic>;

      expect(payload1['jti'], isNotNull);
      expect(payload2['jti'], isNotNull);
      expect(payload1['jti'] != payload2['jti'], true);
    });

    test('respects custom TTL', () {
      final assertion = PrivateKeyJwt.build(
        clientId: 'https://sp.example.it',
        tokenEndpoint: Uri.parse('https://idp.example.it/token'),
        privateKey: keyPair.privateKey,
        kid: keyPair.kid,
        ttl: const Duration(minutes: 10),
      );

      final decoded = JWT.decode(assertion);
      final payload = decoded.payload as Map<String, dynamic>;

      final iat = payload['iat'] as int;
      final exp = payload['exp'] as int;
      final ttlSeconds = exp - iat;

      // Should be approximately 10 minutes (600 seconds)
      expect(ttlSeconds, greaterThan(590));
      expect(ttlSeconds, lessThan(610));
    });

    test('kClientAssertionType constant is correct', () {
      expect(
        kClientAssertionType,
        'urn:ietf:params:oauth:client-assertion-type:jwt-bearer',
      );
    });
  });
}
