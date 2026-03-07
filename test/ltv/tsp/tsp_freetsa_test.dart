// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/services/ltv/asn1/oids.dart';
import 'package:opencie/services/ltv/tsp/tsp_client.dart';

void main() {
  group('TspClient (FreeTSA.org)', () {
    test(
      'smoke test: timestamp data with FreeTSA',
      () async {
        // Arrange
        final client = TspClient();
        final data = Uint8List.fromList([1, 2, 3, 4, 5]);
        final url = Uri.parse('https://freetsa.org/tsp');

        // Act
        final resp = await client.timestampData(
          url,
          data,
          hashAlgorithmOid: Oid.sha256,
          requestCert: true,
        );

        // Assert
        expect(resp.isSuccess, true);
        expect(resp.genTime, isNotNull);
        expect(resp.timeStampToken, isNotNull);
      },
      skip: 'requires network — run with --tags network',
      tags: ['network'],
    );
  });
}
