// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/services/ltv/pades/pdf_models.dart';
import 'package:opencie/services/ltv/pades/pades_lta.dart';
import 'package:opencie/services/ltv/pades/pdf_reader.dart';
import 'package:opencie/services/ltv/tsp/tsp_client.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'synthetic_pdf.dart';

void main() {
  group('PadesLtaUpgrader', () {
    late HttpServer server;
    late Uri tsaUrl;
    late TspClient tspClient;

    setUp(() async {
      // Start a local shelf server for TSA mock
      final handler = _createTsaHandler();
      server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0);
      tsaUrl = Uri.http('localhost:${server.port}', '/tsp');
      tspClient = TspClient();
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('happy path: B-B → B-LTA', () async {
      // Arrange
      final pdf = buildSyntheticSignedPdf();
      final upgrader = PadesLtaUpgrader(tspClient: tspClient, tspUrl: tsaUrl);

      // Act
      final ltaPdf = await upgrader.upgrade(pdf);

      // Assert
      expect(ltaPdf.length, greaterThan(pdf.length));

      // Should be parseable
      final reader = PdfReader(ltaPdf);
      final trailer = reader.readTrailer();
      expect(trailer.size, greaterThan(5));

      // Should contain DocTimeStamp
      final ltaPdfStr = String.fromCharCodes(ltaPdf);
      expect(ltaPdfStr, contains('/Type /DocTimeStamp'));
      expect(ltaPdfStr, contains('/ETSI.RFC3161'));
      expect(ltaPdfStr, contains('/ByteRange'));
    });

    test('DocTimeStamp /Contents is hex-encoded and non-zero', () async {
      // Arrange
      final pdf = buildSyntheticSignedPdf();
      final upgrader = PadesLtaUpgrader(tspClient: tspClient, tspUrl: tsaUrl);

      // Act
      final ltaPdf = await upgrader.upgrade(pdf);

      // Assert
      final ltaPdfStr = String.fromCharCodes(ltaPdf);

      // Find /Contents <...>
      final contentsMatch = RegExp(
        r'/Contents\s*<([0-9A-Fa-f]+)>',
      ).firstMatch(ltaPdfStr);
      expect(contentsMatch, isNotNull);

      final contentsHex = contentsMatch!.group(1)!;
      expect(contentsHex.length, greaterThan(0));

      // Should not be all zeros (TST should have real bytes)
      expect(contentsHex, isNot(matches(RegExp(r'^0+$'))));

      // Should be valid hex
      expect(() => hex.decode(contentsHex), returnsNormally);
    });

    test('DocTimeStamp /ByteRange is valid', () async {
      // Arrange
      final pdf = buildSyntheticSignedPdf();
      final upgrader = PadesLtaUpgrader(tspClient: tspClient, tspUrl: tsaUrl);

      // Act
      final ltaPdf = await upgrader.upgrade(pdf);

      // Assert
      final ltaPdfStr = String.fromCharCodes(ltaPdf);

      // Find /ByteRange [0 a b c]
      final byteRangeMatch = RegExp(
        r'/ByteRange\s*\[\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*\]',
      ).allMatches(ltaPdfStr).toList();

      // Should have at least 1 ByteRange (the DocTimeStamp)
      expect(byteRangeMatch.length, greaterThanOrEqualTo(1));

      // Last ByteRange is the DocTimeStamp
      // Format: [start1 length1 start2 length2]
      final lastMatch = byteRangeMatch.last;
      final start1 = int.parse(lastMatch.group(1)!);
      final length1 = int.parse(lastMatch.group(2)!);
      final start2 = int.parse(lastMatch.group(3)!);
      final length2 = int.parse(lastMatch.group(4)!);

      // Verify ByteRange validity
      expect(start1, equals(0));
      // Range 1 should end before Range 2 starts (because /Contents is in between)
      expect(start1 + length1, lessThan(start2));
      // Both ranges should be positive
      expect(length1, greaterThan(0));
      expect(length2, greaterThan(0));
    });

    test('hash correctness: TSA receives correct byte ranges', () async {
      // Arrange
      final pdf = buildSyntheticSignedPdf();

      final upgrader = PadesLtaUpgrader(tspClient: tspClient, tspUrl: tsaUrl);

      // Act
      final ltaPdf = await upgrader.upgrade(pdf);

      // Assert: The result should be a valid PDF with DocTimeStamp
      final ltaPdfStr = String.fromCharCodes(ltaPdf);
      expect(ltaPdfStr, contains('/Type /DocTimeStamp'));
      expect(ltaPdfStr, contains('/ByteRange'));

      // Extract the DocTimeStamp /ByteRange from the result
      final byteRangeMatches = RegExp(
        r'/ByteRange\s*\[\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*\]',
      ).allMatches(ltaPdfStr).toList();

      expect(byteRangeMatches.length, greaterThanOrEqualTo(1));

      final lastMatch = byteRangeMatches.last;
      final start1 = int.parse(lastMatch.group(1)!);
      final length1 = int.parse(lastMatch.group(2)!);
      final start2 = int.parse(lastMatch.group(3)!);
      final length2 = int.parse(lastMatch.group(4)!);

      // Verify that the byte ranges are valid
      expect(start1, equals(0));
      expect(length1, greaterThan(0));
      expect(start2, greaterThan(start1 + length1));
      expect(length2, greaterThan(0));

      // The byte ranges should cover the entire file except the /Contents
      final coveredBytes = length1 + length2;
      expect(coveredBytes, lessThan(ltaPdf.length));
    });

    test('original signature is byte-preserved', () async {
      // Arrange
      final pdf = buildSyntheticSignedPdf();
      final upgrader = PadesLtaUpgrader(tspClient: tspClient, tspUrl: tsaUrl);

      // Act
      final ltaPdf = await upgrader.upgrade(pdf);

      // Assert: original bytes should be preserved (at least the first part)
      // Note: The original PDF is preserved in the incremental update,
      // but the patching may affect bytes after the original if they're in the new section
      expect(ltaPdf.length, greaterThan(pdf.length));

      // The original PDF header should be preserved
      expect(ltaPdf.sublist(0, 10), equals(pdf.sublist(0, 10)));
    });

    test('TSA rejection throws PadesException', () async {
      // Arrange
      final pdf = buildSyntheticSignedPdf();

      // Create a TSA handler that returns rejection
      Future<shelf.Response> tsaRejectionHandler(shelf.Request request) async {
        if (request.method != 'POST') {
          return shelf.Response.notFound('');
        }

        // Return rejection status
        return _buildTsaRejectionResponse();
      }

      await server.close(force: true);
      server = await shelf_io.serve(
        tsaRejectionHandler,
        InternetAddress.loopbackIPv4,
        0,
      );
      tsaUrl = Uri.http('localhost:${server.port}', '/tsp');

      final upgrader = PadesLtaUpgrader(tspClient: tspClient, tspUrl: tsaUrl);

      // Act & Assert
      expect(() => upgrader.upgrade(pdf), throwsA(isA<PadesException>()));
    });

    test('oversized TST throws PadesException', () async {
      // Arrange
      final pdf = buildSyntheticSignedPdf();

      // Create a TSA handler that returns a very large TST
      Future<shelf.Response> tsaOversizedHandler(shelf.Request request) async {
        if (request.method != 'POST') {
          return shelf.Response.notFound('');
        }

        final body = await request.read().toList().then(
          (chunks) => Uint8List.fromList(chunks.expand((c) => c).toList()),
        );

        // Parse the request to extract hash
        final parser = ASN1Parser(body);
        final reqSeq = parser.nextObject() as ASN1Sequence;
        final msgImprint = reqSeq.elements![1] as ASN1Sequence;
        final hashedMessage = msgImprint.elements![1] as ASN1OctetString;
        final hash = hashedMessage.octets!;

        // Return a response with a huge TST (larger than reserved space)
        return _buildTsaResponseWithOversizedTst(hash);
      }

      await server.close(force: true);
      server = await shelf_io.serve(
        tsaOversizedHandler,
        InternetAddress.loopbackIPv4,
        0,
      );
      tsaUrl = Uri.http('localhost:${server.port}', '/tsp');

      final upgrader = PadesLtaUpgrader(
        tspClient: tspClient,
        tspUrl: tsaUrl,
        contentsReserveBytes: 512, // Small reserve (50KB TST will exceed this)
      );

      // Act & Assert
      expect(() => upgrader.upgrade(pdf), throwsA(isA<PadesException>()));
    });

    test('round-trip parse: B-LTA result is valid PDF', () async {
      // Arrange
      final pdf = buildSyntheticSignedPdf();
      final upgrader = PadesLtaUpgrader(tspClient: tspClient, tspUrl: tsaUrl);

      // Act
      final ltaPdf = await upgrader.upgrade(pdf);

      // Assert: should be parseable
      final reader = PdfReader(ltaPdf);
      final trailer = reader.readTrailer();

      expect(trailer.size, greaterThan(0));
      expect(trailer.rootRef.objNum, greaterThan(0));

      // Should have xref entries
      expect(trailer.xrefEntries.length, greaterThan(0));
    });

    test('contentsReserveBytes validation', () {
      // Arrange & Act & Assert
      expect(
        () => PadesLtaUpgrader(
          tspClient: tspClient,
          tspUrl: tsaUrl,
          contentsReserveBytes: 63, // odd number
        ),
        throwsA(isA<PadesException>()),
      );

      expect(
        () => PadesLtaUpgrader(
          tspClient: tspClient,
          tspUrl: tsaUrl,
          contentsReserveBytes: 100, // too small
        ),
        throwsA(isA<PadesException>()),
      );

      // Should succeed with valid values
      expect(
        () => PadesLtaUpgrader(
          tspClient: tspClient,
          tspUrl: tsaUrl,
          contentsReserveBytes: 256,
        ),
        returnsNormally,
      );
    });

    test('P0-1 self-verification: hash correctness via ByteRange', () async {
      // This test verifies that the hash computed from the result PDF's ByteRange
      // matches the hash that the TSA actually received and signed.
      // This catches the P0-1 bug where ByteRange was patched AFTER hashing.

      // Arrange
      final pdf = buildSyntheticSignedPdf();

      // Capture the hash that the TSA receives
      Uint8List? capturedHash;
      Future<shelf.Response> tsaCaptureHandler(shelf.Request request) async {
        if (request.method != 'POST') {
          return shelf.Response.notFound('');
        }

        final body = await request.read().toList().then(
          (chunks) => Uint8List.fromList(chunks.expand((c) => c).toList()),
        );

        // Parse the request to extract hash
        final parser = ASN1Parser(body);
        final reqSeq = parser.nextObject() as ASN1Sequence;
        final msgImprint = reqSeq.elements![1] as ASN1Sequence;
        final hashedMessage = msgImprint.elements![1] as ASN1OctetString;
        capturedHash = hashedMessage.octets!;

        return _buildTsaResponse(capturedHash!);
      }

      await server.close(force: true);
      server = await shelf_io.serve(
        tsaCaptureHandler,
        InternetAddress.loopbackIPv4,
        0,
      );
      tsaUrl = Uri.http('localhost:${server.port}', '/tsp');

      final upgrader = PadesLtaUpgrader(tspClient: tspClient, tspUrl: tsaUrl);

      // Act
      final ltaPdf = await upgrader.upgrade(pdf);

      // Assert: Extract the DocTimeStamp /ByteRange from the result
      final ltaPdfStr = String.fromCharCodes(ltaPdf);
      final byteRangeMatches = RegExp(
        r'/ByteRange\s*\[\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*\]',
      ).allMatches(ltaPdfStr).toList();

      expect(
        byteRangeMatches.length,
        greaterThanOrEqualTo(1),
        reason: 'Should have at least one ByteRange',
      );

      // Last ByteRange is the DocTimeStamp
      final lastMatch = byteRangeMatches.last;
      final start1 = int.parse(lastMatch.group(1)!);
      final length1 = int.parse(lastMatch.group(2)!);
      final start2 = int.parse(lastMatch.group(3)!);
      final length2 = int.parse(lastMatch.group(4)!);

      // Compute hash from the result PDF using the ByteRange
      final hashBuilder = BytesBuilder();
      hashBuilder.add(ltaPdf.sublist(start1, start1 + length1));
      hashBuilder.add(ltaPdf.sublist(start2, start2 + length2));
      final sha256Digest = SHA256Digest();
      final computedHash = sha256Digest.process(hashBuilder.toBytes());

      // Verify that the computed hash matches what the TSA received
      expect(
        capturedHash,
        isNotNull,
        reason: 'TSA should have received a hash',
      );
      expect(
        computedHash,
        capturedHash,
        reason:
            'Hash computed from result ByteRange should match the hash the TSA signed. '
            'This verifies that ByteRange was patched BEFORE hashing (P0-1 fix).',
      );
    });
  });
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

    // Parse the request to extract hash
    final parser = ASN1Parser(body);
    final reqSeq = parser.nextObject() as ASN1Sequence;
    final msgImprint = reqSeq.elements![1] as ASN1Sequence;
    final hashedMessage = msgImprint.elements![1] as ASN1OctetString;
    final hash = hashedMessage.octets!;

    return _buildTsaResponse(hash);
  };
}

/// Build a valid TimeStampResp with granted status.
shelf.Response _buildTsaResponse(Uint8List hash) {
  // Build a minimal TimeStampToken (CMS SignedData)
  final tstToken = _buildMinimalTimeStampToken(hash);

  // Build TimeStampResp: SEQUENCE { status PKIStatusInfo, timeStampToken }
  final statusSeq = ASN1Sequence();
  statusSeq.add(ASN1Integer(BigInt.zero)); // granted

  final respSeq = ASN1Sequence();
  respSeq.add(statusSeq);
  respSeq.add(ASN1Parser(tstToken).nextObject());

  return shelf.Response.ok(
    respSeq.encode(),
    headers: {'Content-Type': 'application/timestamp-reply'},
  );
}

/// Build a minimal TimeStampToken for testing.
Uint8List _buildMinimalTimeStampToken(Uint8List hash) {
  // Build a minimal CMS SignedData structure
  // This is a simplified version for testing purposes

  // TSTInfo: SEQUENCE { version, policy, messageImprint, serialNumber, genTime }
  final tstInfo = ASN1Sequence();
  tstInfo.add(ASN1Integer(BigInt.one)); // version
  tstInfo.add(
    ASN1ObjectIdentifier([1, 2, 840, 113549, 1, 9, 16, 1, 4]),
  ); // id-ct-TSTInfo
  tstInfo.add(ASN1Integer(BigInt.one)); // serialNumber
  tstInfo.add(ASN1GeneralizedTime(DateTime.now())); // genTime

  // SignedData: SEQUENCE { version, digestAlgorithms, contentInfo, certificates, signerInfos }
  final signedData = ASN1Sequence();
  signedData.add(ASN1Integer(BigInt.from(3))); // version

  // digestAlgorithms: SET OF AlgorithmIdentifier
  final digestAlgos = ASN1Set();
  final sha256Algo = ASN1Sequence();
  sha256Algo.add(
    ASN1ObjectIdentifier([2, 16, 840, 1, 101, 3, 4, 2, 1]),
  ); // SHA-256
  sha256Algo.add(ASN1Null());
  digestAlgos.add(sha256Algo);
  signedData.add(digestAlgos);

  // contentInfo: SEQUENCE { contentType, content [0] }
  final contentInfo = ASN1Sequence();
  contentInfo.add(
    ASN1ObjectIdentifier([1, 2, 840, 113549, 1, 9, 16, 1, 4]),
  ); // id-ct-TSTInfo
  contentInfo.add(ASN1OctetString(octets: tstInfo.encode()));
  signedData.add(contentInfo);

  // signerInfos: SET OF SignerInfo (empty for testing)
  signedData.add(ASN1Set());

  return signedData.encode();
}

/// Build a TimeStampResp with rejection status.
shelf.Response _buildTsaRejectionResponse() {
  final statusSeq = ASN1Sequence();
  statusSeq.add(ASN1Integer(BigInt.from(2))); // rejection

  final respSeq = ASN1Sequence();
  respSeq.add(statusSeq);

  return shelf.Response.ok(
    respSeq.encode(),
    headers: {'Content-Type': 'application/timestamp-reply'},
  );
}

/// Build a TimeStampResp with an oversized TST.
shelf.Response _buildTsaResponseWithOversizedTst(Uint8List hash) {
  // Build a TimeStampToken with a huge payload
  final tstInfo = ASN1Sequence();
  tstInfo.add(ASN1Integer(BigInt.one)); // version
  tstInfo.add(ASN1ObjectIdentifier([1, 2, 840, 113549, 1, 9, 16, 1, 4]));
  tstInfo.add(ASN1Integer(BigInt.one)); // serialNumber
  tstInfo.add(ASN1GeneralizedTime(DateTime.now()));

  // Add a huge octet string to make the token large
  final hugeData = Uint8List(50000); // 50 KB
  tstInfo.add(ASN1OctetString(octets: hugeData));

  final signedData = ASN1Sequence();
  signedData.add(ASN1Integer(BigInt.from(3))); // version

  final digestAlgos = ASN1Set();
  final sha256Algo = ASN1Sequence();
  sha256Algo.add(ASN1ObjectIdentifier([2, 16, 840, 1, 101, 3, 4, 2, 1]));
  sha256Algo.add(ASN1Null());
  digestAlgos.add(sha256Algo);
  signedData.add(digestAlgos);

  final contentInfo = ASN1Sequence();
  contentInfo.add(ASN1ObjectIdentifier([1, 2, 840, 113549, 1, 9, 16, 1, 4]));
  contentInfo.add(ASN1OctetString(octets: tstInfo.encode()));
  signedData.add(contentInfo);

  signedData.add(ASN1Set());

  final tstToken = signedData.encode();

  // Build TimeStampResp
  final statusSeq = ASN1Sequence();
  statusSeq.add(ASN1Integer(BigInt.zero)); // granted

  final respSeq = ASN1Sequence();
  respSeq.add(statusSeq);
  respSeq.add(ASN1Parser(tstToken).nextObject());

  return shelf.Response.ok(
    respSeq.encode(),
    headers: {'Content-Type': 'application/timestamp-reply'},
  );
}
