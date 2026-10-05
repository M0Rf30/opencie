// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/services/ltv/cades/cades_lta.dart';
import 'package:opencie/services/ltv/cades/cades_models.dart';
import 'package:opencie/services/ltv/cades/cades_t.dart';
import 'package:opencie/services/ltv/tsp/tsp_client.dart';

import '../../services/sign/upgrade_test_support.dart';
import 'synthetic_cades.dart';

final _tsaUrl = Uri.parse('https://tsa.test/tsr');

void main() {
  group('CAdES TSA policy OID', () {
    test('signature-time-stamp request carries the policy', () async {
      final policies = <String?>[];
      final upgrader = CadesTUpgrader(
        tspClient: TspClient(httpClient: fakeTsaClient(policies: policies)),
        tspUrl: _tsaUrl,
        policyOid: '1.3.6.1.4.1.601.10.3.1',
      );

      await upgrader.upgrade(buildSyntheticCadesBes());

      expect(policies, ['1.3.6.1.4.1.601.10.3.1']);
    });

    test('archive-time-stamp request carries the policy', () async {
      final policies = <String?>[];
      final upgrader = CadesLtaUpgrader(
        tspClient: TspClient(httpClient: fakeTsaClient(policies: policies)),
        tspUrl: _tsaUrl,
        policyOid: '0.4.0.2023.1.1',
      );

      await upgrader.upgrade(buildSyntheticCadesBes());

      expect(policies, ['0.4.0.2023.1.1']);
    });

    test('no policy configured: no reqPolicy is sent', () async {
      final policies = <String?>[];
      final client = TspClient(httpClient: fakeTsaClient(policies: policies));

      final bt = await CadesTUpgrader(
        tspClient: client,
        tspUrl: _tsaUrl,
      ).upgrade(buildSyntheticCadesBes());
      await CadesLtaUpgrader(
        tspClient: client,
        tspUrl: _tsaUrl,
        policyOid: '  ',
      ).upgrade(bt);

      expect(policies, [null, null]);
    });

    test('an invalid policy is a CadesException, without a request', () async {
      final requests = <Uri>[];
      final client = TspClient(httpClient: fakeTsaClient(requests: requests));

      await expectLater(
        CadesTUpgrader(
          tspClient: client,
          tspUrl: _tsaUrl,
          policyOid: 'nope',
        ).upgrade(buildSyntheticCadesBes()),
        throwsA(isA<CadesException>()),
      );
      await expectLater(
        CadesLtaUpgrader(
          tspClient: client,
          tspUrl: _tsaUrl,
          policyOid: '1.2.',
        ).upgrade(buildSyntheticCadesBes()),
        throwsA(isA<CadesException>()),
      );
      expect(requests, isEmpty);
    });
  });
}
