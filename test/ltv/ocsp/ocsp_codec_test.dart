// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';
import 'package:test/test.dart';

import 'package:opencie/services/ltv/asn1/der.dart';
import 'package:opencie/services/ltv/asn1/oids.dart';
import 'package:opencie/services/ltv/ocsp/ocsp_codec.dart';
import 'package:opencie/services/ltv/ocsp/ocsp_models.dart';

void main() {
  group('OcspCodec', () {
    // Test certificate from x509_extensions_test.dart
    const testCertDerBase64 =
        'MIIDlTCCAn2gAwIBAgIUBddQvAx7Lu5jngzCradozgxW0YcwDQYJKoZIhvcNAQELBQAwDzENMAsGA1UEAwwEdGVzdDAeFw0yNjA1MDQyMDE5NTJaFw0yNjA1MDUyMDE5NTJaMA8xDTALBgNVBAMMBHRlc3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCGHrW5oIeAsMPOp/KNGXGUyArltGVRpz5DbZGV5C5/A/m7LTLeWrIj8QYHH53JGpkkA88sfSxwPAab6OQCyfLN2bAgejK2PPJC+fRrTGjMXYyP2RvXjtJFR8GlwcJwpMRHaTfGT3BnSkM8O8jfD1v50C+mtjCc1KWoXgjSukCUxsraoqiq0iO7XOWd7UR7YxFBIjER83xrgxUjqHTndMQXb2q2E6v3UXPtulJhe2jntwVUPSDNkJqYfzmhQEPI557+WoHLIHBi5GnosHgOHCYDQaTFbdxYDlsLfrrpm5R3pS6MNttKvnVvECdfEvJqCsG6t51/W6ANRC2HXV0sNrKXAgMBAAGjgegwgeUwDwYDVR0TAQH/BAUwAwEB/zBhBggrBgEFBQcBAQRVMFMwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLmV4YW1wbGUuY29tMCwGCCsGAQUFBzAChiBodHRwOi8vaXNzdWVyLmV4YW1wbGUuY29tL2NhLmNlcjAvBgNVHR8EKDAmMCSgIqAghh5odHRwOi8vY3JsLmV4YW1wbGUuY29tL2NybC5wZW0wHQYDVR0OBBYEFC5qoyEy/VVaKVl36gwWvLnHOZ1bMB8GA1UdIwQYMBaAFC5qoyEy/VVaKVl36gwWvLnHOZ1bMA0GCSqGSIb3DQEBCwUAA4IBAQBOkT6+rwIzhUPhp7ciz9fjxoohS+8jfnDnAFpwSO0jg6iY9PbNs50WlW9pGhMgIFleEevhYi0coNRBGe9g3W94N72jbGbsOcN6YUXqOseN/c6c4VP870zWwnYbev1AMXBAC1y9cY/P6efvRowzD69YHIWTw5wEuAmS9/OHAvI89dRAiZa//qKdYXjysR1xzGEilyvtTeUxrZZ6iHfPBYtdgQgPmbc8KLm1kof2H+SYsDry9U/WZywl2unRXNT8+yCyQJ1D8S2979qcCTMYhlO6YrGAC7NQPkLSKVX7sVLbyTDrbAjQ+L1zpUZOwKjAzCO8vzMRd2pQ93SbNbX2lOdY';

    late Uint8List testCertDer;

    setUp(() {
      testCertDer = base64Decode(testCertDerBase64);
    });

    test('encode request with single CertID, no nonce', () {
      final certId = OcspCertId(
        hashAlgorithmOid: Oid.sha1,
        issuerNameHash: Uint8List(20),
        issuerKeyHash: Uint8List(20),
        serialNumber: BigInt.from(12345),
      );

      final requestDer = encodeOcspRequest(certIds: [certId]);
      expect(requestDer, isNotEmpty);

      // Verify it's a valid SEQUENCE
      final obj = derDecode(requestDer);
      expect(obj, isA<ASN1Sequence>());

      final seq = obj as ASN1Sequence;
      expect(seq.elements, isNotNull);
      expect(seq.elements!.isNotEmpty, isTrue);
    });

    test('encode request with nonce', () {
      final certId = OcspCertId(
        hashAlgorithmOid: Oid.sha1,
        issuerNameHash: Uint8List(20),
        issuerKeyHash: Uint8List(20),
        serialNumber: BigInt.from(12345),
      );

      final nonce = Uint8List.fromList([
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        14,
        15,
        16,
      ]);
      final requestDer = encodeOcspRequest(certIds: [certId], nonce: nonce);
      expect(requestDer, isNotEmpty);

      // Verify it's a valid SEQUENCE
      final obj = derDecode(requestDer);
      expect(obj, isA<ASN1Sequence>());
    });

    test('encode request with multiple CertIDs', () {
      final certIds = [
        OcspCertId(
          hashAlgorithmOid: Oid.sha1,
          issuerNameHash: Uint8List(20),
          issuerKeyHash: Uint8List(20),
          serialNumber: BigInt.from(1),
        ),
        OcspCertId(
          hashAlgorithmOid: Oid.sha1,
          issuerNameHash: Uint8List(20),
          issuerKeyHash: Uint8List(20),
          serialNumber: BigInt.from(2),
        ),
        OcspCertId(
          hashAlgorithmOid: Oid.sha1,
          issuerNameHash: Uint8List(20),
          issuerKeyHash: Uint8List(20),
          serialNumber: BigInt.from(3),
        ),
      ];

      final requestDer = encodeOcspRequest(certIds: certIds);
      expect(requestDer, isNotEmpty);

      final obj = derDecode(requestDer);
      expect(obj, isA<ASN1Sequence>());
    });

    test('CertID.fromCert with SHA-1 (self-signed test cert)', () {
      // Use the test cert as both subject and issuer (self-signed)
      final certId = _buildCertIdFromCert(testCertDer, testCertDer, Oid.sha1);
      expect(certId, isNotNull);
      expect(certId!.issuerNameHash.length, equals(20)); // SHA-1 = 20 bytes
      expect(certId.issuerKeyHash.length, equals(20));
      expect(certId.hashAlgorithmOid, equals(Oid.sha1));
      expect(certId.serialNumber, isNotNull);
    });

    test('CertID.fromCert with SHA-256', () {
      final certId = _buildCertIdFromCert(testCertDer, testCertDer, Oid.sha256);
      expect(certId, isNotNull);
      expect(certId!.issuerNameHash.length, equals(32)); // SHA-256 = 32 bytes
      expect(certId.issuerKeyHash.length, equals(32));
      expect(certId.hashAlgorithmOid, equals(Oid.sha256));
    });

    test('parse malformed response returns internalError', () {
      final malformedDer = Uint8List.fromList([0xFF, 0xFF, 0xFF]);
      final parsed = parseOcspResponse(malformedDer);
      expect(parsed.status, equals(OcspResponseStatus.internalError));
      expect(parsed.responses, isEmpty);
    });

    test(
      'parse response with wrong responseType OID returns internalError',
      () {
        final response = _buildOcspResponseWithWrongOid();
        final parsed = parseOcspResponse(response);
        expect(parsed.status, equals(OcspResponseStatus.internalError));
      },
    );

    test(
      'extractBasicOcspResponse extracts inner BasicOCSPResponse from OCSPResponse',
      () {
        // Build a synthetic OCSPResponse with a BasicOCSPResponse inside
        final basicOcspResponse = ASN1Sequence();
        basicOcspResponse.add(ASN1Sequence()); // ResponseData (minimal)
        basicOcspResponse.add(algorithmIdentifier(Oid.sha256WithRSA));
        basicOcspResponse.add(
          ASN1BitString(stringValues: List<int>.filled(256, 0)),
        );
        final basicOcspResponseDer = derEncode(basicOcspResponse);

        // Wrap in OCSPResponse
        final responseBytes = ASN1Sequence();
        responseBytes.add(
          ASN1ObjectIdentifier.fromIdentifierString(Oid.ocspBasic),
        );
        responseBytes.add(ASN1OctetString(octets: basicOcspResponseDer));

        final ocspResponse = ASN1Sequence();
        ocspResponse.add(ASN1Enumerated(0)); // successful
        ocspResponse.add(explicit(0, responseBytes));

        final ocspResponseDer = derEncode(ocspResponse);

        // Extract BasicOCSPResponse
        final extracted = extractBasicOcspResponse(ocspResponseDer);
        expect(extracted, isNotNull);
        expect(extracted, equals(basicOcspResponseDer));
      },
    );

    test('extractBasicOcspResponse returns null for invalid OCSPResponse', () {
      // Build an invalid OCSPResponse (missing responseBytes)
      final ocspResponse = ASN1Sequence();
      ocspResponse.add(ASN1Enumerated(0)); // successful
      final ocspResponseDer = derEncode(ocspResponse);

      final extracted = extractBasicOcspResponse(ocspResponseDer);
      expect(extracted, isNull);
    });

    // OC-05: ResponseData positional parsing (RFC 6960 §4.2.1). The
    // `DEFINITIONS EXPLICIT TAGS` module means responderID's byName [1]
    // and the optional responseExtensions [1] share the same outer tag,
    // so these must be disambiguated by field position, not by tag alone.
    group('ResponseData parsing (OC-05)', () {
      test('version omitted, responderID byName, no extensions', () {
        final der = _buildOcspResponse(includeVersion: false, byName: true);
        final parsed = parseOcspResponse(der);
        expect(parsed.status, OcspResponseStatus.successful);
        expect(parsed.producedAt, isNotNull);
        expect(parsed.responses, hasLength(1));
        expect(parsed.responses.single.status, OcspCertStatus.good);
        expect(parsed.respNonce, isNull);
      });

      test('version omitted, responderID byKey, no extensions', () {
        final der = _buildOcspResponse(includeVersion: false, byName: false);
        final parsed = parseOcspResponse(der);
        expect(parsed.status, OcspResponseStatus.successful);
        expect(parsed.producedAt, isNotNull);
        expect(parsed.responses, hasLength(1));
        expect(parsed.responses.single.status, OcspCertStatus.good);
        expect(parsed.respNonce, isNull);
      });

      test('version present (v1), responderID byName, no extensions', () {
        final der = _buildOcspResponse(includeVersion: true, byName: true);
        final parsed = parseOcspResponse(der);
        expect(parsed.status, OcspResponseStatus.successful);
        expect(parsed.producedAt, isNotNull);
        expect(parsed.responses, hasLength(1));
      });

      test('version omitted, responderID byName, with nonce extension', () {
        final nonce = Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD]);
        final der = _buildOcspResponse(
          includeVersion: false,
          byName: true,
          includeExtensions: true,
          nonce: nonce,
        );
        final parsed = parseOcspResponse(der);
        expect(parsed.status, OcspResponseStatus.successful);
        expect(parsed.producedAt, isNotNull);
        expect(parsed.responses, hasLength(1));
        // Must not be misclassified: responderID (byName, tag 0xA1) is
        // positional field #1, extensions (also tag 0xA1) is the last,
        // optional field — only the real extensions carry the nonce.
        expect(parsed.respNonce, equals(nonce));
      });

      test('version omitted, responderID byKey, with nonce extension', () {
        final nonce = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
        final der = _buildOcspResponse(
          includeVersion: false,
          byName: false,
          includeExtensions: true,
          nonce: nonce,
        );
        final parsed = parseOcspResponse(der);
        expect(parsed.status, OcspResponseStatus.successful);
        expect(parsed.producedAt, isNotNull);
        expect(parsed.responses, hasLength(1));
        expect(parsed.respNonce, equals(nonce));
      });
    });
  });
}

/// Helper: build a CertID from cert and issuer DER (mimics OcspClient._buildCertId).
OcspCertId? _buildCertIdFromCert(
  Uint8List certDer,
  Uint8List issuerDer,
  String hashAlgorithmOid,
) {
  try {
    final issuerObj = derDecode(issuerDer);
    if (issuerObj is! ASN1Sequence ||
        issuerObj.elements == null ||
        issuerObj.elements!.isEmpty) {
      return null;
    }

    final issuerTbsCert = issuerObj.elements![0];
    if (issuerTbsCert is! ASN1Sequence || issuerTbsCert.elements == null) {
      return null;
    }

    if (issuerTbsCert.elements!.length < 7) {
      return null;
    }

    final issuerSubjectObj = issuerTbsCert.elements![5];
    final issuerSubjectDer = derEncode(issuerSubjectObj);
    final issuerNameHash = hashOf(issuerSubjectDer, hashAlgorithmOid);

    final issuerSpkiObj = issuerTbsCert.elements![6];
    if (issuerSpkiObj is! ASN1Sequence ||
        issuerSpkiObj.elements == null ||
        issuerSpkiObj.elements!.length < 2) {
      return null;
    }

    final issuerSpkBitStringObj = issuerSpkiObj.elements![1];
    if (issuerSpkBitStringObj is! ASN1BitString) {
      return null;
    }

    final issuerSpkBytes = issuerSpkBitStringObj.stringValues;
    if (issuerSpkBytes == null || issuerSpkBytes.isEmpty) {
      return null;
    }
    final issuerKeyHash = hashOf(
      Uint8List.fromList(issuerSpkBytes),
      hashAlgorithmOid,
    );

    final certObj = derDecode(certDer);
    if (certObj is! ASN1Sequence ||
        certObj.elements == null ||
        certObj.elements!.isEmpty) {
      return null;
    }

    final certTbsCert = certObj.elements![0];
    if (certTbsCert is! ASN1Sequence || certTbsCert.elements == null) {
      return null;
    }

    if (certTbsCert.elements!.length < 2) {
      return null;
    }

    final serialNumberObj = certTbsCert.elements![1];
    if (serialNumberObj is! ASN1Integer) {
      return null;
    }

    final serialNumber = serialNumberObj.integer ?? BigInt.zero;

    return OcspCertId(
      hashAlgorithmOid: hashAlgorithmOid,
      issuerNameHash: issuerNameHash,
      issuerKeyHash: issuerKeyHash,
      serialNumber: serialNumber,
    );
  } catch (e) {
    return null;
  }
}

/// Helper: build OCSP response with wrong responseType OID.
Uint8List _buildOcspResponseWithWrongOid() {
  final responseBytes = ASN1Sequence();
  responseBytes.add(
    ASN1ObjectIdentifier.fromIdentifierString('1.2.3.4.5'),
  ); // Wrong OID
  responseBytes.add(ASN1OctetString(octets: Uint8List(10)));

  final ocspResponse = ASN1Sequence();
  ocspResponse.add(ASN1Enumerated(0)); // successful
  ocspResponse.add(explicit(0, responseBytes));

  return derEncode(ocspResponse);
}

/// Builds a synthetic, fully DER-correct BasicOCSPResponse for OC-05 tests,
/// covering the optional [0] version, both ResponderID CHOICE arms, and the
/// optional [1] responseExtensions carrying the nonce extension (RFC 6960
/// §4.2.1).
Uint8List _buildOcspResponse({
  required bool includeVersion,
  required bool byName,
  bool includeExtensions = false,
  Uint8List? nonce,
}) {
  // CertID
  final certId = ASN1Sequence();
  certId.add(algorithmIdentifier(Oid.sha1));
  certId.add(ASN1OctetString(octets: Uint8List(20))); // issuerNameHash
  certId.add(ASN1OctetString(octets: Uint8List(20))); // issuerKeyHash
  certId.add(ASN1Integer(BigInt.one)); // serialNumber

  // CertStatus ::= CHOICE { good [0] IMPLICIT NULL, ... }
  final certStatus = ASN1Parser(Uint8List.fromList([0x80, 0x00])).nextObject();

  final thisUpdate = _properGeneralizedTime(DateTime.utc(2026, 1, 1, 0, 0, 0));

  final singleResponse = ASN1Sequence();
  singleResponse.add(certId);
  singleResponse.add(certStatus);
  singleResponse.add(thisUpdate);

  final responses = ASN1Sequence();
  responses.add(singleResponse);

  final responseData = ASN1Sequence();
  if (includeVersion) {
    responseData.add(explicit(0, ASN1Integer(BigInt.zero)));
  }

  // ResponderID ::= CHOICE { byName [1] Name, byKey [2] KeyHash }
  if (byName) {
    responseData.add(explicit(1, ASN1Sequence())); // empty RDNSequence
  } else {
    responseData.add(explicit(2, ASN1OctetString(octets: Uint8List(20))));
  }

  responseData.add(_properGeneralizedTime(DateTime.utc(2026, 1, 2, 0, 0, 0)));
  responseData.add(responses);

  if (includeExtensions) {
    final nonceBytes = nonce ?? Uint8List.fromList([1, 2, 3, 4]);
    final nonceExtValue = ASN1OctetString(octets: nonceBytes);
    final nonceExt = ASN1Sequence();
    nonceExt.add(ASN1ObjectIdentifier.fromIdentifierString(Oid.ocspNonce));
    nonceExt.add(ASN1OctetString(octets: nonceExtValue.encode()));
    final extensions = ASN1Sequence();
    extensions.add(nonceExt);
    responseData.add(explicit(1, extensions));
  }

  final basicOcspResponse = ASN1Sequence();
  basicOcspResponse.add(responseData);
  basicOcspResponse.add(algorithmIdentifier(Oid.sha256WithRSA));
  basicOcspResponse.add(ASN1BitString(stringValues: List<int>.filled(32, 0)));

  final basicOcspResponseDer = derEncode(basicOcspResponse);

  final responseBytes = ASN1Sequence();
  responseBytes.add(ASN1ObjectIdentifier.fromIdentifierString(Oid.ocspBasic));
  responseBytes.add(ASN1OctetString(octets: basicOcspResponseDer));

  final ocspResponse = ASN1Sequence();
  ocspResponse.add(ASN1Enumerated(0)); // successful
  ocspResponse.add(explicit(0, responseBytes));

  return derEncode(ocspResponse);
}

/// Builds a DER-correct (zero-padded) GeneralizedTime ASN1 object.
///
/// pointycastle 4.0.0's `ASN1GeneralizedTime(dt).encode()` formats
/// year/month/day/hour/minute/second via bare `int.toString()`, dropping
/// leading zeros and producing bytes its own `fromBytes` cannot re-parse
/// (fixed-width substring offsets throw `RangeError`). Build valid DER by
/// hand instead of tripping over the dependency's own encoder bug.
ASN1Object _properGeneralizedTime(DateTime dt) {
  final utc = dt.toUtc();
  String pad(int v, int w) => v.toString().padLeft(w, '0');
  final s =
      '${pad(utc.year, 4)}${pad(utc.month, 2)}${pad(utc.day, 2)}'
      '${pad(utc.hour, 2)}${pad(utc.minute, 2)}${pad(utc.second, 2)}Z';
  final content = Uint8List.fromList(s.codeUnits);
  final builder = BytesBuilder();
  builder.addByte(0x18); // GeneralizedTime tag
  builder.addByte(content.length);
  builder.add(content);
  return ASN1Parser(builder.toBytes()).nextObject();
}
