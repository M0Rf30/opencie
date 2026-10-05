// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/services/ltv/asn1/oids.dart';
import 'package:opencie/services/ltv/cades/cades_lta.dart';
import 'package:opencie/services/ltv/tsp/tsp_client.dart';

import '../../services/sign/upgrade_test_support.dart';
import 'synthetic_cades.dart';

bool _hasOpenssl() {
  try {
    return Process.runSync('openssl', ['version']).exitCode == 0;
  } catch (_) {
    // Intentional: no openssl binary means "skip", not "fail".
    return false;
  }
}

void main() {
  final skip = _hasOpenssl() ? null : 'openssl is not available';

  group('OpenSSL reads the produced CAdES-LTA', () {
    late Directory dir;
    late File file;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('cades_openssl_');
      file = File('${dir.path}/doc.p7m');
      final bes = buildSyntheticCadesBes(
        eContent: Uint8List.fromList(utf8.encode('hello')),
        trueImplicit: true,
        rawUnsignedAttrs: [
          buildSyntheticAttribute(Oid.certificateValues, [1]),
        ],
      );
      final first = await CadesLtaUpgrader(
        tspClient: TspClient(httpClient: fakeTsaClient()),
        tspUrl: Uri.parse('https://tsa.test/tsr'),
      ).upgrade(bes);
      // A renewal as well, so the file carries two archive time-stamps.
      final second = await CadesLtaUpgrader(
        tspClient: TspClient(httpClient: fakeTsaClient()),
        tspUrl: Uri.parse('https://tsa.test/tsr'),
      ).upgrade(first);
      await file.writeAsBytes(second);
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('openssl asn1parse accepts the DER and shows both archive '
        'time-stamp-v3 attributes and their hash indexes', () {
      final r = Process.runSync('openssl', [
        'asn1parse',
        '-inform',
        'DER',
        '-in',
        file.path,
      ]);

      expect(r.exitCode, 0, reason: '${r.stderr}');
      final out = '${r.stdout}';
      // OpenSSL 3 prints the ETSI names; older builds print the numeric OIDs.
      // 0.4.0.1733.2.4 = id-aa-ets-archiveTimestampV3, one per stamp.
      expect(
        RegExp(
          r'OBJECT\s+:(id-aa-ets-archiveTimestampV3|0\.4\.0\.1733\.2\.4)\s*$',
          multiLine: true,
        ).allMatches(out),
        hasLength(2),
      );
      // 0.4.0.19122.1.5 = id-aa-ATSHashIndex-v3, one in each token.
      expect(
        RegExp(
          r'OBJECT\s+:(id-aa-ATSHashIndex-v3|0\.4\.0\.19122\.1\.5)\s*$',
          multiLine: true,
        ).allMatches(out),
        hasLength(2),
      );
    }, skip: skip);

    test('openssl cms -cmsout -print parses it as CMS SignedData', () {
      final r = Process.runSync('openssl', [
        'cms',
        '-cmsout',
        '-print',
        '-inform',
        'DER',
        '-in',
        file.path,
      ]);

      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect('${r.stdout}', contains('pkcs7-signedData'));
    }, skip: skip);
  });
}
