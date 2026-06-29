// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

Future<Uint8List> generateDefaultSignatureImage({
  String? signerCN,
  DateTime? signingDate,
}) async {
  const double w = 600;
  const double h = 180;
  const double iconZone = 140;
  const double radius = 12.0;
  const double pad = 18.0;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));

  const primary = Color(0xFF0D47A1);
  const bg = Color(0xFFE8EAF6);

  canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = bg);
  canvas.drawRRect(
    RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, h), Radius.circular(radius)),
    Paint()..color = bg,
  );

  final iconBg = Paint()..color = primary;
  canvas.drawRRect(
    RRect.fromRectAndCorners(
      Rect.fromLTWH(0, 0, iconZone, h),
      topLeft: Radius.circular(radius),
      bottomLeft: Radius.circular(radius),
    ),
    iconBg,
  );

  final iconPainter = TextPainter(
    text: const TextSpan(text: '🔏', style: TextStyle(fontSize: 56, height: 1)),
    textDirection: TextDirection.ltr,
  );
  iconPainter.layout();
  iconPainter.paint(
    canvas,
    Offset((iconZone - iconPainter.width) / 2, (h - iconPainter.height) / 2),
  );

  final border = Paint()
    ..color = primary
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2;
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(1, 1, w - 2, h - 2),
      Radius.circular(radius),
    ),
    border,
  );

  final textLeft = iconZone + pad;
  final textWidth = w - textLeft - pad;

  void drawLine(
    String text,
    double y, {
    double fontSize = 22,
    FontWeight weight = FontWeight.normal,
    Color? color,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: weight,
          color: color ?? primary,
          height: 1.25,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    );
    tp.layout(maxWidth: textWidth);
    tp.paint(canvas, Offset(textLeft, y));
  }

  drawLine(
    'Firmato digitalmente con CIE',
    20,
    fontSize: 20,
    weight: FontWeight.bold,
  );

  final name = signerCN?.isNotEmpty == true ? signerCN! : 'Titolare CIE';
  drawLine(name, 60, fontSize: 26, weight: FontWeight.w600);

  final now = signingDate ?? DateTime.now();
  final dateStr =
      '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}'
      '  ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  drawLine('Data: $dateStr', 100, fontSize: 20, color: const Color(0xFF37474F));

  drawLine(
    'opencie · firma qualificata eIDAS',
    134,
    fontSize: 16,
    color: const Color(0xFF78909C),
  );

  final picture = recorder.endRecording();
  final image = await picture.toImage(w.toInt(), h.toInt());
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();

  if (byteData == null) throw Exception('Failed to encode signature image');
  return byteData.buffer.asUint8List();
}
