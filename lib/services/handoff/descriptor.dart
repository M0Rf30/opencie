// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import 'messages.dart';

/// Builds a [DescriptorPayload] from a local file path.
///
/// Reads the whole file once for SHA-256. For PDFs, also extracts page
/// count and a first-page thumbnail PNG capped at [maxThumbnailBytes].
class HandoffDescriptorBuilder {
  HandoffDescriptorBuilder._();

  /// Maximum thumbnail PNG size. Larger renders are dropped, the
  /// descriptor is sent without a thumbnail.
  static const int maxThumbnailBytes = 50 * 1024;

  /// Maximum thumbnail width in pixels (height scales to preserve aspect).
  static const int maxThumbnailWidth = 320;

  /// Build a descriptor for [filePath]. Best-effort — failures in
  /// optional fields (page count, thumbnail) leave them null rather
  /// than throwing.
  static Future<DescriptorPayload> fromFile(String filePath) async {
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    final hash = await Sha256().hash(bytes);
    final sha256Hex = _hex(hash.bytes);

    final ext = p.extension(filePath).toLowerCase();
    final mime = _mimeForExt(ext);

    int? pageCount;
    Uint8List? thumbnailPng;
    if (ext == '.pdf') {
      try {
        final doc = await PdfDocument.openData(bytes);
        try {
          pageCount = doc.pages.length;
          if (pageCount > 0) {
            thumbnailPng = await _renderFirstPagePng(doc.pages.first);
            if (thumbnailPng != null &&
                thumbnailPng.lengthInBytes > maxThumbnailBytes) {
              thumbnailPng = null;
            }
          }
        } finally {
          await doc.dispose();
        }
      } catch (_) {
        // Best-effort: fall through with null pageCount/thumbnail.
      }
    }

    return DescriptorPayload(
      fileName: p.basename(filePath),
      byteSize: bytes.length,
      sha256Hex: sha256Hex,
      pageCount: pageCount,
      thumbnailPng: thumbnailPng,
      mimeType: mime,
    );
  }

  static Future<Uint8List?> _renderFirstPagePng(PdfPage page) async {
    final aspect = page.height / page.width;
    final w = maxThumbnailWidth;
    final h = (w * aspect).round();
    final img = await page.render(
      fullWidth: w.toDouble(),
      fullHeight: h.toDouble(),
      backgroundColor: 0xFFFFFFFF,
    );
    if (img == null) return null;
    try {
      // pdfrx hands us BGRA8888; dart:ui needs RGBA8888.
      final rgba = _bgraToRgba(img.pixels);
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        rgba,
        img.width,
        img.height,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      final uiImage = await completer.future;
      try {
        final bd = await uiImage.toByteData(format: ui.ImageByteFormat.png);
        return bd?.buffer.asUint8List();
      } finally {
        uiImage.dispose();
      }
    } finally {
      img.dispose();
    }
  }

  static Uint8List _bgraToRgba(Uint8List src) {
    final out = Uint8List(src.length);
    for (var i = 0; i < src.length; i += 4) {
      out[i] = src[i + 2]; // R
      out[i + 1] = src[i + 1]; // G
      out[i + 2] = src[i]; // B
      out[i + 3] = src[i + 3]; // A
    }
    return out;
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
