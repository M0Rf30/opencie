// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart';

/// Preview material rendered by the receiving side (the phone) from bytes
/// it has already validated against the descriptor's SHA-256. Unlike the
/// old protocol, this is never peer-supplied: what's previewed is exactly
/// what will be signed.
class DocumentPreview {
  const DocumentPreview({this.pageCount, this.thumbnailPng});

  final int? pageCount;
  final Uint8List? thumbnailPng;
}

/// Renders a [DocumentPreview] from raw document bytes. Best-effort: any
/// failure (unsupported format, corrupt PDF, render error) yields an empty
/// preview rather than throwing, since the preview is cosmetic — the
/// SHA-256 check is what actually gates signing.
class DocumentPreviewBuilder {
  DocumentPreviewBuilder._();

  /// Maximum thumbnail PNG size; larger renders are dropped.
  static const int maxThumbnailBytes = 50 * 1024;

  /// Maximum thumbnail width in pixels (height scales to preserve aspect).
  static const int maxThumbnailWidth = 320;

  static Future<DocumentPreview> fromBytes(
    Uint8List bytes, {
    String? mimeType,
  }) async {
    if (mimeType != 'application/pdf') {
      return const DocumentPreview();
    }
    try {
      final doc = await PdfDocument.openData(bytes);
      try {
        final pageCount = doc.pages.length;
        Uint8List? thumbnailPng;
        if (pageCount > 0) {
          thumbnailPng = await _renderFirstPagePng(doc.pages.first);
          if (thumbnailPng != null &&
              thumbnailPng.lengthInBytes > maxThumbnailBytes) {
            thumbnailPng = null;
          }
        }
        return DocumentPreview(
          pageCount: pageCount,
          thumbnailPng: thumbnailPng,
        );
      } finally {
        await doc.dispose();
      }
    } catch (_) {
      // Best-effort: fall back to no preview rather than blocking signing.
      return const DocumentPreview();
    }
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
}
