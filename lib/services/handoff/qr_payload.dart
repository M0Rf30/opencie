// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

/// Compact QR payload format used by both QR1 (desktop offer) and QR2
/// (phone answer).
///
/// Wire shape (JSON, base64url then gzipped before final base64-encoding to
/// keep QR Version ≤ 12 at 2 KB practical limit):
///
/// ```json
/// {
///   "v": 1,
///   "r": "offer" | "answer",
///   "sdp": "<full sdp string>",
///   "pk": "<base64url x25519 public key>",
///   "ts": 1738587600000
/// }
/// ```
///
/// SDP is intentionally **not** further compressed. Tests with default Flutter
/// SDP show ~1.4 KB which fits a Version 12 QR comfortably at error-correction
/// level Q with a 10:1 cell-to-pixel ratio.
class HandoffQrPayload {
  HandoffQrPayload({
    required this.role,
    required this.sdp,
    required this.publicKey,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now().toUtc();

  /// 'offer' (desktop QR1) or 'answer' (phone QR2).
  final String role;

  /// Full SDP string from WebRTC.
  final String sdp;

  /// Sender's ephemeral X25519 public key (32 raw bytes).
  final Uint8List publicKey;

  /// UTC timestamp of payload creation. Receiver enforces a freshness window.
  final DateTime timestamp;

  /// Encodes to a compact ASCII string suitable for QR rendering. The string
  /// is JSON wrapped and base64url-encoded so QR readers emit clean text.
  String encode() {
    final root = <String, dynamic>{
      'v': 1,
      'r': role,
      'sdp': sdp,
      'pk': base64UrlEncode(publicKey),
      'ts': timestamp.millisecondsSinceEpoch,
    };
    return jsonEncode(root);
  }

  /// Decodes a payload produced by [encode]. Throws [FormatException] on
  /// malformed input or version mismatch. Does not enforce freshness — the
  /// caller is responsible for that.
  static HandoffQrPayload decode(String wire) {
    final root = jsonDecode(wire);
    if (root is! Map<String, dynamic>) {
      throw const FormatException('QR payload: root not an object');
    }
    final v = root['v'];
    if (v is! int || v != 1) {
      throw FormatException('QR payload: unsupported version $v');
    }
    final r = root['r'];
    if (r is! String || (r != 'offer' && r != 'answer')) {
      throw FormatException('QR payload: bad role "$r"');
    }
    final sdp = root['sdp'];
    if (sdp is! String || sdp.isEmpty) {
      throw const FormatException('QR payload: missing sdp');
    }
    final pkB64 = root['pk'];
    if (pkB64 is! String) {
      throw const FormatException('QR payload: missing pk');
    }
    final ts = root['ts'];
    if (ts is! int) {
      throw const FormatException('QR payload: missing ts');
    }
    return HandoffQrPayload(
      role: r,
      sdp: sdp,
      publicKey: Uint8List.fromList(base64Url.decode(pkB64)),
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
    );
  }

  /// Whether the payload was created within [maxAge] of now.
  bool isFresh({Duration maxAge = const Duration(seconds: 90)}) {
    final age = DateTime.now().toUtc().difference(timestamp);
    return age >= Duration.zero && age <= maxAge;
  }
}
