// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:opencie/services/handoff/messages.dart';

/// Encodes a raw JSON map into a [HandoffMessage]-compatible [Uint8List]
/// (UTF-8 JSON), bypassing [HandoffMessage.encode] for error-path tests.
Uint8List _rawJson(Map<String, dynamic> map) =>
    Uint8List.fromList(utf8.encode(jsonEncode(map)));

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
      expect(decoded['v'], equals(1));
      expect(decoded['d'], isA<Map<String, dynamic>>());
      expect(
        (decoded['d'] as Map<String, dynamic>)['reason'],
        equals('user cancelled'),
      );
    });

    test('decode(encode()) round-trip for descriptor type', () {
      final msg = HandoffMessage(
        type: HandoffMessageType.descriptor,
        data: {'name': 'contract.pdf', 'size': 2048, 'sha256': 'deadbeef'},
      );
      final decoded = HandoffMessage.decode(msg.encode());
      expect(decoded.type, equals(HandoffMessageType.descriptor));
      expect(decoded.data['name'], equals('contract.pdf'));
      expect(decoded.data['size'], equals(2048));
      expect(decoded.data['sha256'], equals('deadbeef'));
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

    test('decode(encode()) round-trip for signature type', () {
      final msg = HandoffMessage(
        type: HandoffMessageType.signature,
        data: {
          'cms_b64': base64Encode([0xDE, 0xAD, 0xBE, 0xEF]),
        },
      );
      final decoded = HandoffMessage.decode(msg.encode());
      expect(decoded.type, equals(HandoffMessageType.signature));
      expect(decoded.data['cms_b64'], isA<String>());
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
      final bad = _rawJson({'v': 1, 'd': <String, Object?>{}});
      expect(() => HandoffMessage.decode(bad), throwsA(isA<FormatException>()));
    });

    test('decode throws FormatException for unknown message type', () {
      final bad = _rawJson({
        't': 'unknown_type',
        'v': 1,
        'd': <String, Object?>{},
      });
      expect(() => HandoffMessage.decode(bad), throwsA(isA<FormatException>()));
    });

    test('decode throws FormatException when version is wrong', () {
      final bad = _rawJson({'t': 'abort', 'v': 99, 'd': <String, Object?>{}});
      expect(() => HandoffMessage.decode(bad), throwsA(isA<FormatException>()));
    });

    test('decode throws FormatException when "d" is not an object', () {
      final bad = _rawJson({'t': 'abort', 'v': 1, 'd': 'not-an-object'});
      expect(() => HandoffMessage.decode(bad), throwsA(isA<FormatException>()));
    });

    test('decode throws FormatException when "d" is missing', () {
      final bad = _rawJson({'t': 'abort', 'v': 1});
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
        sha256Hex: 'aabbccdd',
      );
      final j = p.toJson();
      final p2 = DescriptorPayload.fromJson(j);
      expect(p2.fileName, equals('report.pdf'));
      expect(p2.byteSize, equals(512));
      expect(p2.sha256Hex, equals('aabbccdd'));
      expect(p2.pageCount, isNull);
      expect(p2.mimeType, isNull);
      expect(p2.thumbnailPng, isNull);
    });

    test('toJson/fromJson round-trip with all optional fields', () {
      final thumb = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]); // PNG magic
      final p = DescriptorPayload(
        fileName: 'slides.pdf',
        byteSize: 102400,
        sha256Hex: 'ff00ff00',
        pageCount: 5,
        mimeType: 'application/pdf',
        thumbnailPng: thumb,
      );
      final p2 = DescriptorPayload.fromJson(p.toJson());
      expect(p2.fileName, equals('slides.pdf'));
      expect(p2.byteSize, equals(102400));
      expect(p2.pageCount, equals(5));
      expect(p2.mimeType, equals('application/pdf'));
      expect(p2.thumbnailPng, equals(thumb));
    });

    test('fromJson throws FormatException when required fields are absent', () {
      expect(
        () => DescriptorPayload.fromJson({'size': 1, 'sha256': 'x'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('toMessage returns HandoffMessage with descriptor type', () {
      final msg = DescriptorPayload(
        fileName: 'a.pdf',
        byteSize: 1,
        sha256Hex: 'a',
      ).toMessage();
      expect(msg.type, equals(HandoffMessageType.descriptor));
      expect(msg.data['name'], equals('a.pdf'));
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
  // SignaturePayload
  // ---------------------------------------------------------------------------
  group('SignaturePayload', () {
    test('toJson/fromJson round-trip preserves CMS bytes', () {
      final cms = Uint8List.fromList(List.generate(32, (i) => i));
      final p = SignaturePayload(cmsBytes: cms, format: 'pades-b-t');
      final p2 = SignaturePayload.fromJson(p.toJson());
      expect(p2.cmsBytes, equals(cms));
      expect(p2.format, equals('pades-b-t'));
    });

    test('toJson/fromJson round-trip without optional format', () {
      final cms = Uint8List.fromList([0xCA, 0xFE]);
      final p = SignaturePayload(cmsBytes: cms);
      final p2 = SignaturePayload.fromJson(p.toJson());
      expect(p2.cmsBytes, equals(cms));
      expect(p2.format, isNull);
    });

    test('fromJson throws FormatException when cms_b64 is absent', () {
      expect(
        () => SignaturePayload.fromJson({'format': 'cades'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson throws on invalid base64 in cms_b64', () {
      expect(
        () => SignaturePayload.fromJson({'cms_b64': '!!!not-base64!!!'}),
        throwsA(anything),
      );
    });

    test('toMessage returns HandoffMessage with signature type', () {
      final msg = SignaturePayload(cmsBytes: Uint8List(1)).toMessage();
      expect(msg.type, equals(HandoffMessageType.signature));
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
}
