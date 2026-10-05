// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opencie/models/proxy_config.dart';
import 'package:opencie/models/signature_options.dart';
import 'package:opencie/providers/settings_provider.dart' show ValidationType;
import 'package:opencie/services/ltv/asn1/der.dart'
    show bytesEqual, derDecode, derEncode, sha256Of;
import 'package:opencie/services/ltv/asn1/oids.dart';
import 'package:opencie/services/ltv/cades/cades_parser.dart';
import 'package:opencie/services/ltv/ocsp/ocsp_models.dart';
import 'package:opencie/services/sign/signature_upgrader.dart';
import 'package:opencie/services/sign/validation_material_collector.dart';
import 'package:pointycastle/asn1.dart';

import '../../ltv/cades/ats_v3_reference.dart';
import '../../ltv/cades/synthetic_cades.dart'
    show
        buildSyntheticAttribute,
        buildSyntheticCadesBes,
        buildSyntheticOcspResponse;
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

final _signerCert = Uint8List.fromList([0x30, 0x03, 0x02, 0x01, 0x01]);
final _tsaIssuerCert = Uint8List.fromList([0x30, 0x03, 0x02, 0x01, 0x7B]);

/// The BasicOCSPResponse inside `buildSyntheticOcspResponse(marker: 42)`.
final _tsaOcspMarker = Uint8List.fromList([0x30, 0x03, 0x02, 0x01, 0x2A]);

/// Collector stub that answers the signer lookup (certificates not
/// containing the fake TSA certificate) with [_material], and the lookup for
/// the TSA that signed the first time-stamp with the TSA certificate, its
/// issuer and, unless [tsaRevocation] is false, a distinct OCSP response.
StubCollector _tsaAwareCollector({bool tsaRevocation = true}) {
  return StubCollector(
    _material(),
    resolver: (certs) {
      final isTsa = certs.any((c) => bytesEqual(c, fakeTsaCertificate));
      if (!isTsa) return _material();
      return CollectedValidationMaterial(
        certificates: [fakeTsaCertificate, _tsaIssuerCert],
        ocspResponses: tsaRevocation
            ? [
                OcspResponse(
                  status: OcspResponseStatus.successful,
                  rawResponse: buildSyntheticOcspResponse(marker: 42),
                ),
              ]
            : const [],
      );
    },
  );
}

List<int> _offsets(Uint8List bytes, List<int> needle) {
  final out = <int>[];
  for (var i = 0; i + needle.length <= bytes.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) out.add(i);
  }
  return out;
}

List<int> _textOffsets(Uint8List bytes, String needle) =>
    _offsets(bytes, needle.codeUnits);

bool _contains(Uint8List bytes, List<int> needle) =>
    _offsets(bytes, needle).isNotEmpty;

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

      // B-T stamp + B-LTA stamp, both from the primary TSA.
      expect(requests.map((u) => u.host), [
        'primary.tsa.test',
        'primary.tsa.test',
      ]);
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
      // The fallback TSA serves both DocTimeStamps (#1 and #2).
      expect(requests.map((u) => u.host), [
        'primary.tsa.test',
        'fallback.tsa.test',
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
      'an unreachable SOCKS proxy fails closed (never goes direct)',
      () async {
        final original = buildSyntheticSignedPdf();
        final file = await writeFile('a.pdf', original);
        // A local port with nothing listening: connects are refused at once.
        final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final deadPort = probe.port;
        await probe.close();
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
            proxy: ProxyConfig(
              mode: ProxyMode.manual,
              type: ProxyType.socks5,
              host: '127.0.0.1',
              port: deadPort,
            ),
          ),
        );

        expect(result.warning, SignatureUpgradeWarning.timestampFailed);
        expect(result.detail, contains('SOCKS'));
        expect(await file.readAsBytes(), original);
      },
    );

    test('builds the full baseline sequence: DocTimeStamp #1 (B-T), DSS '
        'with signer + TSA #1 chain (B-LT), DocTimeStamp #2 (B-LTA)', () async {
      final original = buildSyntheticSignedPdf();
      final file = await writeFile('doc_signed.pdf', original);
      final imprints = <Uint8List>[];
      final collector = _tsaAwareCollector();
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) => fakeTsaClient(imprints: imprints),
        collectorFactory: (_) => collector,
      );

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.pades,
        settings: testUpgradeSettings(validationType: ValidationType.crlFirst),
      );

      expect(result.timestamped, isTrue);
      expect(result.revocationEmbedded, isTrue);
      expect(result.warning, isNull);

      final bytes = await file.readAsBytes();
      // The signed revision is untouched: only incremental updates follow.
      expect(bytes.sublist(0, original.length), original);

      // Four revisions: signature, stamp #1, DSS, stamp #2.
      final eofs = _textOffsets(bytes, '%%EOF');
      expect(eofs, hasLength(4));
      const eofLen = 6; // '%%EOF\n'
      final stamp1 = bytes.sublist(eofs[0] + eofLen, eofs[1] + eofLen);
      final dss = bytes.sublist(eofs[1] + eofLen, eofs[2] + eofLen);
      final stamp2 = bytes.sublist(eofs[2] + eofLen, eofs[3] + eofLen);

      expect(_textOffsets(stamp1, '/Type /DocTimeStamp'), hasLength(1));
      expect(_textOffsets(stamp1, '/Type /DSS'), isEmpty);
      expect(_textOffsets(dss, '/Type /DSS'), hasLength(1));
      expect(_textOffsets(dss, '/Type /DocTimeStamp'), isEmpty);
      expect(_textOffsets(stamp2, '/Type /DocTimeStamp'), hasLength(1));
      expect(_textOffsets(stamp2, '/Type /DSS'), isEmpty);

      // The DSS carries the signer chain AND the TSA #1 chain with its
      // revocation evidence.
      expect(_contains(dss, _signerCert), isTrue);
      expect(_contains(dss, fakeTsaCertificate), isTrue);
      expect(_contains(dss, _tsaIssuerCert), isTrue);
      expect(
        _contains(dss, buildSyntheticOcspResponse(marker: 42)),
        isTrue,
        reason: 'TSA #1 OCSP response',
      );
      expect(_contains(dss, buildSyntheticOcspResponse()), isTrue);

      // The collector was asked for the TSA #1 chain too, honouring the
      // configured validation type.
      expect(collector.calls, hasLength(2));
      expect(
        collector.calls[1].any((c) => bytesEqual(c, fakeTsaCertificate)),
        isTrue,
      );
      expect(collector.lastType, ValidationType.crlFirst);

      // Each DocTimeStamp imprint is the SHA-256 of exactly the bytes its
      // /ByteRange covers; stamp #1 ends at its own revision, stamp #2
      // covers the whole file (so it protects the DSS).
      final text = String.fromCharCodes(bytes);
      final ranges = RegExp(
        r'/ByteRange \[0 (\d+) (\d+) (\d+)\]',
      ).allMatches(text).toList();
      expect(ranges, hasLength(2));
      expect(imprints, hasLength(2));
      for (var i = 0; i < 2; i++) {
        final a = int.parse(ranges[i].group(1)!);
        final b = int.parse(ranges[i].group(2)!);
        final c = int.parse(ranges[i].group(3)!);
        final covered = Uint8List.fromList([
          ...bytes.sublist(0, a),
          ...bytes.sublist(b, b + c),
        ]);
        expect(
          sha256Of(covered),
          imprints[i],
          reason: 'DocTimeStamp #${i + 1}',
        );
        if (i == 0) expect(b + c, eofs[1] + eofLen);
        if (i == 1) expect(b + c, bytes.length);
      }
    });

    test('works when the signature dictionary uses spaced keys (the '
        'placeholders are looked up in the new revision only)', () async {
      final original = buildSyntheticSignedPdf(spacedKeys: true);
      final file = await writeFile('a.pdf', original);
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) => fakeTsaClient(),
        collectorFactory: (_) => StubCollector(_material()),
      );

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.pades,
        settings: testUpgradeSettings(),
      );

      expect(result.timestamped, isTrue);
      final bytes = await file.readAsBytes();
      expect(bytes.sublist(0, original.length), original);
      expect(_textOffsets(bytes, '/Type /DocTimeStamp'), hasLength(2));
    });

    test('TSA #1 chain without OCSP/CRL: still B-LTA, with a '
        'revocationUnavailable warning', () async {
      final file = await writeFile('a.pdf', buildSyntheticSignedPdf());
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) => fakeTsaClient(),
        collectorFactory: (_) => _tsaAwareCollector(tsaRevocation: false),
      );

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.pades,
        settings: testUpgradeSettings(),
      );

      expect(result.timestamped, isTrue);
      expect(result.revocationEmbedded, isTrue); // the signer's evidence
      expect(result.warning, SignatureUpgradeWarning.revocationUnavailable);
      expect(result.detail, contains('timestamp authority'));
      final bytes = await file.readAsBytes();
      expect(_textOffsets(bytes, '/Type /DocTimeStamp'), hasLength(2));
      expect(_textOffsets(bytes, '/Type /DSS'), hasLength(1));
      expect(_contains(bytes, fakeTsaCertificate), isTrue);
    });

    test('a token without any TSA certificate warns but proceeds', () async {
      final file = await writeFile('a.pdf', buildSyntheticSignedPdf());
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) => fakeTsaClient(tsaCertificates: const []),
        collectorFactory: (_) => _tsaAwareCollector(),
      );

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.pades,
        settings: testUpgradeSettings(),
      );

      expect(result.timestamped, isTrue);
      expect(result.warning, SignatureUpgradeWarning.revocationUnavailable);
      expect(result.detail, contains('no TSA certificate'));
      expect(
        _textOffsets(await file.readAsBytes(), '/Type /DocTimeStamp'),
        hasLength(2),
      );
    });

    test('TSA failure on DocTimeStamp #2 leaves the file byte-identical '
        '(all-or-nothing per TSA attempt)', () async {
      final original = buildSyntheticSignedPdf();
      final file = await writeFile('a.pdf', original);
      final requests = <Uri>[];
      final upgrader = LtvSignatureUpgrader(
        // The first request (DocTimeStamp #1) succeeds; everything after it
        // fails: stamp #2, then the fallback TSA's attempt.
        httpClientFactory: (_) =>
            fakeTsaClient(requests: requests, failAfter: 1),
        collectorFactory: (_) => _tsaAwareCollector(),
      );

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.pades,
        settings: testUpgradeSettings(),
      );

      expect(result.timestamped, isFalse);
      expect(result.warning, SignatureUpgradeWarning.timestampFailed);
      expect(requests.map((u) => u.host), [
        'primary.tsa.test', // stamp #1 ok
        'primary.tsa.test', // stamp #2 fails
        'fallback.tsa.test', // restart from the original: stamp #1 fails
      ]);
      expect(await file.readAsBytes(), original);
      expect(filesInDir(), ['a.pdf']);
    });

    test('after a stamp #2 failure the fallback TSA redoes the whole '
        'sequence from the original', () async {
      final original = buildSyntheticSignedPdf();
      final file = await writeFile('a.pdf', original);
      final requests = <Uri>[];
      final inner = fakeTsaClient();
      var n = 0;
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) => MockClient((req) async {
          requests.add(req.url);
          n++;
          if (n == 2) return http.Response('boom', 500); // primary, stamp #2
          return inner.post(req.url, headers: req.headers, body: req.bodyBytes);
        }),
        collectorFactory: (_) => _tsaAwareCollector(),
      );

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.pades,
        settings: testUpgradeSettings(),
      );

      expect(result.timestamped, isTrue);
      expect(requests.map((u) => u.host), [
        'primary.tsa.test',
        'primary.tsa.test',
        'fallback.tsa.test',
        'fallback.tsa.test',
      ]);
      final bytes = await file.readAsBytes();
      expect(bytes.sublist(0, original.length), original);
      // Exactly two DocTimeStamps: the aborted attempt left nothing behind.
      expect(_textOffsets(bytes, '/Type /DocTimeStamp'), hasLength(2));
      expect(_textOffsets(bytes, '/Type /DSS'), hasLength(1));
    });

    test('the configured TSA policy OID is sent with both DocTimeStamp '
        'requests', () async {
      final file = await writeFile('a.pdf', buildSyntheticSignedPdf());
      final policies = <String?>[];
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) => fakeTsaClient(policies: policies),
        collectorFactory: (_) => StubCollector(_material()),
      );

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.pades,
        settings: testUpgradeSettings(policyOid: ' 1.3.6.1.4.1.601.10.3.1 '),
      );

      expect(result.timestamped, isTrue);
      expect(policies, ['1.3.6.1.4.1.601.10.3.1', '1.3.6.1.4.1.601.10.3.1']);
    });

    test('no policy OID configured: no reqPolicy is sent', () async {
      final file = await writeFile('a.pdf', buildSyntheticSignedPdf());
      final policies = <String?>[];
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) => fakeTsaClient(policies: policies),
        collectorFactory: (_) => StubCollector(_material()),
      );

      await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.pades,
        settings: testUpgradeSettings(),
      );

      expect(policies, [null, null]);
    });

    test('an invalid policy OID is a timestampFailed warning: no TSA '
        'request, file untouched', () async {
      final original = buildSyntheticSignedPdf();
      final file = await writeFile('a.pdf', original);
      final requests = <Uri>[];
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) => fakeTsaClient(requests: requests),
        collectorFactory: (_) => StubCollector(_material()),
      );

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.pades,
        settings: testUpgradeSettings(policyOid: 'not an oid'),
      );

      expect(result.timestamped, isFalse);
      expect(result.warning, SignatureUpgradeWarning.timestampFailed);
      expect(result.detail, contains('invalid TSA policy OID'));
      expect(result.detail, contains('not an oid'));
      expect(requests, isEmpty);
      expect(await file.readAsBytes(), original);
      expect(filesInDir(), ['a.pdf']);
    });
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

    test('LT includes the signature-time-stamp TSA chain (certificate-values '
        '+ revocation-values); existing attributes are kept and the new '
        'ones are appended in sequence', () async {
      // A pre-existing unsigned attribute in deliberately non-DER form.
      final pre = buildSyntheticAttribute('1.2.3.4.5', [2, 1]);
      final original = buildSyntheticCadesBes(rawUnsignedAttrs: [pre]);
      final file = await writeFile('doc.p7m', original);
      final collector = _tsaAwareCollector();
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) => fakeTsaClient(),
        collectorFactory: (_) => collector,
      );

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.cades,
        settings: testUpgradeSettings(),
      );

      expect(result.timestamped, isTrue);
      expect(result.revocationEmbedded, isTrue);
      expect(result.warning, isNull);
      expect(
        collector.calls[1].any((c) => bytesEqual(c, fakeTsaCertificate)),
        isTrue,
        reason: 'the collector is asked about the TSA chain',
      );

      final bytes = await file.readAsBytes();
      final upgraded = CadesSignedData.parse(bytes);

      // Existing attribute first and byte-identical; then B-T, LT, LTA.
      final attrs = upgraded.unsignedAttributesForArchiveTimestamp;
      expect(attrs.map((e) => e.key).toList(), [
        '1.2.3.4.5',
        Oid.signatureTimeStampToken,
        Oid.certificateValues,
        Oid.revocationValues,
      ]);
      expect(attrs.first.value, pre);
      expect(upgraded.getUnsignedAttribute(Oid.archiveTimeStampV3), isNotNull);

      // certificate-values holds the TSA certificate and its issuer.
      final certValues =
          derDecode(upgraded.getUnsignedAttribute(Oid.certificateValues)!)
              as ASN1Set;
      final certs = (certValues.elements!.single as ASN1Sequence).elements!
          .map(derEncode)
          .toList();
      expect(certs.any((c) => bytesEqual(c, fakeTsaCertificate)), isTrue);
      expect(certs.any((c) => bytesEqual(c, _tsaIssuerCert)), isTrue);

      // revocation-values holds the TSA's OCSP response next to the signer's.
      expect(_contains(bytes, _tsaOcspMarker), isTrue);
    });

    test('TSA chain without OCSP/CRL: archive timestamp still added, '
        'revocationUnavailable warning', () async {
      final file = await writeFile('doc.p7m', buildSyntheticCadesBes());
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) => fakeTsaClient(),
        collectorFactory: (_) => _tsaAwareCollector(tsaRevocation: false),
      );

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.cades,
        settings: testUpgradeSettings(),
      );

      expect(result.timestamped, isTrue);
      expect(result.warning, SignatureUpgradeWarning.revocationUnavailable);
      expect(result.detail, contains('timestamp authority'));
      final upgraded = CadesSignedData.parse(await file.readAsBytes());
      expect(upgraded.getUnsignedAttribute(Oid.archiveTimeStampV3), isNotNull);
      expect(upgraded.getUnsignedAttribute(Oid.certificateValues), isNotNull);
    });

    test('the configured TSA policy OID is sent with the signature and '
        'archive time-stamp requests', () async {
      final file = await writeFile('doc.p7m', buildSyntheticCadesBes());
      final policies = <String?>[];
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) => fakeTsaClient(policies: policies),
        collectorFactory: (_) => StubCollector(_material()),
      );

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.cades,
        settings: testUpgradeSettings(policyOid: '0.4.0.2023.1.1'),
      );

      expect(result.timestamped, isTrue);
      expect(policies, ['0.4.0.2023.1.1', '0.4.0.2023.1.1']);
    });

    test('an invalid policy OID is a timestampFailed warning and the p7m '
        'stays untouched', () async {
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
        settings: testUpgradeSettings(policyOid: '1.2.3.'),
      );

      expect(result.timestamped, isFalse);
      expect(result.warning, SignatureUpgradeWarning.timestampFailed);
      expect(result.detail, contains('invalid TSA policy OID'));
      expect(requests, isEmpty);
      expect(await file.readAsBytes(), original);
    });

    test('the archive time-stamp imprint follows EN 319 122-1 §5.5.3 end to '
        'end (independent reference over the pre-stamp signature)', () async {
      final file = await writeFile('doc.p7m', buildSyntheticCadesBes());
      final imprints = <Uint8List>[];
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) => fakeTsaClient(imprints: imprints),
        collectorFactory: (_) => _tsaAwareCollector(),
      );

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.cades,
        settings: testUpgradeSettings(),
      );

      expect(result.timestamped, isTrue);
      final finished = await file.readAsBytes();
      final before = refWithoutLastUnsignedAttribute(finished);
      expect(imprints, hasLength(2)); // signature-time-stamp, archive stamp
      expect(
        imprints.last,
        refDigest(Oid.sha256, referenceArchiveImprintInput(before)),
      );
      // The ATS token carries the matching hash index.
      final token = CadesSignedData.parse(
        CadesSignedData.parse(finished).archiveTimeStampTokens.single,
      );
      expect(
        token.getUnsignedAttribute(Oid.atsHashIndexV3),
        refTlv(0x31, referenceAtsHashIndex(before)),
      );
    });

    test('upgrading an already archived p7m appends a second archive '
        'time-stamp, keeps the first, and embeds validation data for the '
        'first stamp TSA in SignedData', () async {
      final file = await writeFile('doc.p7m', buildSyntheticCadesBes());
      final requests = <Uri>[];
      final collector = _tsaAwareCollector();
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) => fakeTsaClient(requests: requests),
        collectorFactory: (_) => collector,
      );
      await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.cades,
        settings: testUpgradeSettings(),
      );
      final first = await file.readAsBytes();
      final firstParts = CadesSignedData.parse(first).unsignedAttributeParts;
      requests.clear();
      collector.calls.clear();

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.cades,
        settings: testUpgradeSettings(),
      );

      expect(result.timestamped, isTrue);
      expect(result.warning, isNull);
      // Renewal needs one TSA request only (no new B-T / LT). The collector
      // is asked about the signer, then about the previous stamp's TSA.
      expect(requests, hasLength(1));
      expect(collector.calls, hasLength(2));
      expect(
        collector.calls.last.any((c) => bytesEqual(c, fakeTsaCertificate)),
        isTrue,
      );

      final second = await file.readAsBytes();
      final sd = CadesSignedData.parse(second);
      final parts = sd.unsignedAttributeParts;
      expect(parts, hasLength(firstParts.length + 1));
      for (var i = 0; i < firstParts.length; i++) {
        expect(parts[i].typeTlv, firstParts[i].typeTlv, reason: 'attr $i');
        expect(parts[i].valueTlvs, firstParts[i].valueTlvs, reason: 'attr $i');
      }
      expect(sd.archiveTimeStampTokens, hasLength(2));
      // Validation data for the previous TSA went into SignedData.
      expect(
        sd.signedDataCertificateTlvs.any(
          (c) => bytesEqual(c, fakeTsaCertificate),
        ),
        isTrue,
      );
      expect(sd.signedDataCertificateTlvs, contains(equals(_tsaIssuerCert)));
      expect(sd.signedDataCrlTlvs, hasLength(1));
    });

    test('renewal with no revocation evidence for the previous TSA warns '
        'but still appends the stamp', () async {
      final file = await writeFile('doc.p7m', buildSyntheticCadesBes());
      final upgrader = LtvSignatureUpgrader(
        httpClientFactory: (_) => fakeTsaClient(),
        collectorFactory: (_) => _tsaAwareCollector(tsaRevocation: false),
      );
      await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.cades,
        settings: testUpgradeSettings(),
      );

      final result = await upgrader.upgrade(
        path: file.path,
        format: SignatureFormat.cades,
        settings: testUpgradeSettings(),
      );

      expect(result.timestamped, isTrue);
      expect(result.warning, SignatureUpgradeWarning.revocationUnavailable);
      expect(
        CadesSignedData.parse(await file.readAsBytes()).archiveTimeStampTokens,
        hasLength(2),
      );
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
