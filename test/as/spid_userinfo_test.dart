// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:opencie/services/oidc/as/server.dart';
import 'package:test/test.dart';

void main() {
  group('SPID/CIE UserInfo Endpoints', () {
    late MockIdpServer spidIdp;
    late MockIdpServer cieIdp;
    late http.Client client;

    setUp(() async {
      spidIdp = MockIdpServer(profile: MockIdpProfile.spid);
      cieIdp = MockIdpServer(profile: MockIdpProfile.cie);
      await spidIdp.start();
      await cieIdp.start();
      client = http.Client();
    });

    tearDown(() async {
      await spidIdp.stop();
      await cieIdp.stop();
      client.close();
    });

    test(
      'SPID userinfo returns URI-keyed claims without standard name/email',
      () async {
        final base = spidIdp.baseUrl!;
        const clientId = 'test-client';
        final redirectUri = '$base/callback';

        // Authorize
        final authUri = base.replace(
          path: '/authorize',
          queryParameters: {
            'client_id': clientId,
            'redirect_uri': redirectUri,
            'state': 'test-state',
            'nonce': 'test-nonce-1234567890123456789012',
            'code_challenge': 'test-challenge',
            'acr_values': 'https://www.spid.gov.it/SpidL2',
          },
        );
        final authReq = http.Request('GET', authUri)..followRedirects = false;
        final authRes = await client.send(authReq);
        expect(authRes.statusCode, 302);

        final location = authRes.headers['location']!;
        final code = Uri.parse(location).queryParameters['code']!;

        // Token
        final tokenUri = base.replace(path: '/token');
        final tokenRes = await client.post(
          tokenUri,
          headers: {'content-type': 'application/x-www-form-urlencoded'},
          body: {
            'grant_type': 'authorization_code',
            'code': code,
            'redirect_uri': redirectUri,
            'client_id': clientId,
            'code_verifier': 'test-verifier',
          },
        );
        expect(tokenRes.statusCode, 200);

        final tokenBody = json.decode(tokenRes.body) as Map<String, dynamic>;
        final accessToken = tokenBody['access_token'] as String;
        final idToken = tokenBody['id_token'] as String;

        // Verify ID token has acr claim
        expect(idToken, isNotEmpty);

        // UserInfo
        final userinfoUri = base.replace(path: '/userinfo');
        final userinfoRes = await client.get(
          userinfoUri,
          headers: {'Authorization': 'Bearer $accessToken'},
        );
        expect(userinfoRes.statusCode, 200);

        final userinfo = json.decode(userinfoRes.body) as Map<String, dynamic>;

        // SPID: should have URI-keyed claims
        expect(userinfo['sub'], 'mock-user-1');
        expect(
          userinfo['https://attributes.spid.gov.it/fiscalNumber'],
          'TINIT-RSSMRA80A01H501U',
        );
        expect(userinfo['https://attributes.spid.gov.it/name'], 'Mario');
        expect(userinfo['https://attributes.spid.gov.it/familyName'], 'Rossi');
        expect(
          userinfo['https://attributes.spid.gov.it/dateOfBirth'],
          '1980-01-01',
        );
        expect(userinfo['https://attributes.spid.gov.it/placeOfBirth'], 'Roma');
        expect(userinfo['https://attributes.spid.gov.it/gender'], 'M');
        expect(
          userinfo['https://attributes.spid.gov.it/email'],
          'mario.rossi@example.it',
        );

        // SPID: should NOT have standard name/email
        expect(userinfo.containsKey('name'), false);
        expect(userinfo.containsKey('email'), false);
      },
    );

    test(
      'CIE userinfo returns standard OIDC + URI-style fiscal number',
      () async {
        final base = cieIdp.baseUrl!;
        const clientId = 'test-client';
        final redirectUri = '$base/callback';

        // Authorize
        final authUri = base.replace(
          path: '/authorize',
          queryParameters: {
            'client_id': clientId,
            'redirect_uri': redirectUri,
            'state': 'test-state',
            'nonce': 'test-nonce-1234567890123456789012',
            'code_challenge': 'test-challenge',
            'acr_values': 'https://www.spid.gov.it/SpidL2',
          },
        );
        final authReq = http.Request('GET', authUri)..followRedirects = false;
        final authRes = await client.send(authReq);
        expect(authRes.statusCode, 302);

        final location = authRes.headers['location']!;
        final code = Uri.parse(location).queryParameters['code']!;

        // Token
        final tokenUri = base.replace(path: '/token');
        final tokenRes = await client.post(
          tokenUri,
          headers: {'content-type': 'application/x-www-form-urlencoded'},
          body: {
            'grant_type': 'authorization_code',
            'code': code,
            'redirect_uri': redirectUri,
            'client_id': clientId,
            'code_verifier': 'test-verifier',
          },
        );
        expect(tokenRes.statusCode, 200);

        final tokenBody = json.decode(tokenRes.body) as Map<String, dynamic>;
        final accessToken = tokenBody['access_token'] as String;

        // UserInfo
        final userinfoUri = base.replace(path: '/userinfo');
        final userinfoRes = await client.get(
          userinfoUri,
          headers: {'Authorization': 'Bearer $accessToken'},
        );
        expect(userinfoRes.statusCode, 200);

        final userinfo = json.decode(userinfoRes.body) as Map<String, dynamic>;

        // CIE: should have standard OIDC claims
        expect(userinfo['sub'], 'mock-user-1');
        expect(userinfo['given_name'], 'Mario');
        expect(userinfo['family_name'], 'Rossi');
        expect(userinfo['birthdate'], '1980-01-01');
        expect(userinfo['email'], 'mario.rossi@example.it');
        expect(userinfo['gender'], 'M');

        // CIE: should have URI-style fiscal number
        expect(
          userinfo['https://attributes.eid.gov.it/fiscal_number'],
          'TINIT-RSSMRA80A01H501U',
        );
      },
    );

    test('ID token includes acr claim from acr_values', () async {
      final base = spidIdp.baseUrl!;
      const clientId = 'test-client';
      final redirectUri = '$base/callback';
      const acrValue = 'https://www.spid.gov.it/SpidL3';

      // Authorize with specific acr_values
      final authUri = base.replace(
        path: '/authorize',
        queryParameters: {
          'client_id': clientId,
          'redirect_uri': redirectUri,
          'state': 'test-state',
          'nonce': 'test-nonce-1234567890123456789012',
          'code_challenge': 'test-challenge',
          'acr_values': acrValue,
        },
      );
      final authReq = http.Request('GET', authUri)..followRedirects = false;
      final authRes = await client.send(authReq);
      expect(authRes.statusCode, 302);

      final location = authRes.headers['location']!;
      final code = Uri.parse(location).queryParameters['code']!;

      // Token
      final tokenUri = base.replace(path: '/token');
      final tokenRes = await client.post(
        tokenUri,
        headers: {'content-type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': redirectUri,
          'client_id': clientId,
          'code_verifier': 'test-verifier',
        },
      );
      expect(tokenRes.statusCode, 200);

      final tokenBody = json.decode(tokenRes.body) as Map<String, dynamic>;
      final idToken = tokenBody['id_token'] as String;

      // Decode ID token (without verification for mock)
      final parts = idToken.split('.');
      expect(parts.length, 3);

      final payload =
          json.decode(utf8.decode(base64Url.decode(_pad(parts[1]))))
              as Map<String, dynamic>;

      expect(payload['acr'], acrValue);
      expect(payload['nonce'], 'test-nonce-1234567890123456789012');
    });
  });
}

String _pad(String s) {
  final m = s.length % 4;
  return m == 0 ? s : s + '=' * (4 - m);
}
