// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';
import 'package:test/test.dart';

import 'package:opencie/services/ltv/asn1/der.dart';
import 'package:opencie/services/ltv/asn1/oids.dart';

void main() {
  group('DER encoding/decoding', () {
    test('derEncode/derDecode round-trip', () {
      // Build a SEQUENCE of (INTEGER, OctetString, OID, Null)
      final seq = ASN1Sequence();
      seq.add(ASN1Integer(BigInt.from(42)));
      seq.add(ASN1OctetString(octets: Uint8List.fromList([1, 2, 3, 4])));
      seq.add(ASN1ObjectIdentifier.fromIdentifierString(Oid.sha256));
      seq.add(ASN1Null());

      final encoded = derEncode(seq);
      final decoded = derDecode(encoded);

      expect(decoded, isA<ASN1Sequence>());
      final decodedSeq = decoded as ASN1Sequence;
      expect(decodedSeq.elements, isNotNull);
      expect(decodedSeq.elements!.length, equals(4));
      expect(decodedSeq.elements![0], isA<ASN1Integer>());
      expect(decodedSeq.elements![1], isA<ASN1OctetString>());
      expect(decodedSeq.elements![2], isA<ASN1ObjectIdentifier>());
      expect(decodedSeq.elements![3], isA<ASN1Null>());
    });

    test('algorithmIdentifier for sha256WithRSA', () {
      final algId = algorithmIdentifier(
        Oid.sha256WithRSA,
        parameters: ASN1Null(),
      );
      final encoded = derEncode(algId);

      // sha256WithRSA AlgorithmIdentifier is well-known:
      // 30 0d 06 09 2a 86 48 86 f7 0d 01 01 0b 05 00
      final expected = Uint8List.fromList([
        0x30,
        0x0d,
        0x06,
        0x09,
        0x2a,
        0x86,
        0x48,
        0x86,
        0xf7,
        0x0d,
        0x01,
        0x01,
        0x0b,
        0x05,
        0x00,
      ]);

      expect(encoded, equals(expected));
    });

    test('algorithmIdentifier for ecdsaWithSha256 (no parameters)', () {
      final algId = algorithmIdentifier(Oid.ecdsaWithSha256);
      final encoded = derEncode(algId);

      // ecdsaWithSha256 AlgorithmIdentifier (no parameters):
      // 30 0a 06 08 2a 86 48 ce 3d 04 03 02
      final expected = Uint8List.fromList([
        0x30,
        0x0a,
        0x06,
        0x08,
        0x2a,
        0x86,
        0x48,
        0xce,
        0x3d,
        0x04,
        0x03,
        0x02,
      ]);

      expect(encoded, equals(expected));
    });

    test('derSortedSet produces consistent output', () {
      // Create two sets with items in different orders
      final items1 = [
        ASN1Integer(BigInt.from(3)),
        ASN1Integer(BigInt.from(1)),
        ASN1Integer(BigInt.from(2)),
      ];

      final items2 = [
        ASN1Integer(BigInt.from(1)),
        ASN1Integer(BigInt.from(3)),
        ASN1Integer(BigInt.from(2)),
      ];

      final set1 = derSortedSet(items1);
      final set2 = derSortedSet(items2);

      final encoded1 = derEncode(set1);
      final encoded2 = derEncode(set2);

      expect(encoded1, equals(encoded2));
    });

    test('sha256Of empty bytes', () {
      final hash = sha256Of(Uint8List(0));

      // Well-known SHA-256 of empty string
      final expected = Uint8List.fromList([
        0xe3,
        0xb0,
        0xc4,
        0x42,
        0x98,
        0xfc,
        0x1c,
        0x14,
        0x9a,
        0xfb,
        0xf4,
        0xc8,
        0x99,
        0x6f,
        0xb9,
        0x24,
        0x27,
        0xae,
        0x41,
        0xe4,
        0x64,
        0x9b,
        0x93,
        0x4c,
        0xa4,
        0x95,
        0x99,
        0x1b,
        0x78,
        0x52,
        0xb8,
        0x55,
      ]);

      expect(hash, equals(expected));
    });

    test('sha384Of empty bytes', () {
      final hash = sha384Of(Uint8List(0));

      // Well-known SHA-384 of empty string
      final expected = Uint8List.fromList([
        0x38,
        0xb0,
        0x60,
        0xa7,
        0x51,
        0xac,
        0x96,
        0x38,
        0x4c,
        0xd9,
        0x32,
        0x7e,
        0xb1,
        0xb1,
        0xe3,
        0x6a,
        0x21,
        0xfd,
        0xb7,
        0x11,
        0x14,
        0xbe,
        0x07,
        0x43,
        0x4c,
        0x0c,
        0xc7,
        0xbf,
        0x63,
        0xf6,
        0xe1,
        0xda,
        0x27,
        0x4e,
        0xde,
        0xbf,
        0xe7,
        0x6f,
        0x65,
        0xfb,
        0xd5,
        0x1a,
        0xd2,
        0xf1,
        0x48,
        0x98,
        0xb9,
        0x5b,
      ]);

      expect(hash, equals(expected));
    });

    test('sha512Of empty bytes', () {
      final hash = sha512Of(Uint8List(0));

      // Well-known SHA-512 of empty string
      final expected = Uint8List.fromList([
        0xcf,
        0x83,
        0xe1,
        0x35,
        0x7e,
        0xef,
        0xb8,
        0xbd,
        0xf1,
        0x54,
        0x28,
        0x50,
        0xd6,
        0x6d,
        0x80,
        0x07,
        0xd6,
        0x20,
        0xe4,
        0x05,
        0x0b,
        0x57,
        0x15,
        0xdc,
        0x83,
        0xf4,
        0xa9,
        0x21,
        0xd3,
        0x6c,
        0xe9,
        0xce,
        0x47,
        0xd0,
        0xd1,
        0x3c,
        0x5d,
        0x85,
        0xf2,
        0xb0,
        0xff,
        0x83,
        0x18,
        0xd2,
        0x87,
        0x7e,
        0xec,
        0x2f,
        0x63,
        0xb9,
        0x31,
        0xbd,
        0x47,
        0x41,
        0x7a,
        0x81,
        0xa5,
        0x38,
        0x32,
        0x7a,
        0xf9,
        0x27,
        0xda,
        0x3e,
      ]);

      expect(hash, equals(expected));
    });

    test('hashOf dispatches by OID', () {
      final data = Uint8List.fromList([1, 2, 3]);

      final sha256Hash = hashOf(data, Oid.sha256);
      expect(sha256Hash, equals(sha256Of(data)));

      final sha384Hash = hashOf(data, Oid.sha384);
      expect(sha384Hash, equals(sha384Of(data)));

      final sha512Hash = hashOf(data, Oid.sha512);
      expect(sha512Hash, equals(sha512Of(data)));
    });

    test('hashOf throws on unknown OID', () {
      final data = Uint8List.fromList([1, 2, 3]);
      expect(
        () => hashOf(data, '1.2.3.4.5.6.7.8.9'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('hashOf supports SHA-1 (required for OCSP CertID)', () {
      final data = Uint8List.fromList([1, 2, 3]);
      // Known SHA-1("\x01\x02\x03") = 7037807198c22a7d2b0807371d763779a84fdfcf
      final expected = Uint8List.fromList([
        0x70,
        0x37,
        0x80,
        0x71,
        0x98,
        0xc2,
        0x2a,
        0x7d,
        0x2b,
        0x08,
        0x07,
        0x37,
        0x1d,
        0x76,
        0x37,
        0x79,
        0xa8,
        0x4f,
        0xdf,
        0xcf,
      ]);
      expect(hashOf(data, Oid.sha1), equals(expected));
    });

    test('bytesEqual true for identical bytes', () {
      final a = Uint8List.fromList([1, 2, 3, 4, 5]);
      final b = Uint8List.fromList([1, 2, 3, 4, 5]);
      expect(bytesEqual(a, b), isTrue);
    });

    test('bytesEqual false for different bytes', () {
      final a = Uint8List.fromList([1, 2, 3, 4, 5]);
      final b = Uint8List.fromList([1, 2, 3, 4, 6]);
      expect(bytesEqual(a, b), isFalse);
    });

    test('bytesEqual false for different lengths', () {
      final a = Uint8List.fromList([1, 2, 3, 4, 5]);
      final b = Uint8List.fromList([1, 2, 3, 4]);
      expect(bytesEqual(a, b), isFalse);
    });

    test('bytesEqual true for empty bytes', () {
      final a = Uint8List(0);
      final b = Uint8List(0);
      expect(bytesEqual(a, b), isTrue);
    });
  });

  group('Oid.hashForSignatureAlgorithm', () {
    test('maps RSA signature algorithms to hash OIDs', () {
      expect(
        Oid.hashForSignatureAlgorithm(Oid.sha256WithRSA),
        equals(Oid.sha256),
      );
      expect(
        Oid.hashForSignatureAlgorithm(Oid.sha384WithRSA),
        equals(Oid.sha384),
      );
      expect(
        Oid.hashForSignatureAlgorithm(Oid.sha512WithRSA),
        equals(Oid.sha512),
      );
    });

    test('maps ECDSA signature algorithms to hash OIDs', () {
      expect(
        Oid.hashForSignatureAlgorithm(Oid.ecdsaWithSha256),
        equals(Oid.sha256),
      );
      expect(
        Oid.hashForSignatureAlgorithm(Oid.ecdsaWithSha384),
        equals(Oid.sha384),
      );
      expect(
        Oid.hashForSignatureAlgorithm(Oid.ecdsaWithSha512),
        equals(Oid.sha512),
      );
    });

    test('returns null for unknown OID', () {
      expect(Oid.hashForSignatureAlgorithm('1.2.3.4.5.6.7.8.9'), isNull);
    });
  });
}
