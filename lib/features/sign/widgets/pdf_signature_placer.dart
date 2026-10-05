// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';

import 'package:pdfrx/pdfrx.dart';

import '../../../core/l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../services/ltv/pades/pdf_reader.dart';
import '../../../widgets/oc_radio_card.dart';
import '../../../widgets/oc_section_label.dart';
import '../utils/signature_image_generator.dart';
import 'signature_box_geometry.dart';
import 'signature_box_overlay.dart';

/// Amber outline for existing AcroForm signature fields the user can
/// align to — distinct from the active placement's teal highlight.
const _kFieldOutlineFill = Color.fromRGBO(255, 149, 0, 0.10);
const _kFieldOutlineBorder = Color.fromRGBO(255, 149, 0, 0.9);

/// Runs off the UI thread via [compute] so parsing a large/complex PDF's
/// AcroForm never blocks first paint.
List<PdfSignatureFieldInfo> _findSigFieldsInBytes(Uint8List bytes) =>
    PdfReader(bytes).findSignatureFields();

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
    required this.alignedFieldName,
    this.includeDate = true,
    super.key,
  });

  final String pdfPath;
  final int page;
  final double sigX;
  final double sigY;
  final double sigW;
  final double sigH;
  final Uint8List? imageData;
  final String? alignedFieldName;

  /// Whether the generated default appearance shows the signing date
  /// (the `includeDate` setting).
  final bool includeDate;
  final void Function({
    required int page,
    required double x,
    required double y,
    required double w,
    required double h,
    Uint8List? imageData,
    required String? alignedFieldName,
  })
  onChanged;

  @override
  State<PdfSignaturePlacer> createState() => _PdfSignaturePlacerState();
}

class _PdfSignaturePlacerState extends State<PdfSignaturePlacer> {
  PdfDocument? _doc;
  bool _loading = true;
  String? _error;
  int _pageIndex = 0;

  bool _lockAspect = true;
  double? _imageAspect;

  Uint8List? _defaultImageData;
  bool _generatingDefault = false;

  List<PdfSignatureFieldInfo> _sigFields = const [];

  @override
  void initState() {
    super.initState();
    _pageIndex = widget.page;
    _load();
    _ensureDefaultImage();
    _loadSigFields();
    _resolveImageAspect();
  }

  @override
  void didUpdateWidget(PdfSignaturePlacer old) {
    super.didUpdateWidget(old);
    if (old.page != widget.page && widget.page != _pageIndex) {
      _pageIndex = widget.page;
    }
    if (old.pdfPath != widget.pdfPath) {
      _doc?.dispose();
      _doc = null;
      _load();
      _sigFields = const [];
      _loadSigFields();
    }
    if (old.includeDate != widget.includeDate) {
      _regenerateDefaultImage();
    }
    _resolveImageAspect();
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
      final bytes = await generateDefaultSignatureImage(
        includeDate: widget.includeDate,
      );
      if (mounted) {
        setState(() {
          _defaultImageData = bytes;
          _generatingDefault = false;
        });
        _resolveImageAspect();
        if (widget.imageData == null) {
          widget.onChanged(
            page: _pageIndex,
            x: widget.sigX,
            y: widget.sigY,
            w: widget.sigW,
            h: widget.sigH,
            imageData: bytes,
            alignedFieldName: widget.alignedFieldName,
          );
        }
      }
    } catch (_) {
      if (mounted) setState(() => _generatingDefault = false);
    }
  }

  /// Re-renders the default appearance after the `includeDate` setting
  /// changed. A user-picked custom image is left alone; only an image that
  /// is (still) the generated default follows the change.
  Future<void> _regenerateDefaultImage() async {
    final previous = _defaultImageData;
    final followsDefault =
        widget.imageData == null || identical(widget.imageData, previous);
    try {
      final bytes = await generateDefaultSignatureImage(
        includeDate: widget.includeDate,
      );
      if (!mounted) return;
      setState(() => _defaultImageData = bytes);
      _resolveImageAspect();
      if (followsDefault) {
        widget.onChanged(
          page: _pageIndex,
          x: widget.sigX,
          y: widget.sigY,
          w: widget.sigW,
          h: widget.sigH,
          imageData: bytes,
          alignedFieldName: widget.alignedFieldName,
        );
      }
    } catch (e) {
      debugPrint('PdfSignaturePlacer._regenerateDefaultImage: $e');
    }
  }

  Future<void> _loadSigFields() async {
    try {
      final bytes = await File(widget.pdfPath).readAsBytes();
      final fields = await compute(_findSigFieldsInBytes, bytes);
      if (mounted) setState(() => _sigFields = fields);
    } catch (_) {
      // Best-effort convenience: leave the list empty on any failure.
    }
  }

  void _selectField(PdfSignatureFieldInfo field) {
    setState(() => _pageIndex = field.pageIndex);
    widget.onChanged(
      page: field.pageIndex,
      x: field.x,
      y: field.y,
      w: field.width,
      h: field.height,
      imageData: _effectiveImageData,
      alignedFieldName: field.name,
    );
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

  Uint8List? _aspectFor;

  /// Resolves the signature image aspect (w / h) for the aspect lock.
  Future<void> _resolveImageAspect() async {
    final bytes = _effectiveImageData;
    if (bytes == null || identical(bytes, _aspectFor)) return;
    _aspectFor = bytes;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final a = frame.image.width / frame.image.height;
      frame.image.dispose();
      codec.dispose();
      if (mounted && identical(bytes, _aspectFor)) {
        setState(() => _imageAspect = a);
      }
    } catch (_) {
      if (mounted) setState(() => _imageAspect = null);
    }
  }

  Rect _sigAsFractionRect() =>
      Rect.fromLTWH(widget.sigX, widget.sigY, widget.sigW, widget.sigH);

  void _notify(Rect fracRect) {
    widget.onChanged(
      page: _pageIndex,
      x: fracRect.left,
      y: fracRect.top,
      w: fracRect.width,
      h: fracRect.height,
      imageData: _effectiveImageData,
      alignedFieldName: null,
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
      alignedFieldName: null,
    );
  }

  Widget _pageButton(IconData icon, String tooltip, VoidCallback? onPressed) =>
      IconButton(
        icon: Icon(icon),
        tooltip: tooltip,
        onPressed: onPressed,
        iconSize: 20,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      );

  void _resetSigBox() {
    widget.onChanged(
      page: _pageIndex,
      x: 0.02,
      y: 0.02,
      w: 0.50,
      h: 0.095,
      imageData: _effectiveImageData,
      alignedFieldName: null,
    );
  }

  Future<void> _pickImage() async {
    final file = await FilePicker.pickFile(type: FileType.image);
    {
      final path = file?.path;
      if (path != null) {
        final bytes = await File(path).readAsBytes();
        widget.onChanged(
          page: _pageIndex,
          x: widget.sigX,
          y: widget.sigY,
          w: widget.sigW,
          h: widget.sigH,
          imageData: bytes,
          alignedFieldName: widget.alignedFieldName,
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
      alignedFieldName: widget.alignedFieldName,
    );
  }

  Widget _buildImageControl(ColorScheme cs) {
    final l10n = AppLocalizations.of(context);
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
                  ? l10n.signPlacerCustomImageTooltip
                  : l10n.signPlacerDefaultImageTooltip,
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
          tooltip: l10n.signPlacerImageMenuTooltip,
          icon: Icon(
            isCustom ? Icons.image_rounded : Icons.auto_awesome_rounded,
            size: 16,
            color: cs.primary,
          ),
          padding: EdgeInsets.zero,
          itemBuilder: (_) => [
            PopupMenuItem(
              value: _ImageAction.pick,
              child: Row(
                children: [
                  const Icon(Icons.upload_file, size: 16),
                  const SizedBox(width: 8),
                  Text(l10n.signPlacerPickImageMenuItem),
                ],
              ),
            ),
            if (isCustom)
              PopupMenuItem(
                value: _ImageAction.reset,
                child: Row(
                  children: [
                    const Icon(Icons.auto_awesome_rounded, size: 16),
                    const SizedBox(width: 8),
                    Text(l10n.signPlacerResetDefaultMenuItem),
                  ],
                ),
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
    final l10n = AppLocalizations.of(context);

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
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: cs.surfaceContainer,
              border: Border(bottom: BorderSide(color: cs.outlineVariant)),
            ),
            child: Row(
              children: [
                // Title + page info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.signPlacerTitle,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          color: cs.onSurface,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      if (_pageCount > 0)
                        Text(
                          l10n.signPlacerPageCounter(
                            _pageIndex + 1,
                            _pageCount,
                          ),
                          style: AppTheme.monoCaption(cs),
                        ),
                    ],
                  ),
                ),
                Flexible(
                  flex: 3,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      // Page navigation
                      if (_pageCount > 1) ...[
                        _pageButton(
                          Icons.first_page_rounded,
                          l10n.signPlacerFirstPage,
                          _pageIndex > 0 ? () => _notifyPage(0) : null,
                        ),
                        _pageButton(
                          Icons.chevron_left_rounded,
                          l10n.signPlacerPreviousPage,
                          _pageIndex > 0
                              ? () => _notifyPage(_pageIndex - 1)
                              : null,
                        ),
                        _pageButton(
                          Icons.chevron_right_rounded,
                          l10n.signPlacerNextPage,
                          _pageIndex < _pageCount - 1
                              ? () => _notifyPage(_pageIndex + 1)
                              : null,
                        ),
                        _pageButton(
                          Icons.last_page_rounded,
                          l10n.signPlacerLastPage,
                          _pageIndex < _pageCount - 1
                              ? () => _notifyPage(_pageCount - 1)
                              : null,
                        ),
                        const SizedBox(width: 4),
                      ],

                      // Aspect-ratio lock (corner resize)
                      IconButton(
                        icon: Icon(
                          _lockAspect
                              ? Icons.lock_rounded
                              : Icons.lock_open_rounded,
                        ),
                        isSelected: _lockAspect,
                        tooltip: _lockAspect
                            ? l10n.signPlacerAspectLockedTooltip
                            : l10n.signPlacerAspectFreeTooltip,
                        onPressed: () =>
                            setState(() => _lockAspect = !_lockAspect),
                        iconSize: 18,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                      ),

                      // Image control
                      _buildImageControl(cs),

                      const SizedBox(width: 8),

                      // Reset (real, focusable button)
                      OutlinedButton(
                        onPressed: _resetSigBox,
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          minimumSize: const Size(0, 28),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          shape: const StadiumBorder(),
                          side: BorderSide(color: cs.outlineVariant),
                          backgroundColor: cs.surfaceContainerHigh,
                          foregroundColor: cs.onSurface,
                        ),
                        child: Text(
                          l10n.signPlacerReset,
                          style: AppTheme.monoCaption(cs),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ── Field alignment (only when the PDF has AcroForm sig fields) ──
          if (_sigFields.isNotEmpty) _buildFieldPicker(cs),

          // ── PDF preview ─────────────────────────────────────────────
          Padding(padding: const EdgeInsets.all(16), child: _buildPreview(cs)),
        ],
      ),
    );
  }

  Widget _buildFieldPicker(ColorScheme cs) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OcSectionLabel(l10n.signAlignToFieldLabel),
          const SizedBox(height: 4),
          Text(
            l10n.signAlignToFieldHint(_sigFields.length),
            style: AppTheme.monoCaption(cs),
          ),
          const SizedBox(height: 8),
          ..._sigFields.map(
            (field) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: OcRadioCard(
                title: field.name,
                subtitle: l10n.signPlacerFieldPage(field.pageIndex + 1),
                selected: widget.alignedFieldName == field.name,
                onTap: () => _selectField(field),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Non-interactive amber outline for an existing AcroForm signature
  /// field's rectangle, so the user can see where a form expects a
  /// signature before choosing to align the new signature to it.
  Widget _buildFieldMarker(PdfSignatureFieldInfo field, Size page) {
    final rect = SignatureBoxGeometry.fractionToScreen(
      Rect.fromLTWH(field.x, field.y, field.width, field.height),
      page,
    );
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _kFieldOutlineFill,
            border: Border.all(color: _kFieldOutlineBorder, width: 1.5),
          ),
        ),
      ),
    );
  }

  Widget _buildPreview(ColorScheme cs) {
    final l10n = AppLocalizations.of(context);
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
            l10n.signPlacerPdfError(_error.toString()),
            style: TextStyle(color: cs.error),
          ),
        ),
      );
    }
    final pageSize = _pdfPageSize;
    if (pageSize == null) {
      return SizedBox(
        height: 120,
        child: Center(child: Text(l10n.signPlacerNoPage)),
      );
    }

    // Fit the WHOLE page in the visible area: bounded by the available width
    // and by roughly the viewport height minus the surrounding chrome.
    final maxH = max(240.0, MediaQuery.sizeOf(context).height - 260);

    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = min(
          constraints.maxWidth / pageSize.width,
          maxH / pageSize.height,
        );
        final display = Size(pageSize.width * scale, pageSize.height * scale);
        final doc = _doc!;
        final pageNumber = _pageIndex + 1;

        return Center(
          child: Container(
            width: display.width,
            height: display.height,
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
            child: Stack(
              children: [
                // PDF page (not rebuilt by pointer moves: the overlay keeps
                // its live state in its own subtree).
                Positioned.fill(
                  child: RepaintBoundary(
                    child: PdfPageView(
                      document: doc,
                      pageNumber: pageNumber,
                      alignment: Alignment.center,
                    ),
                  ),
                ),

                // Existing AcroForm signature field rectangles: purely
                // informational, never intercept pointer events.
                for (final field in _sigFields)
                  if (field.pageIndex == _pageIndex)
                    _buildFieldMarker(field, display),

                // Interactive placement box.
                Positioned.fill(
                  child: SignatureBoxOverlay(
                    pageSize: display,
                    fraction: _sigAsFractionRect(),
                    imageData: _effectiveImageData,
                    imageAspect: _imageAspect,
                    lockAspect: _lockAspect,
                    onCommit: _notify,
                    semanticsLabel: l10n.signPlacerAreaSemanticsLabel,
                    signHereLabel: l10n.signPlacerSignHere,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

enum _ImageAction { pick, reset }
