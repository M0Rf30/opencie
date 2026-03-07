// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/l10n/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/color_schemes.dart';
import '../../services/handoff/desktop_handoff_session.dart';
import '../../services/handoff/messages.dart';
import '../../widgets/oc_file_tile.dart';
import '../../widgets/oc_gradient_button.dart';
import '../../widgets/oc_mark.dart';
import '../../widgets/oc_section_label.dart';
import '../../widgets/oc_status_disc.dart';

/// Desktop-side UI for the "Firma con telefono" handoff flow.
///
/// Push this page via [Navigator.of(context).push] and pass the file to be
/// signed. The page drives a [DesktopHandoffSession] from idle through done
/// or error, writing the resulting .p7m file to disk alongside the source.
class DesktopHandoffPage extends StatefulWidget {
  const DesktopHandoffPage({
    super.key,
    required this.filePath,
    this.fileName,
  });

  final String filePath;
  final String? fileName;

  @override
  State<DesktopHandoffPage> createState() => _DesktopHandoffPageState();
}

class _DesktopHandoffPageState extends State<DesktopHandoffPage> {
  late final DesktopHandoffSession _session;
  late final StreamSubscription<DesktopHandoffState> _sub;
  final TextEditingController _pasteCtrl = TextEditingController();

  String? _signedFilePath;
  bool _writingFile = false;

  // ── lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _session = DesktopHandoffSession(filePath: widget.filePath);
    _sub = _session.states.listen((s) {
      if (mounted) setState(() {});
      if (s == DesktopHandoffState.done) _writeSigned();
    });
    Future.microtask(_start);
  }

  Future<void> _start() async {
    try {
      await _session.start();
    } catch (_) {
      // Error state is set internally by the session.
    }
  }

  @override
  void dispose() {
    _sub.cancel();
    _session.dispose();
    _pasteCtrl.dispose();
    super.dispose();
  }

  // ── actions ───────────────────────────────────────────────────────────────

  Future<void> _writeSigned() async {
    if (_writingFile || _signedFilePath != null) return;
    _writingFile = true;
    try {
      final dir = p.dirname(widget.filePath);
      final base = p.basename(widget.filePath);
      final out = File(p.join(dir, '$base.p7m'));
      await out.writeAsBytes(_session.signatureBytes!, flush: true);
      if (mounted) setState(() => _signedFilePath = out.path);
    } catch (_) {
      _writingFile = false;
    }
  }

  Future<void> _acceptQr2(String wire) async {
    try {
      await _session.acceptQr2(wire);
    } catch (_) {}
  }

  Future<void> _sendDescriptor() async {
    try {
      await _session.sendDescriptor();
    } catch (_) {}
  }

  Future<void> _abort([String? reason]) async {
    try {
      await _session.abort(reason);
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _openFile() async {
    if (_signedFilePath == null) return;
    await launchUrl(Uri.file(_signedFilePath!));
  }

  // ── helpers ───────────────────────────────────────────────────────────────

  String get _displayFileName =>
      widget.fileName ?? p.basename(widget.filePath);

  String get _fileSizeKb {
    try {
      return '${(File(widget.filePath).lengthSync() / 1024).round()}';
    } catch (_) {
      return '?';
    }
  }

  // ── scaffold ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => _abort('user_cancel'),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const OcMark(size: 28),
            const SizedBox(width: 10),
            Text('OpenCIE', style: Theme.of(context).textTheme.titleLarge),
          ],
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
                child: _buildBody(context, l10n, cs),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme cs,
  ) {
    switch (_session.state) {
      case DesktopHandoffState.idle:
      case DesktopHandoffState.preparingOffer:
        return _buildLoading(context, l10n, cs);
      case DesktopHandoffState.showingQr:
        return _buildShowQr(context, l10n, cs);
      case DesktopHandoffState.connecting:
        return _buildConnecting(context, l10n, cs);
      case DesktopHandoffState.awaitingSasConfirm:
        return _buildSasConfirm(context, l10n, cs);
      case DesktopHandoffState.descriptorSent:
      case DesktopHandoffState.signing:
        return _buildSigning(context, l10n, cs);
      case DesktopHandoffState.done:
        return _buildDone(context, l10n, cs);
      case DesktopHandoffState.error:
        return _buildError(context, l10n, cs);
    }
  }

  // ── 1. idle / preparingOffer ──────────────────────────────────────────────

  Widget _buildLoading(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme cs,
  ) {
    return Column(
      key: const ValueKey('loading'),
      children: [
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                OcStatusDisc(
                  tone: OcStatusTone.warning,
                  icon: const Icon(
                    Icons.qr_code_2,
                    color: Colors.white,
                    size: 36,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  l10n.handoffStartTitle,
                  style: AppTheme.headlineBold(cs),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                OcMonoText(
                  '$_displayFileName · $_fileSizeKb KB',
                  color: cs.onSurfaceVariant,
                ),
                const SizedBox(height: 24),
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ],
            ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton(
              onPressed: () => _abort('user_cancel'),
              child: Text(l10n.handoffCancel),
            ),
          ],
        ),
      ],
    );
  }

  // ── 2. showingQr ──────────────────────────────────────────────────────────

  Widget _buildShowQr(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme cs,
  ) {
    return Column(
      key: const ValueKey('showingQr'),
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (ctx, constraints) {
              final wide = constraints.maxWidth >= 840;
              final left = _qrLeftPane(l10n, cs);
              final right = _qrRightPane(l10n, cs);

              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: left),
                    const SizedBox(width: 32),
                    Expanded(child: right),
                  ],
                );
              }
              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    left,
                    const SizedBox(height: 32),
                    right,
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            OutlinedButton(
              onPressed: () => _abort('user_cancel'),
              child: Text(l10n.handoffCancel),
            ),
          ],
        ),
      ],
    );
  }

  Widget _qrLeftPane(AppLocalizations l10n, ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.handoffShowQrTitle, style: AppTheme.headlineBold(cs)),
        const SizedBox(height: 8),
        Text(
          l10n.handoffShowQrBody,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            color: cs.onSurface,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
          ),
          child: QrImageView(
            data: _session.qr1Wire!,
            size: 280,
            version: QrVersions.auto,
            errorCorrectionLevel: QrErrorCorrectLevel.M,
          ),
        ),
      ],
    );
  }

  Widget _qrRightPane(AppLocalizations l10n, ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.handoffScanQr2Title, style: AppTheme.headlineBold(cs)),
        const SizedBox(height: 8),
        Text(
          l10n.handoffScanQr2Body,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            color: cs.onSurface,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 20),
        // Webcam scanner — falls back gracefully if no camera is available.
        _ScannerBox(onScan: (wire) => _acceptQr2(wire)),
        const SizedBox(height: 20),
        // Paste fallback
        TextField(
          controller: _pasteCtrl,
          maxLines: 3,
          decoration: InputDecoration(
            hintText: l10n.handoffPasteQr2Hint,
            filled: true,
            fillColor: cs.surfaceContainerHigh,
          ),
        ),
        const SizedBox(height: 8),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _pasteCtrl,
          builder: (_, value, _) => OcGradientButton(
            label: l10n.commonConfirm,
            onPressed: value.text.trim().isNotEmpty
                ? () => _acceptQr2(_pasteCtrl.text.trim())
                : null,
            expand: false,
          ),
        ),
      ],
    );
  }

  // ── 3. connecting ─────────────────────────────────────────────────────────

  Widget _buildConnecting(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme cs,
  ) {
    return Column(
      key: const ValueKey('connecting'),
      children: [
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                OcStatusDisc(
                  tone: OcStatusTone.warning,
                  icon: const Icon(
                    Icons.cloud_sync_outlined,
                    color: Colors.white,
                    size: 36,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  l10n.handoffWaitingForPhone,
                  style: AppTheme.headlineBold(cs),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                OcMonoText(
                  'STUN · DataChannel · AEAD',
                  color: cs.onSurfaceVariant,
                ),
                const SizedBox(height: 24),
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── 4. awaitingSasConfirm ─────────────────────────────────────────────────

  Widget _buildSasConfirm(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme cs,
  ) {
    final words = _session.sasWords ?? const <String>[];

    return Column(
      key: const ValueKey('sasConfirm'),
      children: [
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.handoffSasConfirmTitle,
                    style: AppTheme.headlineBold(cs),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.handoffSasConfirmBody,
                    style: AppTheme.monoBody(cs, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 20),
                  // SAS word panel
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: ColorSchemes.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: ColorSchemes.primary.withValues(alpha: 0.32),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        for (var i = 0; i < words.length; i++) ...[
                          if (i > 0) const SizedBox(width: 24),
                          Flexible(
                            child: Text(
                              words[i],
                              style: const TextStyle(
                                fontFamily: 'JetBrainsMono',
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.0,
                                color: ColorSchemes.primary,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _abort('sas_mismatch'),
                          child: Text(l10n.handoffSasConfirmMismatch),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OcGradientButton(
                          label: l10n.handoffSasConfirmMatch,
                          onPressed: _sendDescriptor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.handoffSafetyWarning,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      color: cs.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── 5. descriptorSent / signing ───────────────────────────────────────────

  Widget _buildSigning(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme cs,
  ) {
    final isSigning = _session.state == DesktopHandoffState.signing;
    final label =
        isSigning ? l10n.handoffSigning : l10n.handoffWaitingForPin;

    return Column(
      key: const ValueKey('signing'),
      children: [
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    OcDiscHalo(size: 120, color: ColorSchemes.accent),
                    OcStatusDisc(
                      tone: OcStatusTone.warning,
                      icon: const Icon(
                        Icons.lock_clock_outlined,
                        color: Colors.white,
                        size: 36,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Text(
                  label,
                  style: AppTheme.headlineBold(cs),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── 6. done ───────────────────────────────────────────────────────────────

  Widget _buildDone(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme cs,
  ) {
    final desc = _session.descriptor;

    return Column(
      key: const ValueKey('done'),
      children: [
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    OcDiscHalo(size: 120, color: ColorSchemes.valid),
                    OcStatusDisc(
                      tone: OcStatusTone.valid,
                      icon: const Icon(
                        Icons.check,
                        color: Colors.white,
                        size: 36,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Text(
                  l10n.handoffSignedReceived,
                  style: AppTheme.displayBold(cs),
                  textAlign: TextAlign.center,
                ),
                if (desc != null) ...[
                  const SizedBox(height: 20),
                  _DescriptorChip(descriptor: desc, cs: cs),
                ],
                const SizedBox(height: 32),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    OcGradientButton(
                      label: l10n.signOpenButton,
                      icon: Icons.open_in_new,
                      onPressed: _signedFilePath != null ? _openFile : null,
                      expand: false,
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.shield_outlined),
                      label: Text(l10n.verifyVerifyButton),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── 7. error ──────────────────────────────────────────────────────────────

  Widget _buildError(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme cs,
  ) {
    return Column(
      key: const ValueKey('error'),
      children: [
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                OcStatusDisc(
                  tone: OcStatusTone.invalid,
                  icon: const Icon(
                    Icons.error_outline,
                    color: Colors.white,
                    size: 36,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  l10n.handoffError,
                  style: AppTheme.headlineBold(cs),
                  textAlign: TextAlign.center,
                ),
                if (_session.errorMessage != null) ...[
                  const SizedBox(height: 8),
                  OcMonoText(
                    _session.errorMessage!,
                    color: cs.onSurfaceVariant,
                  ),
                ],
              ],
            ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.handoffCancel),
            ),
            const SizedBox(width: 12),
            OcGradientButton(
              label: l10n.handoffRetry,
              onPressed: () => Navigator.of(context).pop(),
              expand: false,
            ),
          ],
        ),
      ],
    );
  }
}

// ── Private widgets ──────────────────────────────────────────────────────────

/// Webcam QR scanner box. Gracefully degrades when no camera is available.
class _ScannerBox extends StatefulWidget {
  const _ScannerBox({required this.onScan});

  final void Function(String wire) onScan;

  @override
  State<_ScannerBox> createState() => _ScannerBoxState();
}

class _ScannerBoxState extends State<_ScannerBox> {
  // mobile_scanner only supports Android, iOS, macOS, and web.
  // On Linux/Windows the plugin throws MissingPluginException at runtime,
  // so skip controller construction and render the fallback box.
  static bool get _platformSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  MobileScannerController? _ctrl;
  bool _hasError = false;
  bool _scanned = false;

  @override
  void initState() {
    super.initState();
    if (!_platformSupported) {
      _hasError = true;
      return;
    }
    try {
      _ctrl = MobileScannerController();
    } catch (_) {
      _hasError = true;
    }
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_hasError || _ctrl == null) {
      return _errorBox(cs);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: 320,
        height: 320,
        child: MobileScanner(
          controller: _ctrl!,
          errorBuilder: (_, error) {
            // Schedule state update outside of build.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && !_hasError) {
                setState(() => _hasError = true);
              }
            });
            return _errorBox(cs);
          },
          onDetect: (capture) {
            if (_scanned) return;
            final raw = capture.barcodes.firstOrNull?.rawValue;
            if (raw != null && raw.isNotEmpty && raw.startsWith('{')) {
              _scanned = true;
              _ctrl?.stop();
              widget.onScan(raw);
            }
          },
        ),
      ),
    );
  }

  Widget _errorBox(ColorScheme cs) {
    return Container(
      width: 320,
      height: 320,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.no_photography_outlined,
            size: 36,
            color: cs.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            'Webcam non disponibile',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              color: cs.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Compact file chip shown in the done state. Displays the document name,
/// size, page count (if known) and a truncated SHA-256 fingerprint.
class _DescriptorChip extends StatelessWidget {
  const _DescriptorChip({required this.descriptor, required this.cs});

  final DescriptorPayload descriptor;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    final rawExt = p.extension(descriptor.fileName).replaceFirst('.', '');
    final ext = rawExt.isEmpty ? 'p7m' : rawExt;
    final sizeKb = (descriptor.byteSize / 1024).round();
    final sha = descriptor.sha256Hex;
    final shaShort = sha.length >= 8
        ? '${sha.substring(0, 4)}…${sha.substring(sha.length - 4)}'
        : sha;

    final sizeLine = descriptor.pageCount != null
        ? '$sizeKb KB · ${descriptor.pageCount} pagine'
        : '$sizeKb KB';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          OcFileTile(extension: ext),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                descriptor.fileName,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              OcMonoText(sizeLine, color: cs.onSurfaceVariant),
              OcMonoText(shaShort, color: cs.onSurfaceVariant, fontSize: 11),
            ],
          ),
        ],
      ),
    );
  }
}
