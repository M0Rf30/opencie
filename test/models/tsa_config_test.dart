// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';

import 'package:opencie/core/constants/app_constants.dart';
import 'package:opencie/models/tsa_config.dart';

void main() {
  group('tsaDisplayName', () {
    test('resolves the FreeTSA default', () {
      expect(tsaDisplayName(AppConstants.defaultTsaUrl), 'FreeTSA');
    });

    test('resolves every qualified provider by URL', () {
      for (final e in AppConstants.qualifiedTsaProviders.entries) {
        expect(tsaDisplayName(e.value), e.key);
      }
    });

    test('unknown URLs fall back to the host, then the raw string', () {
      expect(
        tsaDisplayName('https://tsa.example.org/stamp'),
        'tsa.example.org',
      );
      expect(tsaDisplayName('not a url'), 'not a url');
    });
  });

  test('only the FreeTSA default is flagged as non-qualified', () {
    expect(const TsaConfig().isFreeTsa, isTrue);
    expect(
      TsaConfig(
        serverUrl: AppConstants.qualifiedTsaProviders['Namirial']!,
      ).isFreeTsa,
      isFalse,
    );
  });
}
