// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:ui';

/// Part of the signature box a pointer is over.
enum BoxHandle {
  none,
  move,
  topLeft,
  top,
  topRight,
  right,
  bottomRight,
  bottom,
  bottomLeft,
  left,
}

/// Pure geometry for the signature placement box.
///
/// Screen rects are in logical pixels with the origin at the top-left of the
/// page preview. Fraction rects are in page fractions with the Y axis
/// measured from the page BOTTOM: `Rect.fromLTWH(x, y, w, h)` where `y` is the
/// distance from the bottom edge to the bottom of the box.
abstract final class SignatureBoxGeometry {
  /// Default minimum box size (logical px).
  static const Size minSize = Size(24, 12);

  // ── fraction <-> screen ────────────────────────────────────────────────

  static Rect fractionToScreen(Rect frac, Size page) => Rect.fromLTWH(
    frac.left * page.width,
    (1.0 - frac.top - frac.height) * page.height,
    frac.width * page.width,
    frac.height * page.height,
  );

  static Rect screenToFraction(Rect screen, Size page) {
    if (page.isEmpty) return Rect.zero;
    final w = (screen.width / page.width).clamp(0.0, 1.0);
    final h = (screen.height / page.height).clamp(0.0, 1.0);
    final left = (screen.left / page.width).clamp(0.0, 1.0 - w);
    final bottom = (1.0 - screen.top / page.height - h).clamp(0.0, 1.0 - h);
    return Rect.fromLTWH(left, bottom, w, h);
  }

  // ── hit testing ────────────────────────────────────────────────────────

  /// Hit-tests [p] against [box]. [slop] is the generous grab distance around
  /// corners and edges (both inside and outside the box); it is capped on
  /// small boxes so that the interior stays reachable for moving.
  static BoxHandle hitTest(Rect box, Offset p, double slop) {
    final cs = math.min(slop, math.min(box.width, box.height) / 2);
    bool near(Offset c) =>
        (p.dx - c.dx).abs() <= cs && (p.dy - c.dy).abs() <= cs;

    if (near(box.topLeft)) return BoxHandle.topLeft;
    if (near(box.topRight)) return BoxHandle.topRight;
    if (near(box.bottomLeft)) return BoxHandle.bottomLeft;
    if (near(box.bottomRight)) return BoxHandle.bottomRight;

    final sx = math.min(slop, box.width / 3);
    final sy = math.min(slop, box.height / 3);
    final inX = p.dx >= box.left && p.dx <= box.right;
    final inY = p.dy >= box.top && p.dy <= box.bottom;
    if (inX && (p.dy - box.top).abs() <= sy) return BoxHandle.top;
    if (inX && (p.dy - box.bottom).abs() <= sy) return BoxHandle.bottom;
    if (inY && (p.dx - box.left).abs() <= sx) return BoxHandle.left;
    if (inY && (p.dx - box.right).abs() <= sx) return BoxHandle.right;
    if (box.contains(p)) return BoxHandle.move;
    return BoxHandle.none;
  }

  // ── move ───────────────────────────────────────────────────────────────

  /// Translates [box] by [delta], clamped to the page [bounds] (0,0,w,h).
  static Rect move(Rect box, Offset delta, Size bounds) =>
      clampInside(box.shift(delta), bounds);

  /// Keeps [box] size and moves it so its centre is at [center].
  static Rect centerAt(Rect box, Offset center, Size bounds) => clampInside(
    Rect.fromCenter(center: center, width: box.width, height: box.height),
    bounds,
  );

  /// Shifts [box] so it lies inside the page, shrinking it if larger.
  static Rect clampInside(Rect box, Size bounds) {
    final w = math.min(box.width, bounds.width);
    final h = math.min(box.height, bounds.height);
    final l = box.left.clamp(0.0, bounds.width - w);
    final t = box.top.clamp(0.0, bounds.height - h);
    return Rect.fromLTWH(l, t, w, h);
  }

  // ── resize / draw ──────────────────────────────────────────────────────

  /// Resizes [start] while dragging [handle] with the pointer at [pointer].
  ///
  /// The point opposite to the handle stays fixed. Dragging past it flips the
  /// box (no negative sizes). The result is clamped to [bounds] and never
  /// smaller than [min] (unless the page itself is). When [aspect]
  /// (width / height) is given, corner handles keep that ratio; edge handles
  /// always resize freely along their single axis.
  static Rect resize(
    Rect start,
    BoxHandle handle,
    Offset pointer,
    Size bounds, {
    Size min = minSize,
    double? aspect,
  }) {
    final left =
        handle == BoxHandle.left ||
        handle == BoxHandle.topLeft ||
        handle == BoxHandle.bottomLeft;
    final right =
        handle == BoxHandle.right ||
        handle == BoxHandle.topRight ||
        handle == BoxHandle.bottomRight;
    final top =
        handle == BoxHandle.top ||
        handle == BoxHandle.topLeft ||
        handle == BoxHandle.topRight;
    final bottom =
        handle == BoxHandle.bottom ||
        handle == BoxHandle.bottomLeft ||
        handle == BoxHandle.bottomRight;
    if (!(left || right || top || bottom)) return start;

    final isCorner = (left || right) && (top || bottom);
    if (isCorner && aspect != null && aspect > 0) {
      final anchor = Offset(
        left ? start.right : start.left,
        top ? start.bottom : start.top,
      );
      return _aspectFromAnchor(anchor, pointer, bounds, min, aspect);
    }

    var x0 = start.left;
    var w = start.width;
    var y0 = start.top;
    var h = start.height;
    if (left || right) {
      final r = _axis(
        left ? start.right : start.left,
        pointer.dx,
        bounds.width,
        min.width,
      );
      x0 = r.$1;
      w = r.$2;
    }
    if (top || bottom) {
      final r = _axis(
        top ? start.bottom : start.top,
        pointer.dy,
        bounds.height,
        min.height,
      );
      y0 = r.$1;
      h = r.$2;
    }
    return Rect.fromLTWH(x0, y0, w, h);
  }

  /// Draws a new box from the fixed [start] point to [pointer] in any
  /// direction, clamped to [bounds] and at least [min] in size.
  static Rect newRect(
    Offset start,
    Offset pointer,
    Size bounds, {
    Size min = minSize,
  }) {
    final x = _axis(start.dx, pointer.dx, bounds.width, min.width);
    final y = _axis(start.dy, pointer.dy, bounds.height, min.height);
    return Rect.fromLTWH(x.$1, y.$1, x.$2, y.$2);
  }

  /// Returns (start, length) on one axis between a fixed [anchor] and the
  /// [pointer], within `[0, max]`, with at least [minLen] length.
  static (double, double) _axis(
    double anchor,
    double pointer,
    double max,
    double minLen,
  ) {
    final a = anchor.clamp(0.0, max);
    final p = pointer.clamp(0.0, max);
    var dir = p >= a ? 1 : -1;
    var len = (p - a).abs();
    if (len < minLen) {
      len = math.min(minLen, max);
      if (dir > 0 && a + len > max) dir = -1;
      if (dir < 0 && a - len < 0) dir = 1;
    }
    return (dir > 0 ? a : a - len, len);
  }

  static Rect _aspectFromAnchor(
    Offset anchor,
    Offset pointer,
    Size bounds,
    Size min,
    double aspect,
  ) {
    final p = Offset(
      pointer.dx.clamp(0.0, bounds.width),
      pointer.dy.clamp(0.0, bounds.height),
    );
    var dirX = p.dx >= anchor.dx ? 1 : -1;
    var dirY = p.dy >= anchor.dy ? 1 : -1;
    double room(int dir, double a, double max) => dir > 0 ? max - a : a;

    var w = math.max(
      (p.dx - anchor.dx).abs(),
      (p.dy - anchor.dy).abs() * aspect,
    );
    var h = w / aspect;

    // Enforce minimum (keeping the ratio).
    final minW = math.max(min.width, min.height * aspect);
    if (w < minW) {
      w = minW;
      h = w / aspect;
    }
    // Flip towards the side that has room if the minimum does not fit.
    if (room(dirX, anchor.dx, bounds.width) < w &&
        room(-dirX, anchor.dx, bounds.width) >
            room(dirX, anchor.dx, bounds.width)) {
      dirX = -dirX;
    }
    if (room(dirY, anchor.dy, bounds.height) < h &&
        room(-dirY, anchor.dy, bounds.height) >
            room(dirY, anchor.dy, bounds.height)) {
      dirY = -dirY;
    }
    // Clamp into the available room, shrinking uniformly.
    final maxW = room(dirX, anchor.dx, bounds.width);
    final maxH = room(dirY, anchor.dy, bounds.height);
    final s = math.min(1.0, math.min(maxW / w, maxH / h));
    w *= s;
    h *= s;
    return Rect.fromLTWH(
      dirX > 0 ? anchor.dx : anchor.dx - w,
      dirY > 0 ? anchor.dy : anchor.dy - h,
      w,
      h,
    );
  }

  // ── keyboard ───────────────────────────────────────────────────────────

  /// Nudges [box] by [dx]/[dy] screen pixels (positive = right/down),
  /// clamped to the page.
  static Rect nudge(Rect box, double dx, double dy, Size bounds) =>
      clampInside(box.shift(Offset(dx, dy)), bounds);
}
