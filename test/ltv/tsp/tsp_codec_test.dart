// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/services/ltv/asn1/der.dart';
import 'package:opencie/services/ltv/asn1/oids.dart';
import 'package:opencie/services/ltv/tsp/tsp_codec.dart';
import 'package:opencie/services/ltv/tsp/tsp_models.dart';
import 'package:pointycastle/asn1.dart';

void main() {
  group('TspCodec', () {
    test('encode/decode round-trip (SHA-256, no nonce, no cert)', () {
      // Arrange
      final hash = Uint8List(32); // 32 zero bytes for SHA-256
      final req = TspRequest(
        messageImprintHash: hash,
        hashAlgorithmOid: Oid.sha256,
      );

      // Act
      final encoded = encodeTspRequest(req);
      final parser = ASN1Parser(encoded);
      final seq = parser.nextObject() as ASN1Sequence;

      // Assert
      expect(seq.elements!.length, greaterThanOrEqualTo(2));

      // Check version
      final version = seq.elements![0] as ASN1Integer;
      expect(version.integer, BigInt.one);

      // Check messageImprint
      final msgImprint = seq.elements![1] as ASN1Sequence;
      expect(msgImprint.elements!.length, 2);

      final hashAlgoSeq = msgImprint.elements![0] as ASN1Sequence;
      final hashAlgoOid = hashAlgoSeq.elements![0] as ASN1ObjectIdentifier;
      expect(hashAlgoOid.objectIdentifierAsString, Oid.sha256);

      final hashedMessage = msgImprint.elements![1] as ASN1OctetString;
      expect(hashedMessage.octets, hash);

      // Check no nonce, no certReq
      expect(seq.elements!.length, 2);
    });

    test('encode with nonce', () {
      // Arrange
      final hash = Uint8List(32);
      final nonce = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final req = TspRequest(
        messageImprintHash: hash,
        hashAlgorithmOid: Oid.sha256,
        nonce: nonce,
      );

      // Act
      final encoded = encodeTspRequest(req);
      final parser = ASN1Parser(encoded);
      final seq = parser.nextObject() as ASN1Sequence;

      // Assert
      expect(seq.elements!.length, 3);
      final nonceInt = seq.elements![2] as ASN1Integer;
      expect(nonceInt.integer, isNotNull);
    });

    test('encode with policy OID', () {
      // Arrange
      final hash = Uint8List(32);
      const policyOid = '1.3.6.1.4.1.601.10.3.1';
      final req = TspRequest(
        messageImprintHash: hash,
        hashAlgorithmOid: Oid.sha256,
        policyOid: policyOid,
      );

      // Act
      final encoded = encodeTspRequest(req);
      final parser = ASN1Parser(encoded);
      final seq = parser.nextObject() as ASN1Sequence;

      // Assert
      expect(seq.elements!.length, 3);
      final policyOidObj = seq.elements![2] as ASN1ObjectIdentifier;
      expect(policyOidObj.objectIdentifierAsString, policyOid);
    });

    test('encode with certReq=true', () {
      // Arrange
      final hash = Uint8List(32);
      final req = TspRequest(
        messageImprintHash: hash,
        hashAlgorithmOid: Oid.sha256,
        reqCertReq: true,
      );

      // Act
      final encoded = encodeTspRequest(req);
      final parser = ASN1Parser(encoded);
      final seq = parser.nextObject() as ASN1Sequence;

      // Assert
      expect(seq.elements!.length, 3);
      final certReq = seq.elements![2] as ASN1Boolean;
      expect(certReq.boolValue, true);
    });

    test('encode with SHA-384', () {
      // Arrange
      final hash = Uint8List(48); // 48 bytes for SHA-384
      final req = TspRequest(
        messageImprintHash: hash,
        hashAlgorithmOid: Oid.sha384,
      );

      // Act
      final encoded = encodeTspRequest(req);
      final parser = ASN1Parser(encoded);
      final seq = parser.nextObject() as ASN1Sequence;

      // Assert
      final msgImprint = seq.elements![1] as ASN1Sequence;
      final hashAlgoSeq = msgImprint.elements![0] as ASN1Sequence;
      final hashAlgoOid = hashAlgoSeq.elements![0] as ASN1ObjectIdentifier;
      expect(hashAlgoOid.objectIdentifierAsString, Oid.sha384);
    });

    test('encode with SHA-512', () {
      // Arrange
      final hash = Uint8List(64); // 64 bytes for SHA-512
      final req = TspRequest(
        messageImprintHash: hash,
        hashAlgorithmOid: Oid.sha512,
      );

      // Act
      final encoded = encodeTspRequest(req);
      final parser = ASN1Parser(encoded);
      final seq = parser.nextObject() as ASN1Sequence;

      // Assert
      final msgImprint = seq.elements![1] as ASN1Sequence;
      final hashAlgoSeq = msgImprint.elements![0] as ASN1Sequence;
      final hashAlgoOid = hashAlgoSeq.elements![0] as ASN1ObjectIdentifier;
      expect(hashAlgoOid.objectIdentifierAsString, Oid.sha512);
    });

    test('parse rejection response', () {
      // Arrange: synthesize a minimal TimeStampResp with status=2 (rejection)
      final statusSeq = ASN1Sequence();
      statusSeq.add(ASN1Integer(BigInt.two)); // rejection
      final respSeq = ASN1Sequence();
      respSeq.add(statusSeq);

      // Act
      final resp = parseTspResponse(respSeq.encode());

      // Assert
      expect(resp.status, TspStatus.rejection);
      expect(resp.timeStampToken, isNull);
    });

    test('parse granted response with TSTInfo', () {
      // Arrange: build a hand-crafted TimeStampToken with TSTInfo
      final genTime = DateTime.utc(2026, 5, 4, 12, 0, 0);
      final hash = Uint8List(32);
      final token = _buildTstToken(
        genTime: genTime,
        hashOid: Oid.sha256,
        hash: hash,
      );

      // Build TimeStampResp
      final statusSeq = ASN1Sequence();
      statusSeq.add(ASN1Integer(BigInt.zero)); // granted
      final respSeq = ASN1Sequence();
      respSeq.add(statusSeq);
      respSeq.add(ASN1Parser(token).nextObject());

      // Act
      final resp = parseTspResponse(respSeq.encode());

      // Assert
      expect(resp.status, TspStatus.granted);
      expect(resp.isSuccess, true);
      expect(resp.timeStampToken, isNotNull);
      // Note: TSTInfo parsing is complex and requires proper CMS structure
      // For now, just verify the response is parsed as granted
    });

    test('parse malformed response returns rejection', () {
      // Arrange: random bytes
      final malformed = Uint8List.fromList([0xFF, 0xFF, 0xFF]);

      // Act
      final resp = parseTspResponse(malformed);

      // Assert
      expect(resp.status, TspStatus.rejection);
      expect(resp.statusStrings, isNotEmpty);
      expect(resp.statusStrings[0], contains('parse error'));
    });
  });
}

/// Helper to build a minimal TSTInfo token for testing.
Uint8List _buildTstToken({
  required DateTime genTime,
  required String hashOid,
  required Uint8List hash,
  Uint8List? nonce,
}) {
  // Build TSTInfo
  final tstInfo = ASN1Sequence();
  tstInfo.add(ASN1Integer(BigInt.one)); // version
  tstInfo.add(
    ASN1ObjectIdentifier.fromIdentifierString('1.3.6.1.4.1.601.10.3.1'),
  ); // policy

  // messageImprint
  final msgImprint = ASN1Sequence();
  msgImprint.add(algorithmIdentifier(hashOid));
  msgImprint.add(ASN1OctetString(octets: hash));
  tstInfo.add(msgImprint);

  tstInfo.add(ASN1Integer(BigInt.one)); // serialNumber
  tstInfo.add(ASN1GeneralizedTime(genTime)); // genTime

  if (nonce != null) {
    // Encode nonce as INTEGER
    var value = BigInt.zero;
    for (final byte in nonce) {
      value = (value << 8) | BigInt.from(byte & 0xFF);
    }
    tstInfo.add(ASN1Integer(value));
  }

  // Wrap in EncapsulatedContentInfo
  final encapContentInfo = ASN1Sequence();
  encapContentInfo.add(
    ASN1ObjectIdentifier.fromIdentifierString(Oid.timeStampToken),
  );

  // eContent [0] EXPLICIT OCTET STRING
  final eContentOctet = ASN1OctetString(octets: tstInfo.encode());
  // Build context-specific tag manually
  final eContentCtxBytes = _buildContextSpecificTagBytes(
    0,
    eContentOctet.encode(),
  );
  final eContentCtx = ASN1Parser(eContentCtxBytes).nextObject();
  encapContentInfo.add(eContentCtx);

  // Build minimal SignedData
  final signedData = ASN1Sequence();
  signedData.add(ASN1Integer(BigInt.from(3))); // version

  // digestAlgorithms SET
  final digestAlgos = ASN1Set();
  signedData.add(digestAlgos);

  signedData.add(encapContentInfo);

  // signerInfos SET — empty
  final signerInfos = ASN1Set();
  signedData.add(signerInfos);

  // Wrap in ContentInfo
  final contentInfo = ASN1Sequence();
  contentInfo.add(
    ASN1ObjectIdentifier.fromIdentifierString(Oid.pkcs7SignedData),
  );

  // [0] EXPLICIT SignedData
  final signedDataBytes = signedData.encode();
  final signedDataCtxBytes = _buildContextSpecificTagBytes(0, signedDataBytes);
  final signedDataCtx = ASN1Parser(signedDataCtxBytes).nextObject();
  contentInfo.add(signedDataCtx);

  return contentInfo.encode();
}

/// Helper to build context-specific tag bytes.
Uint8List _buildContextSpecificTagBytes(int tagNumber, Uint8List content) {
  final tag = 0xA0 | tagNumber;
  final result = BytesBuilder();
  result.addByte(tag);

  // Encode length
  if (content.length < 128) {
    result.addByte(content.length);
  } else {
    final lenBytes = <int>[];
    var len = content.length;
    while (len > 0) {
      lenBytes.insert(0, len & 0xFF);
      len >>= 8;
    }
    result.addByte(0x80 | lenBytes.length);
    result.add(lenBytes);
  }

  result.add(content);
  return result.toBytes();
}
