// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:opencie/services/oidc/as/server.dart';
import 'package:test/test.dart';

void main() {
  group('Federation Endpoints', () {
    late MockIdpServer idp;
    late http.Client client;

    setUp(() async {
      idp = MockIdpServer(profile: MockIdpProfile.spid);
      await idp.start();
      client = http.Client();
    });

    tearDown(() async {
      await idp.stop();
      client.close();
    });

    test('/.well-known/openid-federation returns signed JWT entity configuration', () async {
      final base = idp.baseUrl!;
      final federationUri = base.replace(path: '/.well-known/openid-federation');

      final res = await client.get(federationUri);
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], 'application/jwt');

      final jwt = res.body;
      final parts = jwt.split('.');
      expect(parts.length, 3, reason: 'JWT should have 3 parts (header.payload.signature)');

      // Decode header
      final headerJson = json.decode(
        utf8.decode(base64Url.decode(_pad(parts[0]))),
      ) as Map<String, dynamic>;
      expect(headerJson['alg'], 'RS256');
      expect(headerJson['typ'], 'entity-statement+jwt');
      expect(headerJson['kid'], isNotNull);

      // Decode payload
      final payloadJson = json.decode(
        utf8.decode(base64Url.decode(_pad(parts[1]))),
      ) as Map<String, dynamic>;

      expect(payloadJson['iss'], base.toString());
      expect(payloadJson['sub'], base.toString());
      expect(payloadJson['iat'], isA<int>());
      expect(payloadJson['exp'], isA<int>());
      expect(payloadJson['exp'], greaterThan(payloadJson['iat']));

      // Check jwks
      expect(payloadJson['jwks'], isA<Map>());
      expect(payloadJson['jwks']['keys'], isA<List>());
      expect((payloadJson['jwks']['keys'] as List).isNotEmpty, true);

      // Check metadata
      expect(payloadJson['metadata'], isA<Map>());
      final metadata = payloadJson['metadata'] as Map<String, dynamic>;
      expect(metadata['openid_provider'], isA<Map>());
      expect(metadata['federation_entity'], isA<Map>());

      final opMetadata = metadata['openid_provider'] as Map<String, dynamic>;
      expect(opMetadata['issuer'], base.toString());
      expect(opMetadata['authorization_endpoint'], isNotNull);
      expect(opMetadata['token_endpoint'], isNotNull);
      expect(opMetadata['userinfo_endpoint'], isNotNull);
      expect(opMetadata['jwks_uri'], isNotNull);
      expect(opMetadata['scopes_supported'], isA<List>());
      expect(opMetadata['response_types_supported'], ['code']);
      expect(opMetadata['id_token_signing_alg_values_supported'], ['RS256']);
      expect(opMetadata['token_endpoint_auth_methods_supported'], ['private_key_jwt']);
      expect(opMetadata['code_challenge_methods_supported'], ['S256']);
      expect(opMetadata['acr_values_supported'], isA<List>());

      final fedEntity = metadata['federation_entity'] as Map<String, dynamic>;
      expect(fedEntity['organization_name'], 'Mock IdP');
      expect(fedEntity['homepage_uri'], base.toString());
      expect(fedEntity['contacts'], isA<List>());

      // Check trust_marks
      expect(payloadJson['trust_marks'], isA<List>());
      expect((payloadJson['trust_marks'] as List).isNotEmpty, true);
      final trustMark = (payloadJson['trust_marks'] as List).first as Map<String, dynamic>;
      expect(trustMark['id'], 'https://registry.example.it/openid_provider/public/');
      expect(trustMark['trust_mark'], isA<String>());

      // Check authority_hints
      expect(payloadJson['authority_hints'], isA<List>());
    });

    test('/federation/trust_mark_status returns active:true for valid trust mark', () async {
      final base = idp.baseUrl!;
      final statusUri = base.replace(
        path: '/federation/trust_mark_status',
        queryParameters: {
          'trust_mark_id': 'https://registry.example.it/openid_provider/public/',
          'sub': base.toString(),
        },
      );

      final res = await client.get(statusUri);
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], 'application/json');

      final body = json.decode(res.body) as Map<String, dynamic>;
      expect(body['active'], true);
    });

    test('/federation/trust_mark_status returns active:false for invalid trust mark', () async {
      final base = idp.baseUrl!;
      final statusUri = base.replace(
        path: '/federation/trust_mark_status',
        queryParameters: {
          'trust_mark_id': 'bogus',
          'sub': 'bogus',
        },
      );

      final res = await client.get(statusUri);
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], 'application/json');

      final body = json.decode(res.body) as Map<String, dynamic>;
      expect(body['active'], false);
    });

    test('/federation/list returns empty array', () async {
      final base = idp.baseUrl!;
      final listUri = base.replace(path: '/federation/list');

      final res = await client.get(listUri);
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], 'application/json');

      final body = json.decode(res.body);
      expect(body, isA<List>());
      expect(body, isEmpty);
    });
  });
}

String _pad(String s) {
  final m = s.length % 4;
  return m == 0 ? s : s + '=' * (4 - m);
}
