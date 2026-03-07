// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:opencie/services/ltv/asn1/x509_extensions.dart';

void main() {
  group('X509Extensions', () {
    // Test certificate generated with:
    // openssl req -x509 -newkey rsa:2048 -keyout k.pem -out c.pem -days 1 -nodes -subj "/CN=test" \
    //   -addext "authorityInfoAccess = OCSP;URI:http://ocsp.example.com,caIssuers;URI:http://issuer.example.com/ca.cer" \
    //   -addext "crlDistributionPoints = URI:http://crl.example.com/crl.pem" \
    //   -addext "subjectKeyIdentifier = hash" \
    //   -addext "authorityKeyIdentifier = keyid:always"
    // Then: openssl x509 -in c.pem -outform DER | base64 -w 0
    const testCertDerBase64 =
        'MIIDlTCCAn2gAwIBAgIUBddQvAx7Lu5jngzCradozgxW0YcwDQYJKoZIhvcNAQELBQAwDzENMAsGA1UEAwwEdGVzdDAeFw0yNjA1MDQyMDE5NTJaFw0yNjA1MDUyMDE5NTJaMA8xDTALBgNVBAMMBHRlc3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCGHrW5oIeAsMPOp/KNGXGUyArltGVRpz5DbZGV5C5/A/m7LTLeWrIj8QYHH53JGpkkA88sfSxwPAab6OQCyfLN2bAgejK2PPJC+fRrTGjMXYyP2RvXjtJFR8GlwcJwpMRHaTfGT3BnSkM8O8jfD1v50C+mtjCc1KWoXgjSukCUxsraoqiq0iO7XOWd7UR7YxFBIjER83xrgxUjqHTndMQXb2q2E6v3UXPtulJhe2jntwVUPSDNkJqYfzmhQEPI557+WoHLIHBi5GnosHgOHCYDQaTFbdxYDlsLfrrpm5R3pS6MNttKvnVvECdfEvJqCsG6t51/W6ANRC2HXV0sNrKXAgMBAAGjgegwgeUwDwYDVR0TAQH/BAUwAwEB/zBhBggrBgEFBQcBAQRVMFMwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLmV4YW1wbGUuY29tMCwGCCsGAQUFBzAChiBodHRwOi8vaXNzdWVyLmV4YW1wbGUuY29tL2NhLmNlcjAvBgNVHR8EKDAmMCSgIqAghh5odHRwOi8vY3JsLmV4YW1wbGUuY29tL2NybC5wZW0wHQYDVR0OBBYEFC5qoyEy/VVaKVl36gwWvLnHOZ1bMB8GA1UdIwQYMBaAFC5qoyEy/VVaKVl36gwWvLnHOZ1bMA0GCSqGSIb3DQEBCwUAA4IBAQBOkT6+rwIzhUPhp7ciz9fjxoohS+8jfnDnAFpwSO0jg6iY9PbNs50WlW9pGhMgIFleEevhYi0coNRBGe9g3W94N72jbGbsOcN6YUXqOseN/c6c4VP870zWwnYbev1AMXBAC1y9cY/P6efvRowzD69YHIWTw5wEuAmS9/OHAvI89dRAiZa//qKdYXjysR1xzGEilyvtTeUxrZZ6iHfPBYtdgQgPmbc8KLm1kof2H+SYsDry9U/WZywl2unRXNT8+yCyQJ1D8S2979qcCTMYhlO6YrGAC7NQPkLSKVX7sVLbyTDrbAjQ+L1zpUZOwKjAzCO8vzMRd2pQ93SbNbX2lOdY';

    late Uint8List testCertDer;

    setUp(() {
      testCertDer = base64Decode(testCertDerBase64);
    });

    test('parseFromCertificate extracts extensions', () {
      final extensions = X509Extensions.parseFromCertificate(testCertDer);
      expect(extensions, isNotEmpty);
      expect(extensions.length, greaterThanOrEqualTo(4));

      // Check that we have the expected OIDs
      final oids = extensions.map((e) => e.oid).toSet();
      expect(oids.contains('2.5.29.19'), isTrue); // basicConstraints
      expect(oids.contains('1.3.6.1.5.5.7.1.1'), isTrue); // authorityInfoAccess
      expect(oids.contains('2.5.29.31'), isTrue); // crlDistributionPoints
      expect(oids.contains('2.5.29.14'), isTrue); // subjectKeyIdentifier
      expect(oids.contains('2.5.29.35'), isTrue); // authorityKeyIdentifier
    });

    test('ocspUrls extracts OCSP URL', () {
      final urls = X509Extensions.ocspUrls(testCertDer);
      expect(urls, contains('http://ocsp.example.com'));
    });

    test('caIssuersUrls extracts CA Issuers URL', () {
      final urls = X509Extensions.caIssuersUrls(testCertDer);
      expect(urls, contains('http://issuer.example.com/ca.cer'));
    });

    test('crlUrls extracts CRL URL', () {
      final urls = X509Extensions.crlUrls(testCertDer);
      expect(urls, contains('http://crl.example.com/crl.pem'));
    });

    test('subjectKeyIdentifier returns 20 bytes', () {
      final ski = X509Extensions.subjectKeyIdentifier(testCertDer);
      expect(ski, isNotNull);
      expect(ski!.length, equals(20));
      // Expected value from openssl: 2E:6A:A3:21:32:FD:55:5A:29:59:77:EA:0C:16:BC:B9:C7:39:9D:5B
      final expected = Uint8List.fromList([
        0x2E, 0x6A, 0xA3, 0x21, 0x32, 0xFD, 0x55, 0x5A,
        0x29, 0x59, 0x77, 0xEA, 0x0C, 0x16, 0xBC, 0xB9,
        0xC7, 0x39, 0x9D, 0x5B,
      ]);
      expect(ski, equals(expected));
    });

    test('authorityKeyIdentifier returns 20 bytes', () {
      final aki = X509Extensions.authorityKeyIdentifier(testCertDer);
      expect(aki, isNotNull);
      expect(aki!.length, equals(20));
      // Expected value from openssl: 2E:6A:A3:21:32:FD:55:5A:29:59:77:EA:0C:16:BC:B9:C7:39:9D:5B
      final expected = Uint8List.fromList([
        0x2E, 0x6A, 0xA3, 0x21, 0x32, 0xFD, 0x55, 0x5A,
        0x29, 0x59, 0x77, 0xEA, 0x0C, 0x16, 0xBC, 0xB9,
        0xC7, 0x39, 0x9D, 0x5B,
      ]);
      expect(aki, equals(expected));
    });

    test('ocspUrls returns empty list for cert without AIA', () {
      // Create a minimal cert without AIA (just the DER header for a cert)
      // For now, use an empty/invalid DER to test defensive behavior
      final invalidDer = Uint8List.fromList([0x30, 0x00]); // Empty SEQUENCE
      final urls = X509Extensions.ocspUrls(invalidDer);
      expect(urls, isEmpty);
    });

    test('caIssuersUrls returns empty list for cert without AIA', () {
      final invalidDer = Uint8List.fromList([0x30, 0x00]); // Empty SEQUENCE
      final urls = X509Extensions.caIssuersUrls(invalidDer);
      expect(urls, isEmpty);
    });

    test('crlUrls returns empty list for cert without CDP', () {
      final invalidDer = Uint8List.fromList([0x30, 0x00]); // Empty SEQUENCE
      final urls = X509Extensions.crlUrls(invalidDer);
      expect(urls, isEmpty);
    });

    test('subjectKeyIdentifier returns null for cert without SKI', () {
      final invalidDer = Uint8List.fromList([0x30, 0x00]); // Empty SEQUENCE
      final ski = X509Extensions.subjectKeyIdentifier(invalidDer);
      expect(ski, isNull);
    });

    test('authorityKeyIdentifier returns null for cert without AKI', () {
      final invalidDer = Uint8List.fromList([0x30, 0x00]); // Empty SEQUENCE
      final aki = X509Extensions.authorityKeyIdentifier(invalidDer);
      expect(aki, isNull);
    });

    test('parseFromCertificate handles malformed input gracefully', () {
      final malformedDer = Uint8List.fromList([0xFF, 0xFF, 0xFF]);
      final extensions = X509Extensions.parseFromCertificate(malformedDer);
      expect(extensions, isEmpty);
    });

    test('ocspUrls filters non-HTTP URLs', () {
      // This test verifies that only HTTP/HTTPS URLs are returned
      // The test cert only has HTTP URLs, so we just verify the behavior
      final urls = X509Extensions.ocspUrls(testCertDer);
      for (final url in urls) {
        expect(
          url.startsWith('http://') || url.startsWith('https://'),
          isTrue,
        );
      }
    });

    test('crlUrls filters non-HTTP URLs', () {
      // This test verifies that only HTTP/HTTPS URLs are returned
      final urls = X509Extensions.crlUrls(testCertDer);
      for (final url in urls) {
        expect(
          url.startsWith('http://') || url.startsWith('https://'),
          isTrue,
        );
      }
    });
  });
}
