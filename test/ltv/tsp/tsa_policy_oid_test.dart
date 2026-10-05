// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/services/ltv/tsp/tsp_client.dart';

import '../../services/sign/upgrade_test_support.dart';

final _tsaUrl = Uri.parse('https://tsa.test/tsr');

void main() {
  group('normalizeTsaPolicyOid', () {
    test('blank means "no policy"', () {
      expect(normalizeTsaPolicyOid(null), isNull);
      expect(normalizeTsaPolicyOid(''), isNull);
      expect(normalizeTsaPolicyOid('   '), isNull);
    });

    test('accepts and trims dotted OIDs', () {
      expect(normalizeTsaPolicyOid('1.2.3.4'), '1.2.3.4');
      expect(normalizeTsaPolicyOid('  0.4.0.2023.1.1 '), '0.4.0.2023.1.1');
      expect(normalizeTsaPolicyOid('2.999.1'), '2.999.1');
      expect(normalizeTsaPolicyOid('1.39'), '1.39');
    });

    test('rejects everything that is not a dotted OID', () {
      for (final bad in [
        'abc',
        '1',
        '1.',
        '.1.2',
        '1..2',
        '1.2.x',
        '3.1.2',
        '1.2.03',
        '1.40',
        '0.40.1',
        'urn:oid:1.2.3',
        '1.2.3 4',
      ]) {
        expect(
          () => normalizeTsaPolicyOid(bad),
          throwsA(isA<TspException>()),
          reason: bad,
        );
      }
    });
  });

  group('TspClient.timestampData policyOid', () {
    test('is sent as reqPolicy in the TimeStampReq', () async {
      final policies = <String?>[];
      final client = TspClient(httpClient: fakeTsaClient(policies: policies));

      final resp = await client.timestampData(
        _tsaUrl,
        _data,
        policyOid: ' 1.2.3.4 ',
      );

      expect(resp.isSuccess, isTrue);
      expect(policies, ['1.2.3.4']);
    });

    test('blank policy sends no reqPolicy', () async {
      final policies = <String?>[];
      final client = TspClient(httpClient: fakeTsaClient(policies: policies));

      await client.timestampData(_tsaUrl, _data, policyOid: '');
      await client.timestampData(_tsaUrl, _data);

      expect(policies, [null, null]);
    });

    test('an invalid policy throws TspException before any request', () async {
      final requests = <Uri>[];
      final client = TspClient(httpClient: fakeTsaClient(requests: requests));

      await expectLater(
        client.timestampData(_tsaUrl, _data, policyOid: 'not-an-oid'),
        throwsA(
          isA<TspException>().having(
            (e) => e.message,
            'message',
            contains('invalid TSA policy OID'),
          ),
        ),
      );
      expect(requests, isEmpty);
    });
  });
}

final _data = Uint8List.fromList([1, 2, 3]);
