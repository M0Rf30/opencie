// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:http/http.dart' as http;
import 'package:opencie/services/oidc/as/key_pair.dart';
import 'package:opencie/services/oidc/as/server.dart';
import 'package:opencie/services/oidc/redirect_listener.dart';
import 'package:opencie/services/oidc/spid/acr.dart';
import 'package:opencie/services/oidc/spid/claims.dart';
import 'package:opencie/services/oidc/spid/spid_auth_service.dart';
import 'package:test/test.dart';

void main() {
  group('SpidAuthService end-to-end', () {
    late http.Client client;
    late MockIdpKeyPair clientKeyPair;

    setUp(() {
      client = http.Client();
      // RP signing key for request_object + private_key_jwt.
      clientKeyPair = MockIdpKeyPair.generate();
    });

    tearDown(() {
      client.close();
    });

    test('SPID L2 flow returns URI-keyed attributes and L2 ACR', () async {
      final idp = MockIdpServer(profile: MockIdpProfile.spid);
      await idp.start();
      addTearDown(idp.stop);

      final issuer = idp.baseUrl!.toString();
      const clientId = 'https://rp.example.it/';
      final redirectUri = '${idp.baseUrl}/callback';

      Uri? capturedCallback;

      final service = SpidAuthService(
        profile: SpidProfile.spid,
        level: SpidLevel.l2,
        clientId: clientId,
        redirectUri: redirectUri,
        privateKey: clientKeyPair.privateKey,
        kid: clientKeyPair.kid,
        httpClient: client,
        onLaunchUrl: (url) async {
          final req = http.Request('GET', url)..followRedirects = false;
          final res = await http.Response.fromStream(await client.send(req));
          if (res.statusCode != 302) {
            fail('Authorize did not redirect: ${res.statusCode} ${res.body}');
          }
          capturedCallback = Uri.parse(res.headers['location']!);
          return true;
        },
        onListenForCallback: (redirectUri, state) async {
          if (capturedCallback == null) fail('Callback URI not captured');
          return OidcRedirectListener.parseUri(capturedCallback!);
        },
      );

      final session = await service.authenticate(issuer: issuer);

      expect(session.profile, SpidProfile.spid);
      expect(session.level, SpidLevel.l2);
      expect(session.session.issuer, issuer);
      expect(session.session.clientId, clientId);
      expect(session.session.idToken.acr, SpidLevel.l2.acrValue);

      // SPID URI-keyed attributes
      expect(session.attributes.fiscalNumber, 'TINIT-RSSMRA80A01H501U');
      expect(session.attributes.name, 'Mario');
      expect(session.attributes.familyName, 'Rossi');
      expect(session.attributes.dateOfBirth, '1980-01-01');
      expect(session.attributes.email, 'mario.rossi@example.it');
    });

    test(
      'CIE L3 flow returns standard OIDC attrs + URI fiscal_number',
      () async {
        final idp = MockIdpServer(profile: MockIdpProfile.cie);
        await idp.start();
        addTearDown(idp.stop);

        final issuer = idp.baseUrl!.toString();
        const clientId = 'https://rp.example.it/';
        final redirectUri = '${idp.baseUrl}/callback';

        Uri? capturedCallback;

        final service = SpidAuthService(
          profile: SpidProfile.cie,
          level: SpidLevel.l3,
          clientId: clientId,
          redirectUri: redirectUri,
          privateKey: clientKeyPair.privateKey,
          kid: clientKeyPair.kid,
          httpClient: client,
          onLaunchUrl: (url) async {
            final req = http.Request('GET', url)..followRedirects = false;
            final res = await http.Response.fromStream(await client.send(req));
            if (res.statusCode != 302) {
              fail('Authorize did not redirect: ${res.statusCode} ${res.body}');
            }
            capturedCallback = Uri.parse(res.headers['location']!);
            return true;
          },
          onListenForCallback: (redirectUri, state) async {
            if (capturedCallback == null) fail('Callback URI not captured');
            return OidcRedirectListener.parseUri(capturedCallback!);
          },
        );

        final session = await service.authenticate(issuer: issuer);

        expect(session.profile, SpidProfile.cie);
        expect(session.level, SpidLevel.l3);
        expect(session.session.idToken.acr, SpidLevel.l3.acrValue);

        // CIE: standard OIDC + URI fiscal number normalized into attributes.
        expect(session.attributes.fiscalNumber, 'TINIT-RSSMRA80A01H501U');
        expect(session.attributes.name, 'Mario');
        expect(session.attributes.familyName, 'Rossi');
        expect(session.attributes.email, 'mario.rossi@example.it');
      },
    );
  });
}
