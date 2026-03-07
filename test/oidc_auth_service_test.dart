// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:http/http.dart' as http;
import 'package:opencie/services/oidc/as/server.dart';
import 'package:opencie/services/oidc/oidc_auth_service.dart';
import 'package:opencie/services/oidc/redirect_listener.dart';
import 'package:test/test.dart';

void main() {
  late MockIdpServer idp;
  late http.Client client;

  setUp(() async {
    idp = MockIdpServer();
    await idp.start();
    client = http.Client();
  });

  tearDown(() async {
    await idp.stop();
    client.close();
  });

  test('full auth-code+PKCE flow against mock IdP', () async {
    final issuer = idp.baseUrl!.toString();
    const clientId = 'test-client';
    const redirectUri = 'http://127.0.0.1:12345/';

    // Shared between onLaunchUrl and onListenForCallback.
    Uri? callbackUri;

    final service = OidcAuthService(
      httpClient: client,
      onLaunchUrl: (url) async {
        // Simulate browser: GET the authorize endpoint, do NOT follow redirect.
        final request = http.Request('GET', url)..followRedirects = false;
        final streamed = await client.send(request);
        final authorizeRes = await http.Response.fromStream(streamed);
        if (authorizeRes.statusCode != 302) {
          fail('Authorize did not redirect: ${authorizeRes.statusCode}');
        }
        callbackUri = Uri.parse(authorizeRes.headers['location']!);
        return true;
      },
      onListenForCallback: (redirectUri, state) async {
        // Return the callback we already captured in onLaunchUrl.
        if (callbackUri == null) {
          fail('Callback URI not captured');
        }
        return OidcRedirectListener.parseUri(callbackUri!);
      },
    );

    final session = await service.authenticate(
      issuer: issuer,
      clientId: clientId,
      redirectUri: redirectUri,
      scope: 'openid',
    );

    expect(session, isNotNull);
    expect(session.issuer, issuer);
    expect(session.clientId, clientId);
    expect(session.accessToken, isNotEmpty);
    expect(session.idToken.subject, 'mock-user-1');
    expect(session.userinfoClaims?['email'], 'mock@example.com');
  });
}
