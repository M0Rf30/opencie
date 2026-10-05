// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'signature_box_geometry.dart';

enum _Mode { idle, pending, move, resize, draw }

/// Interactive signature box laid over the page preview.
///
/// Sized to exactly the rendered page ([pageSize]); the committed box comes
/// in as a page-fraction rect (bottom-origin Y) so it is always consistent
/// with the saved values regardless of layout changes. During a gesture the
/// live rect is held in a [ValueNotifier] so only this subtree repaints, and
/// [onCommit] fires once on gesture end / keyboard nudge.
class SignatureBoxOverlay extends StatefulWidget {
  const SignatureBoxOverlay({
    required this.pageSize,
    required this.fraction,
    required this.imageData,
    required this.imageAspect,
    required this.lockAspect,
    required this.onCommit,
    required this.semanticsLabel,
    required this.signHereLabel,
    super.key,
  });

  final Size pageSize;

  /// Committed box as page fractions (x, y-from-bottom, w, h).
  final Rect fraction;
  final Uint8List? imageData;

  /// Width / height of the signature image, used for corner-resize lock.
  final double? imageAspect;
  final bool lockAspect;
  final ValueChanged<Rect> onCommit;
  final String semanticsLabel;
  final String signHereLabel;

  @override
  State<SignatureBoxOverlay> createState() => _SignatureBoxOverlayState();
}

class _SignatureBoxOverlayState extends State<SignatureBoxOverlay> {
  final ValueNotifier<Rect?> _live = ValueNotifier(null);
  final ValueNotifier<MouseCursor> _cursor = ValueNotifier(
    SystemMouseCursors.precise,
  );
  final FocusNode _focus = FocusNode(debugLabel: 'SignatureBoxOverlay');

  _Mode _mode = _Mode.idle;
  int? _pointer;
  Offset _startPos = Offset.zero;
  Rect _startRect = Rect.zero;
  BoxHandle _handle = BoxHandle.none;
  double _slop = 12;
  double _dragSlop = 4;

  Rect get _committed =>
      SignatureBoxGeometry.fractionToScreen(widget.fraction, widget.pageSize);
  Rect get _current => _live.value ?? _committed;

  @override
  void didUpdateWidget(SignatureBoxOverlay old) {
    super.didUpdateWidget(old);
    if (old.pageSize != widget.pageSize) _cancel();
  }

  @override
  void dispose() {
    _live.dispose();
    _cursor.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _cancel() {
    _mode = _Mode.idle;
    _pointer = null;
    _live.value = null;
  }

  void _commit(Rect screen) {
    final frac = SignatureBoxGeometry.screenToFraction(screen, widget.pageSize);
    _live.value = null;
    widget.onCommit(frac);
  }

  static MouseCursor _cursorFor(BoxHandle h) => switch (h) {
    BoxHandle.move => SystemMouseCursors.move,
    BoxHandle.topLeft ||
    BoxHandle.bottomRight => SystemMouseCursors.resizeUpLeftDownRight,
    BoxHandle.topRight ||
    BoxHandle.bottomLeft => SystemMouseCursors.resizeUpRightDownLeft,
    BoxHandle.top || BoxHandle.bottom => SystemMouseCursors.resizeUpDown,
    BoxHandle.left || BoxHandle.right => SystemMouseCursors.resizeLeftRight,
    BoxHandle.none => SystemMouseCursors.precise,
  };

  void _onDown(PointerDownEvent e) {
    if (_pointer != null) return;
    if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryButton) {
      return;
    }
    _focus.requestFocus();
    final touch =
        e.kind == PointerDeviceKind.touch || e.kind == PointerDeviceKind.stylus;
    _slop = touch ? 22 : 12;
    _dragSlop = touch ? 8 : 4;
    _pointer = e.pointer;
    _startPos = e.localPosition;
    _startRect = _current;
    _handle = SignatureBoxGeometry.hitTest(_startRect, _startPos, _slop);
    _cursor.value = _cursorFor(_handle);
    _mode = switch (_handle) {
      BoxHandle.none => _Mode.pending,
      BoxHandle.move => _Mode.move,
      _ => _Mode.resize,
    };
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    final bounds = widget.pageSize;
    final pos = e.localPosition;
    if (_mode == _Mode.pending) {
      if ((pos - _startPos).distance <= _dragSlop) return;
      _mode = _Mode.draw;
    }
    switch (_mode) {
      case _Mode.move:
        _live.value = SignatureBoxGeometry.move(
          _startRect,
          pos - _startPos,
          bounds,
        );
      case _Mode.resize:
        _live.value = SignatureBoxGeometry.resize(
          _startRect,
          _handle,
          pos,
          bounds,
          aspect: widget.lockAspect ? _aspect(_startRect) : null,
        );
      case _Mode.draw:
        _live.value = SignatureBoxGeometry.newRect(_startPos, pos, bounds);
      case _Mode.idle || _Mode.pending:
        break;
    }
  }

  double? _aspect(Rect r) {
    final a = widget.imageAspect;
    if (a != null && a > 0) return a;
    if (r.height > 0 && r.width > 0) return r.width / r.height;
    return null;
  }

  void _onUp(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    final mode = _mode;
    _mode = _Mode.idle;
    _pointer = null;
    switch (mode) {
      case _Mode.pending:
        _commit(
          SignatureBoxGeometry.centerAt(
            _startRect,
            e.localPosition,
            widget.pageSize,
          ),
        );
      case _Mode.move || _Mode.resize || _Mode.draw:
        final r = _live.value;
        if (r != null) {
          _commit(r);
        }
      case _Mode.idle:
        break;
    }
    _cursor.value = _cursorFor(
      SignatureBoxGeometry.hitTest(_current, e.localPosition, _slop),
    );
  }

  void _onCancel(PointerCancelEvent e) {
    if (e.pointer != _pointer) return;
    _cancel();
  }

  void _onHover(PointerHoverEvent e) {
    if (_mode != _Mode.idle) return;
    _cursor.value = _cursorFor(
      SignatureBoxGeometry.hitTest(_current, e.localPosition, _slop),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final step = HardwareKeyboard.instance.isShiftPressed ? 10.0 : 1.0;
    double dx = 0, dy = 0;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowLeft) {
      dx = -step;
    } else if (k == LogicalKeyboardKey.arrowRight) {
      dx = step;
    } else if (k == LogicalKeyboardKey.arrowUp) {
      dy = -step;
    } else if (k == LogicalKeyboardKey.arrowDown) {
      dy = step;
    } else {
      return KeyEventResult.ignored;
    }
    if (_mode != _Mode.idle) return KeyEventResult.handled;
    _commit(SignatureBoxGeometry.nudge(_current, dx, dy, widget.pageSize));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      label: widget.semanticsLabel,
      child: Focus(
        focusNode: _focus,
        onKeyEvent: _onKey,
        child: RawGestureDetector(
          // Claim the pointer immediately so a touch drag on the page
          // never turns into a parent scroll.
          gestures: {
            EagerGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
                  EagerGestureRecognizer.new,
                  (_) {},
                ),
          },
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onDown,
            onPointerMove: _onMove,
            onPointerUp: _onUp,
            onPointerCancel: _onCancel,
            onPointerHover: _onHover,
            child: ValueListenableBuilder<MouseCursor>(
              valueListenable: _cursor,
              builder: (context, cursor, child) =>
                  MouseRegion(cursor: cursor, child: child),
              child: ListenableBuilder(
                listenable: Listenable.merge([_live, _focus]),
                builder: (context, _) => _buildBox(cs),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBox(ColorScheme cs) {
    final r = _current;
    final visible = r.width > 1 && r.height > 1;
    final img = widget.imageData;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (visible && img != null)
          Positioned.fromRect(
            rect: r,
            child: IgnorePointer(
              child: Image.memory(
                img,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _OverlayPainter(
                rect: r,
                color: cs.primary,
                focused: _focus.hasFocus,
              ),
            ),
          ),
        ),
        if (visible && img == null && r.width > 32 && r.height > 18)
          Positioned.fromRect(
            rect: r,
            child: IgnorePointer(
              child: Center(
                child: Text(
                  widget.signHereLabel,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    color: cs.primary,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _OverlayPainter extends CustomPainter {
  const _OverlayPainter({
    required this.rect,
    required this.color,
    required this.focused,
  });

  final Rect rect;
  final Color color;
  final bool focused;

  @override
  void paint(Canvas canvas, Size size) {
    if (rect.width < 1 || rect.height < 1) return;
    canvas.drawRect(rect, Paint()..color = color.withValues(alpha: 0.14));
    canvas.drawRect(
      rect,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = focused ? 3.0 : 2.0,
    );
    const r = 5.0;
    final fill = Paint()..color = Colors.white;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    for (final c in [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ]) {
      canvas.drawCircle(c, r, fill);
      canvas.drawCircle(c, r, stroke);
    }
  }

  @override
  bool shouldRepaint(_OverlayPainter old) =>
      old.rect != rect || old.color != color || old.focused != focused;
}
