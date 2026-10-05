// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:opencie/services/handoff/messages.dart';

/// Encodes a raw JSON map into a [HandoffMessage]-compatible [Uint8List]
/// (UTF-8 JSON), bypassing [HandoffMessage.encode] for error-path tests.
Uint8List _rawJson(Map<String, dynamic> map) =>
    Uint8List.fromList(utf8.encode(jsonEncode(map)));

/// A valid 64-char lower-case hex SHA-256, used across payload tests.
final String _validSha = List.filled(64, 'a').join();

void main() {
  // ---------------------------------------------------------------------------
  // HandoffMessage encode / decode — frame layer
  // ---------------------------------------------------------------------------
  group('HandoffMessage frame encode/decode', () {
    test('encode produces valid UTF-8 JSON with correct keys', () {
      final msg = HandoffMessage(
        type: HandoffMessageType.abort,
        data: {'reason': 'user cancelled'},
      );
      final bytes = msg.encode();
      final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      expect(decoded['t'], equals('abort'));
      expect(decoded['v'], equals(protocolVersion));
      expect(decoded['d'], isA<Map<String, dynamic>>());
      expect(
        (decoded['d'] as Map<String, dynamic>)['reason'],
        equals('user cancelled'),
      );
    });

    test('decode(encode()) round-trip for descriptor type', () {
      final msg = HandoffMessage(
        type: HandoffMessageType.descriptor,
        data: {'name': 'contract.pdf', 'size': 2048, 'sha256': _validSha},
      );
      final decoded = HandoffMessage.decode(msg.encode());
      expect(decoded.type, equals(HandoffMessageType.descriptor));
      expect(decoded.data['name'], equals('contract.pdf'));
      expect(decoded.data['size'], equals(2048));
      expect(decoded.data['sha256'], equals(_validSha));
    });

    test('decode(encode()) round-trip for documentChunk type', () {
      final msg = HandoffMessage(
        type: HandoffMessageType.documentChunk,
        data: {
          'seq': 3,
          'data_b64': base64Encode([1, 2, 3]),
        },
      );
      final decoded = HandoffMessage.decode(msg.encode());
      expect(decoded.type, equals(HandoffMessageType.documentChunk));
      expect(decoded.data['seq'], equals(3));
    });

    test('decode(encode()) round-trip for pinOk type', () {
      final msg = HandoffMessage(
        type: HandoffMessageType.pinOk,
        data: {'attempts_left': 2},
      );
      final decoded = HandoffMessage.decode(msg.encode());
      expect(decoded.type, equals(HandoffMessageType.pinOk));
      expect(decoded.data['attempts_left'], equals(2));
    });

    test('decode(encode()) round-trip for signedStart type', () {
      final msg = HandoffMessage(
        type: HandoffMessageType.signedStart,
        data: {'size': 10, 'sha256': _validSha, 'format': 'pades-b-t'},
      );
      final decoded = HandoffMessage.decode(msg.encode());
      expect(decoded.type, equals(HandoffMessageType.signedStart));
      expect(decoded.data['format'], equals('pades-b-t'));
    });

    test('decode(encode()) round-trip for signedChunk type', () {
      final msg = HandoffMessage(
        type: HandoffMessageType.signedChunk,
        data: {
          'seq': 0,
          'data_b64': base64Encode([0xDE, 0xAD, 0xBE, 0xEF]),
        },
      );
      final decoded = HandoffMessage.decode(msg.encode());
      expect(decoded.type, equals(HandoffMessageType.signedChunk));
      expect(decoded.data['data_b64'], isA<String>());
    });

    test('decode(encode()) round-trip for abort type with no reason', () {
      final msg = HandoffMessage(
        type: HandoffMessageType.abort,
        data: const {},
      );
      final decoded = HandoffMessage.decode(msg.encode());
      expect(decoded.type, equals(HandoffMessageType.abort));
    });

    test('decode throws FormatException for malformed JSON', () {
      final bad = Uint8List.fromList(utf8.encode('not json at all'));
      expect(() => HandoffMessage.decode(bad), throwsA(isA<FormatException>()));
    });

    test('decode throws FormatException for JSON array root (not object)', () {
      final arrayBytes = Uint8List.fromList(utf8.encode('[1,2,3]'));
      expect(
        () => HandoffMessage.decode(arrayBytes),
        throwsA(isA<FormatException>()),
      );
    });

    test('decode throws FormatException when "t" field is missing', () {
      final bad = _rawJson({'v': protocolVersion, 'd': <String, Object?>{}});
      expect(() => HandoffMessage.decode(bad), throwsA(isA<FormatException>()));
    });

    test('decode throws FormatException for unknown message type', () {
      final bad = _rawJson({
        't': 'unknown_type',
        'v': protocolVersion,
        'd': <String, Object?>{},
      });
      expect(() => HandoffMessage.decode(bad), throwsA(isA<FormatException>()));
    });

    test('decode throws FormatException when version is wrong', () {
      final bad = _rawJson({'t': 'abort', 'v': 99, 'd': <String, Object?>{}});
      expect(() => HandoffMessage.decode(bad), throwsA(isA<FormatException>()));
    });

    test(
      'decode rejects the old v1 protocol version cleanly (single-version protocol)',
      () {
        final bad = _rawJson({'t': 'abort', 'v': 1, 'd': <String, Object?>{}});
        expect(
          () => HandoffMessage.decode(bad),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('decode throws FormatException when "d" is not an object', () {
      final bad = _rawJson({
        't': 'abort',
        'v': protocolVersion,
        'd': 'not-an-object',
      });
      expect(() => HandoffMessage.decode(bad), throwsA(isA<FormatException>()));
    });

    test('decode throws FormatException when "d" is missing', () {
      final bad = _rawJson({'t': 'abort', 'v': protocolVersion});
      expect(() => HandoffMessage.decode(bad), throwsA(isA<FormatException>()));
    });
  });

  // ---------------------------------------------------------------------------
  // DescriptorPayload
  // ---------------------------------------------------------------------------
  group('DescriptorPayload', () {
    test('toJson/fromJson round-trip with required fields only', () {
      final p = DescriptorPayload(
        fileName: 'report.pdf',
        byteSize: 512,
        sha256Hex: _validSha,
      );
      final j = p.toJson();
      final p2 = DescriptorPayload.fromJson(j);
      expect(p2.fileName, equals('report.pdf'));
      expect(p2.byteSize, equals(512));
      expect(p2.sha256Hex, equals(_validSha));
      expect(p2.mimeType, isNull);
    });

    test('toJson/fromJson round-trip with mime type', () {
      final p = DescriptorPayload(
        fileName: 'slides.pdf',
        byteSize: 102400,
        sha256Hex: _validSha,
        mimeType: 'application/pdf',
      );
      final p2 = DescriptorPayload.fromJson(p.toJson());
      expect(p2.fileName, equals('slides.pdf'));
      expect(p2.byteSize, equals(102400));
      expect(p2.mimeType, equals('application/pdf'));
    });

    test('fromJson throws FormatException when required fields are absent', () {
      expect(
        () => DescriptorPayload.fromJson({'size': 1, 'sha256': _validSha}),
        throwsA(isA<FormatException>()),
      );
    });

    test('constructor throws when sha256 is not 64 lower-case hex chars', () {
      expect(
        () => DescriptorPayload(
          fileName: 'a.pdf',
          byteSize: 1,
          sha256Hex: 'not-a-hash',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('constructor lower-cases a mixed-case sha256', () {
      final mixed = List.filled(32, 'A').join() + List.filled(32, 'b').join();
      final p = DescriptorPayload(
        fileName: 'a.pdf',
        byteSize: 1,
        sha256Hex: mixed,
      );
      expect(p.sha256Hex, equals(mixed.toLowerCase()));
    });

    test('constructor throws when byteSize is zero or negative', () {
      expect(
        () => DescriptorPayload(
          fileName: 'a.pdf',
          byteSize: 0,
          sha256Hex: _validSha,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('constructor throws when byteSize exceeds the handoff limit', () {
      expect(
        () => DescriptorPayload(
          fileName: 'a.pdf',
          byteSize: HandoffLimits.maxDocumentBytes + 1,
          sha256Hex: _validSha,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('strips control and bidi-override characters from the filename', () {
      final p = DescriptorPayload(
        fileName: 'evil\u202Egnp.exe',
        byteSize: 1,
        sha256Hex: _validSha,
      );
      expect(p.fileName, equals('evilgnp.exe'));
    });

    test('caps filename length at 255 characters', () {
      final p = DescriptorPayload(
        fileName: 'a' * 500,
        byteSize: 1,
        sha256Hex: _validSha,
      );
      expect(p.fileName.length, equals(255));
    });

    test('toMessage returns HandoffMessage with descriptor type', () {
      final msg = DescriptorPayload(
        fileName: 'a.pdf',
        byteSize: 1,
        sha256Hex: _validSha,
      ).toMessage();
      expect(msg.type, equals(HandoffMessageType.descriptor));
      expect(msg.data['name'], equals('a.pdf'));
    });
  });

  // ---------------------------------------------------------------------------
  // DocumentChunkPayload
  // ---------------------------------------------------------------------------
  group('DocumentChunkPayload', () {
    test('toJson/fromJson round-trip preserves seq and bytes', () {
      final data = Uint8List.fromList(List.generate(32, (i) => i));
      final p = DocumentChunkPayload(seq: 7, data: data);
      final p2 = DocumentChunkPayload.fromJson(p.toJson());
      expect(p2.seq, equals(7));
      expect(p2.data, equals(data));
    });

    test('constructor throws on negative seq', () {
      expect(
        () => DocumentChunkPayload(seq: -1, data: Uint8List(0)),
        throwsA(isA<FormatException>()),
      );
    });

    test('constructor throws when chunk exceeds chunkBytes', () {
      expect(
        () => DocumentChunkPayload(
          seq: 0,
          data: Uint8List(HandoffLimits.chunkBytes + 1),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson throws FormatException when seq/data_b64 are absent', () {
      expect(
        () => DocumentChunkPayload.fromJson({'seq': 0}),
        throwsA(isA<FormatException>()),
      );
    });

    test('toMessage returns HandoffMessage with documentChunk type', () {
      final msg = DocumentChunkPayload(seq: 0, data: Uint8List(1)).toMessage();
      expect(msg.type, equals(HandoffMessageType.documentChunk));
    });
  });

  // ---------------------------------------------------------------------------
  // PinOkPayload
  // ---------------------------------------------------------------------------
  group('PinOkPayload', () {
    test('toJson/fromJson round-trip with attemptsLeft', () {
      final p = PinOkPayload(attemptsLeft: 3);
      final p2 = PinOkPayload.fromJson(p.toJson());
      expect(p2.attemptsLeft, equals(3));
    });

    test('toJson/fromJson round-trip without attemptsLeft', () {
      final p = PinOkPayload();
      final p2 = PinOkPayload.fromJson(p.toJson());
      expect(p2.attemptsLeft, isNull);
    });

    test('toMessage returns HandoffMessage with pinOk type', () {
      final msg = PinOkPayload(attemptsLeft: 1).toMessage();
      expect(msg.type, equals(HandoffMessageType.pinOk));
    });
  });

  // ---------------------------------------------------------------------------
  // SignedStartPayload / SignedChunkPayload
  // ---------------------------------------------------------------------------
  group('SignedStartPayload', () {
    test('toJson/fromJson round-trip preserves size/sha/format', () {
      final p = SignedStartPayload(
        byteSize: 4096,
        sha256Hex: _validSha,
        format: 'pades-b-t',
      );
      final p2 = SignedStartPayload.fromJson(p.toJson());
      expect(p2.byteSize, equals(4096));
      expect(p2.sha256Hex, equals(_validSha));
      expect(p2.format, equals('pades-b-t'));
    });

    test('toJson/fromJson round-trip without optional format', () {
      final p = SignedStartPayload(byteSize: 1, sha256Hex: _validSha);
      final p2 = SignedStartPayload.fromJson(p.toJson());
      expect(p2.format, isNull);
    });

    test('constructor throws when sha256 is malformed', () {
      expect(
        () => SignedStartPayload(byteSize: 1, sha256Hex: 'nope'),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson throws FormatException when required fields are absent', () {
      expect(
        () => SignedStartPayload.fromJson({'format': 'cades'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('toMessage returns HandoffMessage with signedStart type', () {
      final msg = SignedStartPayload(
        byteSize: 1,
        sha256Hex: _validSha,
      ).toMessage();
      expect(msg.type, equals(HandoffMessageType.signedStart));
    });
  });

  group('SignedChunkPayload', () {
    test('toJson/fromJson round-trip preserves seq and bytes', () {
      final cms = Uint8List.fromList(List.generate(32, (i) => i));
      final p = SignedChunkPayload(seq: 2, data: cms);
      final p2 = SignedChunkPayload.fromJson(p.toJson());
      expect(p2.seq, equals(2));
      expect(p2.data, equals(cms));
    });

    test('fromJson throws when data_b64 is absent', () {
      expect(
        () => SignedChunkPayload.fromJson({'seq': 0}),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson throws on invalid base64 in data_b64', () {
      expect(
        () => SignedChunkPayload.fromJson({
          'seq': 0,
          'data_b64': '!!!not-base64!!!',
        }),
        throwsA(anything),
      );
    });

    test('toMessage returns HandoffMessage with signedChunk type', () {
      final msg = SignedChunkPayload(seq: 0, data: Uint8List(1)).toMessage();
      expect(msg.type, equals(HandoffMessageType.signedChunk));
    });
  });

  // ---------------------------------------------------------------------------
  // AbortPayload
  // ---------------------------------------------------------------------------
  group('AbortPayload', () {
    test('toJson/fromJson round-trip with reason', () {
      final p = AbortPayload(reason: 'PIN blocked');
      final p2 = AbortPayload.fromJson(p.toJson());
      expect(p2.reason, equals('PIN blocked'));
    });

    test('toJson/fromJson round-trip without reason', () {
      final p = AbortPayload();
      final p2 = AbortPayload.fromJson(p.toJson());
      expect(p2.reason, isNull);
    });

    test('toMessage returns HandoffMessage with abort type', () {
      final msg = AbortPayload(reason: 'timeout').toMessage();
      expect(msg.type, equals(HandoffMessageType.abort));
    });
  });

  // ---------------------------------------------------------------------------
  // HandoffLimits
  // ---------------------------------------------------------------------------
  group('HandoffLimits.totalChunksFor', () {
    test('rounds up to a whole chunk for a size smaller than chunkBytes', () {
      expect(HandoffLimits.totalChunksFor(1), equals(1));
    });

    test('computes an exact chunk count for an exact multiple', () {
      expect(
        HandoffLimits.totalChunksFor(HandoffLimits.chunkBytes * 3),
        equals(3),
      );
    });

    test('rounds up a non-exact multiple', () {
      expect(
        HandoffLimits.totalChunksFor(HandoffLimits.chunkBytes * 3 + 1),
        equals(4),
      );
    });
  });
}
