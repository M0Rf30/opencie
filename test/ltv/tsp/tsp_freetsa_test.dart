// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/services/ltv/asn1/oids.dart';
import 'package:opencie/services/ltv/tsp/tsp_client.dart';

/// Hits the live FreeTSA endpoint, so it is skipped unless explicitly enabled:
///   OPENCIE_NETWORK_TESTS=1 fvm flutter test --tags network
/// The `network` tag keeps CI's `--exclude-tags network` excluding it.
final bool _enabled = Platform.environment['OPENCIE_NETWORK_TESTS'] == '1';

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
      skip: _enabled
          ? false
          : 'requires network — set OPENCIE_NETWORK_TESTS=1 and run with --tags network',
      tags: ['network'],
    );
  });
}
