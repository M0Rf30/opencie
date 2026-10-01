// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The OpenCIE app icon, rendered in Flutter via [CustomPainter].
///
/// Mirrors the canonical SVG at `assets/branding/icon.svg` (128x128 space).
class OcMark extends StatelessWidget {
  const OcMark({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _OcMarkPainter()),
    );
  }
}

class _OcMarkPainter extends CustomPainter {
  // Brand colors (kept private — not theme tokens).
  static const _bgTop = Color(0xFF123A6B);
  static const _bgBot = Color(0xFF071528);
  static const _glow = Color(0xFF5FA8E8);
  static const _wave = Color(0xFFFFD866);
  static const _cardHi = Color(0xFFE9F2FB);
  static const _cardLo = Color(0xFFB9D3EC);
  static const _ink = Color(0xFF1F4E82);
  static const _itGreen = Color(0xFF009246);
  static const _itRed = Color(0xFFCE2B37);
  static const _goldHi = Color(0xFFFFE38A);
  static const _goldMid = Color(0xFFE0AE3E);
  static const _goldLo = Color(0xFFB07F22);
  static const _goldLine = Color(0xFF8A6116);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 128, size.height / 128);

    // Backdrop
    final bgRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(0, 0, 128, 128),
      const Radius.circular(28),
    );
    canvas.drawRRect(
      bgRect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_bgTop, _bgBot],
        ).createShader(const Rect.fromLTWH(0, 0, 128, 128)),
    );
    canvas.drawRRect(
      bgRect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.375, -0.53), // (40, 30)
          radius: 90 / 128, // fraction of the shortest side
          colors: [_glow.withValues(alpha: 0.35), _glow.withValues(alpha: 0)],
        ).createShader(const Rect.fromLTWH(0, 0, 128, 128)),
    );

    // Contactless waves: SVG `M x,(58-r') A r,r 0 0,1 x,(58+r')`, shifted +3.
    _wave3(canvas, x: 91, halfChord: 12, r: 18, opacity: 1);
    _wave3(canvas, x: 101, halfChord: 20, r: 30, opacity: 0.7);
    _wave3(canvas, x: 111, halfChord: 28, r: 42, opacity: 0.4);

    // Card: translate(14 40) rotate(-8 about 36,24)
    canvas.save();
    canvas.translate(14 + 36, 40 + 24);
    canvas.rotate(-8 * math.pi / 180);
    canvas.translate(-36, -24);

    final card = RRect.fromRectAndRadius(
      const Rect.fromLTWH(0, 0, 72, 48),
      const Radius.circular(7),
    );
    canvas.drawRRect(
      card.shift(const Offset(1.5, 4)),
      Paint()..color = Colors.black.withValues(alpha: 0.35),
    );
    canvas.save();
    canvas.clipRRect(card);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 72, 48),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_cardHi, _cardLo],
        ).createShader(const Rect.fromLTWH(0, 0, 72, 48)),
    );
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 24, 7),
      Paint()..color = _itGreen,
    );
    canvas.drawRect(
      const Rect.fromLTWH(24, 0, 24, 7),
      Paint()..color = Colors.white,
    );
    canvas.drawRect(const Rect.fromLTWH(48, 0, 24, 7), Paint()..color = _itRed);
    final mrz = Paint()..color = _ink.withValues(alpha: 0.45);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(8, 37, 56, 2.6),
        const Radius.circular(1.3),
      ),
      mrz,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(8, 42, 40, 2.6),
        const Radius.circular(1.3),
      ),
      mrz,
    );
    canvas.restore();

    // Chip
    const chip = Rect.fromLTWH(8, 14, 20, 16);
    canvas.drawRRect(
      RRect.fromRectAndRadius(chip, const Radius.circular(3)),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_goldHi, _goldMid, _goldLo],
          stops: [0, 0.6, 1],
        ).createShader(chip),
    );
    final pad = Paint()
      ..color = _goldLine
      ..strokeWidth = 0.9;
    canvas.drawLine(const Offset(8, 19.3), const Offset(28, 19.3), pad);
    canvas.drawLine(const Offset(8, 24.7), const Offset(28, 24.7), pad);
    canvas.drawLine(const Offset(18, 14), const Offset(18, 30), pad);

    // Portrait
    final face = Paint()..color = _ink.withValues(alpha: 0.75);
    canvas.drawCircle(const Offset(55, 18), 4, face);
    canvas.drawPath(
      Path()
        ..moveTo(48, 31)
        ..quadraticBezierTo(48, 24, 55, 24)
        ..quadraticBezierTo(62, 24, 62, 31)
        ..close(),
      face,
    );

    canvas.restore(); // card
    canvas.restore(); // scale
  }

  /// Right-opening arc between (x, 58-halfChord) and (x, 58+halfChord) with
  /// radius [r], matching SVG `A r r 0 0 1`.
  void _wave3(
    Canvas canvas, {
    required double x,
    required double halfChord,
    required double r,
    required double opacity,
  }) {
    final cx = x - math.sqrt(r * r - halfChord * halfChord);
    final sweep = 2 * math.asin(halfChord / r);
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, 58), radius: r),
      -sweep / 2,
      sweep,
      false,
      Paint()
        ..color = _wave.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _OcMarkPainter oldDelegate) => false;
}
