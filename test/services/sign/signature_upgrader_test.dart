// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:opencie/models/proxy_config.dart';
import 'package:opencie/models/signature_options.dart';
import 'package:opencie/providers/settings_provider.dart' show ValidationType;
import 'package:opencie/services/ltv/asn1/oids.dart';
import 'package:opencie/services/ltv/cades/cades_parser.dart';
import 'package:opencie/services/ltv/ocsp/ocsp_models.dart';
import 'package:opencie/services/sign/signature_upgrader.dart';
import 'package:opencie/services/sign/validation_material_collector.dart';

import '../../ltv/cades/synthetic_cades.dart'
    show buildSyntheticCadesBes, buildSyntheticOcspResponse;
import '../../ltv/pades/synthetic_pdf.dart';
import 'upgrade_test_support.dart';

CollectedValidationMaterial _material({bool withRevocation = true}) {
  return CollectedValidationMaterial(
    certificates: [
      // SEQUENCE { INTEGER 1 }: structurally valid DER, not a real X.509.
      Uint8List.fromList([0x30, 0x03, 0x02, 0x01, 0x01]),
    ],
    ocspResponses: withRevocation
        ? [
            OcspResponse(
              status: OcspResponseStatus.successful,
              rawResponse: buildSyntheticOcspResponse(),
            ),
          ]
        : const [],
  );
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('upgrader_test_'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<File> writeFile(String name, Uint8List bytes) async {
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(bytes);
    return f;
  }

  List<String> filesInDir() =>
      dir.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();

  group('LtvSignatureUpgrader PAdES', () {
    test('adds DSS + document timestamp and replaces the file', () async {
      final original = buildSyntheticSignedPdf();
      final file = await writeFile('doc_signed.pdf', original);
      final requests = <Uri>[];
      final collector = StubCollector(_material());
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) => fakeTsaClient(requests: requests),
        collectorFactory: (_) => collector,
      );

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.pades,
        settings: testUpgradeSettings(),
      );

      expect(result.timestamped, isTrue);
      expect(result.revocationEmbedded, isTrue);
      expect(result.warning, isNull);

      final bytes = await file.readAsBytes();
      // Incremental updates: the original signed revision is untouched.
      expect(bytes.length, greaterThan(original.length));
      expect(bytes.sublist(0, original.length), original);
      final text = String.fromCharCodes(bytes);
      expect(text, contains('/DSS'));
      expect(text, contains('/Type /DocTimeStamp'));

      expect(requests.map((u) => u.host), ['primary.tsa.test']);
      // Atomic replace left no temp file behind.
      expect(filesInDir(), ['doc_signed.pdf']);
    });

    test('forwards the configured validation type to the collector', () async {
      final file = await writeFile('a.pdf', buildSyntheticSignedPdf());
      final collector = StubCollector(_material());
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) => fakeTsaClient(),
        collectorFactory: (_) => collector,
      );

      await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.pades,
        settings: testUpgradeSettings(validationType: ValidationType.crlOnly),
      );

      expect(collector.lastType, ValidationType.crlOnly);
    });

    test('timestamp still applied, with a warning, when no revocation '
        'evidence is available', () async {
      final file = await writeFile('a.pdf', buildSyntheticSignedPdf());
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) => fakeTsaClient(),
        collectorFactory: (_) =>
            StubCollector(_material(withRevocation: false)),
      );

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.pades,
        settings: testUpgradeSettings(),
      );

      expect(result.timestamped, isTrue);
      expect(result.revocationEmbedded, isFalse);
      expect(result.warning, SignatureUpgradeWarning.revocationUnavailable);
      expect(
        String.fromCharCodes(await file.readAsBytes()),
        contains('/Type /DocTimeStamp'),
      );
    });

    test('a crashing revocation backend degrades to a warning, not a '
        'failure', () async {
      final file = await writeFile('a.pdf', buildSyntheticSignedPdf());
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) => fakeTsaClient(),
        collectorFactory: (_) => ThrowingCollector(),
      );

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.pades,
        settings: testUpgradeSettings(),
      );

      expect(result.timestamped, isTrue);
      expect(result.warning, SignatureUpgradeWarning.revocationUnavailable);
      expect(result.detail, contains('exploded'));
    });

    test('TSA failure keeps the signed file byte-for-byte and warns', () async {
      final original = buildSyntheticSignedPdf();
      final file = await writeFile('a.pdf', original);
      final requests = <Uri>[];
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) => fakeTsaClient(
          requests: requests,
          failHosts: {'primary.tsa.test', 'fallback.tsa.test'},
        ),
        collectorFactory: (_) => StubCollector(_material()),
      );

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.pades,
        settings: testUpgradeSettings(),
      );

      expect(result.timestamped, isFalse);
      expect(result.warning, SignatureUpgradeWarning.timestampFailed);
      expect(result.detail, isNotEmpty);
      expect(await file.readAsBytes(), original);
      expect(filesInDir(), ['a.pdf']);
      expect(requests.map((u) => u.host), [
        'primary.tsa.test',
        'fallback.tsa.test',
      ]);
    });

    test('falls back to the secondary TSA when the primary fails', () async {
      final file = await writeFile('a.pdf', buildSyntheticSignedPdf());
      final requests = <Uri>[];
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) =>
            fakeTsaClient(requests: requests, failHosts: {'primary.tsa.test'}),
        collectorFactory: (_) => StubCollector(_material()),
      );

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.pades,
        settings: testUpgradeSettings(),
      );

      expect(result.timestamped, isTrue);
      expect(requests.map((u) => u.host), [
        'primary.tsa.test',
        'fallback.tsa.test',
      ]);
    });

    test('an invalid TSA URL is a warning and leaves the file alone', () async {
      final original = buildSyntheticSignedPdf();
      final file = await writeFile('a.pdf', original);
      var clientCreated = false;
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) {
          clientCreated = true;
          return fakeTsaClient();
        },
        collectorFactory: (_) => StubCollector(_material()),
      );

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.pades,
        settings: testUpgradeSettings(fallbackUrl: '').copyWithTsaUrl('nope'),
      );

      expect(result.warning, SignatureUpgradeWarning.timestampFailed);
      expect(clientCreated, isFalse);
      expect(await file.readAsBytes(), original);
    });

    test('a file that is not a usable PDF is left untouched', () async {
      final garbage = Uint8List.fromList('not a pdf at all'.codeUnits);
      final file = await writeFile('a.pdf', garbage);
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) => fakeTsaClient(),
        collectorFactory: (_) => StubCollector(_material()),
      );

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.pades,
        settings: testUpgradeSettings(),
      );

      expect(result.timestamped, isFalse);
      expect(result.warning, SignatureUpgradeWarning.timestampFailed);
      expect(await file.readAsBytes(), garbage);
      expect(filesInDir(), ['a.pdf']);
    });

    test('a missing file yields a warning instead of throwing', () async {
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) => fakeTsaClient(),
        collectorFactory: (_) => StubCollector(_material()),
      );

      final result = await upgrader.upgrade(
        path: '${dir.path}/missing.pdf',
        format: SignatureFormat.pades,
        settings: testUpgradeSettings(),
      );

      expect(result.warning, SignatureUpgradeWarning.timestampFailed);
    });

    test(
      'an unsupported SOCKS proxy fails closed (never goes direct)',
      () async {
        final original = buildSyntheticSignedPdf();
        final file = await writeFile('a.pdf', original);
        // Default HTTP client factory: builds the proxy-aware client.
        final upgrader = LtvSignatureUpgrader(
          collectorFactory: (_) => StubCollector(_material()),
        );
        final base = testUpgradeSettings();

        final result = await upgrader.upgrade(
          path: file.path,
          format: SignatureFormat.pades,
          settings: SignatureUpgradeSettings(
            tsa: base.tsa,
            proxy: const ProxyConfig(
              mode: ProxyMode.manual,
              type: ProxyType.socks5,
              host: 'proxy.test',
              port: 1080,
            ),
          ),
        );

        expect(result.warning, SignatureUpgradeWarning.timestampFailed);
        expect(result.detail, contains('socks5'));
        expect(await file.readAsBytes(), original);
      },
    );
  });

  group('LtvSignatureUpgrader CAdES', () {
    test('adds revocation values + archive timestamp', () async {
      final original = buildSyntheticCadesBes();
      final file = await writeFile('doc.p7m', original);
      final requests = <Uri>[];
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) => fakeTsaClient(requests: requests),
        collectorFactory: (_) => StubCollector(_material()),
      );

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.cades,
        settings: testUpgradeSettings(),
      );

      expect(result.timestamped, isTrue);
      expect(result.revocationEmbedded, isTrue);
      expect(result.warning, isNull);

      final upgraded = CadesSignedData.parse(await file.readAsBytes());
      expect(upgraded.getUnsignedAttribute(Oid.revocationValues), isNotNull);
      expect(upgraded.getUnsignedAttribute(Oid.archiveTimeStampV3), isNotNull);
      // B-T first: signature time-stamp, then LT, then the archive stamp.
      expect(
        upgraded.getUnsignedAttribute(Oid.signatureTimeStampToken),
        isNotNull,
      );
      expect(requests.map((u) => u.host), [
        'primary.tsa.test', // signature-time-stamp
        'primary.tsa.test', // archive-time-stamp-v3
      ]);
      expect(filesInDir(), ['doc.p7m']);
    });

    test('without revocation evidence: timestamp + warning', () async {
      final file = await writeFile('doc.p7m', buildSyntheticCadesBes());
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) => fakeTsaClient(),
        collectorFactory: (_) =>
            StubCollector(_material(withRevocation: false)),
      );

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.cades,
        settings: testUpgradeSettings(),
      );

      expect(result.timestamped, isTrue);
      expect(result.warning, SignatureUpgradeWarning.revocationUnavailable);
      final upgraded = CadesSignedData.parse(await file.readAsBytes());
      expect(upgraded.getUnsignedAttribute(Oid.archiveTimeStampV3), isNotNull);
      expect(
        upgraded.getUnsignedAttribute(Oid.signatureTimeStampToken),
        isNotNull,
      );
    });

    test('TSA rejection keeps the p7m untouched', () async {
      final original = buildSyntheticCadesBes();
      final file = await writeFile('doc.p7m', original);
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) =>
            fakeTsaClient(failHosts: {'primary.tsa.test', 'fallback.tsa.test'}),
        collectorFactory: (_) => StubCollector(_material()),
      );

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.cades,
        settings: testUpgradeSettings(),
      );

      expect(result.timestamped, isFalse);
      expect(result.warning, SignatureUpgradeWarning.timestampFailed);
      expect(await file.readAsBytes(), original);
      expect(filesInDir(), ['doc.p7m']);
    });

    test('TSA dying after the signature-time-stamp still leaves the p7m '
        'byte-identical (no partial B-T result persisted)', () async {
      final original = buildSyntheticCadesBes();
      final file = await writeFile('doc.p7m', original);
      final requests = <Uri>[];
      final upgrader = LtvSignatureUpgrader(
        // First request (signature-time-stamp) succeeds, everything after it
        // fails: the archive-time-stamp, then the fallback TSA's attempt.
        httpClientFactory: (_) =>
            fakeTsaClient(requests: requests, failAfter: 1),
        collectorFactory: (_) => StubCollector(_material()),
      );

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.cades,
        settings: testUpgradeSettings(),
      );

      expect(result.timestamped, isFalse);
      expect(result.warning, SignatureUpgradeWarning.timestampFailed);
      expect(requests.map((u) => u.host), [
        'primary.tsa.test', // B-T ok
        'primary.tsa.test', // LTA fails
        'fallback.tsa.test', // retry from the untouched original: B-T fails
      ]);
      expect(await file.readAsBytes(), original);
      expect(filesInDir(), ['doc.p7m']);
    });
  });

  group('LtvSignatureUpgrader XAdES', () {
    test(
      'is not faked: no network, file untouched, warning returned',
      () async {
        final xml = Uint8List.fromList('<Signature/>'.codeUnits);
        final file = await writeFile('doc.xml', xml);
        var clientCreated = false;
        final upgrader = LtvSignatureUpgrader(
          httpClientFactory: (_) {
            clientCreated = true;
            return http.Client();
          },
        );

        final result = await upgrader.upgrade(
          path: file.path,
          format: SignatureFormat.xades,
          settings: testUpgradeSettings(),
        );

        expect(result.timestamped, isFalse);
        expect(result.warning, SignatureUpgradeWarning.timestampFailed);
        expect(clientCreated, isFalse);
        expect(await file.readAsBytes(), xml);
      },
    );
  });

  group('SignatureFormat / SignatureOptions', () {
    test('XAdES cannot be timestamped, PAdES and CAdES can', () {
      expect(SignatureFormat.pades.supportsTimestamp, isTrue);
      expect(SignatureFormat.cades.supportsTimestamp, isTrue);
      expect(SignatureFormat.xades.supportsTimestamp, isFalse);
    });

    test('timestampRequested needs the toggle and a supporting format', () {
      const on = SignatureOptions(addTimestamp: true);
      expect(on.timestampRequested, isTrue);
      expect(
        on.copyWith(format: SignatureFormat.xades).timestampRequested,
        isFalse,
      );
      expect(const SignatureOptions().timestampRequested, isFalse);
    });
  });
}

extension on SignatureUpgradeSettings {
  SignatureUpgradeSettings copyWithTsaUrl(String url) =>
      SignatureUpgradeSettings(
        tsa: tsa.copyWith(serverUrl: url),
        proxy: proxy,
        validationType: validationType,
      );
}
