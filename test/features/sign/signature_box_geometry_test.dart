// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/features/sign/widgets/signature_box_geometry.dart';

void main() {
  const page = Size(400, 600);
  const min = Size(24, 12);
  const box = Rect.fromLTWH(100, 200, 120, 60);

  group('fraction <-> screen', () {
    test('bottom-origin y round trip', () {
      const frac = Rect.fromLTWH(0.1, 0.02, 0.5, 0.1);
      final s = SignatureBoxGeometry.fractionToScreen(frac, page);
      expect(s.left, closeTo(40, 1e-9));
      expect(s.width, closeTo(200, 1e-9));
      expect(s.height, closeTo(60, 1e-9));
      // bottom of the box is 2% above the page bottom
      expect(s.bottom, closeTo(600 - 12, 1e-9));
      final back = SignatureBoxGeometry.screenToFraction(s, page);
      expect(back.left, closeTo(frac.left, 1e-9));
      expect(back.top, closeTo(frac.top, 1e-9));
      expect(back.width, closeTo(frac.width, 1e-9));
      expect(back.height, closeTo(frac.height, 1e-9));
    });

    test('resizing the container keeps the fraction', () {
      const frac = Rect.fromLTWH(0.2, 0.3, 0.25, 0.1);
      for (final size in const [Size(200, 300), Size(800, 1200)]) {
        final s = SignatureBoxGeometry.fractionToScreen(frac, size);
        final back = SignatureBoxGeometry.screenToFraction(s, size);
        expect(back.left, closeTo(frac.left, 1e-9));
        expect(back.top, closeTo(frac.top, 1e-9));
        expect(back.width, closeTo(frac.width, 1e-9));
        expect(back.height, closeTo(frac.height, 1e-9));
      }
    });

    test('out of page rect is clamped', () {
      final f = SignatureBoxGeometry.screenToFraction(
        const Rect.fromLTWH(380, 590, 100, 100),
        page,
      );
      expect(f.left + f.width, lessThanOrEqualTo(1.0 + 1e-9));
      expect(f.top + f.height, lessThanOrEqualTo(1.0 + 1e-9));
      expect(f.left, greaterThanOrEqualTo(0));
    });
  });

  group('hitTest', () {
    BoxHandle hit(Offset p, [double slop = 12]) =>
        SignatureBoxGeometry.hitTest(box, p, slop);

    test('corners, edges, inside, outside', () {
      expect(hit(box.topLeft + const Offset(-5, 3)), BoxHandle.topLeft);
      expect(hit(box.topRight), BoxHandle.topRight);
      expect(hit(box.bottomLeft), BoxHandle.bottomLeft);
      expect(hit(box.bottomRight), BoxHandle.bottomRight);
      expect(hit(Offset(box.center.dx, box.top - 4)), BoxHandle.top);
      expect(hit(Offset(box.center.dx, box.bottom)), BoxHandle.bottom);
      expect(hit(Offset(box.left + 2, box.center.dy)), BoxHandle.left);
      expect(hit(Offset(box.right + 6, box.center.dy)), BoxHandle.right);
      expect(hit(box.center), BoxHandle.move);
      expect(hit(const Offset(10, 10)), BoxHandle.none);
    });

    test('small box keeps an inside move area', () {
      const small = Rect.fromLTWH(100, 100, 24, 12);
      expect(
        SignatureBoxGeometry.hitTest(small, small.center, 22),
        BoxHandle.move,
      );
    });
  });

  group('move', () {
    test('translates', () {
      expect(
        SignatureBoxGeometry.move(box, const Offset(10, -20), page),
        const Rect.fromLTWH(110, 180, 120, 60),
      );
    });

    test('clamps to every page edge', () {
      final a = SignatureBoxGeometry.move(box, const Offset(-999, -999), page);
      expect(a.topLeft, Offset.zero);
      final b = SignatureBoxGeometry.move(box, const Offset(999, 999), page);
      expect(b.bottomRight, const Offset(400, 600));
      expect(b.size, box.size);
    });

    test('centerAt keeps size and clamps', () {
      final c = SignatureBoxGeometry.centerAt(
        box,
        const Offset(300, 300),
        page,
      );
      expect(c.center, const Offset(300, 300));
      expect(c.size, box.size);
      final e = SignatureBoxGeometry.centerAt(box, Offset.zero, page);
      expect(e.topLeft, Offset.zero);
    });

    test('nudge moves and clamps', () {
      expect(
        SignatureBoxGeometry.nudge(box, 1, -10, page),
        const Rect.fromLTWH(101, 190, 120, 60),
      );
      expect(
        SignatureBoxGeometry.nudge(
          const Rect.fromLTWH(0, 0, 10, 10),
          -5,
          -5,
          page,
        ).topLeft,
        Offset.zero,
      );
    });
  });

  group('resize (free)', () {
    Rect r(BoxHandle h, Offset p) =>
        SignatureBoxGeometry.resize(box, h, p, page, min: min);

    test('each corner keeps the opposite corner', () {
      expect(
        r(BoxHandle.topLeft, const Offset(80, 150)).bottomRight,
        box.bottomRight,
      );
      expect(
        r(BoxHandle.topRight, const Offset(300, 150)).bottomLeft,
        box.bottomLeft,
      );
      expect(
        r(BoxHandle.bottomLeft, const Offset(80, 300)).topRight,
        box.topRight,
      );
      expect(
        r(BoxHandle.bottomRight, const Offset(300, 300)),
        const Rect.fromLTRB(100, 200, 300, 300),
      );
    });

    test('edges only change one axis', () {
      expect(
        r(BoxHandle.right, const Offset(350, 999)),
        const Rect.fromLTRB(100, 200, 350, 260),
      );
      expect(
        r(BoxHandle.left, const Offset(50, 0)),
        const Rect.fromLTRB(50, 200, 220, 260),
      );
      expect(
        r(BoxHandle.top, const Offset(0, 100)),
        const Rect.fromLTRB(100, 100, 220, 260),
      );
      expect(
        r(BoxHandle.bottom, const Offset(0, 400)),
        const Rect.fromLTRB(100, 200, 220, 400),
      );
    });

    test('dragging past the opposite edge flips', () {
      expect(
        r(BoxHandle.right, const Offset(40, 0)),
        const Rect.fromLTRB(40, 200, 100, 260),
      );
      expect(
        r(BoxHandle.top, const Offset(0, 300)),
        const Rect.fromLTRB(100, 260, 220, 300),
      );
      expect(
        r(BoxHandle.bottomRight, const Offset(50, 100)),
        const Rect.fromLTRB(50, 100, 100, 200),
      );
      expect(
        r(BoxHandle.topLeft, const Offset(300, 400)),
        const Rect.fromLTRB(220, 260, 300, 400),
      );
    });

    test('clamped to the page', () {
      expect(
        r(BoxHandle.bottomRight, const Offset(999, 999)),
        const Rect.fromLTRB(100, 200, 400, 600),
      );
      expect(
        r(BoxHandle.topLeft, const Offset(-50, -50)),
        const Rect.fromLTRB(0, 0, 220, 260),
      );
    });

    test('min size is enforced', () {
      final a = r(BoxHandle.bottomRight, const Offset(101, 201));
      expect(a.width, 24);
      expect(a.height, 12);
      expect(a.topLeft, box.topLeft);
      const edge = Rect.fromLTWH(380, 590, 20, 10);
      final b = SignatureBoxGeometry.resize(
        edge,
        BoxHandle.topLeft,
        const Offset(399, 599),
        page,
        min: min,
      );
      expect(b.width, 24);
      expect(b.height, 12);
      expect(b.right, lessThanOrEqualTo(400));
      expect(b.bottom, lessThanOrEqualTo(600));
    });
  });

  group('resize (aspect lock)', () {
    const aspect = 4.0; // w / h

    Rect r(BoxHandle h, Offset p) =>
        SignatureBoxGeometry.resize(box, h, p, page, min: min, aspect: aspect);

    test('corner keeps ratio and anchor', () {
      final a = r(BoxHandle.bottomRight, const Offset(300, 230));
      expect(a.topLeft, box.topLeft);
      expect(a.width / a.height, closeTo(aspect, 1e-9));
      expect(a.width, closeTo(200, 1e-9)); // dx dominates
      final b = r(BoxHandle.bottomRight, const Offset(120, 260));
      expect(b.width / b.height, closeTo(aspect, 1e-9));
      expect(b.height, closeTo(60, 1e-9)); // dy dominates
    });

    test('flip past anchor keeps ratio', () {
      final a = r(BoxHandle.topLeft, const Offset(300, 300));
      expect(a.width / a.height, closeTo(aspect, 1e-9));
      expect(a.left, closeTo(220, 1e-9));
      expect(a.top, closeTo(260, 1e-9));
    });

    test('clamped to page keeps ratio', () {
      final a = r(BoxHandle.bottomRight, const Offset(999, 999));
      expect(a.width / a.height, closeTo(aspect, 1e-9));
      expect(a.right, lessThanOrEqualTo(400 + 1e-9));
      expect(a.bottom, lessThanOrEqualTo(600 + 1e-9));
      expect(a.topLeft, box.topLeft);
    });

    test('min size respected with ratio', () {
      final a = r(BoxHandle.bottomRight, const Offset(100, 200));
      expect(a.width, greaterThanOrEqualTo(24 - 1e-9));
      expect(a.height, greaterThanOrEqualTo(12 - 1e-9));
      expect(a.width / a.height, closeTo(aspect, 1e-9));
    });

    test('edges stay free', () {
      expect(
        r(BoxHandle.right, const Offset(350, 0)),
        const Rect.fromLTRB(100, 200, 350, 260),
      );
    });
  });

  group('newRect', () {
    const start = Offset(200, 300);
    Rect n(Offset p) => SignatureBoxGeometry.newRect(start, p, page, min: min);

    test('all four directions anchor on the fixed start', () {
      expect(
        n(const Offset(300, 350)),
        const Rect.fromLTRB(200, 300, 300, 350),
      );
      expect(
        n(const Offset(100, 350)),
        const Rect.fromLTRB(100, 300, 200, 350),
      );
      expect(
        n(const Offset(300, 250)),
        const Rect.fromLTRB(200, 250, 300, 300),
      );
      expect(
        n(const Offset(100, 250)),
        const Rect.fromLTRB(100, 250, 200, 300),
      );
    });

    test('moving back and forth never moves the anchor', () {
      expect(n(const Offset(100, 100)).bottomRight, start);
      expect(n(const Offset(300, 500)).topLeft, start);
    });

    test('immediate feedback with min size, clamped to page', () {
      final a = n(const Offset(201, 301));
      expect(a.topLeft, start);
      expect(a.size, min);
      expect(n(const Offset(-50, 999)), const Rect.fromLTRB(0, 300, 200, 600));
    });

    test('min size near the page corner flips inwards', () {
      final a = SignatureBoxGeometry.newRect(
        const Offset(399, 599),
        const Offset(399.5, 599.5),
        page,
        min: min,
      );
      expect(a.size, min);
      expect(a.bottomRight, const Offset(399, 599));
    });
  });
}
