// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'crypto.dart';

/// Wire-frame protocol for the desktop ↔ phone signing handoff over the
/// AEAD-sealed WebRTC data channel.
///
/// Every frame on the wire is the output of [HandoffSession.seal] applied
/// to a UTF-8 encoded JSON object with the shape:
///
/// ```json
/// {"t": "<type>", "v": 1, "d": { ...type-specific fields... }}
/// ```
///
/// `t` is one of [HandoffMessageType], `v` is a protocol version (currently 1),
/// `d` carries the payload.
///
/// Receivers should call [HandoffSession.open] first, then [HandoffMessage.decode]
/// on the resulting plaintext.

const int _protocolVersion = 1;

enum HandoffMessageType {
  /// Desktop → phone, sent immediately after the channel is open and the SAS
  /// has been confirmed. Describes the document the user is about to sign:
  /// filename, byte size, page count, SHA-256, and an optional thumbnail.
  descriptor,

  /// Phone → desktop. Sent after the user has typed the PIN on the phone but
  /// before the actual NFC-mediated signing call. Tells the desktop "the user
  /// has confirmed and we're about to drive the card".
  pinOk,

  /// Phone → desktop. Carries the final detached CMS / PAdES signature bytes
  /// produced by the CIE.
  signature,

  /// Either side. Aborts the session; carries an optional reason string.
  abort,
}

extension on HandoffMessageType {
  String get wire => switch (this) {
        HandoffMessageType.descriptor => 'descriptor',
        HandoffMessageType.pinOk => 'pin_ok',
        HandoffMessageType.signature => 'signature',
        HandoffMessageType.abort => 'abort',
      };
}

/// Top-level frame after AEAD decryption.
class HandoffMessage {
  HandoffMessage({required this.type, required this.data});

  final HandoffMessageType type;
  final Map<String, dynamic> data;

  Uint8List encode() {
    final root = <String, dynamic>{
      't': type.wire,
      'v': _protocolVersion,
      'd': data,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(root)));
  }

  static HandoffMessage decode(Uint8List plaintext) {
    final root = jsonDecode(utf8.decode(plaintext));
    if (root is! Map<String, dynamic>) {
      throw const FormatException('Handoff frame: root not a JSON object');
    }
    final tStr = root['t'];
    if (tStr is! String) {
      throw const FormatException('Handoff frame: missing "t"');
    }
    final type = HandoffMessageTypeWire.fromWire(tStr);
    if (type == null) {
      throw FormatException('Handoff frame: unknown type "$tStr"');
    }
    final v = root['v'];
    if (v is! int || v != _protocolVersion) {
      throw FormatException('Handoff frame: unsupported version $v');
    }
    final d = root['d'];
    if (d is! Map<String, dynamic>) {
      throw const FormatException('Handoff frame: "d" not a JSON object');
    }
    return HandoffMessage(type: type, data: d);
  }
}

/// Re-export of [HandoffMessageType.fromWire] as a top-level helper so it's
/// callable from [HandoffMessage.decode] (Dart extensions can't define static
/// methods).
extension HandoffMessageTypeWire on HandoffMessageType {
  static HandoffMessageType? fromWire(String s) => switch (s) {
        'descriptor' => HandoffMessageType.descriptor,
        'pin_ok' => HandoffMessageType.pinOk,
        'signature' => HandoffMessageType.signature,
        'abort' => HandoffMessageType.abort,
        _ => null,
      };
}

// ───────────────────────────── typed payloads ─────────────────────────────

/// Document descriptor sent by the desktop before the phone enters the PIN.
/// The phone displays this so the user can see *what* is being signed.
class DescriptorPayload {
  DescriptorPayload({
    required this.fileName,
    required this.byteSize,
    required this.sha256Hex,
    this.pageCount,
    this.thumbnailPng,
    this.mimeType,
  });

  /// Filename only (no path). Shown to the user.
  final String fileName;

  /// Size in bytes of the file the desktop intends to sign.
  final int byteSize;

  /// Lower-case hex SHA-256 of the file. Phone shows first/last 4 hex chars
  /// next to the file name.
  final String sha256Hex;

  /// Optional, only meaningful for PDFs.
  final int? pageCount;

  /// Optional thumbnail PNG bytes; should be ≤50 KB before AEAD framing.
  final Uint8List? thumbnailPng;

  /// Optional MIME hint, e.g. `application/pdf`.
  final String? mimeType;

  Map<String, dynamic> toJson() => {
        'name': fileName,
        'size': byteSize,
        'sha256': sha256Hex,
        if (pageCount != null) 'pages': pageCount,
        if (mimeType != null) 'mime': mimeType,
        if (thumbnailPng != null)
          'thumb_b64': base64Encode(thumbnailPng!),
      };

  static DescriptorPayload fromJson(Map<String, dynamic> j) {
    final name = j['name'];
    final size = j['size'];
    final sha = j['sha256'];
    if (name is! String || size is! int || sha is! String) {
      throw const FormatException('Descriptor: missing required fields');
    }
    final thumbB64 = j['thumb_b64'];
    return DescriptorPayload(
      fileName: name,
      byteSize: size,
      sha256Hex: sha,
      pageCount: j['pages'] is int ? j['pages'] as int : null,
      mimeType: j['mime'] is String ? j['mime'] as String : null,
      thumbnailPng: thumbB64 is String ? base64Decode(thumbB64) : null,
    );
  }

  HandoffMessage toMessage() =>
      HandoffMessage(type: HandoffMessageType.descriptor, data: toJson());
}

/// Phone → desktop: PIN was accepted by the user; signing is starting.
class PinOkPayload {
  PinOkPayload({this.attemptsLeft});

  /// Optional remaining-attempts hint surfaced to the desktop progress UI.
  final int? attemptsLeft;

  Map<String, dynamic> toJson() => {
        if (attemptsLeft != null) 'attempts_left': attemptsLeft,
      };

  static PinOkPayload fromJson(Map<String, dynamic> j) => PinOkPayload(
        attemptsLeft: j['attempts_left'] is int ? j['attempts_left'] as int : null,
      );

  HandoffMessage toMessage() =>
      HandoffMessage(type: HandoffMessageType.pinOk, data: toJson());
}

/// Phone → desktop: final detached CMS / PAdES signature bytes.
class SignaturePayload {
  SignaturePayload({required this.cmsBytes, this.format});

  /// Raw signature bytes (CMS / PKCS#7 / PAdES envelope).
  final Uint8List cmsBytes;

  /// Optional format tag, e.g. `pades-b-t`, `cades`, `xades`.
  final String? format;

  Map<String, dynamic> toJson() => {
        'cms_b64': base64Encode(cmsBytes),
        if (format != null) 'format': format,
      };

  static SignaturePayload fromJson(Map<String, dynamic> j) {
    final b64 = j['cms_b64'];
    if (b64 is! String) {
      throw const FormatException('Signature: missing cms_b64');
    }
    return SignaturePayload(
      cmsBytes: base64Decode(b64),
      format: j['format'] is String ? j['format'] as String : null,
    );
  }

  HandoffMessage toMessage() =>
      HandoffMessage(type: HandoffMessageType.signature, data: toJson());
}

/// Either side: abort the session.
class AbortPayload {
  AbortPayload({this.reason});

  final String? reason;

  Map<String, dynamic> toJson() => {
        if (reason != null) 'reason': reason,
      };

  static AbortPayload fromJson(Map<String, dynamic> j) => AbortPayload(
        reason: j['reason'] is String ? j['reason'] as String : null,
      );

  HandoffMessage toMessage() =>
      HandoffMessage(type: HandoffMessageType.abort, data: toJson());
}

// ───────────────────────────── send / receive helpers ────────────────────

/// Encodes [message], seals it through [session] (AEAD), and returns the
/// ciphertext envelope ready to put on the wire.
Future<Uint8List> sealMessage(
  HandoffSession session,
  HandoffMessage message,
) async {
  return session.seal(message.encode());
}

/// Opens a wire envelope through [session] and decodes it into a
/// [HandoffMessage]. Returns null if AEAD verification fails.
Future<HandoffMessage?> openMessage(
  HandoffSession session,
  Uint8List envelope,
) async {
  final plaintext = await session.open(envelope);
  if (plaintext == null) return null;
  return HandoffMessage.decode(plaintext);
}
