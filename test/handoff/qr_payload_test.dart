// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:opencie/services/handoff/qr_payload.dart';

// A 32-byte synthetic X25519 public key used across tests.
final _syntheticPk = Uint8List.fromList(List.generate(32, (i) => i + 1));

// A minimal but valid SDP offer string (content is not validated by the impl).
const _fakeSdp =
    'v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n';

/// Builds a valid [HandoffQrPayload] with sensible defaults.
HandoffQrPayload _payload({
  String role = 'offer',
  String sdp = _fakeSdp,
  Uint8List? publicKey,
  DateTime? timestamp,
}) => HandoffQrPayload(
  role: role,
  sdp: sdp,
  publicKey: publicKey ?? _syntheticPk,
  timestamp: timestamp,
);

void main() {
  // ---------------------------------------------------------------------------
  // encode / decode round-trips
  // ---------------------------------------------------------------------------
  group('HandoffQrPayload encode/decode', () {
    test('encode produces a JSON string (no binary encoding)', () {
      final wire = _payload().encode();
      // Must be valid JSON and contain expected keys.
      final map = jsonDecode(wire) as Map<String, dynamic>;
      expect(map['v'], equals(1));
      expect(map['r'], isA<String>());
      expect(map['sdp'], isA<String>());
      expect(map['pk'], isA<String>());
      expect(map['ts'], isA<int>());
    });

    test('decode(encode()) round-trip preserves role=offer', () {
      final p = _payload(role: 'offer');
      final p2 = HandoffQrPayload.decode(p.encode());
      expect(p2.role, equals('offer'));
    });

    test('decode(encode()) round-trip preserves role=answer', () {
      final p = _payload(role: 'answer');
      final p2 = HandoffQrPayload.decode(p.encode());
      expect(p2.role, equals('answer'));
    });

    test('decode(encode()) round-trip preserves SDP string', () {
      final p = _payload(sdp: 'v=0\r\nm=data\r\n');
      final p2 = HandoffQrPayload.decode(p.encode());
      expect(p2.sdp, equals('v=0\r\nm=data\r\n'));
    });

    test('decode(encode()) round-trip preserves public key bytes', () {
      final p = _payload();
      final p2 = HandoffQrPayload.decode(p.encode());
      expect(p2.publicKey, equals(_syntheticPk));
    });

    test('decode(encode()) round-trip preserves timestamp to millisecond', () {
      // DateTime stores at ms resolution; ensure no drift beyond that.
      final ts = DateTime.utc(2026, 3, 15, 12, 0, 0);
      final p = _payload(timestamp: ts);
      final p2 = HandoffQrPayload.decode(p.encode());
      expect(p2.timestamp, equals(ts));
    });

    test('public key survives base64url encode/decode unchanged', () {
      // Specifically test a key with bytes that differ at every nibble.
      final pk = Uint8List.fromList(
        List.generate(32, (i) => (i * 7 + 13) & 0xFF),
      );
      final p = _payload(publicKey: pk);
      final p2 = HandoffQrPayload.decode(p.encode());
      expect(p2.publicKey, equals(pk));
    });
  });

  // ---------------------------------------------------------------------------
  // isFresh() — freshness window (default maxAge = 90 s)
  // ---------------------------------------------------------------------------
  group('HandoffQrPayload.isFresh()', () {
    test('returns true when timestamp is within the 90-second window', () {
      final p = _payload(
        timestamp: DateTime.now().toUtc().subtract(const Duration(seconds: 45)),
      );
      expect(p.isFresh(), isTrue);
    });

    test(
      'returns true for a timestamp well within the 90-second window (1 s old)',
      () {
        // Use a fixed past timestamp that is far enough from the boundary that
        // clock drift between construction and isFresh() evaluation never flips it.
        final p = _payload(
          timestamp: DateTime.now().toUtc().subtract(
            const Duration(seconds: 1),
          ),
        );
        expect(p.isFresh(), isTrue);
      },
    );

    test('returns false when timestamp is older than 90 seconds', () {
      final p = _payload(
        timestamp: DateTime.now().toUtc().subtract(
          const Duration(seconds: 120),
        ),
      );
      expect(p.isFresh(), isFalse);
    });

    test('returns false for a future timestamp (negative age)', () {
      // age = now - futureTimestamp < 0; fails the age >= Duration.zero guard.
      final p = _payload(
        timestamp: DateTime.now().toUtc().add(const Duration(seconds: 10)),
      );
      expect(p.isFresh(), isFalse);
    });

    test('custom maxAge is respected', () {
      // 30-second window; 45-second-old payload is stale under that window.
      final p = _payload(
        timestamp: DateTime.now().toUtc().subtract(const Duration(seconds: 45)),
      );
      expect(p.isFresh(maxAge: const Duration(seconds: 30)), isFalse);
      expect(p.isFresh(maxAge: const Duration(seconds: 60)), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // decode() — malformed input rejection
  // ---------------------------------------------------------------------------
  group('HandoffQrPayload.decode() rejects malformed input', () {
    test('throws FormatException on non-JSON string', () {
      expect(
        () => HandoffQrPayload.decode('not-json-at-all'),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException when root is a JSON array', () {
      expect(
        () => HandoffQrPayload.decode('[1,2,3]'),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException for unsupported version', () {
      final wire = jsonEncode({
        'v': 2,
        'r': 'offer',
        'sdp': _fakeSdp,
        'pk': base64UrlEncode(_syntheticPk),
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
      expect(
        () => HandoffQrPayload.decode(wire),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException for unknown role', () {
      final wire = jsonEncode({
        'v': 1,
        'r': 'relay', // not 'offer' or 'answer'
        'sdp': _fakeSdp,
        'pk': base64UrlEncode(_syntheticPk),
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
      expect(
        () => HandoffQrPayload.decode(wire),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException when sdp is an empty string', () {
      final wire = jsonEncode({
        'v': 1,
        'r': 'offer',
        'sdp': '',
        'pk': base64UrlEncode(_syntheticPk),
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
      expect(
        () => HandoffQrPayload.decode(wire),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException when pk is missing', () {
      final wire = jsonEncode({
        'v': 1,
        'r': 'offer',
        'sdp': _fakeSdp,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
      expect(
        () => HandoffQrPayload.decode(wire),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException when ts is missing', () {
      final wire = jsonEncode({
        'v': 1,
        'r': 'offer',
        'sdp': _fakeSdp,
        'pk': base64UrlEncode(_syntheticPk),
      });
      expect(
        () => HandoffQrPayload.decode(wire),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws on invalid base64url in pk field', () {
      final wire = jsonEncode({
        'v': 1,
        'r': 'offer',
        'sdp': _fakeSdp,
        'pk': '!!!not valid base64!!!',
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
      // base64Url.decode throws FormatException on invalid input.
      expect(() => HandoffQrPayload.decode(wire), throwsA(anything));
    });
  });
}
