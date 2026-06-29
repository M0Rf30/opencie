// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The OpenCIE app icon, rendered in Flutter via [CustomPainter].
///
/// Mirrors the canonical SVG at `assets/branding/icon.svg`.
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
  // V2 palette (kept private — these are brand colors, not theme tokens).
  static const _itGreen = Color(0xFF008C45);
  static const _itRed = Color(0xFFCD212A);
  static const _cieBlue = Color(0xFF3D7AB7);
  static const _cieDeep = Color(0xFF1F4E82);
  static const _cardHi = Color(0xFF9CC1E2);
  static const _goldLo = Color(0xFFA07520);
  static const _goldMid = Color(0xFFD4A437);
  static const _goldHi = Color(0xFFFFE082);
  static const _bgTop = Color(0xFF0B1F3F);
  static const _bgBot = Color(0xFF06121F);

  @override
  void paint(Canvas canvas, Size size) {
    // All coordinates are computed against a 128-unit virtual canvas (matching
    // the canonical SVG viewBox) and scaled at the end.
    final scale = size.width / 128.0;
    canvas.save();
    canvas.scale(scale, scale);

    final rect = const Rect.fromLTWH(0, 0, 128, 128);
    final radius = const Radius.circular(28);
    final rrect = RRect.fromRectAndRadius(rect, radius);

    // Backdrop
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_bgTop, _bgBot],
        ).createShader(rect),
    );

    // Gold halo (radial, off-center top-left)
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.5, -0.25), // (32,48) on 128 → (-0.5,-0.25)
          radius: 60 / 64.0, // r=60 over half-width 64
          colors: [
            _goldHi.withValues(alpha: 0.45),
            _goldHi.withValues(alpha: 0),
          ],
        ).createShader(rect),
    );

    // NFC waves: three arcs, opening to the right, centered around the chip
    // area. Each arc is a half-circle from top to bottom of its bounding box.
    final wavePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..color = _goldHi;
    _arc(canvas, wavePaint, cx: 78, ry: 28, dy: 24, sw: 3, opacity: 0.85);
    _arc(canvas, wavePaint, cx: 88, ry: 38, dy: 30, sw: 2.5, opacity: 0.7);
    _arc(canvas, wavePaint, cx: 98, ry: 48, dy: 36, sw: 2, opacity: 0.45);

    // Card: rotate -14° around centre (64,64), then translate to local origin
    canvas.save();
    canvas.translate(64, 64);
    canvas.rotate(-14 * math.pi / 180);
    canvas.translate(-50, -38);

    // Drop shadow rect under the card
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(3, 6, 100, 76),
        const Radius.circular(9),
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );

    // Card body
    final cardRect = const Rect.fromLTWH(0, 0, 100, 76);
    canvas.drawRRect(
      RRect.fromRectAndRadius(cardRect, const Radius.circular(9)),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_cardHi, _cieBlue, _cieDeep],
          stops: [0, 0.5, 1],
        ).createShader(const Rect.fromLTWH(0, 0, 100, 80)),
    );

    // Header text bars
    _bar(canvas, 8, 9, 58, 2.5, Colors.white.withValues(alpha: 0.85));
    _bar(canvas, 8, 14.5, 40, 2, Colors.white.withValues(alpha: 0.55));

    // Italian flag (3 rects 4.5×7 at x=76 y=8)
    _flag(canvas, 76, 8);

    // Gold smartcard chip (28×22 at x=10 y=28)
    _chip(canvas, 10, 28, 28, 22);

    // Portrait avatar (circle + bust shape)
    _portrait(canvas, 50, 30);

    // MRZ lines
    _bar(canvas, 8, 60, 84, 2, Colors.white.withValues(alpha: 0.55));
    _bar(canvas, 8, 65, 70, 2, Colors.white.withValues(alpha: 0.55));

    // Glossy highlight strip across top of card
    final gloss = Path()
      ..moveTo(0, 0)
      ..lineTo(100, 0)
      ..lineTo(100, 12)
      ..quadraticBezierTo(50, 22, 0, 12)
      ..close();
    canvas.drawPath(
      gloss,
      Paint()..color = Colors.white.withValues(alpha: 0.18),
    );

    canvas.restore();
    canvas.restore();
  }

  // Half-arc opening to the right: SVG `M cx,(64-ry) A ry,ry 0 0,1 cx,(64+ry)`
  // becomes a Bezier-based arc spanning vertical extent 2*ry centered at y=64.
  void _arc(
    Canvas canvas,
    Paint base, {
    required double cx,
    required double ry,
    required double
    dy, // half height of NFC arc bounding (dy = ry on right side)
    required double sw,
    required double opacity,
  }) {
    // The SVG arcs are: M cx (64-ry) A ry ry 0 0 1 cx (64+ry)
    // This is the right half of a circle of radius ry centered at (cx-?, 64).
    // For "M 78 28 A 28 28 0 0 1 78 76" the arc has radius 28, sweeps clockwise
    // from (78, 36) to (78, 92)? Actually 28→76 means y goes 28→76 = 48 span,
    // but ry=28 means full diameter 56, so y span 28→76 = 48 ≠ 56. Let me
    // re-read: M 78 28, end 78 76 — vertical chord length 48; with rx=ry=28
    // (radius 28, diameter 56), a 48-unit chord doesn't span the diameter, so
    // the arc is less than a half-circle. Using Path.arcToPoint matches SVG's
    // arc command exactly.
    final path = Path()
      ..moveTo(cx, 64 - dy)
      ..arcToPoint(
        Offset(cx, 64 + dy),
        radius: Radius.circular(ry),
        clockwise: true,
      );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = sw
        ..color = base.color.withValues(alpha: opacity),
    );
  }

  void _bar(
    Canvas canvas,
    double x,
    double y,
    double w,
    double h,
    Color color,
  ) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, w, h),
        const Radius.circular(1),
      ),
      Paint()..color = color,
    );
  }

  void _flag(Canvas canvas, double x, double y) {
    canvas.drawRect(Rect.fromLTWH(x, y, 4.5, 7), Paint()..color = _itGreen);
    canvas.drawRect(
      Rect.fromLTWH(x + 4.5, y, 4.5, 7),
      Paint()..color = Colors.white,
    );
    canvas.drawRect(Rect.fromLTWH(x + 9, y, 4.5, 7), Paint()..color = _itRed);
  }

  void _chip(Canvas canvas, double x, double y, double w, double h) {
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(x, y, w, h),
      const Radius.circular(2.5),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_goldHi, _goldMid, _goldLo],
          stops: [0, 0.55, 1],
        ).createShader(Rect.fromLTWH(x, y, w, h)),
    );

    final pad = Paint()
      ..color = const Color(0xFF7A5512)
      ..strokeWidth = 0.7;
    // 2 horizontal lines at h*0.33, h*0.66
    canvas.drawLine(Offset(x, y + h * 0.33), Offset(x + w, y + h * 0.33), pad);
    canvas.drawLine(Offset(x, y + h * 0.66), Offset(x + w, y + h * 0.66), pad);
    // 2 vertical lines at w*0.33, w*0.66
    canvas.drawLine(Offset(x + w * 0.33, y), Offset(x + w * 0.33, y + h), pad);
    canvas.drawLine(Offset(x + w * 0.66, y), Offset(x + w * 0.66, y + h), pad);

    // Inner edge highlight
    final highlight = RRect.fromRectAndRadius(
      Rect.fromLTWH(x + 0.5, y + 0.5, w - 1, h - 1),
      const Radius.circular(2),
    );
    canvas.drawRRect(
      highlight,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.4
        ..color = const Color(0xFFFFE9A6).withValues(alpha: 0.7),
    );
  }

  void _portrait(Canvas canvas, double x, double y) {
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.8);
    canvas.drawCircle(Offset(x + 8, y + 5), 3.5, paint);
    final bust = Path()
      ..moveTo(x + 1, y + 19)
      ..quadraticBezierTo(x + 1, y + 12, x + 8, y + 12)
      ..quadraticBezierTo(x + 15, y + 12, x + 15, y + 19)
      ..lineTo(x + 15, y + 22)
      ..lineTo(x + 1, y + 22)
      ..close();
    canvas.drawPath(bust, paint);
  }

  @override
  bool shouldRepaint(covariant _OcMarkPainter oldDelegate) => false;
}
