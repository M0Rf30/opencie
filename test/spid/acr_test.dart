// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/services/oidc/spid/acr.dart';

void main() {
  group('SpidLevel', () {
    test('fromAcr returns correct level for L1', () {
      final level = SpidLevel.fromAcr('https://www.spid.gov.it/SpidL1');
      expect(level, SpidLevel.l1);
    });

    test('fromAcr returns correct level for L2', () {
      final level = SpidLevel.fromAcr('https://www.spid.gov.it/SpidL2');
      expect(level, SpidLevel.l2);
    });

    test('fromAcr returns correct level for L3', () {
      final level = SpidLevel.fromAcr('https://www.spid.gov.it/SpidL3');
      expect(level, SpidLevel.l3);
    });

    test('fromAcr returns null for unknown ACR', () {
      final level = SpidLevel.fromAcr('https://unknown.example.it/L1');
      expect(level, isNull);
    });

    test('fromAcr returns null for null input', () {
      final level = SpidLevel.fromAcr(null);
      expect(level, isNull);
    });

    test('acrValue round-trip', () {
      for (final level in SpidLevel.values) {
        final parsed = SpidLevel.fromAcr(level.acrValue);
        expect(parsed, level);
      }
    });
  });
}
