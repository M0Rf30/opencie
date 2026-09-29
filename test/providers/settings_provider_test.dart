// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:opencie/models/enrolled_card.dart';
import 'package:opencie/providers/settings_provider.dart';

/// Platform stub that always throws [PlatformException] for every
/// operation, simulating a locked keyring or a missing Secret Service.
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

Future<Map<String, dynamic>> _rawSettings() async {
  final prefs = await SharedPreferences.getInstance();
  final json = prefs.getString('opencie_settings');
  return json == null ? {} : jsonDecode(json) as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
  });

  group('SettingsNotifier / SecureStore availability', () {
    test('normal path: enrolling a card round-trips through a healthy secure '
        'store, and the legacy prefs blob never carries it', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(settingsProvider.notifier);
      await notifier.load();

      notifier.update(
        (s) => s.copyWith(enrolledCards: const [EnrolledCard(pan: 'AAAA')]),
      );
      await Future<void>.delayed(Duration.zero);

      final state = container.read(settingsProvider);
      expect(state.enrolledCards.map((c) => c.pan), ['AAAA']);
      expect(state.secureStorageUnavailable, isFalse);

      final raw = await _rawSettings();
      expect(raw.containsKey('enrolledCards'), isFalse);

      // A fresh notifier reading the same backing stores sees the card.
      final container2 = ProviderContainer();
      addTearDown(container2.dispose);
      final notifier2 = container2.read(settingsProvider.notifier);
      await notifier2.load();
      final state2 = container2.read(settingsProvider);
      expect(state2.enrolledCards.map((c) => c.pan), ['AAAA']);
      expect(state2.secureStorageUnavailable, isFalse);
    });

    test('read failure at load() is reported as unavailable, not absent: '
        'legacy cards are kept, the legacy prefs blob is not stripped, and no '
        'migration write is attempted', () async {
      SharedPreferences.setMockInitialValues({
        'opencie_settings': jsonEncode({
          'enrolledCards': [
            {'pan': 'AAAA'},
          ],
        }),
      });
      final failing = _ReadFailingPlatform();
      FlutterSecureStoragePlatform.instance = failing;

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(settingsProvider.notifier);
      await notifier.load();

      final state = container.read(settingsProvider);
      expect(state.enrolledCards.map((c) => c.pan), ['AAAA']);
      expect(state.secureStorageUnavailable, isTrue);
      expect(failing.writeCalls, 0);

      final raw = await _rawSettings();
      expect(raw['enrolledCards'], isNotEmpty);
    });

    test('write failure during _save() is caught and flagged instead of '
        'crashing, and the legacy prefs copy is preserved rather than '
        'stripped', () async {
      SharedPreferences.setMockInitialValues({
        'opencie_settings': jsonEncode({
          'enrolledCards': [
            {'pan': 'AAAA'},
          ],
        }),
      });
      FlutterSecureStoragePlatform.instance = _FailingSecureStoragePlatform();

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(settingsProvider.notifier);
      await notifier.load();

      var raw = await _rawSettings();
      expect(raw['enrolledCards'], isNotEmpty);
      expect(container.read(settingsProvider).secureStorageUnavailable, isTrue);

      // An unrelated settings change still triggers a save; it must not
      // throw (no unhandled async exception) and must keep preserving
      // the legacy enrolled-cards copy since the secure write fails again.
      expect(
        () => notifier.update((s) => s.copyWith(uiScale: 1.15)),
        returnsNormally,
      );
      await Future<void>.delayed(Duration.zero);

      final state = container.read(settingsProvider);
      expect(state.uiScale, 1.15);
      expect(state.enrolledCards.map((c) => c.pan), ['AAAA']);
      expect(state.secureStorageUnavailable, isTrue);

      raw = await _rawSettings();
      expect(raw['enrolledCards'], isNotEmpty);
    });
  });
}
