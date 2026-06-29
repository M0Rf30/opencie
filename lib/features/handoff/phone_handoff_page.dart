// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/constants/app_constants.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/l10n/app_localizations_ext.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/color_schemes.dart';
import '../../ffi/opencie_pkcs11.dart';
import '../../services/handoff/messages.dart';
import '../../services/handoff/phone_handoff_session.dart';
import '../../widgets/nfc_card_dialog.dart';
import '../../widgets/oc_file_tile.dart';
import '../../widgets/oc_gradient_button.dart';
import '../../widgets/oc_mark.dart';
import '../../widgets/oc_section_label.dart';
import '../../widgets/oc_status_disc.dart';

/// Phone-side screen for the QR desktop-signing handoff.
///
/// Full-screen flow: scan QR1 → show QR2 → confirm SAS → approve document
/// → sign with CIE → done.
class PhoneHandoffPage extends StatefulWidget {
  const PhoneHandoffPage({super.key});

  @override
  State<PhoneHandoffPage> createState() => _PhoneHandoffPageState();
}

class _PhoneHandoffPageState extends State<PhoneHandoffPage> {
  // ── Session & subscription (non-final so retry can replace them) ──────────
  PhoneHandoffSession _session = PhoneHandoffSession();
  StreamSubscription<PhoneHandoffState>? _sub;

  // ── UI state ──────────────────────────────────────────────────────────────
  bool _sasConfirmed = false;

  /// Guard against double-firing the QR1 scanner callback.
  bool _qrScanned = false;

  @override
  void initState() {
    super.initState();
    _listenSession();
  }

  void _listenSession() {
    _sub?.cancel();
    _sub = _session.states.listen((s) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _session.dispose();
    super.dispose();
  }

  // ── QR1 scan ──────────────────────────────────────────────────────────────

  Future<void> _onQr1Detected(String raw) async {
    if (_qrScanned) return;
    if (!raw.startsWith('{')) return;
    setState(() => _qrScanned = true);
    try {
      await _session.startFromQr1(raw);
    } catch (_) {
      // _session transitions to error; setState in listener rebuilds.
    }
  }

  // ── PIN dialog ────────────────────────────────────────────────────────────

  Future<String?> _showPinDialog() async {
    final l10n = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final controller = TextEditingController();

    try {
      return await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx, setS) {
              final ready = controller.text.length == 8;
              return AlertDialog(
                backgroundColor: cs.surfaceContainer,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                actionsPadding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    OcSectionLabel('PIN CIE'),
                    const SizedBox(height: 8),
                    Text(
                      l10n.signEnterPinTitle,
                      style: AppTheme.headlineBold(cs).copyWith(fontSize: 20),
                    ),
                  ],
                ),
                content: TextFormField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  autofocus: true,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(8),
                  ],
                  onChanged: (_) => setS(() {}),
                  onFieldSubmitted: (v) {
                    if (v.length == 8) Navigator.pop(ctx, v);
                  },
                  decoration: InputDecoration(
                    hintText: '••••••••',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                actions: [
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: Text(l10n.handoffCancel),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OcGradientButton(
                          label: l10n.handoffSasConfirmMatch,
                          onPressed: ready
                              ? () => Navigator.pop(ctx, controller.text)
                              : null,
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      controller.dispose();
    }
  }

  // ── Sign helpers ──────────────────────────────────────────────────────────

  String _signatureTypeForMime(String? mimeType) {
    if (mimeType == null) return AppConstants.formatCades;
    final m = mimeType.toLowerCase();
    if (m.contains('pdf')) return AppConstants.formatPades;
    if (m.contains('xml')) return AppConstants.formatXades;
    return AppConstants.formatCades;
  }

  Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }

  Future<void> _runSign(DescriptorPayload descriptor) async {
    final l10n = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;

    // 1. PIN dialog
    final pin = await _showPinDialog();
    if (pin == null) return;

    // 2. NFC dialog
    final nfcNotifier = ValueNotifier<(bool, double, String)>((true, 0.0, ''));
    bool dialogOpen = true;

    void closeDialog() {
      if (dialogOpen && mounted) {
        dialogOpen = false;
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    if (!mounted) {
      nfcNotifier.dispose();
      return;
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => NfcCardDialog(
        notifier: nfcNotifier,
        processingTitle: l10n.handoffSigning,
        onCancel: () {
          dialogOpen = false;
          Navigator.pop(ctx);
          _session.abort('user_cancelled');
          if (mounted) Navigator.pop(context);
        },
      ),
    ).whenComplete(() => dialogOpen = false);

    try {
      // 3. Determine signature format and write hash bytes to temp input file
      final signatureType = _signatureTypeForMime(descriptor.mimeType);
      final tempDir = await getTemporaryDirectory();
      final hashBytes = _hexToBytes(descriptor.sha256Hex);
      final inputPath = '${tempDir.path}/handoff_input.bin';
      final outputPath = '${tempDir.path}/handoff_signed.$signatureType';
      await File(inputPath).writeAsBytes(hashBytes);

      // 4. Drive the CIE card
      nfcNotifier.value = (true, 0.0, '');
      final result = await OpenCiePkcs11.instance.sign(
        inputPath: inputPath,
        outputPath: outputPath,
        signatureType: signatureType,
        pin: pin,
        pan: '',
        onProgress: (p) {
          nfcNotifier.value = (
            false,
            p.percent / 100.0,
            l10n.localizeProgress(p.message),
          );
        },
      );

      closeDialog();
      nfcNotifier.dispose();

      if (!mounted) return;

      if (result.isSuccess) {
        // 5. Submit signature to desktop
        final cmsBytes = await File(outputPath).readAsBytes();
        await _session.markPinOk();

        final format = switch (signatureType) {
          AppConstants.formatPades => 'pades-b-t',
          AppConstants.formatXades => 'xades-bes',
          _ => 'cades-bes',
        };
        await _session.submitSignature(cmsBytes: cmsBytes, format: format);

        if (mounted) setState(() {});
      } else if (result.isPinIncorrect) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                result.remainingAttempts != null
                    ? l10n.signIncorrectPinWithAttempts(
                        result.remainingAttempts!,
                      )
                    : l10n.signIncorrectPin,
              ),
              behavior: SnackBarBehavior.floating,
              backgroundColor: cs.error,
            ),
          );
        }
      } else if (result.isPinLocked) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.signPinLocked),
              behavior: SnackBarBehavior.floating,
              backgroundColor: cs.error,
            ),
          );
        }
        await _session.abort('pin_locked');
      } else {
        await _session.abort('signing_failed');
      }
    } catch (e) {
      closeDialog();
      nfcNotifier.dispose();
      try {
        await _session.abort('signing_failed');
      } catch (_) {}
      if (mounted) {
        final cs2 = Theme.of(context).colorScheme;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${l10n.handoffError}: $e'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: cs2.error,
          ),
        );
      }
    }
  }

  // ── Retry: replace session object ─────────────────────────────────────────

  void _retry() {
    _sub?.cancel();
    _session.dispose();
    setState(() {
      _session = PhoneHandoffSession();
      _sasConfirmed = false;
      _qrScanned = false;
    });
    _listenSession();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () {
            _session.abort('user_dismissed');
            Navigator.pop(context);
          },
          tooltip: l10n.handoffCancel,
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const OcMark(size: 24),
            const SizedBox(width: 8),
            Text(
              'OpenCIE',
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w700,
                fontSize: 15,
                color: cs.onSurface,
              ),
            ),
          ],
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
                child: _buildBody(l10n, cs),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(AppLocalizations l10n, ColorScheme cs) {
    final state = _session.state;

    // SAS confirmation has priority over state-based dispatch until confirmed.
    if (!_sasConfirmed &&
        (state == PhoneHandoffState.awaitingSasConfirm ||
            state == PhoneHandoffState.descriptorReceived)) {
      return _buildAwaitingSas(l10n, cs);
    }

    return switch (state) {
      PhoneHandoffState.idle => _buildIdle(l10n, cs),
      PhoneHandoffState.preparingAnswer => _buildPreparingAnswer(l10n, cs),
      PhoneHandoffState.showingQr => _buildShowingQr(l10n, cs),
      // _sasConfirmed is true here; wait for descriptor frame
      PhoneHandoffState.awaitingSasConfirm => _buildPreparingAnswer(l10n, cs),
      PhoneHandoffState.descriptorReceived => _buildDescriptorPreview(l10n, cs),
      PhoneHandoffState.signing => _buildSigningOrDone(l10n, cs, signing: true),
      PhoneHandoffState.done => _buildSigningOrDone(l10n, cs, signing: false),
      PhoneHandoffState.error => _buildError(l10n, cs),
    };
  }

  // ── State 1: Idle — QR1 scanner ──────────────────────────────────────────

  Widget _buildIdle(AppLocalizations l10n, ColorScheme cs) {
    return SingleChildScrollView(
      key: const ValueKey('idle'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 8),
          Text(
            l10n.handoffPhoneScanTitle,
            style: AppTheme.headlineBold(cs),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.handoffPhoneScanBody,
            style: TextStyle(
              fontFamily: 'Inter',
              color: cs.onSurfaceVariant,
              fontSize: 14,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),

          // ── Camera viewfinder ─────────────────────────────────────────────
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: SizedBox(
              width: 320,
              height: 320,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  MobileScanner(
                    controller: MobileScannerController(),
                    onDetect: (capture) {
                      for (final barcode in capture.barcodes) {
                        final raw = barcode.rawValue;
                        if (raw != null && raw.isNotEmpty) {
                          _onQr1Detected(raw);
                          return;
                        }
                      }
                    },
                  ),
                  // Brand mark overlay
                  const Positioned(top: 12, right: 12, child: OcMark(size: 28)),
                ],
              ),
            ),
          ),

          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.handoffCancel),
            ),
          ),
        ],
      ),
    );
  }

  // ── State 2: Preparing answer — spinner ──────────────────────────────────

  Widget _buildPreparingAnswer(AppLocalizations l10n, ColorScheme cs) {
    return Column(
      key: const ValueKey('preparing'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 20),
        Text(
          'Preparazione…',
          style: AppTheme.headlineBold(cs),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  // ── State 3: Showing QR2 ─────────────────────────────────────────────────

  Widget _buildShowingQr(AppLocalizations l10n, ColorScheme cs) {
    final qr2 = _session.qr2Wire ?? '';

    return SingleChildScrollView(
      key: const ValueKey('showingQr'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 8),
          Text(
            l10n.handoffPhoneShowQr2Title,
            style: AppTheme.headlineBold(cs),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.handoffPhoneShowQr2Body,
            style: TextStyle(
              fontFamily: 'Inter',
              color: cs.onSurfaceVariant,
              fontSize: 14,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),

          // ── QR code card ──────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.10),
                  blurRadius: 24,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: QrImageView(
              data: qr2,
              size: 280,
              version: QrVersions.auto,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
            ),
          ),

          const SizedBox(height: 16),

          // Copy button
          OutlinedButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: qr2));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(l10n.handoffPhoneCopiedQr2),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            icon: const Icon(Icons.copy_all_outlined, size: 16),
            label: Text(l10n.handoffPhoneCopyQr2),
          ),

          const SizedBox(height: 24),
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          OcMonoText(
            'In attesa del computer…',
            color: cs.onSurfaceVariant,
            fontSize: 12,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // ── State 4: SAS confirmation ────────────────────────────────────────────

  Widget _buildAwaitingSas(AppLocalizations l10n, ColorScheme cs) {
    final words = _session.sasWords ?? ['—', '—', '—', '—'];

    return SingleChildScrollView(
      key: const ValueKey('sas'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 8),
          OcSectionLabel('SICUREZZA'),
          const SizedBox(height: 12),
          Text(
            l10n.handoffSasConfirmTitle,
            style: AppTheme.headlineBold(cs),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.handoffSasConfirmBody,
            style: TextStyle(
              fontFamily: 'Inter',
              color: cs.onSurfaceVariant,
              fontSize: 14,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),

          // ── Safety warning strip ──────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: ColorSchemes.accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: ColorSchemes.accent.withValues(alpha: 0.30),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.shield_outlined,
                  color: ColorSchemes.accent,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.handoffSafetyWarning,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // ── SAS word pill ─────────────────────────────────────────────────
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
            child: Wrap(
              spacing: 24,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: words
                  .map(
                    (w) => Text(
                      w,
                      style: const TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: ColorSchemes.primary,
                        letterSpacing: 1.0,
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),

          const SizedBox(height: 28),

          // ── Action buttons ────────────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    _session.abort('sas_mismatch');
                    Navigator.pop(context);
                  },
                  child: Text(
                    l10n.handoffSasConfirmMismatch,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OcGradientButton(
                  label: l10n.handoffSasConfirmMatch,
                  onPressed: () => setState(() => _sasConfirmed = true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── State 5: Descriptor preview ──────────────────────────────────────────

  Widget _buildDescriptorPreview(AppLocalizations l10n, ColorScheme cs) {
    final d = _session.descriptor!;
    final ext = d.fileName.contains('.')
        ? d.fileName.split('.').last.toLowerCase()
        : 'bin';
    final shortSha = d.sha256Hex.length >= 16
        ? '${d.sha256Hex.substring(0, 8)}…'
              '${d.sha256Hex.substring(d.sha256Hex.length - 8)}'
        : d.sha256Hex;
    final sizeKb = d.byteSize ~/ 1024;
    final pageInfo = d.pageCount != null ? '${d.pageCount} pagine' : '— pagine';

    return SingleChildScrollView(
      key: const ValueKey('descriptor'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Text(
            l10n.handoffPhoneDocumentPreviewTitle,
            style: AppTheme.headlineBold(cs),
          ),
          const SizedBox(height: 20),

          // ── Document card ─────────────────────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Optional thumbnail
                  if (d.thumbnailPng != null) ...[
                    Center(
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: cs.outlineVariant),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(
                            d.thumbnailPng!,
                            fit: BoxFit.contain,
                            height: 200,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // File info row
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      OcFileTile(extension: ext, width: 38, height: 46),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              d.fileName,
                              style: const TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            OcMonoText(
                              '$sizeKb KB · $pageInfo',
                              fontSize: 11,
                              color: cs.onSurfaceVariant,
                            ),
                            const SizedBox(height: 2),
                            OcMonoText(
                              'sha256: $shortSha',
                              fontSize: 11,
                              color: cs.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 28),

          // ── Action buttons ────────────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    _session.abort('user_cancelled');
                    Navigator.pop(context);
                  },
                  child: Text(l10n.handoffCancel),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OcGradientButton(
                  label: l10n.handoffPhoneDocumentSignPrompt,
                  icon: Icons.fingerprint,
                  onPressed: () => _runSign(d),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── State 6/7: Signing / Done ────────────────────────────────────────────

  Widget _buildSigningOrDone(
    AppLocalizations l10n,
    ColorScheme cs, {
    required bool signing,
  }) {
    final tone = signing ? OcStatusTone.warning : OcStatusTone.valid;
    final haloColor = signing ? ColorSchemes.primary : ColorSchemes.valid;

    return Column(
      key: ValueKey(signing ? 'signing' : 'done'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            OcDiscHalo(size: 120, color: haloColor),
            OcStatusDisc(
              tone: tone,
              icon: Icon(
                signing ? Icons.fingerprint : Icons.check_rounded,
                color: Colors.white,
                size: 36,
              ),
              size: 92,
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          signing ? l10n.handoffSigning : l10n.handoffPaired,
          style: AppTheme.displayBold(cs),
          textAlign: TextAlign.center,
        ),
        if (signing) ...[
          const SizedBox(height: 16),
          const CircularProgressIndicator(),
        ],
        if (!signing) ...[
          const SizedBox(height: 28),
          OcGradientButton(
            label: l10n.commonClose,
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ],
    );
  }

  // ── State 8: Error ───────────────────────────────────────────────────────

  Widget _buildError(AppLocalizations l10n, ColorScheme cs) {
    return Column(
      key: const ValueKey('error'),
      mainAxisSize: MainAxisSize.min,
      children: [
        OcStatusDisc(
          tone: OcStatusTone.invalid,
          icon: const Icon(Icons.close_rounded, color: Colors.white, size: 36),
          size: 92,
        ),
        const SizedBox(height: 20),
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
            fontSize: 12,
          ),
        ],
        const SizedBox(height: 28),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: Text(l10n.handoffCancel),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OcGradientButton(
                label: l10n.handoffRetry,
                onPressed: _retry,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
