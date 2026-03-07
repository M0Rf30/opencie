// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/services/oidc/spid/acr.dart';
import 'package:opencie/services/oidc/spid/request_object.dart';
import 'package:opencie/services/oidc/as/key_pair.dart';

void main() {
  group('SpidRequestObject', () {
    late MockIdpKeyPair keyPair;

    setUpAll(() {
      keyPair = MockIdpKeyPair.generate();
    });

    test('builds a valid signed request object', () {
      final requestObject = SpidRequestObject.build(
        iss: 'https://sp.example.it',
        aud: 'https://idp.example.it',
        clientId: 'https://sp.example.it',
        scope: 'openid profile email',
        redirectUri: 'https://sp.example.it/callback',
        state: 'state-value-32-chars-minimum-ok',
        nonce: 'nonce-value-32-chars-minimum-ok',
        codeChallenge: 'E9Mrozoa2owUednMg8_p5wqichJeuWMqFH7I80dP5YE',
        acrValue: SpidLevel.l2.acrValue,
        privateKey: keyPair.privateKey,
        kid: keyPair.kid,
      );

      expect(requestObject, isNotEmpty);
      expect(requestObject.split('.').length, 3); // JWT format: header.payload.signature
    });

    test('decodes and verifies JWT structure', () {
      final requestObject = SpidRequestObject.build(
        iss: 'https://sp.example.it',
        aud: 'https://idp.example.it',
        clientId: 'https://sp.example.it',
        scope: 'openid profile email',
        redirectUri: 'https://sp.example.it/callback',
        state: 'state-value-32-chars-minimum-ok',
        nonce: 'nonce-value-32-chars-minimum-ok',
        codeChallenge: 'E9Mrozoa2owUednMg8_p5wqichJeuWMqFH7I80dP5YE',
        acrValue: SpidLevel.l2.acrValue,
        privateKey: keyPair.privateKey,
        kid: keyPair.kid,
      );

      final decoded = JWT.decode(requestObject);
      final header = decoded.header;
      final payload = decoded.payload as Map<String, dynamic>;

      // Verify header
      expect(header?['alg'], 'RS256');
      expect(header?['typ'], 'oauth-authz-req+jwt');
      expect(header?['kid'], keyPair.kid);

      // Verify payload claims
      expect(payload['iss'], 'https://sp.example.it');
      expect(payload['aud'], 'https://idp.example.it');
      expect(payload['client_id'], 'https://sp.example.it');
      expect(payload['response_type'], 'code');
      expect(payload['scope'], 'openid profile email');
      expect(payload['redirect_uri'], 'https://sp.example.it/callback');
      expect(payload['state'], 'state-value-32-chars-minimum-ok');
      expect(payload['nonce'], 'nonce-value-32-chars-minimum-ok');
      expect(payload['code_challenge'], 'E9Mrozoa2owUednMg8_p5wqichJeuWMqFH7I80dP5YE');
      expect(payload['code_challenge_method'], 'S256');
      expect(payload['acr_values'], SpidLevel.l2.acrValue);
      expect(payload['prompt'], 'consent');
      expect(payload['iat'], isNotNull);
      expect(payload['exp'], isNotNull);
      expect(payload['exp'] > payload['iat'], true);
    });

    test('includes claims request when provided', () {
      final claimsRequest = {
        'userinfo': {
          'https://attributes.spid.gov.it/fiscalNumber': null,
          'https://attributes.spid.gov.it/name': null,
        }
      };

      final requestObject = SpidRequestObject.build(
        iss: 'https://sp.example.it',
        aud: 'https://idp.example.it',
        clientId: 'https://sp.example.it',
        scope: 'openid',
        redirectUri: 'https://sp.example.it/callback',
        state: 'state-value-32-chars-minimum-ok',
        nonce: 'nonce-value-32-chars-minimum-ok',
        codeChallenge: 'E9Mrozoa2owUednMg8_p5wqichJeuWMqFH7I80dP5YE',
        acrValue: SpidLevel.l2.acrValue,
        privateKey: keyPair.privateKey,
        kid: keyPair.kid,
        claimsRequest: claimsRequest,
      );

      final decoded = JWT.decode(requestObject);
      final payload = decoded.payload as Map<String, dynamic>;

      expect(payload['claims'], isNotNull);
      expect(payload['claims']['userinfo'], isNotNull);
    });

    test('omits claims request when not provided', () {
      final requestObject = SpidRequestObject.build(
        iss: 'https://sp.example.it',
        aud: 'https://idp.example.it',
        clientId: 'https://sp.example.it',
        scope: 'openid',
        redirectUri: 'https://sp.example.it/callback',
        state: 'state-value-32-chars-minimum-ok',
        nonce: 'nonce-value-32-chars-minimum-ok',
        codeChallenge: 'E9Mrozoa2owUednMg8_p5wqichJeuWMqFH7I80dP5YE',
        acrValue: SpidLevel.l2.acrValue,
        privateKey: keyPair.privateKey,
        kid: keyPair.kid,
      );

      final decoded = JWT.decode(requestObject);
      final payload = decoded.payload as Map<String, dynamic>;

      expect(payload.containsKey('claims'), false);
    });
  });
}
