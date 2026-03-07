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

      final nonce = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]);
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

    test('parse response with wrong responseType OID returns internalError', () {
      final response = _buildOcspResponseWithWrongOid();
      final parsed = parseOcspResponse(response);
      expect(parsed.status, equals(OcspResponseStatus.internalError));
    });

    test('extractBasicOcspResponse extracts inner BasicOCSPResponse from OCSPResponse', () {
      // Build a synthetic OCSPResponse with a BasicOCSPResponse inside
      final basicOcspResponse = ASN1Sequence();
      basicOcspResponse.add(ASN1Sequence()); // ResponseData (minimal)
      basicOcspResponse.add(algorithmIdentifier(Oid.sha256WithRSA));
      basicOcspResponse.add(ASN1BitString(stringValues: List<int>.filled(256, 0)));
      final basicOcspResponseDer = derEncode(basicOcspResponse);

      // Wrap in OCSPResponse
      final responseBytes = ASN1Sequence();
      responseBytes.add(ASN1ObjectIdentifier.fromIdentifierString(Oid.ocspBasic));
      responseBytes.add(ASN1OctetString(octets: basicOcspResponseDer));

      final ocspResponse = ASN1Sequence();
      ocspResponse.add(ASN1Enumerated(0)); // successful
      ocspResponse.add(explicit(0, responseBytes));

      final ocspResponseDer = derEncode(ocspResponse);

      // Extract BasicOCSPResponse
      final extracted = extractBasicOcspResponse(ocspResponseDer);
      expect(extracted, isNotNull);
      expect(extracted, equals(basicOcspResponseDer));
    });

    test('extractBasicOcspResponse returns null for invalid OCSPResponse', () {
      // Build an invalid OCSPResponse (missing responseBytes)
      final ocspResponse = ASN1Sequence();
      ocspResponse.add(ASN1Enumerated(0)); // successful
      final ocspResponseDer = derEncode(ocspResponse);

      final extracted = extractBasicOcspResponse(ocspResponseDer);
      expect(extracted, isNull);
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
    if (issuerObj is! ASN1Sequence || issuerObj.elements == null || issuerObj.elements!.isEmpty) {
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
    if (issuerSpkiObj is! ASN1Sequence || issuerSpkiObj.elements == null || issuerSpkiObj.elements!.length < 2) {
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
    final issuerKeyHash = hashOf(Uint8List.fromList(issuerSpkBytes), hashAlgorithmOid);

    final certObj = derDecode(certDer);
    if (certObj is! ASN1Sequence || certObj.elements == null || certObj.elements!.isEmpty) {
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
  responseBytes.add(ASN1ObjectIdentifier.fromIdentifierString('1.2.3.4.5')); // Wrong OID
  responseBytes.add(ASN1OctetString(octets: Uint8List(10)));

  final ocspResponse = ASN1Sequence();
  ocspResponse.add(ASN1Enumerated(0)); // successful
  ocspResponse.add(explicit(0, responseBytes));

   return derEncode(ocspResponse);
}
