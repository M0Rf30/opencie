// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/services/pin_policy.dart';

void main() {
  group('validateCiePin', () {
    test('accepts a reasonable PIN', () {
      expect(validateCiePin('40391827'), isNull);
    });

    test('accepts the non-wrapping boundary case 89012345', () {
      expect(validateCiePin('89012345'), isNull);
    });

    test('rejects short input as tooShort', () {
      expect(validateCiePin('1234567'), PinWeakness.tooShort);
    });

    test('rejects long input as tooShort', () {
      expect(validateCiePin('123456789'), PinWeakness.tooShort);
    });

    test('rejects a 4-digit new PIN (a new CIE PIN is always 8 digits)', () {
      expect(validateCiePin('4039'), PinWeakness.tooShort);
    });
  });

  group('isAcceptedPinEntry', () {
    test('accepts 4 or 8 digits, including weak-looking PINs', () {
      expect(isAcceptedPinEntry('4039'), isTrue);
      expect(isAcceptedPinEntry('40391827'), isTrue);
      expect(isAcceptedPinEntry('12345678'), isTrue);
    });

    test('rejects other lengths and non-digits', () {
      expect(isAcceptedPinEntry('40391'), isFalse);
      expect(isAcceptedPinEntry(''), isFalse);
      expect(isAcceptedPinEntry('4039182a'), isFalse);
    });
  });

  group('validateCiePin (continued)', () {
    test('rejects non-numeric input', () {
      expect(validateCiePin('1234abcd'), PinWeakness.notNumeric);
    });

    test('tooShort takes precedence over notNumeric', () {
      expect(validateCiePin('abcdefg'), PinWeakness.tooShort);
    });

    test('rejects all-same-digit PINs', () {
      expect(validateCiePin('11111111'), PinWeakness.allSameDigit);
    });

    test('rejects ascending sequential PINs', () {
      expect(validateCiePin('12345678'), PinWeakness.sequential);
    });

    test('rejects descending sequential PINs', () {
      expect(validateCiePin('87654321'), PinWeakness.sequential);
    });

    test('rejects repeated 2-digit group PINs', () {
      expect(validateCiePin('12121212'), PinWeakness.repeatedPair);
    });

    test('rejects repeated 4-digit group PINs', () {
      expect(validateCiePin('12341234'), PinWeakness.repeatedPair);
    });
  });
}
