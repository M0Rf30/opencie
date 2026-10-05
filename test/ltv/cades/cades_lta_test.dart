// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/services/ltv/asn1/der.dart';
import 'package:opencie/services/ltv/asn1/oids.dart';
import 'package:opencie/services/ltv/cades/cades_lt.dart';
import 'package:opencie/services/ltv/cades/cades_lta.dart';
import 'package:opencie/services/ltv/cades/cades_models.dart';
import 'package:opencie/services/ltv/cades/cades_parser.dart';
import 'package:opencie/services/ltv/crl/crl_models.dart';
import 'package:opencie/services/ltv/tsp/tsp_client.dart';
import 'package:pointycastle/asn1.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'synthetic_cades.dart';

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
  tstInfo.add(_properGeneralizedTime(genTime)); // genTime

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

  // signerInfos SET — one minimal (unsigned/unverified, test-only)
  // SignerInfo so CadesSignedData.parse() has something to attach the
  // ats-hash-index-v3 unsigned attribute to.
  final signerInfo = ASN1Sequence();
  signerInfo.add(ASN1Integer(BigInt.one)); // version
  final signerInfos = ASN1Set();
  signerInfos.add(signerInfo);
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

/// Builds a DER-correct (zero-padded) GeneralizedTime ASN1 object.
/// See tsp_codec_test.dart's twin helper for why this can't use
/// pointycastle's own `ASN1GeneralizedTime(dt)` constructor.
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

/// Create a TSA handler that returns a valid granted response.
shelf.Handler _createTsaHandler() {
  return (shelf.Request request) async {
    if (request.method != 'POST') {
      return shelf.Response.notFound('');
    }

    final body = await request.read().toList().then(
      (chunks) => Uint8List.fromList(chunks.expand((c) => c).toList()),
    );

    // Parse the request to extract nonce and hash
    final parser = ASN1Parser(body);
    final reqSeq = parser.nextObject() as ASN1Sequence;

    // Extract messageImprint hash
    final msgImprint = reqSeq.elements![1] as ASN1Sequence;
    final hashedMessage = msgImprint.elements![1] as ASN1OctetString;
    final hash = hashedMessage.octets!;

    // Extract nonce if present
    Uint8List? nonce;
    for (int i = 2; i < reqSeq.elements!.length; i++) {
      if (reqSeq.elements![i] is ASN1Integer) {
        final nonceInt = reqSeq.elements![i] as ASN1Integer;
        // Convert back to bytes
        final value = nonceInt.integer;
        if (value != null && value != BigInt.zero) {
          final bytes = <int>[];
          var v = value;
          while (v > BigInt.zero) {
            bytes.insert(0, (v & BigInt.from(0xFF)).toInt());
            v = v >> 8;
          }
          nonce = Uint8List.fromList(bytes);
          break;
        }
      }
    }

    // Build response
    final genTime = DateTime.utc(2026, 5, 4, 12, 0, 0);
    final token = _buildTstToken(
      genTime: genTime,
      hashOid: Oid.sha256,
      hash: hash,
      nonce: nonce,
    );

    final statusSeq = ASN1Sequence();
    statusSeq.add(ASN1Integer(BigInt.zero)); // granted
    final respSeq = ASN1Sequence();
    respSeq.add(statusSeq);
    respSeq.add(ASN1Parser(token).nextObject());

    return shelf.Response.ok(
      respSeq.encode(),
      headers: {'content-type': 'application/timestamp-reply'},
    );
  };
}

/// Create a TSA handler that returns rejection status.
shelf.Handler _createTsaHandlerWithRejection() {
  return (shelf.Request request) async {
    if (request.method != 'POST') {
      return shelf.Response.notFound('');
    }

    final statusSeq = ASN1Sequence();
    statusSeq.add(ASN1Integer(BigInt.from(2))); // rejection
    final respSeq = ASN1Sequence();
    respSeq.add(statusSeq);

    return shelf.Response.ok(
      respSeq.encode(),
      headers: {'content-type': 'application/timestamp-reply'},
    );
  };
}

// ============================================================================
// Tests
// ============================================================================

void main() {
  group('CadesLtaUpgrader', () {
    late HttpServer server;
    late Uri tsaUrl;
    late TspClient tspClient;

    setUp(() async {
      // Start a local shelf server
      final handler = _createTsaHandler();
      server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0);
      tsaUrl = Uri.http('localhost:${server.port}', '/tsp');
      tspClient = TspClient();
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test(
      'happy path: upgrade C-LT to C-LTA with archive-time-stamp-v3',
      () async {
        // Arrange: Build a synthetic C-LT signature
        final originalBes = buildSyntheticCadesBes();

        // Build validation material
        final dummyCert = ASN1Sequence();
        dummyCert.add(ASN1Integer(BigInt.from(1)));
        final dummyCertDer = derEncode(dummyCert);

        final dummyCrl = buildSyntheticCrl();
        final crlData = CrlData(
          rawCrl: dummyCrl,
          issuerDn: Uint8List(0),
          thisUpdate: DateTime.now(),
        );

        final material = ValidationMaterial(
          certificates: [dummyCertDer],
          crls: [crlData],
        );

        // Upgrade to C-LT
        final ltUpgrader = CadesLtUpgrader();
        final clt = ltUpgrader.upgrade(originalBes, material);

        // Act: Upgrade to C-LTA
        final ltaUpgrader = CadesLtaUpgrader(
          tspClient: tspClient,
          tspUrl: tsaUrl,
        );
        final lta = await ltaUpgrader.upgrade(clt);

        // Assert
        final sd = CadesSignedData.parse(lta);
        expect(sd.getUnsignedAttribute(Oid.archiveTimeStampV3), isNotNull);
        // Verify prior attributes are still present
        expect(sd.getUnsignedAttribute(Oid.certificateValues), isNotNull);
        expect(sd.getUnsignedAttribute(Oid.revocationValues), isNotNull);
      },
    );

    test(
      'round-trip: parse upgraded C-LTA and re-encode is byte-identical',
      () async {
        // Arrange
        final originalBes = buildSyntheticCadesBes();
        final ltUpgrader = CadesLtUpgrader();

        final dummyCert = ASN1Sequence();
        dummyCert.add(ASN1Integer(BigInt.from(1)));
        final dummyCertDer = derEncode(dummyCert);

        final material = ValidationMaterial(certificates: [dummyCertDer]);

        final clt = ltUpgrader.upgrade(originalBes, material);

        // Act: Upgrade to C-LTA
        final ltaUpgrader = CadesLtaUpgrader(
          tspClient: tspClient,
          tspUrl: tsaUrl,
        );
        final lta1 = await ltaUpgrader.upgrade(clt);

        // Re-parse and re-encode
        final sd = CadesSignedData.parse(lta1);
        final lta2 = sd.encode();

        // Assert: byte-identical
        expect(lta2, equals(lta1));
      },
    );

    test('TSA rejection throws CadesException', () async {
      // Arrange
      await server.close(force: true);
      final handler = _createTsaHandlerWithRejection();
      server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0);
      tsaUrl = Uri.http('localhost:${server.port}', '/tsp');

      final originalBes = buildSyntheticCadesBes();
      final ltUpgrader = CadesLtUpgrader();

      final dummyCert = ASN1Sequence();
      dummyCert.add(ASN1Integer(BigInt.from(1)));
      final dummyCertDer = derEncode(dummyCert);

      final material = ValidationMaterial(certificates: [dummyCertDer]);

      final clt = ltUpgrader.upgrade(originalBes, material);

      // Act & Assert
      final ltaUpgrader = CadesLtaUpgrader(
        tspClient: tspClient,
        tspUrl: tsaUrl,
      );

      expect(() => ltaUpgrader.upgrade(clt), throwsA(isA<CadesException>()));
    });

    test('multi-upgrade replaces archive-time-stamp-v3', () async {
      // Arrange
      final originalBes = buildSyntheticCadesBes();
      final ltUpgrader = CadesLtUpgrader();

      final dummyCert = ASN1Sequence();
      dummyCert.add(ASN1Integer(BigInt.from(1)));
      final dummyCertDer = derEncode(dummyCert);

      final material = ValidationMaterial(certificates: [dummyCertDer]);

      final clt = ltUpgrader.upgrade(originalBes, material);

      // Act: First upgrade
      final ltaUpgrader = CadesLtaUpgrader(
        tspClient: tspClient,
        tspUrl: tsaUrl,
      );
      final lta1 = await ltaUpgrader.upgrade(clt);

      // Second upgrade (should replace)
      final lta2 = await ltaUpgrader.upgrade(lta1);

      // Assert: Only one archive-time-stamp-v3 present
      final sd = CadesSignedData.parse(lta2);
      final atsAttr = sd.getUnsignedAttribute(Oid.archiveTimeStampV3);
      expect(atsAttr, isNotNull);

      // Verify it's a SET OF with exactly one element
      final atsSet = derDecode(atsAttr!) as ASN1Set;
      expect(atsSet.elements, isNotNull);
      expect(atsSet.elements!.length, equals(1));
    });

    test('preserves prior unsigned attributes after upgrade', () async {
      // Arrange
      final originalBes = buildSyntheticCadesBes();
      final ltUpgrader = CadesLtUpgrader();

      final dummyCert = ASN1Sequence();
      dummyCert.add(ASN1Integer(BigInt.from(1)));
      final dummyCertDer = derEncode(dummyCert);

      final dummyCrl = buildSyntheticCrl();
      final crlData = CrlData(
        rawCrl: dummyCrl,
        issuerDn: Uint8List(0),
        thisUpdate: DateTime.now(),
      );

      final material = ValidationMaterial(
        certificates: [dummyCertDer],
        crls: [crlData],
      );

      final clt = ltUpgrader.upgrade(originalBes, material);

      // Verify C-LT has cert-values and revocation-values
      final sdBefore = CadesSignedData.parse(clt);
      expect(sdBefore.getUnsignedAttribute(Oid.certificateValues), isNotNull);
      expect(sdBefore.getUnsignedAttribute(Oid.revocationValues), isNotNull);

      // Act: Upgrade to C-LTA
      final ltaUpgrader = CadesLtaUpgrader(
        tspClient: tspClient,
        tspUrl: tsaUrl,
      );
      final lta = await ltaUpgrader.upgrade(clt);

      // Assert: All three attributes present
      final sdAfter = CadesSignedData.parse(lta);
      expect(sdAfter.getUnsignedAttribute(Oid.certificateValues), isNotNull);
      expect(sdAfter.getUnsignedAttribute(Oid.revocationValues), isNotNull);
      expect(sdAfter.getUnsignedAttribute(Oid.archiveTimeStampV3), isNotNull);
    });

    test('archive timestamp input is correctly constructed', () async {
      // Arrange: Capture the hash sent to TSA
      Uint8List? capturedHash;
      Future<shelf.Response> captureHandler(shelf.Request request) async {
        if (request.method != 'POST') {
          return shelf.Response.notFound('');
        }

        final body = await request.read().toList().then(
          (chunks) => Uint8List.fromList(chunks.expand((c) => c).toList()),
        );
        final parser = ASN1Parser(body);
        final reqSeq = parser.nextObject() as ASN1Sequence;

        final msgImprint = reqSeq.elements![1] as ASN1Sequence;
        final hashedMessage = msgImprint.elements![1] as ASN1OctetString;
        capturedHash = hashedMessage.octets!;

        // Extract nonce
        Uint8List? nonce;
        for (int i = 2; i < reqSeq.elements!.length; i++) {
          if (reqSeq.elements![i] is ASN1Integer) {
            final nonceInt = reqSeq.elements![i] as ASN1Integer;
            final value = nonceInt.integer;
            if (value != null && value != BigInt.zero) {
              final bytes = <int>[];
              var v = value;
              while (v > BigInt.zero) {
                bytes.insert(0, (v & BigInt.from(0xFF)).toInt());
                v = v >> 8;
              }
              nonce = Uint8List.fromList(bytes);
              break;
            }
          }
        }

        final genTime = DateTime.utc(2026, 5, 4, 12, 0, 0);
        final token = _buildTstToken(
          genTime: genTime,
          hashOid: Oid.sha256,
          hash: capturedHash!,
          nonce: nonce,
        );

        final statusSeq = ASN1Sequence();
        statusSeq.add(ASN1Integer(BigInt.zero));
        final respSeq = ASN1Sequence();
        respSeq.add(statusSeq);
        respSeq.add(ASN1Parser(token).nextObject());

        return shelf.Response.ok(
          respSeq.encode(),
          headers: {'content-type': 'application/timestamp-reply'},
        );
      }

      await server.close(force: true);
      server = await shelf_io.serve(
        captureHandler,
        InternetAddress.loopbackIPv4,
        0,
      );
      tsaUrl = Uri.http('localhost:${server.port}', '/tsp');

      final originalBes = buildSyntheticCadesBes();
      final ltUpgrader = CadesLtUpgrader();

      final dummyCert = ASN1Sequence();
      dummyCert.add(ASN1Integer(BigInt.from(1)));
      final dummyCertDer = derEncode(dummyCert);

      final material = ValidationMaterial(certificates: [dummyCertDer]);

      final clt = ltUpgrader.upgrade(originalBes, material);

      // Act: Upgrade to C-LTA
      final ltaUpgrader = CadesLtaUpgrader(
        tspClient: tspClient,
        tspUrl: tsaUrl,
      );
      await ltaUpgrader.upgrade(clt);

      // Assert: Recompute the expected hash manually
      final sd = CadesSignedData.parse(clt);
      final encapContentInfoDer = sd.encapContentInfoForAtsV3;
      final signedAttrsDer = sd.signedAttrsDer;
      final signatureValueDer = sd.signatureValueDer;
      final unsignedAttrsForArchive = sd.unsignedAttributesForArchiveTimestamp;
      final unsignedAttrsDerList = unsignedAttrsForArchive
          .map((e) => e.value)
          .toList();
      unsignedAttrsDerList.sort((a, b) => _lexCompare(a, b));
      final unsignedAttrsConcatenated = Uint8List.fromList(
        unsignedAttrsDerList.expand((bytes) => bytes).toList(),
      );

      final expectedInput = Uint8List.fromList([
        ...encapContentInfoDer,
        ...signedAttrsDer,
        ...signatureValueDer,
        ...unsignedAttrsConcatenated,
      ]);

      final expectedHash = sha256Of(expectedInput);

      expect(capturedHash, equals(expectedHash));
    });

    test('upgrade to C-LTA includes ats-hash-index-v3 in inner TST', () async {
      // Arrange: Set up a mock TSA server
      var server = await shelf_io.serve(
        (_) async {
          return shelf.Response.ok('');
        },
        InternetAddress.loopbackIPv4,
        0,
      );

      final tspClient = TspClient();
      var tsaUrl = Uri.http('localhost:${server.port}', '/tsp');

      // Mock TSA handler that returns a proper TSP response
      Future<shelf.Response> mockTsaHandler(shelf.Request request) async {
        if (request.method != 'POST') {
          return shelf.Response.notFound('');
        }

        final body = await request.read().toList().then(
          (chunks) => Uint8List.fromList(chunks.expand((c) => c).toList()),
        );
        final parser = ASN1Parser(body);
        final reqSeq = parser.nextObject() as ASN1Sequence;

        final msgImprint = reqSeq.elements![1] as ASN1Sequence;
        final hashedMessage = msgImprint.elements![1] as ASN1OctetString;
        final hash = hashedMessage.octets!;

        // Extract nonce so the mandatory nonce check (OC-06) passes.
        Uint8List? nonce;
        for (int i = 2; i < reqSeq.elements!.length; i++) {
          if (reqSeq.elements![i] is ASN1Integer) {
            final nonceInt = reqSeq.elements![i] as ASN1Integer;
            final value = nonceInt.integer;
            if (value != null && value != BigInt.zero) {
              final bytes = <int>[];
              var v = value;
              while (v > BigInt.zero) {
                bytes.insert(0, (v & BigInt.from(0xFF)).toInt());
                v = v >> 8;
              }
              nonce = Uint8List.fromList(bytes);
              break;
            }
          }
        }

        // Build a synthetic TST
        final genTime = DateTime.utc(2026, 5, 4, 12, 0, 0);
        final token = _buildTstToken(
          genTime: genTime,
          hashOid: Oid.sha256,
          hash: hash,
          nonce: nonce,
        );

        final statusSeq = ASN1Sequence();
        statusSeq.add(ASN1Integer(BigInt.zero));
        final respSeq = ASN1Sequence();
        respSeq.add(statusSeq);
        respSeq.add(ASN1Parser(token).nextObject());

        return shelf.Response.ok(
          respSeq.encode(),
          headers: {'content-type': 'application/timestamp-reply'},
        );
      }

      await server.close(force: true);
      server = await shelf_io.serve(
        mockTsaHandler,
        InternetAddress.loopbackIPv4,
        0,
      );
      tsaUrl = Uri.http('localhost:${server.port}', '/tsp');

      final originalBes = buildSyntheticCadesBes();
      final ltUpgrader = CadesLtUpgrader();

      final dummyCert = ASN1Sequence();
      dummyCert.add(ASN1Integer(BigInt.from(1)));
      final dummyCertDer = derEncode(dummyCert);

      final material = ValidationMaterial(certificates: [dummyCertDer]);

      final clt = ltUpgrader.upgrade(originalBes, material);

      // Act: Upgrade to C-LTA
      final ltaUpgrader = CadesLtaUpgrader(
        tspClient: tspClient,
        tspUrl: tsaUrl,
      );
      final lta = await ltaUpgrader.upgrade(clt);

      // Assert: Parse the upgraded signature and verify ats-hash-index-v3 is present
      final ltaSd = CadesSignedData.parse(lta);
      final atsV3Attr = ltaSd.getUnsignedAttribute(Oid.archiveTimeStampV3);
      expect(atsV3Attr, isNotNull);

      // Extract the inner TST from the archive-time-stamp-v3 attribute
      final atsV3Set = derDecode(atsV3Attr!) as ASN1Set;
      expect(atsV3Set.elements, isNotNull);
      expect(atsV3Set.elements!.length, equals(1));

      // Parse the inner TST as a ContentInfo
      final innerTstBytes = derEncode(atsV3Set.elements![0]);
      final innerTstContentInfo = derDecode(innerTstBytes) as ASN1Sequence;

      // Extract the SignedData from [0] EXPLICIT
      if (innerTstContentInfo.elements != null &&
          innerTstContentInfo.elements!.length >= 2) {
        final signedDataElem = innerTstContentInfo.elements![1];
        if (signedDataElem.tag == 0xA0) {
          final innerSignedData =
              derDecode(signedDataElem.valueBytes ?? Uint8List(0))
                  as ASN1Sequence;

          // Extract SignerInfos (last element)
          if (innerSignedData.elements != null &&
              innerSignedData.elements!.isNotEmpty) {
            final signerInfosElem = innerSignedData.elements!.last;
            if (signerInfosElem is ASN1Set &&
                signerInfosElem.elements != null &&
                signerInfosElem.elements!.isNotEmpty) {
              final signerInfo = signerInfosElem.elements![0] as ASN1Sequence;

              // Look for ats-hash-index-v3 in unsignedAttrs [1]
              bool foundAtsHashIndex = false;
              for (final elem in signerInfo.elements!) {
                if (elem.tag == 0xA1) {
                  // Found unsignedAttrs [1]
                  final unsignedAttrsBytes = elem.valueBytes ?? Uint8List(0);
                  final p = ASN1Parser(unsignedAttrsBytes);
                  // _wrapImplicit's payload is the raw SET encoding
                  // (including its own universal tag), not a bare
                  // concatenation of Attribute SEQUENCEs, so the first
                  // (and only) parsed object here is the SET itself.
                  final attrsSetOrSeq = p.hasNext() ? p.nextObject() : null;
                  final attrObjs = attrsSetOrSeq is ASN1Set
                      ? (attrsSetOrSeq.elements ?? const <ASN1Object>[])
                      : (attrsSetOrSeq == null
                            ? const <ASN1Object>[]
                            : [attrsSetOrSeq]);
                  for (final attrObj in attrObjs) {
                    final attr = attrObj as ASN1Sequence;
                    if (attr.elements != null && attr.elements!.isNotEmpty) {
                      final oid = attr.elements![0] as ASN1ObjectIdentifier;
                      if (oid.objectIdentifierAsString == Oid.atsHashIndexV3) {
                        foundAtsHashIndex = true;

                        // Verify the structure: SEQUENCE with [AlgorithmIdentifier, SEQUENCE OF, SEQUENCE OF, SEQUENCE OF]
                        if (attr.elements!.length >= 2) {
                          final attrValuesSet = attr.elements![1] as ASN1Set;
                          if (attrValuesSet.elements != null &&
                              attrValuesSet.elements!.isNotEmpty) {
                            final atsHashIndexSeq =
                                attrValuesSet.elements![0] as ASN1Sequence;
                            expect(atsHashIndexSeq.elements, isNotNull);
                            expect(
                              atsHashIndexSeq.elements!.length,
                              equals(4),
                            ); // AlgId + 3 SEQUENCE OF

                            // Verify first element is AlgorithmIdentifier
                            final algId =
                                atsHashIndexSeq.elements![0] as ASN1Sequence;
                            expect(algId.elements, isNotNull);
                            expect(
                              algId.elements!.length,
                              greaterThanOrEqualTo(1),
                            );

                            // Verify remaining elements are SEQUENCE OF OCTET STRING
                            for (int i = 1; i < 4; i++) {
                              final seqOf =
                                  atsHashIndexSeq.elements![i] as ASN1Sequence;
                              expect(seqOf.elements, isNotNull);
                              // Each element should be an OCTET STRING (hash)
                              for (final elem in seqOf.elements!) {
                                expect(elem, isA<ASN1OctetString>());
                              }
                            }
                          }
                        }
                        break;
                      }
                    }
                  }
                  break;
                }
              }
              expect(
                foundAtsHashIndex,
                isTrue,
                reason: 'ats-hash-index-v3 not found in inner TST',
              );
            }
          }
        }
      }

      await server.close(force: true);
    });
  });
}

/// Lexicographic comparison of byte arrays (unsigned).
int _lexCompare(Uint8List a, Uint8List b) {
  final minLen = a.length < b.length ? a.length : b.length;
  for (int i = 0; i < minLen; i++) {
    final cmp = (a[i] & 0xFF).compareTo(b[i] & 0xFF);
    if (cmp != 0) return cmp;
  }
  return a.length.compareTo(b.length);
}
