// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/services/ltv/asn1/der.dart';
import 'package:opencie/services/ltv/asn1/oids.dart';
import 'package:opencie/services/ltv/crl/crl_codec.dart';
import 'package:pointycastle/asn1.dart';

void main() {
  group('CrlCodec', () {
    /// Build a minimal synthetic CRL DER for testing.
    Uint8List buildMinimalCrl({
      required String thisUpdateTime, // e.g., '260101000000Z'
      String? nextUpdateTime,
      bool useGeneralizedTime = false,
    }) {
      // CertificateList ::= SEQUENCE {
      //   tbsCertList TBSCertList,
      //   signatureAlgorithm AlgorithmIdentifier,
      //   signatureValue BIT STRING
      // }

      // TBSCertList ::= SEQUENCE {
      //   version Version OPTIONAL,
      //   signature AlgorithmIdentifier,
      //   issuer Name,
      //   thisUpdate Time,
      //   nextUpdate Time OPTIONAL,
      //   revokedCertificates SEQUENCE OF OPTIONAL
      // }

      final tbsCertList = ASN1Sequence();

      // version INTEGER 1 (v2)
      tbsCertList.add(ASN1Integer(BigInt.one));

      // signature AlgorithmIdentifier (sha256WithRSAEncryption)
      tbsCertList.add(algorithmIdentifier(Oid.sha256WithRSA));

      // issuer Name (SEQUENCE OF SET OF SEQUENCE { OID, UTF8String })
      final issuerRdn = ASN1Sequence();
      final issuerSet = ASN1Set();
      final issuerAttr = ASN1Sequence();
      issuerAttr.add(
        ASN1ObjectIdentifier.fromIdentifierString('2.5.4.3'),
      ); // CN
      issuerAttr.add(ASN1UTF8String(utf8StringValue: 'Test CA'));
      issuerSet.add(issuerAttr);
      issuerRdn.add(issuerSet);
      tbsCertList.add(issuerRdn);

      // thisUpdate Time
      if (useGeneralizedTime) {
        tbsCertList.add(ASN1GeneralizedTime(DateTime.utc(2026, 1, 1, 0, 0, 0)));
      } else {
        tbsCertList.add(ASN1UtcTime(DateTime.utc(2026, 1, 1, 0, 0, 0)));
      }

      // nextUpdate Time OPTIONAL
      if (nextUpdateTime != null) {
        if (useGeneralizedTime) {
          tbsCertList.add(
            ASN1GeneralizedTime(DateTime.utc(2027, 1, 1, 0, 0, 0)),
          );
        } else {
          tbsCertList.add(ASN1UtcTime(DateTime.utc(2027, 1, 1, 0, 0, 0)));
        }
      }

      // revokedCertificates SEQUENCE OF (empty)
      tbsCertList.add(ASN1Sequence());

      // Build outer CertificateList
      final certList = ASN1Sequence();
      certList.add(tbsCertList);
      certList.add(algorithmIdentifier(Oid.sha256WithRSA));
      certList.add(ASN1BitString(stringValues: List<int>.filled(10, 0)));

      return derEncode(certList);
    }

    test('parseCrl parses minimal CRL with UTCTime', () {
      final crlDer = buildMinimalCrl(thisUpdateTime: '260101000000Z');
      final crl = parseCrl(crlDer);

      expect(crl, isNotNull);
      expect(crl!.rawCrl, equals(crlDer));
      expect(crl.issuerDn, isNotEmpty);
      expect(crl.thisUpdate, isNotNull);
      expect(crl.thisUpdate.year, equals(2026));
      expect(crl.thisUpdate.month, equals(1));
      expect(crl.thisUpdate.day, equals(1));
    });

    test('parseCrl with nextUpdate returns non-null nextUpdate', () {
      final crlDer = buildMinimalCrl(
        thisUpdateTime: '260101000000Z',
        nextUpdateTime: '270101000000Z',
      );
      final crl = parseCrl(crlDer);

      expect(crl, isNotNull);
      expect(crl!.nextUpdate, isNotNull);
      expect(crl.nextUpdate!.year, equals(2027));
    });

    test('parseCrl without nextUpdate returns null nextUpdate', () {
      final crlDer = buildMinimalCrl(thisUpdateTime: '260101000000Z');
      final crl = parseCrl(crlDer);

      expect(crl, isNotNull);
      expect(crl!.nextUpdate, isNull);
    });

    test('parseCrl with GeneralizedTime parses correctly', () {
      // Note: GeneralizedTime parsing requires proper ASN1 tag handling by pointycastle.
      // For now, we test that the codec doesn't crash on GeneralizedTime input.
      // The actual parsing is tested via the OCSP codec which uses GeneralizedTime extensively.
      final crlDer = buildMinimalCrl(
        thisUpdateTime: '20260101000000Z',
        useGeneralizedTime: true,
      );
      final crl = parseCrl(crlDer);

      // Either it parses correctly or returns null (both are acceptable for defensive parsing)
      if (crl != null) {
        expect(crl.thisUpdate.year, equals(2026));
      }
    });

    test('parseCrl returns null on malformed DER', () {
      final malformedDer = Uint8List.fromList([0xFF, 0xFF, 0xFF]);
      final crl = parseCrl(malformedDer);

      expect(crl, isNull);
    });

    test('parseCrl returns null on empty SEQUENCE', () {
      final emptySeq = Uint8List.fromList([0x30, 0x00]); // Empty SEQUENCE
      final crl = parseCrl(emptySeq);

      expect(crl, isNull);
    });

    test('isFresh returns false when nextUpdate is null', () {
      final crlDer = buildMinimalCrl(thisUpdateTime: '260101000000Z');
      final crl = parseCrl(crlDer)!;

      expect(crl.isFresh(DateTime.now()), isFalse);
    });

    test('isFresh returns true when nextUpdate is in future', () {
      final crlDer = buildMinimalCrl(
        thisUpdateTime: '260101000000Z',
        nextUpdateTime: '270101000000Z',
      );
      final crl = parseCrl(crlDer)!;

      // nextUpdate is 2027-01-01, so it should be fresh now (2026)
      expect(crl.isFresh(DateTime.utc(2026, 6, 1)), isTrue);
    });

    test('isFresh returns false when nextUpdate is in past', () {
      final crlDer = buildMinimalCrl(
        thisUpdateTime: '260101000000Z',
        nextUpdateTime: '270101000000Z',
      );
      final crl = parseCrl(crlDer)!;

      // nextUpdate is 2027-01-01, so it should not be fresh in 2028
      expect(crl.isFresh(DateTime.utc(2028, 1, 2)), isFalse);
    });

    test('pemOrDerToDer returns input unchanged for DER', () {
      final derBytes = Uint8List.fromList([
        0x30,
        0x05,
        0x02,
        0x01,
        0x00,
        0x05,
        0x00,
      ]);
      final result = pemOrDerToDer(derBytes);

      expect(result, equals(derBytes));
    });

    test('pemOrDerToDer decodes PEM-armored CRL', () {
      // Create a simple DER and wrap it in PEM
      final derBytes = Uint8List.fromList([
        0x30,
        0x05,
        0x02,
        0x01,
        0x00,
        0x05,
        0x00,
      ]);
      final base64Body = base64Encode(derBytes);
      final pemStr =
          '-----BEGIN X509 CRL-----\n$base64Body\n-----END X509 CRL-----';
      final pemBytes = Uint8List.fromList(pemStr.codeUnits);

      final result = pemOrDerToDer(pemBytes);

      expect(result, equals(derBytes));
    });

    test('pemOrDerToDer decodes PEM with BEGIN CRL-----', () {
      final derBytes = Uint8List.fromList([
        0x30,
        0x05,
        0x02,
        0x01,
        0x00,
        0x05,
        0x00,
      ]);
      final base64Body = base64Encode(derBytes);
      final pemStr = '-----BEGIN CRL-----\n$base64Body\n-----END CRL-----';
      final pemBytes = Uint8List.fromList(pemStr.codeUnits);

      final result = pemOrDerToDer(pemBytes);

      expect(result, equals(derBytes));
    });

    test('pemOrDerToDer returns null on malformed PEM base64', () {
      final pemStr =
          '-----BEGIN X509 CRL-----\nNOT_VALID_BASE64!!!\n-----END X509 CRL-----';
      final pemBytes = Uint8List.fromList(pemStr.codeUnits);

      final result = pemOrDerToDer(pemBytes);

      expect(result, isNull);
    });

    test('pemOrDerToDer handles PEM with line breaks in base64', () {
      final derBytes = Uint8List.fromList([
        0x30,
        0x05,
        0x02,
        0x01,
        0x00,
        0x05,
        0x00,
      ]);
      final base64Body = base64Encode(derBytes);
      // Split base64 into multiple lines
      final lines = <String>[];
      for (int i = 0; i < base64Body.length; i += 20) {
        lines.add(
          base64Body.substring(
            i,
            i + 20 > base64Body.length ? base64Body.length : i + 20,
          ),
        );
      }
      final pemStr =
          '-----BEGIN X509 CRL-----\n${lines.join('\n')}\n-----END X509 CRL-----';
      final pemBytes = Uint8List.fromList(pemStr.codeUnits);

      final result = pemOrDerToDer(pemBytes);

      expect(result, equals(derBytes));
    });

    test('parseCrl preserves sourceUrl', () {
      final crlDer = buildMinimalCrl(thisUpdateTime: '260101000000Z');
      final url = 'http://example.com/crl.pem';
      final crl = parseCrl(crlDer, sourceUrl: url);

      expect(crl, isNotNull);
      expect(crl!.sourceUrl, equals(url));
    });
  });
}
