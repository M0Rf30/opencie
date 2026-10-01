// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';

import 'package:opencie/core/l10n/app_localizations_en.dart';
import 'package:opencie/core/l10n/app_localizations_it.dart';
import 'package:opencie/features/sign/sign_requirements.dart';
import 'package:opencie/models/enrolled_card.dart';

EnrolledCard _card({DateTime? notAfter}) => EnrolledCard(
  pan: '0000000000000000',
  name: 'MARIO ROSSI',
  serial: 'RSSMRA80A01H501Z',
  notAfter: notAfter,
);

void main() {
  final now = DateTime(2026, 6, 1);
  final valid = _card(notAfter: DateTime(2034, 1, 15));
  final expired = _card(notAfter: DateTime(2024, 6, 15));

  group('firstSignBlocker', () {
    test('no document wins over everything else', () {
      expect(
        firstSignBlocker(
          hasDocument: false,
          readerReady: false,
          card: null,
          now: now,
        ),
        SignBlocker.noDocument,
      );
    });

    test('no reader comes before the card checks', () {
      expect(
        firstSignBlocker(
          hasDocument: true,
          readerReady: false,
          card: null,
          now: now,
        ),
        SignBlocker.noReader,
      );
    });

    test('no card, then expired card', () {
      expect(
        firstSignBlocker(
          hasDocument: true,
          readerReady: true,
          card: null,
          now: now,
        ),
        SignBlocker.noCard,
      );
      expect(
        firstSignBlocker(
          hasDocument: true,
          readerReady: true,
          card: expired,
          now: now,
        ),
        SignBlocker.expiredCard,
      );
    });

    test('everything met -> null; unknown expiry counts as valid', () {
      expect(
        firstSignBlocker(
          hasDocument: true,
          readerReady: true,
          card: valid,
          now: now,
        ),
        isNull,
      );
      expect(
        firstSignBlocker(
          hasDocument: true,
          readerReady: true,
          card: _card(),
          now: now,
        ),
        isNull,
      );
    });
  });

  test('every blocker has a distinct localised label', () {
    for (final l10n in [AppLocalizationsEn(), AppLocalizationsIt()]) {
      final labels = {
        for (final b in SignBlocker.values) signBlockerLabel(l10n, b),
      };
      expect(labels.length, SignBlocker.values.length);
      expect(labels.every((s) => s.isNotEmpty), isTrue);
    }
    expect(
      signBlockerLabel(AppLocalizationsEn(), SignBlocker.noDocument),
      'Select a document',
    );
    expect(
      signBlockerLabel(AppLocalizationsIt(), SignBlocker.noReader),
      'Collega un lettore',
    );
  });
}
