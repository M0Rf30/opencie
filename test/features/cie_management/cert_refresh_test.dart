// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/features/cie_management/cert_refresh.dart';
import 'package:opencie/models/enrolled_card.dart';

void main() {
  group('cardNeedsCertRefresh', () {
    test('true when notAfter is null', () {
      const card = EnrolledCard(pan: 'AAAA', certSerial: 'abc');
      expect(cardNeedsCertRefresh(card), isTrue);
    });

    test('true when certSerial is null', () {
      final card = EnrolledCard(pan: 'AAAA', notAfter: DateTime.utc(2030, 1, 1));
      expect(cardNeedsCertRefresh(card), isTrue);
    });

    test('false when both are present', () {
      final card = EnrolledCard(
        pan: 'AAAA',
        notAfter: DateTime.utc(2030, 1, 1),
        certSerial: 'abc',
      );
      expect(cardNeedsCertRefresh(card), isFalse);
    });
  });

  group('refreshMissingCertData', () {
    test('returns null (nothing to persist) when no card needs a refresh', () async {
      final card = EnrolledCard(
        pan: 'AAAA',
        notAfter: DateTime.utc(2030, 1, 1),
        certSerial: 'abc',
      );
      var calls = 0;
      final result = await refreshMissingCertData(
        [card],
        fetchCert: (c) async {
          calls++;
          return c;
        },
      );

      expect(result, isNull);
      expect(calls, 0);
    });

    test('fetches only cards missing cert data and merges the result', () async {
      final complete = EnrolledCard(
        pan: 'BBBB',
        notAfter: DateTime.utc(2030, 1, 1),
        certSerial: 'already-there',
      );
      const incomplete = EnrolledCard(pan: 'AAAA', name: 'MARIO ROSSI');
      final fetched = incomplete.copyWith(
        notAfter: DateTime.utc(2031, 1, 1),
        certSerial: 'new-serial',
      );
      final calledWith = <String>[];

      final result = await refreshMissingCertData(
        [complete, incomplete],
        fetchCert: (c) async {
          calledWith.add(c.pan);
          return c.pan == 'AAAA' ? fetched : c;
        },
      );

      expect(calledWith, ['AAAA']);
      expect(result, isNotNull);
      expect(result!.length, 2);
      expect(result[0].pan, 'BBBB');
      expect(result[0].certSerial, 'already-there');
      expect(result[1].pan, 'AAAA');
      expect(result[1].certSerial, 'new-serial');
      expect(result[1].notAfter, DateTime.utc(2031, 1, 1));
    });

    test('returns null when the fetcher cannot enrich (no card/PIN available)', () async {
      const incomplete = EnrolledCard(pan: 'AAAA');

      // Mirrors _enrichCardWithCert's try/catch contract: on failure it
      // returns the original card unchanged rather than throwing.
      final result = await refreshMissingCertData(
        [incomplete],
        fetchCert: (c) async => c,
      );

      expect(result, isNull);
    });

    test('does not loop: fetcher is called exactly once per candidate card', () async {
      final cards = List.generate(
        5,
        (i) => EnrolledCard(pan: 'CARD$i'),
      );
      var calls = 0;

      await refreshMissingCertData(
        cards,
        fetchCert: (c) async {
          calls++;
          return c.copyWith(
            notAfter: DateTime.utc(2030, 1, 1),
            certSerial: 'serial-${c.pan}',
          );
        },
      );

      expect(calls, 5);
    });
  });
}
