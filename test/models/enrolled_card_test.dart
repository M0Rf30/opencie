// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/models/enrolled_card.dart';
import 'package:opencie/models/enrolled_card_utils.dart';

void main() {
  group('EnrolledCard.toJson/fromJson', () {
    test('roundtrips all fields including lastUsed', () {
      final card = EnrolledCard(
        pan: '0000111122223333',
        name: 'MARIO ROSSI',
        serial: 'AA00000AA',
        notBefore: DateTime.utc(2020, 1, 1),
        notAfter: DateTime.utc(2030, 1, 1),
        issuer: 'CN=Test Issuer',
        subject: 'CN=Test Subject',
        certSerial: 'deadbeef',
        keyAlgorithm: 'RSA',
        mrzSurname: 'ROSSI',
        mrzGivenNames: 'MARIO',
        mrzExpiry: DateTime.utc(2029, 6, 1),
        lastUsed: DateTime.utc(2026, 3, 15, 10, 30),
      );

      final decoded = EnrolledCard.fromJson(card.toJson());

      expect(decoded.pan, card.pan);
      expect(decoded.name, card.name);
      expect(decoded.serial, card.serial);
      expect(decoded.notBefore, card.notBefore);
      expect(decoded.notAfter, card.notAfter);
      expect(decoded.issuer, card.issuer);
      expect(decoded.subject, card.subject);
      expect(decoded.certSerial, card.certSerial);
      expect(decoded.keyAlgorithm, card.keyAlgorithm);
      expect(decoded.mrzSurname, card.mrzSurname);
      expect(decoded.mrzGivenNames, card.mrzGivenNames);
      expect(decoded.mrzExpiry, card.mrzExpiry);
      expect(decoded.lastUsed, card.lastUsed);
    });

    test('fromJson on legacy blob without lastUsed leaves it null', () {
      const legacyJson = {
        'pan': '0000111122223333',
        'name': 'MARIO ROSSI',
        'serial': 'AA00000AA',
      };

      final decoded = EnrolledCard.fromJson(legacyJson);

      expect(decoded.pan, '0000111122223333');
      expect(decoded.lastUsed, isNull);
      expect(decoded.notAfter, isNull);
      expect(decoded.certSerial, isNull);
    });

    test('toJson omits lastUsed when null', () {
      const card = EnrolledCard(pan: '0000111122223333');
      expect(card.toJson().containsKey('lastUsed'), isFalse);
    });
  });

  group('missingChipData', () {
    test('true when both photoBytes and mrzSurname are null', () {
      const card = EnrolledCard(pan: '1', name: 'n', serial: 's');
      expect(card.missingChipData, isTrue);
    });

    test('true when photo is missing even with mrz present', () {
      const card = EnrolledCard(
        pan: '1',
        name: 'n',
        serial: 's',
        mrzSurname: 'ROSSI',
      );
      expect(card.missingChipData, isTrue);
    });

    test('true when mrz is missing even with photo present', () {
      final card = EnrolledCard(
        pan: '1',
        name: 'n',
        serial: 's',
        photoBytes: Uint8List.fromList([1, 2, 3]),
      );
      expect(card.missingChipData, isTrue);
    });

    test('false once both mrz and photo are present', () {
      final card = EnrolledCard(
        pan: '1',
        name: 'n',
        serial: 's',
        mrzSurname: 'ROSSI',
        photoBytes: Uint8List.fromList([1, 2, 3]),
      );
      expect(card.missingChipData, isFalse);
    });
  });

  group('copyWith', () {
    test('sets lastUsed without touching other fields', () {
      const card = EnrolledCard(pan: '0000111122223333', name: 'MARIO ROSSI');
      final used = DateTime.utc(2026, 1, 1);
      final updated = card.copyWith(lastUsed: used);

      expect(updated.lastUsed, used);
      expect(updated.name, card.name);
      expect(updated.pan, card.pan);
    });
  });

  group('mergeEnrolledCard', () {
    test('incoming non-null fields win over existing', () {
      const existing = EnrolledCard(
        pan: '0000111122223333',
        name: 'OLD NAME',
        certSerial: 'old-serial',
      );
      const incoming = EnrolledCard(
        pan: '0000111122223333',
        name: 'NEW NAME',
        certSerial: 'new-serial',
      );

      final merged = mergeEnrolledCard(existing, incoming);

      expect(merged.name, 'NEW NAME');
      expect(merged.certSerial, 'new-serial');
    });

    test('keeps existing non-null field when incoming is null (e.g. photo '
        'survives a failed re-read)', () {
      final existing = EnrolledCard(
        pan: '0000111122223333',
        photoBytes: Uint8List.fromList([1, 2, 3]),
        mrzSurname: 'ROSSI',
      );
      const incoming = EnrolledCard(
        pan: '0000111122223333',
        certSerial: 'refreshed-serial',
      );

      final merged = mergeEnrolledCard(existing, incoming);

      expect(merged.photoBytes, existing.photoBytes);
      expect(merged.mrzSurname, existing.mrzSurname);
      expect(merged.certSerial, 'refreshed-serial');
    });
  });

  group('upsertEnrolledCard', () {
    test('appends when pan is new, preserving order', () {
      const a = EnrolledCard(pan: 'AAAA');
      const b = EnrolledCard(pan: 'BBBB');

      final result = upsertEnrolledCard([a], b);

      expect(result.map((c) => c.pan), ['AAAA', 'BBBB']);
    });

    test('replaces/merges in place when pan already present', () {
      const a = EnrolledCard(pan: 'AAAA', name: 'OLD');
      const other = EnrolledCard(pan: 'BBBB', name: 'OTHER');
      const updatedA = EnrolledCard(pan: 'AAAA', name: 'NEW');

      final result = upsertEnrolledCard([a, other], updatedA);

      expect(result.length, 2);
      expect(result[0].pan, 'AAAA');
      expect(result[0].name, 'NEW');
      expect(result[1].pan, 'BBBB');
    });

    test('does not loop or duplicate on repeated upserts of the same pan', () {
      const a = EnrolledCard(pan: 'AAAA', name: 'V1');
      var cards = <EnrolledCard>[];
      cards = upsertEnrolledCard(cards, a);
      cards = upsertEnrolledCard(
        cards,
        const EnrolledCard(pan: 'AAAA', name: 'V2'),
      );
      cards = upsertEnrolledCard(
        cards,
        const EnrolledCard(pan: 'AAAA', name: 'V3'),
      );

      expect(cards.length, 1);
      expect(cards.single.name, 'V3');
    });
  });

  group('markCardUsed', () {
    test('stamps lastUsed when exactly one card is enrolled', () {
      const card = EnrolledCard(pan: '0000111122223333');
      final at = DateTime.utc(2026, 5, 1);

      final result = markCardUsed([card], at);

      expect(result.single.lastUsed, at);
    });

    test('is a no-op (same list) when zero cards are enrolled', () {
      final cards = <EnrolledCard>[];
      final result = markCardUsed(cards);
      expect(identical(result, cards), isTrue);
    });

    test('is a no-op (same list) when multiple cards are enrolled', () {
      final cards = [
        const EnrolledCard(pan: 'AAAA'),
        const EnrolledCard(pan: 'BBBB'),
      ];
      final result = markCardUsed(cards);
      expect(identical(result, cards), isTrue);
    });
  });

  group('markSelectedCardUsed', () {
    final at = DateTime.utc(2026, 5, 1);
    const a = EnrolledCard(pan: 'AAAA');
    const b = EnrolledCard(pan: 'BBBB');

    test('stamps only the selected card among several', () {
      final result = markSelectedCardUsed([a, b], 'BBBB', at);
      expect(result[0].lastUsed, isNull);
      expect(result[1].lastUsed, at);
    });

    test('falls back to markCardUsed when the PAN is null or unknown', () {
      expect(markSelectedCardUsed([a], null, at).single.lastUsed, at);
      expect(markSelectedCardUsed([a], 'ZZZZ', at).single.lastUsed, at);
      final two = [a, b];
      expect(identical(markSelectedCardUsed(two, 'ZZZZ', at), two), isTrue);
    });
  });

  group('card display helpers', () {
    test('cardFiscalCode reads the subject, then the serial', () {
      expect(
        cardFiscalCode(
          const EnrolledCard(
            pan: 'A',
            subject: 'CN=RSSMRA80A01H501Z/MARIO ROSSI',
          ),
        ),
        'RSSMRA80A01H501Z',
      );
      expect(
        cardFiscalCode(
          const EnrolledCard(pan: 'A', serial: 'bncgli85m41f205x'),
        ),
        'BNCGLI85M41F205X',
      );
      expect(
        cardFiscalCode(const EnrolledCard(pan: 'A', serial: 'AA00000AA')),
        isNull,
      );
    });

    test('cardValidity buckets by expiry', () {
      final now = DateTime.utc(2026, 1, 1);
      EnrolledCard withExpiry(DateTime? d) =>
          EnrolledCard(pan: 'A', notAfter: d);

      expect(cardValidity(withExpiry(null), now), CardValidity.active);
      expect(
        cardValidity(withExpiry(DateTime.utc(2030, 1, 1)), now),
        CardValidity.active,
      );
      expect(
        cardValidity(withExpiry(DateTime.utc(2026, 2, 1)), now),
        CardValidity.expiring,
      );
      expect(
        cardValidity(withExpiry(DateTime.utc(2025, 12, 31)), now),
        CardValidity.expired,
      );
    });

    test('cardInitials uses the first letters of up to two words', () {
      expect(
        cardInitials(const EnrolledCard(pan: 'A', name: 'mario rossi')),
        'MR',
      );
      expect(cardInitials(const EnrolledCard(pan: 'A', name: 'Giulia')), 'G');
    });
  });
}
