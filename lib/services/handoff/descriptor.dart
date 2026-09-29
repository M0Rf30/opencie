// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import 'messages.dart';

/// Builds a [DescriptorPayload] from already-read file bytes.
///
/// This is metadata only (filename, size, SHA-256, MIME hint) — no preview
/// material is generated on the desktop side. The phone renders its own
/// preview (page count, first-page thumbnail) from the bytes it actually
/// receives over the handoff channel, so the preview can never diverge from
/// what gets signed.
class HandoffDescriptorBuilder {
  HandoffDescriptorBuilder._();

  /// Builds a descriptor for [fileName] from [bytes], which the caller has
  /// already read once (and will reuse for the chunked transfer).
  static Future<DescriptorPayload> fromBytes({
    required Uint8List bytes,
    required String fileName,
  }) async {
    final hash = await Sha256().hash(bytes);
    return DescriptorPayload(
      fileName: p.basename(fileName),
      byteSize: bytes.length,
      sha256Hex: _hex(hash.bytes),
      mimeType: _mimeForExt(p.extension(fileName).toLowerCase()),
    );
  }

  static String _hex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static String _mimeForExt(String ext) {
    switch (ext) {
      case '.pdf':
        return 'application/pdf';
      case '.p7m':
      case '.p7s':
        return 'application/pkcs7-mime';
      case '.xml':
        return 'application/xml';
      default:
        return 'application/octet-stream';
    }
  }
}
