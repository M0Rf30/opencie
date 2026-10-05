// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/services/ltv/asn1/der.dart';
import 'package:opencie/services/ltv/asn1/oids.dart';
import 'package:opencie/services/ltv/tsp/tsp_client.dart';
import 'package:opencie/services/ltv/tsp/tsp_models.dart';
import 'package:pointycastle/asn1.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

void main() {
  group('TspClient.nonceEquals', () {
    test('a nonce whose leading 0x00 was dropped by DER still matches', () {
      final sent = Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7]);
      final got = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]);
      expect(TspClient.nonceEquals(got, sent), isTrue);
    });

    test('different values do not match', () {
      final sent = Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7]);
      final got = Uint8List.fromList([1, 2, 3, 4, 5, 6, 8]);
      expect(TspClient.nonceEquals(got, sent), isFalse);
      expect(
        TspClient.nonceEquals(Uint8List.fromList([1]), Uint8List(0)),
        isFalse,
      );
    });
  });

  group('TspClient', () {
    late HttpServer server;
    late Uri tsaUrl;
    late TspClient client;

    setUp(() async {
      // Start a local shelf server
      final handler = _createTsaHandler();
      server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0);
      tsaUrl = Uri.http('localhost:${server.port}', '/tsp');
      client = TspClient();
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('happy path: timestamp data and verify response', () async {
      // Arrange
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);

      // Act
      final resp = await client.timestampData(tsaUrl, data);

      // Assert
      expect(resp.isSuccess, true);
      expect(resp.timeStampToken, isNotNull);
    });

    test('nonce mismatch returns rejection', () async {
      // Arrange
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);

      // Act: use a handler that returns wrong nonce
      await server.close(force: true);
      final handler = _createTsaHandlerWithWrongNonce();
      server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0);
      tsaUrl = Uri.http('localhost:${server.port}', '/tsp');

      final resp = await client.timestampData(tsaUrl, data);

      // Assert: a nonce that doesn't match must fail closed (OC-06).
      expect(resp.isSuccess, false);
      expect(resp.status, TspStatus.rejection);
      expect(resp.statusStrings.join(), contains('nonce mismatch'));
    });

    test('hash mismatch returns rejection', () async {
      // Arrange
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);

      // Act: use a handler that returns wrong hash
      await server.close(force: true);
      final handler = _createTsaHandlerWithWrongHash();
      server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0);
      tsaUrl = Uri.http('localhost:${server.port}', '/tsp');

      final resp = await client.timestampData(tsaUrl, data);

      // Assert: an imprint that doesn't match must fail closed (OC-06).
      expect(resp.isSuccess, false);
      expect(resp.status, TspStatus.rejection);
      expect(resp.statusStrings.join(), contains('hash mismatch'));
    });

    test('server 500 throws TspException', () async {
      // Arrange
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);

      // Act: use a handler that returns 500
      await server.close(force: true);
      final handler = _createTsaHandlerWithError();
      server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0);
      tsaUrl = Uri.http('localhost:${server.port}', '/tsp');

      // Assert
      expect(
        () => client.timestampData(tsaUrl, data),
        throwsA(isA<TspException>()),
      );
    });

    test('wrong content-type throws TspException', () async {
      // Arrange
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);

      // Act: use a handler that returns wrong content-type
      await server.close(force: true);
      final handler = _createTsaHandlerWithWrongContentType();
      server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0);
      tsaUrl = Uri.http('localhost:${server.port}', '/tsp');

      // Assert
      expect(
        () => client.timestampData(tsaUrl, data),
        throwsA(isA<TspException>()),
      );
    });

    // Medium/low LTV finding (REPORT.md §4, "LTV" section): TSP HTTP
    // client had no pre-parse size cap, unlike CrlClient's existing
    // 8 MB post-download check — a misbehaving/malicious TSA could force
    // unbounded buffering of an untrusted body.
    test('requestTimestamp throws when response exceeds maxBytes', () async {
      // Arrange: a handler that returns an oversized (but otherwise
      // well-formed HTTP 200) body.
      await server.close(force: true);
      Future<shelf.Response> handler(shelf.Request request) async {
        return shelf.Response.ok(
          Uint8List(2048),
          headers: {'content-type': 'application/timestamp-reply'},
        );
      }

      server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0);
      tsaUrl = Uri.http('localhost:${server.port}', '/tsp');

      final cappedClient = TspClient(maxBytes: 1024);
      final req = TspRequest(
        messageImprintHash: Uint8List(32),
        hashAlgorithmOid: Oid.sha256,
      );

      // Assert
      expect(
        () => cappedClient.requestTimestamp(tsaUrl, req),
        throwsA(
          isA<TspException>().having(
            (e) => e.message,
            'message',
            contains('exceeds max size'),
          ),
        ),
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

/// Create a TSA handler that returns wrong nonce.
shelf.Handler _createTsaHandlerWithWrongNonce() {
  return (shelf.Request request) async {
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

    // Return wrong nonce
    final wrongNonce = Uint8List.fromList([9, 9, 9, 9, 9, 9, 9, 9]);

    final genTime = DateTime.utc(2026, 5, 4, 12, 0, 0);
    final token = _buildTstToken(
      genTime: genTime,
      hashOid: Oid.sha256,
      hash: hash,
      nonce: wrongNonce,
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
  };
}

/// Create a TSA handler that returns wrong hash.
shelf.Handler _createTsaHandlerWithWrongHash() {
  return (shelf.Request request) async {
    if (request.method != 'POST') {
      return shelf.Response.notFound('');
    }

    final body = await request.read().toList().then(
      (chunks) => Uint8List.fromList(chunks.expand((c) => c).toList()),
    );
    final parser = ASN1Parser(body);
    final reqSeq = parser.nextObject() as ASN1Sequence;

    final msgImprint = reqSeq.elements![1] as ASN1Sequence;
    // Note: hash is extracted but not used in this handler (returns wrong hash)
    // ignore: unused_local_variable
    final hashedMessage = msgImprint.elements![1] as ASN1OctetString;

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

    // Return wrong hash
    final wrongHash = Uint8List(32);
    wrongHash[0] = 0xFF;

    final genTime = DateTime.utc(2026, 5, 4, 12, 0, 0);
    final token = _buildTstToken(
      genTime: genTime,
      hashOid: Oid.sha256,
      hash: wrongHash,
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
  };
}

/// Create a TSA handler that returns HTTP 500.
shelf.Handler _createTsaHandlerWithError() {
  return (shelf.Request request) async {
    return shelf.Response.internalServerError();
  };
}

/// Create a TSA handler that returns wrong content-type.
shelf.Handler _createTsaHandlerWithWrongContentType() {
  return (shelf.Request request) async {
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
      headers: {'content-type': 'text/plain'}, // Wrong content-type
    );
  };
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
