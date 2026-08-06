// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';

import 'package:opencie/services/pin_throttle.dart';

void main() {
  DateTime now = DateTime(2026, 1, 1);
  PinThrottle.clock = () => now;

  setUp(() {
    now = DateTime(2026, 1, 1);
    PinThrottle.clock = () => now;
    PinThrottle.reset();
  });

  group('PinThrottle', () {
    test('first four failures impose no delay', () {
      for (var i = 0; i < 4; i++) {
        PinThrottle.recordFailure();
        expect(PinThrottle.isLocked, isFalse);
        expect(PinThrottle.remaining, Duration.zero);
      }
    });

    test('5th failure locks for ~30s', () {
      for (var i = 0; i < 5; i++) {
        PinThrottle.recordFailure();
      }
      expect(PinThrottle.isLocked, isTrue);
      expect(PinThrottle.remaining, const Duration(seconds: 30));
    });

    test('6th failure locks for ~60s', () {
      for (var i = 0; i < 6; i++) {
        PinThrottle.recordFailure();
      }
      expect(PinThrottle.remaining, const Duration(seconds: 60));
    });

    test('7th failure saturates the lockout at 90s', () {
      for (var i = 0; i < 7; i++) {
        PinThrottle.recordFailure();
      }
      expect(PinThrottle.remaining, const Duration(seconds: 90));
    });

    test('8th and further failures stay capped at 90s, not growing', () {
      for (var i = 0; i < 8; i++) {
        PinThrottle.recordFailure();
      }
      expect(PinThrottle.remaining, const Duration(seconds: 90));

      for (var i = 0; i < 10; i++) {
        PinThrottle.recordFailure();
      }
      expect(PinThrottle.remaining, const Duration(seconds: 90));
    });

    test('reset clears the lockout and failure count', () {
      for (var i = 0; i < 7; i++) {
        PinThrottle.recordFailure();
      }
      expect(PinThrottle.isLocked, isTrue);

      PinThrottle.reset();

      expect(PinThrottle.isLocked, isFalse);
      expect(PinThrottle.remaining, Duration.zero);

      // Lockout curve restarts from the beginning after reset.
      for (var i = 0; i < 4; i++) {
        PinThrottle.recordFailure();
      }
      expect(PinThrottle.isLocked, isFalse);
    });

    test('remaining decays to zero as time passes', () {
      for (var i = 0; i < 5; i++) {
        PinThrottle.recordFailure();
      }
      expect(PinThrottle.remaining, const Duration(seconds: 30));

      now = now.add(const Duration(seconds: 10));
      expect(PinThrottle.remaining, const Duration(seconds: 20));

      now = now.add(const Duration(seconds: 20));
      expect(PinThrottle.remaining, Duration.zero);
      expect(PinThrottle.isLocked, isFalse);

      now = now.add(const Duration(seconds: 100));
      expect(PinThrottle.remaining, Duration.zero);
    });
  });
}
