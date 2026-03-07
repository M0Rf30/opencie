// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:pdfrx/pdfrx.dart';

import '../../../core/theme/app_theme.dart';
import '../utils/signature_image_generator.dart';

/// PDF signature-placement widget with a draggable, resizable signature
/// box overlaid on the rendered page.
class PdfSignaturePlacer extends StatefulWidget {
  const PdfSignaturePlacer({
    required this.pdfPath,
    required this.page,
    required this.sigX,
    required this.sigY,
    required this.sigW,
    required this.sigH,
    required this.imageData,
    required this.onChanged,
    super.key,
  });

  final String pdfPath;
  final int page;
  final double sigX;
  final double sigY;
  final double sigW;
  final double sigH;
  final Uint8List? imageData;
  final void Function({
    required int page,
    required double x,
    required double y,
    required double w,
    required double h,
    Uint8List? imageData,
  }) onChanged;

  @override
  State<PdfSignaturePlacer> createState() => _PdfSignaturePlacerState();
}

class _PdfSignaturePlacerState extends State<PdfSignaturePlacer> {
  PdfDocument? _doc;
  bool _loading = true;
  String? _error;
  int _pageIndex = 0;

  Rect? _screenRect;
  bool _moving = false;
  Offset? _moveOffset;

  Uint8List? _defaultImageData;
  bool _generatingDefault = false;

  @override
  void initState() {
    super.initState();
    _pageIndex = widget.page;
    _load();
    _ensureDefaultImage();
  }

  @override
  void didUpdateWidget(PdfSignaturePlacer old) {
    super.didUpdateWidget(old);
    if (old.pdfPath != widget.pdfPath) {
      _doc?.dispose();
      _doc = null;
      _load();
    }
  }

  @override
  void dispose() {
    _doc?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final doc = await PdfDocument.openFile(widget.pdfPath);
      if (mounted) {
        setState(() {
          _doc = doc;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _ensureDefaultImage() async {
    if (_generatingDefault || _defaultImageData != null) return;
    setState(() => _generatingDefault = true);
    try {
      final bytes = await generateDefaultSignatureImage();
      if (mounted) {
        setState(() {
          _defaultImageData = bytes;
          _generatingDefault = false;
        });
        if (widget.imageData == null) {
          widget.onChanged(
            page: _pageIndex,
            x: widget.sigX,
            y: widget.sigY,
            w: widget.sigW,
            h: widget.sigH,
            imageData: bytes,
          );
        }
      }
    } catch (_) {
      if (mounted) setState(() => _generatingDefault = false);
    }
  }

  Uint8List? get _effectiveImageData => widget.imageData ?? _defaultImageData;

  int get _pageCount => _doc?.pages.length ?? 0;

  PdfPage? get _currentPage =>
      _doc != null && _pageIndex < _pageCount ? _doc!.pages[_pageIndex] : null;

  Size? get _pdfPageSize {
    final p = _currentPage;
    if (p == null) return null;
    return Size(p.width, p.height);
  }

  Rect _fractionToScreen(Rect frac, Size containerSize, Size pageSize) {
    final scale = _scale(containerSize, pageSize);
    final offset = _renderOffset(containerSize, pageSize, scale);
    return Rect.fromLTWH(
      frac.left * pageSize.width * scale + offset.dx,
      (1.0 - frac.top - frac.height) * pageSize.height * scale + offset.dy,
      frac.width * pageSize.width * scale,
      frac.height * pageSize.height * scale,
    );
  }

  Rect _screenToFraction(Rect screenRect, Size containerSize, Size pageSize) {
    final scale = _scale(containerSize, pageSize);
    final offset = _renderOffset(containerSize, pageSize, scale);
    final fW = (screenRect.width / scale / pageSize.width).clamp(0.0, 1.0);
    final fH = (screenRect.height / scale / pageSize.height).clamp(0.0, 1.0);
    final fLeft = ((screenRect.left - offset.dx) / scale / pageSize.width)
        .clamp(0.0, 1.0 - fW);
    final fBottom =
        (1.0 - (screenRect.top - offset.dy) / scale / pageSize.height - fH)
            .clamp(0.0, 1.0 - fH);
    return Rect.fromLTWH(fLeft, fBottom, fW, fH);
  }

  double _scale(Size container, Size page) =>
      min(container.width / page.width, container.height / page.height);

  Offset _renderOffset(Size container, Size page, double scale) => Offset(
        (container.width - page.width * scale) / 2,
        (container.height - page.height * scale) / 2,
      );

  Rect _sigAsFractionRect() => Rect.fromLTWH(
        widget.sigX,
        widget.sigY,
        widget.sigW,
        widget.sigH,
      );

  void _notify(Rect fracRect) {
    widget.onChanged(
      page: _pageIndex,
      x: fracRect.left,
      y: fracRect.top,
      w: fracRect.width,
      h: fracRect.height,
      imageData: _effectiveImageData,
    );
  }

  void _notifyPage(int page) {
    setState(() => _pageIndex = page);
    final ps = _pdfPageSize;
    if (ps == null) return;
    widget.onChanged(
      page: page,
      x: widget.sigX,
      y: widget.sigY,
      w: widget.sigW,
      h: widget.sigH,
      imageData: _effectiveImageData,
    );
  }

  void _resetSigBox() {
    setState(() => _screenRect = null);
    widget.onChanged(
      page: _pageIndex,
      x: 0.02,
      y: 0.02,
      w: 0.50,
      h: 0.095,
      imageData: _effectiveImageData,
    );
  }

  Future<void> _pickImage() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    if (result != null && result.paths.isNotEmpty) {
      final path = result.paths.first;
      if (path != null) {
        final bytes = await File(path).readAsBytes();
        widget.onChanged(
          page: _pageIndex,
          x: widget.sigX,
          y: widget.sigY,
          w: widget.sigW,
          h: widget.sigH,
          imageData: bytes,
        );
      }
    }
  }

  void _resetToDefaultImage() {
    widget.onChanged(
      page: _pageIndex,
      x: widget.sigX,
      y: widget.sigY,
      w: widget.sigW,
      h: widget.sigH,
      imageData: _defaultImageData,
    );
  }

  Widget _buildImageControl(ColorScheme cs) {
    final effective = _effectiveImageData;
    final isCustom = widget.imageData != null;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (effective != null)
          GestureDetector(
            onTap: _pickImage,
            child: Tooltip(
              message: isCustom
                  ? 'Immagine personalizzata — tocca per cambiare'
                  : 'Timbro predefinito — tocca per cambiare',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(
                  effective,
                  width: 56,
                  height: 20,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      const SizedBox(width: 56, height: 20),
                ),
              ),
            ),
          ),
        const SizedBox(width: 4),
        PopupMenuButton<_ImageAction>(
          tooltip: 'Immagine firma',
          icon: Icon(
            isCustom ? Icons.image_rounded : Icons.auto_awesome_rounded,
            size: 16,
            color: cs.primary,
          ),
          padding: EdgeInsets.zero,
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: _ImageAction.pick,
              child: Row(children: [
                Icon(Icons.upload_file, size: 16),
                SizedBox(width: 8),
                Text('Immagine personalizzata…'),
              ]),
            ),
            if (isCustom)
              const PopupMenuItem(
                value: _ImageAction.reset,
                child: Row(children: [
                  Icon(Icons.auto_awesome_rounded, size: 16),
                  SizedBox(width: 8),
                  Text('Ripristina predefinito'),
                ]),
              ),
          ],
          onSelected: (action) {
            if (action == _ImageAction.pick) _pickImage();
            if (action == _ImageAction.reset) _resetToDefaultImage();
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.40),
            blurRadius: 40,
            offset: const Offset(0, 20),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header bar ──────────────────────────────────────────────
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: cs.surfaceContainer,
              border: Border(
                bottom: BorderSide(color: cs.outlineVariant),
              ),
            ),
            child: Row(
              children: [
                // Title + page info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Posiziona la firma',
                        style: TextStyle(fontFamily: 'Inter', 
                          color: cs.onSurface,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      if (_pageCount > 0)
                        Text(
                          'Pagina ${_pageIndex + 1} / $_pageCount',
                          style: AppTheme.monoCaption(cs),
                        ),
                    ],
                  ),
                ),

                // Page navigation
                if (_pageCount > 1) ...[
                  IconButton(
                    icon: const Icon(Icons.chevron_left_rounded),
                    tooltip: 'Pagina precedente',
                    onPressed: _pageIndex > 0
                        ? () => _notifyPage(_pageIndex - 1)
                        : null,
                    iconSize: 20,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                        minWidth: 32, minHeight: 32),
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right_rounded),
                    tooltip: 'Pagina successiva',
                    onPressed: _pageIndex < _pageCount - 1
                        ? () => _notifyPage(_pageIndex + 1)
                        : null,
                    iconSize: 20,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                        minWidth: 32, minHeight: 32),
                  ),
                  const SizedBox(width: 4),
                ],

                // Image control
                _buildImageControl(cs),

                const SizedBox(width: 8),

                // Reset pill
                GestureDetector(
                  onTap: _resetSigBox,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: cs.outlineVariant),
                      color: cs.surfaceContainerHigh,
                    ),
                    child: Text(
                      'Reset',
                      style: AppTheme.monoCaption(cs),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── PDF preview ─────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.all(16),
            child: _buildPreview(cs),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview(ColorScheme cs) {
    if (_loading) {
      return const SizedBox(
        height: 300,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return SizedBox(
        height: 120,
        child: Center(
          child: Text(
            'Impossibile visualizzare il PDF: $_error',
            style: TextStyle(color: cs.error),
          ),
        ),
      );
    }
    final pageSize = _pdfPageSize;
    if (pageSize == null) {
      return const SizedBox(
        height: 120,
        child: Center(child: Text('Nessuna pagina disponibile')),
      );
    }

    final aspectRatio = pageSize.width / pageSize.height;

    return LayoutBuilder(
      builder: (context, constraints) {
        final containerW = constraints.maxWidth;
        final containerH = containerW / aspectRatio;

        return Container(
          width: containerW,
          height: containerH,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(4),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.20),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Builder(builder: (context) {
            final containerSize = Size(containerW, containerH);
            final currentScreenRect = _screenRect ??
                _fractionToScreen(
                    _sigAsFractionRect(), containerSize, pageSize);
            final imgBytes = _effectiveImageData;

            return Stack(
              children: [
                // PDF page
                Positioned.fill(
                  child: PdfPageView(
                    document: _doc!,
                    pageNumber: _pageIndex + 1,
                    alignment: Alignment.center,
                  ),
                ),

                // Signature image preview
                if (imgBytes != null &&
                    currentScreenRect.width > 4 &&
                    currentScreenRect.height > 4)
                  Positioned(
                    left: currentScreenRect.left,
                    top: currentScreenRect.top,
                    width: currentScreenRect.width,
                    height: currentScreenRect.height,
                    child: Image.memory(
                      imgBytes,
                      fit: BoxFit.fill,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),

                // Overlay: border + fill + handles (via CustomPainter)
                Positioned.fill(
                  child: GestureDetector(
                    onPanStart: (d) {
                      if (currentScreenRect.contains(d.localPosition)) {
                        setState(() {
                          _moving = true;
                          _moveOffset =
                              d.localPosition - currentScreenRect.topLeft;
                          _screenRect = currentScreenRect;
                        });
                      } else {
                        setState(() {
                          _moving = false;
                          _screenRect = Rect.fromLTWH(
                              d.localPosition.dx,
                              d.localPosition.dy,
                              1,
                              1);
                        });
                      }
                    },
                    onPanUpdate: (d) {
                      final scale = _scale(containerSize, pageSize);
                      final offset =
                          _renderOffset(containerSize, pageSize, scale);
                      final bounds = Rect.fromLTWH(
                        offset.dx,
                        offset.dy,
                        pageSize.width * scale,
                        pageSize.height * scale,
                      );

                      setState(() {
                        if (_moving &&
                            _screenRect != null &&
                            _moveOffset != null) {
                          final newTopLeft =
                              d.localPosition - _moveOffset!;
                          final clamped = Offset(
                            newTopLeft.dx.clamp(bounds.left,
                                bounds.right - _screenRect!.width),
                            newTopLeft.dy.clamp(bounds.top,
                                bounds.bottom - _screenRect!.height),
                          );
                          _screenRect = Rect.fromLTWH(
                            clamped.dx,
                            clamped.dy,
                            _screenRect!.width,
                            _screenRect!.height,
                          );
                        } else if (_screenRect != null) {
                          final raw = Rect.fromPoints(
                              _screenRect!.topLeft, d.localPosition);
                          final clamped = raw.intersect(bounds);
                          if (clamped.width > 4 && clamped.height > 4) {
                            _screenRect = clamped;
                          }
                        }
                      });
                    },
                    onPanEnd: (_) {
                      if (_screenRect == null) return;
                      final fracRect = _screenToFraction(
                          _screenRect!, containerSize, pageSize);
                      setState(() => _moving = false);
                      _notify(fracRect);
                    },
                    child: CustomPaint(
                      painter: _SignatureOverlayPainter(
                        screenRect: currentScreenRect,
                        color: cs.primary,
                      ),
                    ),
                  ),
                ),

                // "FIRMA QUI" label centered in sig box
                if (imgBytes == null &&
                    currentScreenRect.width > 32 &&
                    currentScreenRect.height > 18)
                  Positioned(
                    left: currentScreenRect.left,
                    top: currentScreenRect.top,
                    width: currentScreenRect.width,
                    height: currentScreenRect.height,
                    child: IgnorePointer(
                      child: Center(
                        child: Text(
                          'FIRMA QUI',
                          style: TextStyle(fontFamily: 'JetBrainsMono', 
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
          }),
        );
      },
    );
  }
}

class _SignatureOverlayPainter extends CustomPainter {
  const _SignatureOverlayPainter({
    required this.screenRect,
    required this.color,
  });

  final Rect screenRect;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (screenRect.width < 4 || screenRect.height < 4) return;

    // Fill: primary 14%
    canvas.drawRect(
      screenRect,
      Paint()
        ..color = color.withValues(alpha: 0.14)
        ..style = PaintingStyle.fill,
    );

    // Border: 2px solid primary
    canvas.drawRect(
      screenRect,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );

    // Corner handles: 10×10 white circle with 2px primary border
    const r = 5.0;
    for (final corner in [
      screenRect.topLeft,
      screenRect.topRight,
      screenRect.bottomLeft,
      screenRect.bottomRight,
    ]) {
      // White fill
      canvas.drawCircle(
        corner,
        r,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.fill,
      );
      // Primary border
      canvas.drawCircle(
        corner,
        r,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0,
      );
    }
  }

  @override
  bool shouldRepaint(_SignatureOverlayPainter old) =>
      old.screenRect != screenRect || old.color != color;
}

enum _ImageAction { pick, reset }
