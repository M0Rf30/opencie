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
import 'package:opencie/services/secure_store.dart';

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

  group('SettingsNotifier / languageCode', () {
    test('defaults to null (follow system) and ignores legacy keys', () async {
      SharedPreferences.setMockInitialValues({
        'opencie_settings': jsonEncode({
          'locale': 'en',
          'logLevel': 'debug',
          'includeLocation': true,
          'includeReason': true,
          'preservePdfA': true,
          'oidcIssuer': 'https://old.example/',
          'oidcClientId': 'old-client',
          'includeDate': false,
        }),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(settingsProvider.notifier).load();

      final state = container.read(settingsProvider);
      expect(state.isLoaded, isTrue);
      expect(state.languageCode, isNull);
      expect(state.includeDate, isFalse);
    });

    test(
      'set and clear persist across reloads; legacy keys not rewritten',
      () async {
        SharedPreferences.setMockInitialValues({
          'opencie_settings': jsonEncode({'locale': 'it', 'logLevel': 'debug'}),
        });
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(settingsProvider.notifier);
        await notifier.load();

        notifier.update((s) => s.copyWith(languageCode: 'en'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        var raw = await _rawSettings();
        expect(raw['languageCode'], 'en');
        for (final k in [
          'locale',
          'logLevel',
          'includeLocation',
          'includeReason',
          'preservePdfA',
          'oidcIssuer',
          'oidcClientId',
        ]) {
          expect(raw.containsKey(k), isFalse, reason: k);
        }

        final container2 = ProviderContainer();
        addTearDown(container2.dispose);
        await container2.read(settingsProvider.notifier).load();
        expect(container2.read(settingsProvider).languageCode, 'en');

        // Omitting the argument keeps the value; explicit null clears it.
        notifier.update((s) => s.copyWith(uiScale: 1.15));
        expect(container.read(settingsProvider).languageCode, 'en');
        notifier.update((s) => s.copyWith(languageCode: null));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(container.read(settingsProvider).languageCode, isNull);
        raw = await _rawSettings();
        expect(raw.containsKey('languageCode'), isFalse);
      },
    );

    test('unsupported stored language code is treated as system', () async {
      SharedPreferences.setMockInitialValues({
        'opencie_settings': jsonEncode({'languageCode': 'xx'}),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(settingsProvider.notifier).load();
      expect(container.read(settingsProvider).languageCode, isNull);
    });
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

  group('SettingsNotifier / TSA+proxy password secure storage (OC-19)', () {
    test('a legacy plaintext TSA password is migrated into SecureStore and no '
        'longer round-trips through the settings blob', () async {
      SharedPreferences.setMockInitialValues({
        'opencie_settings': jsonEncode({
          'tsaConfig': {
            'serverUrl': 'https://tsa.example/',
            'username': 'alice',
            'password': 'legacy-secret',
          },
        }),
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(settingsProvider.notifier);
      await notifier.load();

      final state = container.read(settingsProvider);
      expect(state.tsaConfig.password, 'legacy-secret');
      expect(state.secureStorageUnavailable, isFalse);

      final raw = await _rawSettings();
      expect(
        (raw['tsaConfig'] as Map).containsKey('password'),
        isFalse,
        reason:
            'password must not round-trip through plaintext prefs '
            'once migrated',
      );

      // A fresh notifier reading the same backing stores still sees the
      // password, from SecureStore this time.
      final container2 = ProviderContainer();
      addTearDown(container2.dispose);
      final notifier2 = container2.read(settingsProvider.notifier);
      await notifier2.load();
      expect(
        container2.read(settingsProvider).tsaConfig.password,
        'legacy-secret',
      );
    });

    test('a secure-store write failure preserves the plaintext proxy password '
        'in prefs instead of dropping it', () async {
      SharedPreferences.setMockInitialValues({
        'opencie_settings': jsonEncode({
          'proxyConfig': {
            'mode': 'manual',
            'type': 'http',
            'host': 'proxy.example',
            'port': 8080,
            'username': 'bob',
            'password': 'proxy-secret',
          },
        }),
      });
      FlutterSecureStoragePlatform.instance = _FailingSecureStoragePlatform();

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(settingsProvider.notifier);
      await notifier.load();

      expect(container.read(settingsProvider).secureStorageUnavailable, isTrue);
      expect(
        container.read(settingsProvider).proxyConfig.password,
        'proxy-secret',
      );

      // The plaintext copy must survive a subsequent save too, not just
      // the initial migration attempt.
      await notifier.update((s) => s.copyWith(uiScale: 1.15));
      final raw = await _rawSettings();
      expect((raw['proxyConfig'] as Map)['password'], 'proxy-secret');
    });
  });

  group('SettingsNotifier._save awaited (OC-20)', () {
    test('update() awaits the underlying save: state is persisted by the '
        'time the call returns', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(settingsProvider.notifier);
      await notifier.load();

      await notifier.update((s) => s.copyWith(uiScale: 1.30));

      final raw = await _rawSettings();
      expect(raw['uiScale'], 1.30);
    });
  });

  group('SettingsNotifier selected card', () {
    const a = EnrolledCard(pan: 'AAAA', name: 'ALFA');
    const b = EnrolledCard(pan: 'BBBB', name: 'BRAVO');
    const c = EnrolledCard(pan: 'CCCC', name: 'CHARLIE');

    Future<(ProviderContainer, SettingsNotifier)> boot() async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(settingsProvider.notifier);
      await notifier.load();
      return (container, notifier);
    }

    test(
      'defaults to the first enrolled card, and to none when empty',
      () async {
        final (container, notifier) = await boot();
        expect(container.read(settingsProvider).selectedCard, isNull);

        await notifier.update((s) => s.copyWith(enrolledCards: [a, b, c]));

        final state = container.read(settingsProvider);
        expect(state.selectedCardPan, isNull);
        expect(state.selectedCard?.pan, 'AAAA');
      },
    );

    test(
      'selectCard switches the active card and ignores unknown PANs',
      () async {
        final (container, notifier) = await boot();
        await notifier.update((s) => s.copyWith(enrolledCards: [a, b, c]));

        await notifier.selectCard('BBBB');
        expect(container.read(settingsProvider).selectedCard?.pan, 'BBBB');

        await notifier.selectCard('ZZZZ');
        expect(container.read(settingsProvider).selectedCard?.pan, 'BBBB');
      },
    );

    test('the selection survives a reload', () async {
      final (_, notifier) = await boot();
      await notifier.update((s) => s.copyWith(enrolledCards: [a, b, c]));
      await notifier.selectCard('CCCC');

      final (container2, _) = await boot();
      final state = container2.read(settingsProvider);
      expect(state.selectedCardPan, 'CCCC');
      expect(state.selectedCard?.pan, 'CCCC');
    });

    test(
      'removing the selected card falls back to the first remaining one',
      () async {
        final (container, notifier) = await boot();
        await notifier.update((s) => s.copyWith(enrolledCards: [a, b, c]));
        await notifier.selectCard('BBBB');

        await notifier.update((s) => s.copyWith(enrolledCards: [a, c]));

        final state = container.read(settingsProvider);
        expect(state.selectedCardPan, 'AAAA');
        expect(state.selectedCard?.pan, 'AAAA');

        // The corrected selection is what got persisted.
        final (container2, _) = await boot();
        expect(container2.read(settingsProvider).selectedCard?.pan, 'AAAA');
      },
    );

    test('removing every card clears the selection', () async {
      final (container, notifier) = await boot();
      await notifier.update((s) => s.copyWith(enrolledCards: [a, b]));
      await notifier.selectCard('BBBB');

      await notifier.update((s) => s.copyWith(enrolledCards: const []));

      final state = container.read(settingsProvider);
      expect(state.selectedCardPan, isNull);
      expect(state.selectedCard, isNull);
    });

    test(
      'a stale persisted PAN falls back to the first card on load',
      () async {
        final (_, notifier) = await boot();
        await notifier.update((s) => s.copyWith(enrolledCards: [a, b]));
        await notifier.selectCard('BBBB');
        // Cards changed behind the selection's back (e.g. restored backup).
        await SecureStore.write(
          'opencie_enrolled_cards',
          jsonEncode([a.toJson()]),
        );

        final (container2, _) = await boot();
        expect(container2.read(settingsProvider).selectedCard?.pan, 'AAAA');
      },
    );

    test('signPan stays empty whatever is enrolled or selected (the native '
        'library matches a different key; the presented card signs)', () async {
      final (container, notifier) = await boot();
      await notifier.update((s) => s.copyWith(enrolledCards: [a]));
      expect(container.read(settingsProvider).signPan, '');

      await notifier.update((s) => s.copyWith(enrolledCards: [a, b, c]));
      expect(container.read(settingsProvider).signPan, '');

      await notifier.selectCard('BBBB');
      expect(container.read(settingsProvider).signPan, '');
    });
  });
}
