// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:opencie/services/handoff/qr_image_decoder.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Renders [data] as a QR code image with a 4-module quiet zone.
img.Image _render(String data, {int scale = 6, bool transparent = false}) {
  final code = QrCode.fromData(
    data: data,
    errorCorrectLevel: QrErrorCorrectLevel.M,
  );
  final qr = QrImage(code);
  final n = code.moduleCount;
  final size = (n + 8) * scale;
  final image = img.Image(width: size, height: size, numChannels: 4);
  img.fill(
    image,
    color: transparent
        ? img.ColorRgba8(0, 0, 0, 0)
        : img.ColorRgba8(255, 255, 255, 255),
  );
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      if (!qr.isDark(y, x)) continue;
      img.fillRect(
        image,
        x1: (x + 4) * scale,
        y1: (y + 4) * scale,
        x2: (x + 5) * scale - 1,
        y2: (y + 5) * scale - 1,
        color: img.ColorRgba8(0, 0, 0, 255),
      );
    }
  }
  return image;
}

void main() {
  final payload =
      '{"v":1,"r":"answer","pk":"${'A' * 43}","sdp":"${'a=candidate:1 ' * 60}"}';

  test('decodes a PNG-encoded QR back to its text', () {
    final bytes = Uint8List.fromList(img.encodePng(_render(payload)));
    expect(decodeQrFromImageBytesSync(bytes), payload);
  });

  test('decodes a JPEG-encoded QR', () {
    final bytes = Uint8List.fromList(
      img.encodeJpg(_render(payload, scale: 8), quality: 90),
    );
    expect(decodeQrFromImageBytesSync(bytes), payload);
  });

  test('decodes a QR with transparent background', () {
    final bytes = Uint8List.fromList(
      img.encodePng(_render('hello', transparent: true)),
    );
    expect(decodeQrFromImageBytesSync(bytes), 'hello');
  });

  test('async wrapper decodes too', () async {
    final bytes = Uint8List.fromList(img.encodePng(_render(payload)));
    expect(await decodeQrFromImageBytes(bytes), payload);
  });

  test('returns null for an image without a QR code', () {
    final blank = img.Image(width: 200, height: 200, numChannels: 4);
    img.fill(blank, color: img.ColorRgba8(255, 255, 255, 255));
    expect(
      decodeQrFromImageBytesSync(Uint8List.fromList(img.encodePng(blank))),
      isNull,
    );
  });

  test('returns null for non-image bytes', () {
    expect(
      decodeQrFromImageBytesSync(Uint8List.fromList([1, 2, 3, 4, 5])),
      isNull,
    );
  });
}
