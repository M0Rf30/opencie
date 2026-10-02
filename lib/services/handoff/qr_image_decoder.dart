// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

/// Decodes a QR code from encoded image bytes (PNG, JPEG, WebP, BMP, …).
///
/// Pure Dart (no native dependencies), so it works on every desktop target.
/// Runs in a background isolate because screenshots can be large.
///
/// Returns the QR text, or `null` when the bytes are not a decodable image
/// or no QR code is found.
Future<String?> decodeQrFromImageBytes(Uint8List bytes) {
  return Isolate.run(() => decodeQrFromImageBytesSync(bytes));
}

/// Synchronous variant of [decodeQrFromImageBytes] (used by tests and the
/// background isolate).
String? decodeQrFromImageBytesSync(Uint8List bytes) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    return null;
  }
  if (decoded == null) return null;

  // Flatten transparency onto white so transparent QR backgrounds decode.
  var base = decoded.convert(numChannels: 4);
  if (base.hasAlpha) {
    final flat = img.Image(
      width: base.width,
      height: base.height,
      numChannels: 4,
    );
    img.fill(flat, color: img.ColorRgba8(255, 255, 255, 255));
    img.compositeImage(flat, base);
    base = flat;
  }

  // Try full size first, then progressively smaller copies: huge screenshots
  // with a small on-screen QR often decode better once downscaled.
  final attempts = <img.Image>[base];
  const maxSides = [1600, 1000, 700];
  for (final side in maxSides) {
    final longest = base.width > base.height ? base.width : base.height;
    if (longest <= side) continue;
    attempts.add(
      img.copyResize(
        base,
        width: base.width >= base.height ? side : null,
        height: base.height > base.width ? side : null,
        interpolation: img.Interpolation.average,
      ),
    );
  }

  for (final image in attempts) {
    final text = _tryDecode(image);
    if (text != null) return text;
  }
  return null;
}

String? _tryDecode(img.Image image) {
  final pixels = image
      .convert(numChannels: 4)
      .getBytes(order: img.ChannelOrder.rgba)
      .buffer
      .asInt32List();
  final source = RGBLuminanceSource(image.width, image.height, pixels);

  for (final binarizer in <Binarizer Function(LuminanceSource)>[
    HybridBinarizer.new,
    GlobalHistogramBinarizer.new,
  ]) {
    for (final inverted in const [false, true]) {
      try {
        final src = inverted ? InvertedLuminanceSource(source) : source;
        final result = QRCodeReader().decode(
          BinaryBitmap(binarizer(src)),
          hints: DecodeHints()..put(DecodeHintType.tryHarder),
        );
        final text = result.text;
        if (text.isNotEmpty) return text;
      } catch (_) {
        // NotFound / Checksum / Format: try the next strategy.
      }
    }
  }
  return null;
}
