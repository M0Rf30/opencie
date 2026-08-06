// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:opencie/services/secure_store.dart';

/// Platform stub that always throws [PlatformException], simulating a
/// locked keyring, a missing Secret Service, or a corrupted keystore entry.
class _FailingSecureStoragePlatform extends FlutterSecureStoragePlatform {
  static Never _fail() =>
      throw PlatformException(code: 'Unavailable', message: 'boom');

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async => _fail();

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async => _fail();

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async => _fail();

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async => _fail();

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async => _fail();

  @override
  Future<void> deleteAll({required Map<String, String> options}) async =>
      _fail();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
  });

  group('SecureStore', () {
    test('write/read/delete round-trip through the platform', () async {
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );

      await SecureStore.write('token', 'secret-value');
      expect(await SecureStore.read('token'), 'secret-value');

      await SecureStore.delete('token');
      expect(await SecureStore.read('token'), isNull);
    });

    test('read returns null on missing key', () async {
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );
      expect(await SecureStore.read('absent'), isNull);
    });

    test(
      'read swallows a PlatformException from the platform and returns null',
      () async {
        FlutterSecureStoragePlatform.instance = _FailingSecureStoragePlatform();
        expect(await SecureStore.read('token'), isNull);
      },
    );

    test(
      'write surfaces a SecureStoreException on a PlatformException',
      () async {
        FlutterSecureStoragePlatform.instance = _FailingSecureStoragePlatform();
        await expectLater(
          () => SecureStore.write('token', 'secret-value'),
          throwsA(isA<SecureStoreException>()),
        );
      },
    );

    test(
      'delete surfaces a SecureStoreException on a PlatformException',
      () async {
        FlutterSecureStoragePlatform.instance = _FailingSecureStoragePlatform();
        await expectLater(
          () => SecureStore.delete('token'),
          throwsA(isA<SecureStoreException>()),
        );
      },
    );
  });
}
