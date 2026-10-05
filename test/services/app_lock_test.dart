// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/services/app_lock/app_lock_service.dart';
import 'package:opencie/services/app_lock/passcode_hasher.dart';

class MemoryStorage implements AppLockStorage {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

const _fastHasher = PasscodeHasher(iterations: 1000, useIsolate: false);

void main() {
  group('PasscodeHasher', () {
    test('verifies the right passcode and rejects a wrong one', () async {
      final rec = await _fastHasher.create('123456');
      expect(await _fastHasher.verify(rec, '123456'), isTrue);
      expect(await _fastHasher.verify(rec, '123457'), isFalse);
      expect(await _fastHasher.verify(rec, ''), isFalse);
    });

    test('salt is random 16 bytes and hash is not the passcode', () async {
      final a = await _fastHasher.create('1234');
      final b = await _fastHasher.create('1234');
      expect(a.salt.length, 16);
      expect(a.salt, isNot(b.salt));
      expect(a.hash, isNot(b.hash));
      expect(String.fromCharCodes(a.hash).contains('1234'), isFalse);
    });

    test('default iterations are at least 200k', () {
      expect(PasscodeHasher.defaultIterations, greaterThanOrEqualTo(200000));
    });

    test('record round-trips through JSON and rejects garbage', () async {
      final rec = await _fastHasher.create('4321');
      final back = PasscodeRecord.tryParse(jsonEncode(rec.toJson()));
      expect(back, isNotNull);
      expect(back!.iterations, 1000);
      expect(back.version, PasscodeHasher.currentVersion);
      expect(await _fastHasher.verify(back, '4321'), isTrue);
      expect(PasscodeRecord.tryParse('nope'), isNull);
      expect(PasscodeRecord.tryParse(null), isNull);
    });

    test('constantTimeEquals compares every byte and the length', () {
      expect(PasscodeHasher.constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
      expect(PasscodeHasher.constantTimeEquals([1, 2, 3], [9, 2, 3]), isFalse);
      expect(PasscodeHasher.constantTimeEquals([1, 2, 3], [1, 2, 9]), isFalse);
      expect(PasscodeHasher.constantTimeEquals([1, 2], [1, 2, 3]), isFalse);
      expect(PasscodeHasher.constantTimeEquals([], []), isTrue);
    });

    test('isolate-backed derivation matches inline derivation', () async {
      const iso = PasscodeHasher(iterations: 1000);
      final rec = await iso.create('2468');
      expect(await _fastHasher.verify(rec, '2468'), isTrue);
    });
  });

  group('brute-force schedule', () {
    test('free attempts then 30s, 1m, 5m, 15m, 1h cap', () {
      for (var i = 0; i <= 4; i++) {
        expect(appLockDelayForFailures(i), Duration.zero);
      }
      expect(appLockDelayForFailures(5), const Duration(seconds: 30));
      expect(appLockDelayForFailures(6), const Duration(minutes: 1));
      expect(appLockDelayForFailures(7), const Duration(minutes: 5));
      expect(appLockDelayForFailures(8), const Duration(minutes: 15));
      expect(appLockDelayForFailures(9), const Duration(hours: 1));
      expect(appLockDelayForFailures(50), const Duration(hours: 1));
    });

    test('lockout persists across service instances (restart)', () async {
      final storage = MemoryStorage();
      var now = DateTime(2030, 1, 1, 12);
      AppLockService make() => AppLockService(
        storage: storage,
        hasher: _fastHasher,
        clock: () => now,
      );
      final s1 = make();
      await s1.setPasscode('1234');
      for (var i = 0; i < 4; i++) {
        expect(await s1.verify('0000'), isA<UnlockWrong>());
      }
      expect(s1.throttleRemaining, Duration.zero);
      final fifth = await s1.verify('0000') as UnlockWrong;
      expect(fifth.lockedFor, const Duration(seconds: 30));

      // "Restart": new instance reads the persisted throttle.
      final s2 = make();
      await s2.load();
      expect(s2.failures, 5);
      expect(s2.throttleRemaining, const Duration(seconds: 30));
      // Correct code is refused while throttled.
      expect(await s2.verify('1234'), isA<UnlockThrottled>());

      now = now.add(const Duration(seconds: 31));
      expect(s2.throttleRemaining, Duration.zero);
      // Sixth failure escalates to 1 minute.
      final sixth = await s2.verify('0000') as UnlockWrong;
      expect(sixth.lockedFor, const Duration(minutes: 1));

      now = now.add(const Duration(minutes: 2));
      expect(await s2.verify('1234'), isA<UnlockOk>());
      expect(s2.failures, 0);
      final s3 = make();
      await s3.load();
      expect(s3.failures, 0);
      expect(s3.throttleRemaining, Duration.zero);
    });
  });

  group('AppLockService', () {
    test('stores no clear passcode and disable wipes everything', () async {
      final storage = MemoryStorage();
      final s = AppLockService(storage: storage, hasher: _fastHasher);
      await s.setPasscode('987654');
      expect(storage.data.values.any((v) => v.contains('987654')), isFalse);
      expect((await AppLockService(storage: storage).load()).enabled, isTrue);
      await s.disable();
      expect(storage.data, isEmpty);
      expect((await s.load()).enabled, isFalse);
    });

    test('rejects invalid passcodes', () async {
      final s = AppLockService(storage: MemoryStorage(), hasher: _fastHasher);
      expect(AppLockService.isValidPasscode('123'), isFalse);
      expect(AppLockService.isValidPasscode('12a456'), isFalse);
      expect(AppLockService.isValidPasscode('1234'), isTrue);
      await expectLater(s.setPasscode('12'), throwsArgumentError);
    });

    test('config persists', () async {
      final storage = MemoryStorage();
      final s = AppLockService(storage: storage, hasher: _fastHasher);
      await s.setPasscode('1234');
      await s.saveConfig(
        const AppLockConfig(
          enabled: true,
          timeout: AutoLockTimeout.fiveHours,
          biometrics: true,
        ),
      );
      final c = await AppLockService(storage: storage).load();
      expect(c.timeout, AutoLockTimeout.fiveHours);
      expect(c.biometrics, isTrue);
    });
  });

  group('AutoLockPolicy', () {
    late DateTime now;
    late AutoLockPolicy policy;
    setUp(() {
      now = DateTime(2030);
      policy = AutoLockPolicy(clock: () => now);
    });

    test('locks after the timeout but not before', () {
      policy.left(background: true);
      now = now.add(const Duration(seconds: 59));
      expect(policy.returned(AutoLockTimeout.oneMinute), isFalse);

      policy.left(background: true);
      now = now.add(const Duration(seconds: 60));
      expect(policy.returned(AutoLockTimeout.oneMinute), isTrue);
    });

    test('each timeout boundary', () {
      for (final t in [
        AutoLockTimeout.fiveMinutes,
        AutoLockTimeout.oneHour,
        AutoLockTimeout.fiveHours,
      ]) {
        policy.left(background: true);
        now = now.add(t.duration - const Duration(seconds: 1));
        expect(policy.returned(t), isFalse, reason: t.name);
        policy.left(background: true);
        now = now.add(t.duration);
        expect(policy.returned(t), isTrue, reason: t.name);
      }
    });

    test('immediately locks on real background, not on a mere blur', () {
      expect(
        policy.shouldLockOnLeave(AutoLockTimeout.immediately, background: true),
        isTrue,
      );
      expect(
        policy.shouldLockOnLeave(AutoLockTimeout.oneMinute, background: true),
        isFalse,
      );
      policy.left(background: false);
      expect(policy.returned(AutoLockTimeout.immediately), isFalse);
      policy.left(background: true);
      expect(policy.returned(AutoLockTimeout.immediately), isTrue);
    });

    test('returning without leaving never locks', () {
      expect(policy.returned(AutoLockTimeout.immediately), isFalse);
    });

    test('idle expiry follows activity', () {
      policy.activity();
      now = now.add(const Duration(seconds: 59));
      expect(policy.idleExpired(AutoLockTimeout.oneMinute), isFalse);
      policy.activity();
      now = now.add(const Duration(seconds: 59));
      expect(policy.idleExpired(AutoLockTimeout.oneMinute), isFalse);
      now = now.add(const Duration(seconds: 2));
      expect(policy.idleExpired(AutoLockTimeout.oneMinute), isTrue);
      expect(policy.idleExpired(AutoLockTimeout.immediately), isFalse);
    });
  });
}
