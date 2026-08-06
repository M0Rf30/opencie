// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opencie/services/oidc/token_refresher.dart';
import 'package:opencie/services/oidc/userinfo.dart';
import 'package:test/test.dart';

void main() {
  group('UserInfoClient.fetch', () {
    final endpoint = Uri.parse('https://idp.example/userinfo');

    test('200 returns the parsed claims map', () async {
      final client = MockClient((request) async {
        return http.Response(
          json.encode({'sub': 'user-1', 'email': 'user@example.com'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final claims = await UserInfoClient(
        httpClient: client,
      ).fetch(endpoint, 'access-token');

      expect(claims['sub'], 'user-1');
      expect(claims['email'], 'user@example.com');
    });

    test('401 throws UnauthorizedException', () async {
      final client = MockClient((request) async {
        return http.Response('unauthorized', 401);
      });

      await expectLater(
        UserInfoClient(httpClient: client).fetch(endpoint, 'access-token'),
        throwsA(isA<UnauthorizedException>()),
      );
    });

    test('500 throws UserInfoException', () async {
      final client = MockClient((request) async {
        return http.Response('boom', 500);
      });

      await expectLater(
        UserInfoClient(httpClient: client).fetch(endpoint, 'access-token'),
        throwsA(isA<UserInfoException>()),
      );
    });

    test('200 with a JSON array body throws UserInfoException', () async {
      final client = MockClient((request) async {
        return http.Response(
          json.encode([1, 2, 3]),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      await expectLater(
        UserInfoClient(httpClient: client).fetch(endpoint, 'access-token'),
        throwsA(isA<UserInfoException>()),
      );
    });
  });
}
