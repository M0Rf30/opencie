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
/// {"t": "<type>", "v": 2, "d": { ...type-specific fields... }}
/// ```
///
/// `t` is one of [HandoffMessageType], `v` is the protocol version, `d`
/// carries the payload.
///
/// Receivers should call [HandoffSession.open] first, then
/// [HandoffMessage.decode] on the resulting plaintext.
///
/// ## Protocol v2 message flow
///
/// ```
/// desktop                              phone
///    |--------- descriptor ------------->|   metadata only: name/size/sha256/mime
///    |------- document_chunk[0..N] ----->|   the ACTUAL document, chunked
///    |                                    |   phone verifies sha256, renders its
///    |                                    |   own preview from the received bytes
///    |<---------- pin_ok -----------------|   user entered PIN on phone
///    |                                    |   phone signs the real document (not
///    |                                    |   a digest) and chunks the result back
///    |<------- signed_start --------------|   size/sha256/format of the signed file
///    |<------ signed_chunk[0..N] ---------|
///    |---------- abort ------------------>|   either side, any time
///    |<--------- abort -------------------|
/// ```
///
/// v1 signed the SHA-256 digest as if it were the document and sent a
/// single `signature` frame; both are removed in v2. Peers running the old
/// protocol are rejected cleanly by the version check in [HandoffMessage.decode]
/// rather than silently misbehaving.
const int protocolVersion = 2;

/// Hard limits enforced by both peers on the chunked document/signature
/// transfer so a buggy or hostile peer can't exhaust memory or disk.
class HandoffLimits {
  HandoffLimits._();

  /// Maximum size of the document (or the signed result) that will be
  /// transferred over the handoff channel.
  static const int maxDocumentBytes = 50 * 1024 * 1024; // 50 MiB

  /// Plaintext chunk size used for `document_chunk` / `signed_chunk`
  /// frames. Chosen to stay comfortably under typical SCTP data-channel
  /// message-size limits once base64-encoded, JSON-wrapped and AEAD-framed.
  static const int chunkBytes = 16 * 1024; // 16 KiB

  /// Number of chunks a [maxDocumentBytes]-sized transfer produces; used to
  /// sanity-check `total`/`seq` fields against the limits above.
  static int totalChunksFor(int byteSize) =>
      (byteSize + chunkBytes - 1) ~/ chunkBytes;
}

enum HandoffMessageType {
  /// Desktop → phone, sent once, immediately after the channel is open and
  /// the SAS has been confirmed. Describes the document about to be
  /// transferred: filename, byte size, SHA-256 and an optional MIME hint.
  /// Carries no preview material — the phone renders its own preview from
  /// the bytes it actually receives (see `document_chunk`).
  descriptor,

  /// Desktop → phone, one or more frames following `descriptor`. Carries a
  /// sequential slice of the actual document bytes (not a digest).
  documentChunk,

  /// Phone → desktop. Sent after the user has typed the PIN on the phone but
  /// before the actual NFC-mediated signing call. Tells the desktop "the user
  /// has confirmed and we're about to drive the card".
  pinOk,

  /// Phone → desktop. Announces the size/hash/format of the signed
  /// document about to follow as `signed_chunk` frames.
  signedStart,

  /// Phone → desktop, one or more frames following `signed_start`. Carries
  /// a sequential slice of the signed document bytes.
  signedChunk,

  /// Either side. Aborts the session; carries an optional reason string.
  abort,
}

extension on HandoffMessageType {
  String get wire => switch (this) {
    HandoffMessageType.descriptor => 'descriptor',
    HandoffMessageType.documentChunk => 'document_chunk',
    HandoffMessageType.pinOk => 'pin_ok',
    HandoffMessageType.signedStart => 'signed_start',
    HandoffMessageType.signedChunk => 'signed_chunk',
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
      'v': protocolVersion,
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
    if (v is! int || v != protocolVersion) {
      // Single-version protocol: an old (or newer) peer is rejected
      // cleanly here rather than misinterpreting its frames.
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
    'document_chunk' => HandoffMessageType.documentChunk,
    'pin_ok' => HandoffMessageType.pinOk,
    'signed_start' => HandoffMessageType.signedStart,
    'signed_chunk' => HandoffMessageType.signedChunk,
    'abort' => HandoffMessageType.abort,
    _ => null,
  };
}

// ───────────────────────────── typed payloads ─────────────────────────────

/// Lower-case hex SHA-256 shape: exactly 64 hex characters.
final RegExp _sha256HexPattern = RegExp(r'^[0-9a-f]{64}$');

/// Strips control characters (including bidi override characters, which
/// can be used to spoof a file extension visually) and caps length so a
/// malicious peer can't abuse the filename shown to the user.
String _sanitizeFileName(String raw) {
  final buf = StringBuffer();
  for (final rune in raw.runes) {
    // Drop C0/C1 controls and Unicode bidi formatting characters
    // (U+202A–U+202E, U+2066–U+2069).
    if (rune < 0x20 ||
        (rune >= 0x7f && rune <= 0x9f) ||
        (rune >= 0x202a && rune <= 0x202e) ||
        (rune >= 0x2066 && rune <= 0x2069)) {
      continue;
    }
    buf.writeCharCode(rune);
  }
  var s = buf.toString().trim();
  if (s.isEmpty) s = 'document';
  if (s.length > 255) s = s.substring(0, 255);
  return s;
}

/// Document descriptor sent by the desktop before the phone enters the PIN.
/// The phone displays this so the user can see *what* is being signed; the
/// actual bytes follow as `document_chunk` frames and are validated against
/// [sha256Hex] before anything is shown or signed.
class DescriptorPayload {
  DescriptorPayload({
    required String fileName,
    required this.byteSize,
    required String sha256Hex,
    this.mimeType,
  }) : fileName = _sanitizeFileName(fileName),
       sha256Hex = sha256Hex.toLowerCase() {
    if (byteSize <= 0 || byteSize > HandoffLimits.maxDocumentBytes) {
      throw FormatException('Descriptor: byteSize $byteSize out of bounds');
    }
    if (!_sha256HexPattern.hasMatch(this.sha256Hex)) {
      throw const FormatException(
        'Descriptor: sha256 is not 64 lower-case hex chars',
      );
    }
  }

  /// Filename only (no path), sanitized. Shown to the user.
  final String fileName;

  /// Size in bytes of the file the desktop intends to transfer and sign.
  final int byteSize;

  /// Lower-case hex SHA-256 of the file. The phone re-derives this from the
  /// bytes it actually receives and rejects the transfer on mismatch.
  final String sha256Hex;

  /// Optional MIME hint, e.g. `application/pdf`, used to pick the signature
  /// format (PAdES/XAdES/CAdES).
  final String? mimeType;

  Map<String, dynamic> toJson() => {
    'name': fileName,
    'size': byteSize,
    'sha256': sha256Hex,
    if (mimeType != null) 'mime': mimeType,
  };

  static DescriptorPayload fromJson(Map<String, dynamic> j) {
    final name = j['name'];
    final size = j['size'];
    final sha = j['sha256'];
    if (name is! String || size is! int || sha is! String) {
      throw const FormatException('Descriptor: missing required fields');
    }
    return DescriptorPayload(
      fileName: name,
      byteSize: size,
      sha256Hex: sha,
      mimeType: j['mime'] is String ? j['mime'] as String : null,
    );
  }

  HandoffMessage toMessage() =>
      HandoffMessage(type: HandoffMessageType.descriptor, data: toJson());
}

/// One slice of the document being transferred, sent in sequence
/// immediately after [DescriptorPayload]. `seq` is 0-based and must arrive
/// strictly in order (the underlying data channel is already ordered;
/// this is defense in depth against a misbehaving peer).
class DocumentChunkPayload {
  DocumentChunkPayload({required this.seq, required this.data}) {
    if (seq < 0) {
      throw const FormatException('DocumentChunk: negative seq');
    }
    if (data.lengthInBytes > HandoffLimits.chunkBytes) {
      throw const FormatException('DocumentChunk: chunk exceeds chunkBytes');
    }
  }

  final int seq;
  final Uint8List data;

  Map<String, dynamic> toJson() => {'seq': seq, 'data_b64': base64Encode(data)};

  static DocumentChunkPayload fromJson(Map<String, dynamic> j) {
    final seq = j['seq'];
    final b64 = j['data_b64'];
    if (seq is! int || b64 is! String) {
      throw const FormatException('DocumentChunk: missing seq/data_b64');
    }
    return DocumentChunkPayload(seq: seq, data: base64Decode(b64));
  }

  HandoffMessage toMessage() =>
      HandoffMessage(type: HandoffMessageType.documentChunk, data: toJson());
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

/// Phone → desktop: announces the signed document that follows as
/// `signed_chunk` frames.
class SignedStartPayload {
  SignedStartPayload({
    required this.byteSize,
    required String sha256Hex,
    this.format,
  }) : sha256Hex = sha256Hex.toLowerCase() {
    if (byteSize <= 0 || byteSize > HandoffLimits.maxDocumentBytes) {
      throw FormatException('SignedStart: byteSize $byteSize out of bounds');
    }
    if (!_sha256HexPattern.hasMatch(this.sha256Hex)) {
      throw const FormatException(
        'SignedStart: sha256 is not 64 lower-case hex chars',
      );
    }
  }

  /// Size in bytes of the signed document about to be transferred.
  final int byteSize;

  /// SHA-256 of the signed document bytes; the desktop re-derives this from
  /// the bytes it actually receives and rejects the transfer on mismatch.
  final String sha256Hex;

  /// Signature format tag, e.g. `pades-b-t`, `cades-bes`, `xades-bes`.
  final String? format;

  Map<String, dynamic> toJson() => {
    'size': byteSize,
    'sha256': sha256Hex,
    if (format != null) 'format': format,
  };

  static SignedStartPayload fromJson(Map<String, dynamic> j) {
    final size = j['size'];
    final sha = j['sha256'];
    if (size is! int || sha is! String) {
      throw const FormatException('SignedStart: missing required fields');
    }
    return SignedStartPayload(
      byteSize: size,
      sha256Hex: sha,
      format: j['format'] is String ? j['format'] as String : null,
    );
  }

  HandoffMessage toMessage() =>
      HandoffMessage(type: HandoffMessageType.signedStart, data: toJson());
}

/// One slice of the signed document, sent in sequence immediately after
/// [SignedStartPayload].
class SignedChunkPayload {
  SignedChunkPayload({required this.seq, required this.data}) {
    if (seq < 0) {
      throw const FormatException('SignedChunk: negative seq');
    }
    if (data.lengthInBytes > HandoffLimits.chunkBytes) {
      throw const FormatException('SignedChunk: chunk exceeds chunkBytes');
    }
  }

  final int seq;
  final Uint8List data;

  Map<String, dynamic> toJson() => {'seq': seq, 'data_b64': base64Encode(data)};

  static SignedChunkPayload fromJson(Map<String, dynamic> j) {
    final seq = j['seq'];
    final b64 = j['data_b64'];
    if (seq is! int || b64 is! String) {
      throw const FormatException('SignedChunk: missing seq/data_b64');
    }
    return SignedChunkPayload(seq: seq, data: base64Decode(b64));
  }

  HandoffMessage toMessage() =>
      HandoffMessage(type: HandoffMessageType.signedChunk, data: toJson());
}

/// Either side: abort the session.
class AbortPayload {
  AbortPayload({this.reason});

  final String? reason;

  Map<String, dynamic> toJson() => {if (reason != null) 'reason': reason};

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
