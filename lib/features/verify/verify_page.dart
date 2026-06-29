// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:dotted_border/dotted_border.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/color_schemes.dart';
import '../../ffi/models/verify_info.dart';
import '../../ffi/opencie_pkcs11.dart';
import '../../providers/recent_files_provider.dart';
import '../../widgets/oc_action_row.dart';
import '../../widgets/oc_file_tile.dart';
import '../../widgets/oc_gradient_button.dart';
import '../../widgets/oc_help_sheet.dart';
import '../../widgets/oc_section_label.dart';
import '../../widgets/oc_status_disc.dart';

// ---------------------------------------------------------------------------
// Public page — API unchanged
// ---------------------------------------------------------------------------

class VerifyPage extends ConsumerStatefulWidget {
  const VerifyPage({super.key});

  @override
  ConsumerState<VerifyPage> createState() => _VerifyPageState();
}

class _VerifyPageState extends ConsumerState<VerifyPage> {
  String? _selectedFile;
  List<VerifyInfo>? _results;
  bool _isVerifying = false;
  bool _isDragging = false;

  // ── File picking (unchanged FFI layer) ────────────────────────────────────

  Future<void> _pickFile() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: false,
      type: Platform.isAndroid ? FileType.any : FileType.custom,
      allowedExtensions: Platform.isAndroid
          ? null
          : const ['pdf', 'p7m', 'p7s', 'xml'],
    );
    if (result != null && result.paths.isNotEmpty) {
      final path = result.paths.first;
      if (path != null) _setFile(path);
    }
  }

  void _setFile(String path) {
    setState(() {
      _selectedFile = path;
      _results = null;
    });
  }

  Future<void> _verifyPath(String path) async {
    setState(() {
      _selectedFile = path;
      _results = null;
      _isVerifying = true;
    });
    await _runVerify(path);
  }

  Future<void> _verify() async {
    if (_selectedFile == null) return;
    setState(() => _isVerifying = true);
    await _runVerify(_selectedFile!);
  }

  Future<void> _extractP7m() async {
    final l10n = AppLocalizations.of(context);
    final file = _selectedFile;
    if (file == null || !file.toLowerCase().endsWith('.p7m')) return;
    final outputPath = file.substring(0, file.length - 4);
    try {
      final result = await OpenCiePkcs11.instance.extractP7m(
        inputPath: file,
        outputPath: outputPath,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.isSuccess
                  ? l10n.verifyExtractSuccess
                  : l10n.verifyExtractFailed,
            ),
            behavior: SnackBarBehavior.floating,
            backgroundColor: result.isSuccess
                ? null
                : Theme.of(context).colorScheme.error,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        final l10nInner = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10nInner.verifyExtractionError(e.toString())),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _runVerify(String path) async {
    try {
      final results = await OpenCiePkcs11.instance.verify(inputPath: path);
      if (mounted) {
        ref.read(recentFilesProvider.notifier).add(path);
        setState(() {
          _isVerifying = false;
          _results = results;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isVerifying = false);
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.verifyError(e.toString())),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    ref.listen(pendingVerifyFileProvider, (_, next) {
      if (next != null) {
        ref.read(pendingVerifyFileProvider.notifier).set(null);
        _verifyPath(next);
      }
    });

    // If we have results, show the result hero.
    if (_results != null && _results!.isNotEmpty) {
      final allValid = _results!.every((r) => r.isFullyValid);
      if (allValid) {
        return _BVerifyScreen(
          results: _results!,
          filePath: _selectedFile ?? '',
          onBack: () => setState(() {
            _results = null;
          }),
          onExtractP7m: (_selectedFile?.toLowerCase().endsWith('.p7m') ?? false)
              ? _extractP7m
              : null,
        );
      } else {
        return _BInvalidScreen(
          results: _results!,
          filePath: _selectedFile ?? '',
          onBack: () => setState(() {
            _results = null;
          }),
          onExtractP7m: (_selectedFile?.toLowerCase().endsWith('.p7m') ?? false)
              ? _extractP7m
              : null,
        );
      }
    }

    // No-result / empty-result: show landing page.
    return _BLandingPage(
      selectedFile: _selectedFile,
      isVerifying: _isVerifying,
      isDragging: _isDragging,
      onPickFile: _pickFile,
      onVerify: _verify,
      onExtractP7m: (_selectedFile?.toLowerCase().endsWith('.p7m') ?? false)
          ? _extractP7m
          : null,
      onSetFile: _setFile,
      onVerifyPath: _verifyPath,
      onDragEntered: () => setState(() => _isDragging = true),
      onDragExited: () => setState(() => _isDragging = false),
      onDragDone: (path) {
        setState(() => _isDragging = false);
        _setFile(path);
      },
      onClearFile: () => setState(() {
        _selectedFile = null;
        _results = null;
      }),
    );
  }
}

// ---------------------------------------------------------------------------
// B — Landing page (no result yet)
// ---------------------------------------------------------------------------

class _BLandingPage extends ConsumerWidget {
  const _BLandingPage({
    required this.selectedFile,
    required this.isVerifying,
    required this.isDragging,
    required this.onPickFile,
    required this.onVerify,
    required this.onExtractP7m,
    required this.onSetFile,
    required this.onVerifyPath,
    required this.onDragEntered,
    required this.onDragExited,
    required this.onDragDone,
    required this.onClearFile,
  });

  final String? selectedFile;
  final bool isVerifying;
  final bool isDragging;
  final VoidCallback onPickFile;
  final VoidCallback onVerify;
  final VoidCallback? onExtractP7m;
  final void Function(String) onSetFile;
  final void Function(String) onVerifyPath;
  final VoidCallback onDragEntered;
  final VoidCallback onDragExited;
  final void Function(String) onDragDone;
  final VoidCallback onClearFile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final recent = ref.watch(recentFilesProvider);
    final fileName = selectedFile?.split('/').last;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // ── Page heading ──────────────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 8, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.verifyTitle, style: AppTheme.displayBold(cs)),
                        const SizedBox(height: 6),
                        Text(
                          l10n.verifySubtitleFull,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 13,
                            fontWeight: FontWeight.w400,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.info_outline_rounded),
                    tooltip: l10n.helpButtonTooltip,
                    onPressed: () => OcHelpSheet.show(
                      context,
                      OcHelpSheet(
                        title: l10n.helpVerifyTitle,
                        icon: Icons.verified_rounded,
                        iconColor: cs.secondary,
                        steps: [
                          OcHelpStep(
                            title: l10n.helpVerifyStep1Title,
                            body: l10n.helpVerifyStep1Body,
                            icon: Icons.upload_file_rounded,
                          ),
                          OcHelpStep(
                            title: l10n.helpVerifyStep2Title,
                            body: l10n.helpVerifyStep2Body,
                            icon: Icons.fact_check_rounded,
                          ),
                          OcHelpStep(
                            title: l10n.helpVerifyStep3Title,
                            body: l10n.helpVerifyStep3Body,
                            icon: Icons.unarchive_rounded,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 24)),

          // ── Drop zone ─────────────────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _DropZone(
                fileName: fileName,
                isDragging: isDragging,
                isVerifying: isVerifying,
                onPickFile: onPickFile,
                onDragEntered: onDragEntered,
                onDragExited: onDragExited,
                onDragDone: onDragDone,
                onClearFile: onClearFile,
                l10n: l10n,
              ),
            ),
          ),

          // ── Action buttons ────────────────────────────────────────────────
          if (selectedFile != null) ...[
            const SliverToBoxAdapter(child: SizedBox(height: 14)),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    OcGradientButton(
                      label: isVerifying ? '…' : l10n.verifyVerifyButton,
                      icon: isVerifying ? null : Icons.verified_user_rounded,
                      onPressed: isVerifying ? null : onVerify,
                    ),
                    if (onExtractP7m != null) ...[
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: onExtractP7m,
                          icon: const Icon(Icons.unarchive_rounded, size: 18),
                          label: Text(l10n.verifyExtractP7mButton),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],

          // ── Recent files ──────────────────────────────────────────────────
          if (recent.isNotEmpty) ...[
            const SliverToBoxAdapter(child: SizedBox(height: 28)),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    OcSectionLabel(l10n.verifyRecentlyVerified),
                    const Spacer(),
                    GestureDetector(
                      onTap: () =>
                          ref.read(recentFilesProvider.notifier).clear(),
                      child: Text(
                        l10n.commonClear,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          color: cs.error,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 10)),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: OcGroupCard(
                  children: [
                    for (final file in recent)
                      OcActionRow(
                        leading: OcFileTile(
                          extension: file.extension,
                          width: 32,
                          height: 38,
                        ),
                        title: file.fileName,
                        subtitle: _formatRelative(file.addedAt, l10n),
                        subtitleMono: true,
                        onTap: () => onVerifyPath(file.path),
                      ),
                  ],
                ),
              ),
            ),
          ],

          const SliverToBoxAdapter(child: SizedBox(height: 36)),
        ],
      ),
    );
  }

  String _formatRelative(DateTime dt, AppLocalizations l10n) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return l10n.commonJustNow;
    if (diff.inMinutes < 60) return l10n.commonMinutesAgo(diff.inMinutes);
    if (diff.inHours < 24) return l10n.commonHoursAgo(diff.inHours);
    if (diff.inDays < 7) return l10n.commonDaysAgo(diff.inDays);
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}

// ---------------------------------------------------------------------------
// B — Valid result screen
// ---------------------------------------------------------------------------

class _BVerifyScreen extends StatelessWidget {
  const _BVerifyScreen({
    required this.results,
    required this.filePath,
    required this.onBack,
    this.onExtractP7m,
  });

  final List<VerifyInfo> results;
  final String filePath;
  final VoidCallback onBack;
  final VoidCallback? onExtractP7m;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final result = results.first;
    return Scaffold(
      body: _ResultScaffold(
        heroColor: ColorSchemes.valid,
        onBack: onBack,
        disc: OcStatusDisc(
          tone: OcStatusTone.valid,
          icon: Icon(
            Icons.check_rounded,
            color: Colors.white,
            size: _discIconSize,
          ),
          size: 92,
        ),
        titleText: l10n.verifyValid,
        subtitleText: _buildSubtitle(result, l10n),
        detailPanel: _ValidDetailPanel(
          result: result,
          filePath: filePath,
          onExtractP7m: onExtractP7m,
        ),
        result: result,
        signerCount: results.length,
      ),
    );
  }

  static String _buildSubtitle(VerifyInfo r, AppLocalizations l10n) {
    final parts = <String>[];
    if (r.isSignatureValid) parts.add('PAdES');
    parts.add('SHA-256/RSA');
    final ocspLabel = switch (r.certRevocationStatus) {
      0 => l10n.verifyOcspGood,
      1 => l10n.verifyOcspRevoked,
      2 => l10n.verifyOcspSuspended,
      _ => l10n.verifyOcspUpdated,
    };
    parts.add(ocspLabel);
    return parts.join(' · ');
  }
}

// ---------------------------------------------------------------------------
// B — Invalid result screen
// ---------------------------------------------------------------------------

class _BInvalidScreen extends StatelessWidget {
  const _BInvalidScreen({
    required this.results,
    required this.filePath,
    required this.onBack,
    this.onExtractP7m,
  });

  final List<VerifyInfo> results;
  final String filePath;
  final VoidCallback onBack;
  final VoidCallback? onExtractP7m;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final result = results.first;
    return Scaffold(
      body: _ResultScaffold(
        heroColor: ColorSchemes.invalid,
        onBack: onBack,
        disc: _ShakeOnAppear(
          child: OcStatusDisc(
            tone: OcStatusTone.invalid,
            icon: Icon(
              Icons.close_rounded,
              color: Colors.white,
              size: _discIconSize,
            ),
            size: 92,
          ),
        ),
        titleText: l10n.verifyInvalid,
        subtitleText: l10n.verifyInvalidSubtitle,
        detailPanel: _InvalidDetailPanel(
          result: result,
          filePath: filePath,
          onExtractP7m: onExtractP7m,
        ),
        result: result,
        signerCount: results.length,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared result scaffold (hero + scrollable detail)
// ---------------------------------------------------------------------------

const double _discIconSize = 36.0;

class _ResultScaffold extends StatelessWidget {
  const _ResultScaffold({
    required this.heroColor,
    required this.onBack,
    required this.disc,
    required this.titleText,
    required this.subtitleText,
    required this.detailPanel,
    required this.result,
    required this.signerCount,
  });

  final Color heroColor;
  final VoidCallback onBack;
  final Widget disc;
  final String titleText;
  final String subtitleText;
  final Widget detailPanel;
  final VerifyInfo result;
  final int signerCount;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mq = MediaQuery.of(context);
    final l10n = AppLocalizations.of(context);

    return CustomScrollView(
      slivers: [
        // ── Hero ──────────────────────────────────────────────────────
        SliverToBoxAdapter(
          child: Stack(
            children: [
              // Radial gradient backdrop
              Container(
                height: 300 + mq.padding.top,
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -1),
                    radius: 1.2,
                    colors: [
                      heroColor.withValues(alpha: 0.22),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),

              // Content
              Padding(
                padding: EdgeInsets.fromLTRB(20, mq.padding.top + 12, 20, 0),
                child: Column(
                  children: [
                    // ── Top action row ─────────────────────────────────
                    Row(
                      children: [
                        _IconBtn(
                          icon: Icons.chevron_left_rounded,
                          onTap: onBack,
                        ),
                        const Spacer(),
                        OcSectionLabel(l10n.verifyReportLabel),
                        const Spacer(),
                        PopupMenuButton<String>(
                          icon: Icon(
                            Icons.more_vert_rounded,
                            size: 22,
                            color: cs.onSurface,
                          ),
                          style: ButtonStyle(
                            backgroundColor: WidgetStatePropertyAll(
                              cs.surfaceContainerHigh.withValues(alpha: 0.70),
                            ),
                            shape: WidgetStatePropertyAll(
                              RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            fixedSize: const WidgetStatePropertyAll(
                              Size(36, 36),
                            ),
                            padding: const WidgetStatePropertyAll(
                              EdgeInsets.zero,
                            ),
                          ),
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'copy',
                              child: Text(l10n.verifyCopyReport),
                            ),
                          ],
                          onSelected: (value) {
                            if (value == 'copy') {
                              final text = _buildReportText(result, l10n);
                              Clipboard.setData(ClipboardData(text: text));
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(l10n.verifyCopied),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                          },
                        ),
                      ],
                    ),

                    const SizedBox(height: 36),

                    // ── Status disc ────────────────────────────────────
                    disc,
                    const SizedBox(height: 16),

                    // ── Title ──────────────────────────────────────────
                    Text(
                      titleText,
                      style: AppTheme.displayBold(cs),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),

                    // ── Mono subtitle ──────────────────────────────────
                    Text(
                      subtitleText,
                      style: AppTheme.monoBody(
                        cs,
                        color: cs.onSurfaceVariant,
                      ).copyWith(fontSize: 13),
                      textAlign: TextAlign.center,
                    ),

                    // ── Signer count badge (if > 1) ────────────────────
                    if (signerCount > 1) ...[
                      const SizedBox(height: 8),
                      Text(
                        l10n.verifySignersCount(signerCount),
                        style: AppTheme.monoBody(
                          cs,
                          color: cs.onSurfaceVariant,
                        ).copyWith(fontSize: 12),
                        textAlign: TextAlign.center,
                      ),
                    ],

                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ],
          ),
        ),

        // ── Detail panel ──────────────────────────────────────────────────
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.fromLTRB(0, 0, 0, 0),
            decoration: BoxDecoration(
              color: cs.surfaceContainer,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
            ),
            padding: const EdgeInsets.all(18),
            child: detailPanel,
          ),
        ),

        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );
  }

  static String _buildReportText(VerifyInfo result, AppLocalizations l10n) {
    final lines = <String>[
      result.displayName,
      result.commonName,
      '${l10n.verifySignedLabel}: ${result.signingTimeFormatted}',
      '${l10n.verifyIssuedByLabel}: ${result.caDisplayName}',
      '${l10n.verifyValidLabel}: ${result.isFullyValid ? l10n.verifyValidLabel : l10n.verifyInvalidLabel}',
    ];
    return lines.join('\n');
  }
}

// ---------------------------------------------------------------------------
// Valid detail panel
// ---------------------------------------------------------------------------

class _ValidDetailPanel extends StatelessWidget {
  const _ValidDetailPanel({
    required this.result,
    required this.filePath,
    this.onExtractP7m,
  });

  final VerifyInfo result;
  final String filePath;
  final VoidCallback? onExtractP7m;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fileName = filePath.split('/').last;
    final ext = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : 'pdf';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 1. Document chip ──────────────────────────────────────────────
        Row(
          children: [
            OcFileTile(extension: ext, width: 38, height: 46),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.open_in_new_rounded, size: 22, color: cs.primary),
          ],
        ),

        const SizedBox(height: 14),

        // ── 2. Signer card ────────────────────────────────────────────────
        _SignerCard(result: result, isValid: true),

        const SizedBox(height: 14),

        // ── 3. Trust strip ────────────────────────────────────────────────
        _TrustStrip(),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Invalid detail panel
// ---------------------------------------------------------------------------

class _InvalidDetailPanel extends StatelessWidget {
  const _InvalidDetailPanel({
    required this.result,
    required this.filePath,
    this.onExtractP7m,
  });

  final VerifyInfo result;
  final String filePath;
  final VoidCallback? onExtractP7m;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    const invalidColor = ColorSchemes.invalid;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Warning callout ───────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: invalidColor.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: invalidColor.withValues(alpha: 0.30)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              OcSectionLabel(l10n.verifyHashMismatch, color: invalidColor),
              const SizedBox(height: 8),
              Text(
                l10n.verifyHashMismatchBody,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  color: cs.onSurface,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 14),

        // ── Diagnostics block ─────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              OcSectionLabel(l10n.verifyDiagnostics),
              const SizedBox(height: 12),
              Table(
                columnWidths: const {
                  0: IntrinsicColumnWidth(),
                  1: FlexColumnWidth(),
                },
                children: [
                  _diagRow(
                    l10n.verifySignedHash,
                    result.commonName.isNotEmpty
                        ? result.commonName.substring(
                            0,
                            result.commonName.length > 20
                                ? 20
                                : result.commonName.length,
                          )
                        : '—',
                    cs.onSurface,
                    cs,
                  ),
                  _diagRow(l10n.verifyCurrentHash, '—', invalidColor, cs),
                  _diagRow(
                    l10n.verifyCertChain,
                    result.isCertificateValid
                        ? l10n.verifyValidLabel
                        : l10n.verifyInvalidLabel,
                    result.isCertificateValid
                        ? ColorSchemes.valid
                        : invalidColor,
                    cs,
                  ),
                  _diagRow(
                    l10n.verifyRevocationLabel,
                    result.revocationStatusLabel,
                    result.certRevocationStatus == 0
                        ? ColorSchemes.valid
                        : invalidColor,
                    cs,
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 14),
      ],
    );
  }

  TableRow _diagRow(
    String key,
    String value,
    Color valueColor,
    ColorScheme cs,
  ) {
    return TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 16, bottom: 6),
          child: OcMonoText(key, fontSize: 11, color: cs.onSurfaceVariant),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: OcMonoText(value, fontSize: 11, color: valueColor),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Signer card (shared between valid/invalid)
// ---------------------------------------------------------------------------

class _SignerCard extends StatelessWidget {
  const _SignerCard({required this.result, required this.isValid});

  final VerifyInfo result;
  final bool isValid;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    const validColor = ColorSchemes.valid;
    final initials = _initials(result);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Avatar with CIE card gradient
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: ColorSchemes.cieCardGradient,
                  ),
                ),
                child: Center(
                  child: Text(
                    initials,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      result.displayName,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    OcMonoText(
                      result.commonName,
                      fontSize: 11,
                      color: cs.onSurfaceVariant,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Qualification badge
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: validColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  l10n.verifyQualified,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: validColor,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ],
          ),

          Divider(height: 14, color: cs.outlineVariant),

          // 4-row mono grid
          Table(
            columnWidths: const {
              0: IntrinsicColumnWidth(),
              1: FlexColumnWidth(),
            },
            children: [
              _metaRow(
                l10n.verifySignedLabel,
                result.signingTimeFormatted.isNotEmpty
                    ? result.signingTimeFormatted
                    : '—',
                cs,
              ),
              _metaRow(l10n.verifyIssuedByLabel, result.caDisplayName, cs),
              _metaRow(l10n.verifySerialLabel, result.commonName, cs),
              _metaRow(
                l10n.verifyTsaLabel,
                result.signingTimeFormatted.isNotEmpty
                    ? l10n.verifyPresent
                    : '—',
                cs,
              ),
            ],
          ),
        ],
      ),
    );
  }

  TableRow _metaRow(String key, String value, ColorScheme cs) {
    return TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 16, bottom: 4),
          child: OcMonoText(key, fontSize: 11, color: cs.onSurfaceVariant),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: OcMonoText(
            value,
            fontSize: 11,
            color: cs.onSurface,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  String _initials(VerifyInfo r) {
    final n = r.name.isNotEmpty ? r.name[0].toUpperCase() : '';
    final s = r.surname.isNotEmpty ? r.surname[0].toUpperCase() : '';
    if (n.isEmpty && s.isEmpty) {
      return r.displayName.isNotEmpty ? r.displayName[0].toUpperCase() : '?';
    }
    return '$n$s';
  }
}

// ---------------------------------------------------------------------------
// Trust strip
// ---------------------------------------------------------------------------

class _TrustStrip extends StatelessWidget {
  const _TrustStrip();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    const validColor = ColorSchemes.valid;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: validColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: validColor.withValues(alpha: 0.20)),
      ),
      child: Row(
        children: [
          const Icon(Icons.shield_outlined, color: validColor, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l10n.verifyTrustAnchor,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: cs.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Drop zone widget
// ---------------------------------------------------------------------------

class _DropZone extends StatelessWidget {
  const _DropZone({
    required this.fileName,
    required this.isDragging,
    required this.isVerifying,
    required this.onPickFile,
    required this.onDragEntered,
    required this.onDragExited,
    required this.onDragDone,
    required this.onClearFile,
    required this.l10n,
  });

  final String? fileName;
  final bool isDragging;
  final bool isVerifying;
  final VoidCallback onPickFile;
  final VoidCallback onDragEntered;
  final VoidCallback onDragExited;
  final void Function(String) onDragDone;
  final VoidCallback onClearFile;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ext = fileName != null && fileName!.contains('.')
        ? fileName!.split('.').last.toLowerCase()
        : '';

    return DropTarget(
      onDragEntered: (_) => onDragEntered(),
      onDragExited: (_) => onDragExited(),
      onDragDone: (details) {
        if (details.files.isNotEmpty) {
          onDragDone(details.files.first.path);
        }
      },
      child: GestureDetector(
        onTap: onPickFile,
        child: DottedBorder(
          options: RoundedRectDottedBorderOptions(
            radius: const Radius.circular(18),
            dashPattern: const [8, 5],
            color: isDragging ? cs.primary : cs.outlineVariant,
            strokeWidth: isDragging ? 2 : 1.5,
          ),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
            decoration: BoxDecoration(
              color: isDragging
                  ? cs.primary.withValues(alpha: 0.06)
                  : cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(18),
            ),
            child: fileName != null
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      OcFileTile(
                        extension: ext.isNotEmpty ? ext : 'pdf',
                        width: 34,
                        height: 42,
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          fileName!,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: onClearFile,
                        tooltip: l10n.commonClear,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        color: cs.onSurfaceVariant,
                      ),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isDragging
                            ? Icons.file_download_rounded
                            : Icons.cloud_upload_outlined,
                        size: 40,
                        color: isDragging ? cs.primary : cs.onSurfaceVariant,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        l10n.verifyDropHint,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 14,
                          color: cs.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 14),
                      FilledButton.tonal(
                        onPressed: onPickFile,
                        child: Text(l10n.commonSelectFile),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Icon button used in the hero top row
// ---------------------------------------------------------------------------

class _IconBtn extends StatelessWidget {
  const _IconBtn({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh.withValues(alpha: 0.70),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 22, color: cs.onSurface),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shake animation widget for invalid state
// ---------------------------------------------------------------------------

class _ShakeOnAppear extends StatefulWidget {
  const _ShakeOnAppear({required this.child});
  final Widget child;

  @override
  State<_ShakeOnAppear> createState() => _ShakeOnAppearState();
}

class _ShakeOnAppearState extends State<_ShakeOnAppear>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 480),
  );

  late final Animation<double> _offsetX = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0, end: -6), weight: 16),
    TweenSequenceItem(tween: Tween(begin: -6, end: 6), weight: 16),
    TweenSequenceItem(tween: Tween(begin: 6, end: -4), weight: 16),
    TweenSequenceItem(tween: Tween(begin: -4, end: 4), weight: 16),
    TweenSequenceItem(tween: Tween(begin: 4, end: -3), weight: 16),
    TweenSequenceItem(tween: Tween(begin: -3, end: 0), weight: 20),
  ]).animate(CurvedAnimation(parent: _ctrl, curve: Curves.linear));

  @override
  void initState() {
    super.initState();
    // Small delay so the widget is visible before shaking
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _offsetX,
      builder: (_, child) =>
          Transform.translate(offset: Offset(_offsetX.value, 0), child: child),
      child: widget.child,
    );
  }
}
