// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:opencie/services/oidc/id_token.dart';
import 'package:opencie/services/oidc/oidc_session.dart';

/// Platform stub whose reads always fail (unavailable Secret Service) but
/// whose writes would otherwise succeed — used to prove that a read
/// failure never triggers a migration write attempt.
class _ReadFailingPlatform extends FlutterSecureStoragePlatform {
  int writeCalls = 0;
  final Map<String, String> data = {};

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async => throw PlatformException(code: 'Unavailable', message: 'boom');

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    writeCalls++;
    data[key] = value;
  }

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async => data.containsKey(key);

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async => data.remove(key);

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async => data;

  @override
  Future<void> deleteAll({required Map<String, String> options}) async =>
      data.clear();
}

/// A minimal but well-formed (and independently verifiable) ID token JWT —
/// synthetic test material only, HS256-signed with an obviously-fake secret.
String _fakeIdTokenRaw() {
  final now = DateTime.now().toUtc();
  final jwt = JWT({
    'iss': 'https://idp.example',
    'sub': 'test-subject',
    'aud': 'test-client',
    'iat': now.millisecondsSinceEpoch ~/ 1000,
    'exp': now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
  });
  return jwt.sign(SecretKey('test-only-fake-signing-secret'));
}

String _legacySessionJson() => json.encode({
  'issuer': 'https://idp.example',
  'client_id': 'test-client',
  'id_token_raw': _fakeIdTokenRaw(),
  'access_token': 'legacy-access-token',
  'token_type': 'Bearer',
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
  });

  group('OidcSession.load secure-store availability', () {
    test(
      'normal path: save/load round-trips through a healthy store',
      () async {
        final idTokenRaw = _fakeIdTokenRaw();
        final now = DateTime.now().toUtc();
        await OidcSession.save(
          OidcSession(
            issuer: 'https://idp.example',
            clientId: 'test-client',
            idToken: IdToken(
              issuer: 'https://idp.example',
              subject: 'test-subject',
              audience: 'test-client',
              expiration: now.add(const Duration(hours: 1)),
              issuedAt: now,
            ),
            idTokenRaw: idTokenRaw,
            accessToken: 'access',
            tokenType: 'Bearer',
          ),
        );

        final session = await OidcSession.load();
        expect(session, isNotNull);
        expect(session!.accessToken, 'access');
        expect(session.issuer, 'https://idp.example');
      },
    );

    test('read failure is reported as unavailable, not absent: the legacy '
        'plaintext session is used for this run and its prefs entry is not '
        'removed, with no migration write attempted', () async {
      SharedPreferences.setMockInitialValues({
        'opencie_oidc_session': _legacySessionJson(),
      });
      final failing = _ReadFailingPlatform();
      FlutterSecureStoragePlatform.instance = failing;

      final session = await OidcSession.load();

      expect(session, isNotNull);
      expect(session!.accessToken, 'legacy-access-token');
      expect(failing.writeCalls, 0);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('opencie_oidc_session'), isNotNull);
    });

    test(
      'read failure with no legacy copy returns null instead of throwing',
      () async {
        FlutterSecureStoragePlatform.instance = _ReadFailingPlatform();

        expect(await OidcSession.load(), isNull);
      },
    );
  });
}
