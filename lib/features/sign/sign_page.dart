// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:dotted_border/dotted_border.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_constants.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/l10n/app_localizations_ext.dart';
import '../../core/theme/color_schemes.dart';
import '../../widgets/nfc_card_dialog.dart';
import '../../widgets/oc_file_tile.dart';
import '../../widgets/oc_gradient_button.dart';
import '../../widgets/oc_page.dart';
import '../../widgets/oc_section_label.dart';
import '../../ffi/opencie_pkcs11.dart';
import '../../models/signature_options.dart';
import '../../models/tsa_config.dart';
import '../../models/enrolled_card_utils.dart';
import '../../providers/recent_files_provider.dart';
import '../../providers/sign_backend_provider.dart';
import '../../providers/settings_provider.dart';
import '../handoff/desktop_handoff_page.dart';
import '../handoff/phone_handoff_page.dart';
import '../../services/nfc_service.dart';
import '../../services/cie_error.dart';
import '../../services/pin_throttle.dart';
import '../../services/storage_service.dart';
import '../../services/sign/signature_upgrader.dart';
import '../../widgets/oc_help_sheet.dart';
import 'batch_sign_page.dart';
import 'sign_requirements.dart';
import 'utils/signature_image_generator.dart';
import 'widgets/pdf_signature_placer.dart';
import 'widgets/sign_pin_dialog.dart';
import 'widgets/signer_box.dart';
import 'widgets/signed_result_dialog.dart';

const _nfcChannel = MethodChannel('io.github.m0rf30.opencie/nfc');

/// Digital Signature page.
class SignPage extends ConsumerStatefulWidget {
  const SignPage({super.key});

  @override
  ConsumerState<SignPage> createState() => _SignPageState();
}

class _SignPageState extends ConsumerState<SignPage> {
  String? _selectedFile;
  SignatureOptions _options = const SignatureOptions();
  bool _isSigning = false;
  bool _waitingCard = false;
  String? _pendingPin;
  SignatureOptions? _pendingOptions;
  bool _isDragging = false;

  /// Notifier for the NFC modal dialog state: (isWaiting, progress, message).
  final _nfcNotifier = ValueNotifier<(bool, double, String)>((false, 0.0, ''));

  /// Non-null shows a classified failure inline in the NFC dialog instead
  /// of a SnackBar (currently: NFC tag-read failure).
  final _errorNotifier = ValueNotifier<String?>(null);

  /// True while Android NFC is off; shown inline in the NFC dialog
  /// instead of a SnackBar so the user gets a settings shortcut without
  /// leaving the sign flow.
  final _nfcDisabledNotifier = ValueNotifier<bool>(false);
  bool _nfcDialogOpen = false;

  /// PC/SC reader name (desktop only).
  String? _readerName;
  StreamSubscription<String?>? _readerSub;

  @override
  void initState() {
    super.initState();
    // The timestamp toggle starts from the `alwaysTimestamp` setting and
    // follows later changes to it; the user can still flip it per document.
    _options = SignatureOptions(
      addTimestamp: ref.read(settingsProvider).alwaysTimestamp,
    );
    ref.listenManual(settingsProvider.select((s) => s.alwaysTimestamp), (
      _,
      enabled,
    ) {
      if (mounted) {
        setState(() => _options = _options.copyWith(addTimestamp: enabled));
      }
    });
    _subscribeReaders();
  }

  @override
  void dispose() {
    _nfcNotifier.dispose();
    _errorNotifier.dispose();
    _nfcDisabledNotifier.dispose();
    _readerSub?.cancel();
    super.dispose();
  }

  bool get _isPdfFile => _selectedFile?.toLowerCase().endsWith('.pdf') ?? false;

  bool get _isXmlFile => _selectedFile?.toLowerCase().endsWith('.xml') ?? false;

  bool get _readerReady => Platform.isAndroid || _readerName != null;

  void _subscribeReaders() {
    if (Platform.isAndroid) return;
    _readerSub = OpenCiePkcs11.instance.watchReaders().listen((name) {
      if (mounted) setState(() => _readerName = name);
    });
  }

  Future<void> _pickFile() async {
    final file = await FilePicker.pickFile(type: FileType.any);
    {
      final path = file?.path;
      if (path != null) {
        setState(() {
          _selectedFile = path;
          if (!path.toLowerCase().endsWith('.pdf') &&
              _options.format == SignatureFormat.pades) {
            _options = _options.copyWith(
              format: SignatureFormat.cades,
              graphicSignature: false,
            );
          } else if (!path.toLowerCase().endsWith('.xml') &&
              _options.format == SignatureFormat.xades) {
            _options = _options.copyWith(format: SignatureFormat.cades);
          }
        });
      }
    }
  }

  void _onFormatChanged(SignatureFormat format) {
    setState(() => _options = _options.copyWith(format: format));
  }

  void _onGraphicToggled(bool enabled) {
    setState(() => _options = _options.copyWith(graphicSignature: enabled));
  }

  void _onTimestampToggled(bool enabled) {
    setState(() => _options = _options.copyWith(addTimestamp: enabled));
  }

  Future<void> _startSigning() async {
    if (_selectedFile == null || _isSigning || _waitingCard) return;

    // Set the busy guard synchronously, before any `await`, so a second
    // tap arriving before the first `await` yields cannot slip past the
    // guard check above and start a second concurrent signing flow.
    setState(() => _isSigning = true);
    var handedOff = false;
    try {
      if (Platform.isAndroid) {
        final nfcAvailable = await NfcService.instance.isAvailable;
        if (!nfcAvailable && mounted) {
          _nfcDisabledNotifier.value = true;
          _nfcNotifier.value = (true, 0.0, '');
          setState(() => _waitingCard = true);
          _showNfcDialog();
          handedOff = true;
          return;
        }
      }

      final pin = await _showPinDialog();
      if (pin == null) return;

      var options = _options;

      final isPdf = _selectedFile?.toLowerCase().endsWith('.pdf') ?? false;
      if (!isPdf && options.format == SignatureFormat.pades) {
        options = options.copyWith(
          format: SignatureFormat.cades,
          graphicSignature: false,
        );
        setState(() => _options = options);
      }

      if (options.graphicSignature &&
          options.format == SignatureFormat.pades &&
          options.imageData == null) {
        try {
          final bytes = await generateDefaultSignatureImage(
            includeDate: ref.read(settingsProvider).includeDate,
          );
          options = options.copyWith(imageData: bytes);
          if (mounted) setState(() => _options = options);
        } catch (_) {}
      }

      if (Platform.isAndroid) {
        setState(() {
          _waitingCard = true;
          _pendingPin = pin;
          _pendingOptions = options;
        });
        _nfcNotifier.value = (true, 0.0, '');
        _showNfcDialog();
        NfcService.instance.startSession(
          onTagDiscovered: _onCardDetectedForSign,
          onTagFailed: () {
            if (mounted) {
              NfcService.instance.stopSession();
              _errorNotifier.value = cieErrorMessage(
                AppLocalizations.of(context),
                CieErrorKind.cardCommunicationError,
              );
            }
          },
        );
        // Busy state now carries on via `_waitingCard` / `_onCardDetectedForSign`
        // → `_executeSign`, or gets reset by `_cancelWaitCard`/`_dismissNfcError`.
        handedOff = true;
      } else {
        _nfcNotifier.value = (false, 0.0, '');
        _showNfcDialog();
        await _executeSign(pin, options);
        // `_executeSign` owns `_isSigning` for the remainder of this flow.
        handedOff = true;
      }
    } finally {
      if (!handedOff && mounted) setState(() => _isSigning = false);
    }
  }

  void _showNfcDialog() {
    _nfcDialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => NfcCardDialog(
        notifier: _nfcNotifier,
        processingTitle: AppLocalizations.of(ctx).cieProgressSigning,
        onCancel: _cancelWaitCard,
        errorNotifier: _errorNotifier,
        onDismissError: _dismissNfcError,
        nfcDisabledNotifier: _nfcDisabledNotifier,
        onOpenNfcSettings: NfcService.instance.openNfcSettings,
        onDismissNfcDisabled: _dismissNfcDisabled,
      ),
    ).whenComplete(() {
      _nfcDialogOpen = false;
      _nfcDisabledNotifier.value = false;
      // Safety net: if the dialog route ended up closing through some path
      // other than onCancel/onDismissError/_executeSign's finally (e.g. a
      // Navigator.pop triggered from elsewhere), still reset the busy
      // flags so the Sign button doesn't stay stuck disabled.
      if (mounted && (_waitingCard || _pendingPin != null)) {
        setState(() {
          _waitingCard = false;
          _pendingPin = null;
          _pendingOptions = null;
          _isSigning = false;
        });
      }
    });
  }

  void _closeNfcDialog() {
    if (_nfcDialogOpen && mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }

  void _dismissNfcError() {
    _errorNotifier.value = null;
    _closeNfcDialog();
    if (mounted) {
      setState(() {
        _waitingCard = false;
        _pendingPin = null;
        _pendingOptions = null;
        _isSigning = false;
      });
    }
  }

  void _dismissNfcDisabled() {
    _nfcDisabledNotifier.value = false;
    _closeNfcDialog();
    if (mounted) {
      setState(() {
        _waitingCard = false;
        _isSigning = false;
      });
    }
  }

  void _onCardDetectedForSign() {
    final pin = _pendingPin;
    final options = _pendingOptions;
    if (pin == null || options == null || !mounted) return;
    setState(() {
      _waitingCard = false;
      _pendingPin = null;
      _pendingOptions = null;
    });
    _nfcNotifier.value = (false, 0.0, '');
    _executeSign(pin, options);
  }

  void _cancelWaitCard() {
    NfcService.instance.stopSession();
    _closeNfcDialog();
    if (mounted) {
      setState(() {
        _waitingCard = false;
        _pendingPin = null;
        _pendingOptions = null;
        _isSigning = false;
      });
    }
  }

  Future<void> _executeSign(String pin, SignatureOptions options) async {
    if (_selectedFile == null) return;
    final l10n = AppLocalizations.of(context);

    // `_isSigning` is already true here: `_startSigning` sets it
    // synchronously before handing off to this method (directly on
    // desktop, or via `_onCardDetectedForSign` on Android).

    String? successPath;
    SignatureUpgradeResult? upgrade;

    try {
      final file = _selectedFile!;
      final outputPath = await _resolveOutputPath(file, options);

      final result = await ref
          .read(signBackendProvider)
          .sign(
            inputPath: file,
            outputPath: outputPath,
            format: options.format,
            pin: pin,
            pan: ref.read(settingsProvider).signPan,
            page: options.graphicSignature ? options.page : 0,
            x: options.graphicSignature ? options.x : 0,
            y: options.graphicSignature ? options.y : 0,
            w: options.graphicSignature ? options.width : 0,
            h: options.graphicSignature ? options.height : 0,
            imageData: options.graphicSignature ? options.imageData : null,
            onProgress: (p) {
              _nfcNotifier.value = (
                false,
                p.percent / 100.0,
                l10n.localizeProgress(p.message),
              );
            },
          );

      if (!mounted) return;

      if (result.isSuccess) {
        PinThrottle.reset();
        ref.read(recentSignedFilesProvider.notifier).add(file);
        ref
            .read(settingsProvider.notifier)
            .update(
              (s) => s.copyWith(
                enrolledCards: markSelectedCardUsed(
                  s.enrolledCards,
                  s.selectedCard?.pan,
                ),
              ),
            );
        successPath = outputPath;

        // Timestamp / LTV upgrade. The native signature is already valid
        // and on disk, so any failure here only produces a warning.
        if (options.timestampRequested) {
          _nfcNotifier.value = (false, 1.0, l10n.cieProgressTimestamping);
          try {
            upgrade = await ref
                .read(signatureUpgraderProvider)
                .upgrade(
                  path: outputPath,
                  format: options.format,
                  settings: SignatureUpgradeSettings.fromAppSettings(
                    ref.read(settingsProvider),
                  ),
                );
          } catch (e) {
            debugPrint('SignPage._executeSign: timestamp upgrade failed ($e)');
            upgrade = SignatureUpgradeResult(
              warning: SignatureUpgradeWarning.timestampFailed,
              detail: e.toString(),
            );
          }
          if (!mounted) return;
        }

        if (Platform.isAndroid) {
          final settings = ref.read(settingsProvider);
          if (settings.destinationFolder != null) {
            try {
              await StorageService.writeFileToTreeUri(
                treeUri: settings.destinationFolder!,
                sourcePath: outputPath,
                fileName: p.basename(outputPath),
                mimeType: _mimeForExt(p.extension(outputPath)),
              );
            } catch (_) {
              // SAF copy is best-effort; the file is already in app-private
              // storage and can be accessed from the success dialog.
            }
          }
          try {
            await _nfcChannel.invokeMethod<bool>('scanMediaFile', {
              'path': outputPath,
            });
          } catch (_) {}
        }
      } else if (result.isPinIncorrect) {
        PinThrottle.recordFailure();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.remainingAttempts != null
                  ? l10n.signIncorrectPinWithAttempts(result.remainingAttempts!)
                  : l10n.signIncorrectPin,
            ),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      } else if (result.isPinLocked) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.signPinLocked),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Colors.red,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              cieErrorMessage(
                l10n,
                classifyCieError(
                  result.returnValue,
                  nativeErrorKind: result.nativeErrorKind,
                ),
              ),
            ),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.signFailed(e.toString())),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (Platform.isAndroid) await NfcService.instance.stopSession();
      _closeNfcDialog();
      if (mounted) setState(() => _isSigning = false);
    }

    if (successPath != null && mounted) {
      _showSignedResultDialog(successPath, upgrade);
    }
  }

  String _addSignedSuffix(String path) {
    final dot = path.lastIndexOf('.');
    if (dot == -1) return '${path}_signed';
    return '${path.substring(0, dot)}_signed${path.substring(dot)}';
  }

  static const _signatureExtensions = {'.p7m', '.p7s', '.xml'};

  String _stripSignatureExtension(String name) {
    final lower = name.toLowerCase();
    for (final ext in _signatureExtensions) {
      if (lower.endsWith(ext)) {
        return name.substring(0, name.length - ext.length);
      }
    }
    return name;
  }

  Future<String> _resolveOutputPath(
    String inputPath,
    SignatureOptions options,
  ) async {
    final inputFile = File(inputPath);
    final inputName = inputFile.uri.pathSegments.last;
    final baseName = options.format == SignatureFormat.pades
        ? inputName
        : _stripSignatureExtension(inputName);
    final signedName = options.format == SignatureFormat.pades
        ? _addSignedSuffix(baseName)
        : '$baseName${options.format.extension}';

    if (Platform.isAndroid) {
      final outputDir = await _resolveAndroidOutputDir(inputFile);
      return '${outputDir.path}/$signedName';
    }

    return '${inputFile.parent.path}/$signedName';
  }

  Future<Directory> _resolveAndroidOutputDir(File inputFile) async {
    // Always sign into app-private storage; SAF copy happens afterwards
    // if the user has selected an external folder.
    return getApplicationDocumentsDirectory();
  }

  static String _mimeForExt(String ext) {
    switch (ext.toLowerCase()) {
      case '.pdf':
        return 'application/pdf';
      case '.p7m':
        return 'application/pkcs7-mime';
      case '.xml':
        return 'application/xml';
      default:
        return 'application/octet-stream';
    }
  }

  // ── PIN dialog ──────────────────────────────────────────────────────────────

  Future<String?> _showPinDialog() => showDialog<String>(
    context: context,
    builder: (_) => const SignPinDialog(),
  );

  // ── Success dialog ──────────────────────────────────────────────────────────

  void _showSignedResultDialog(
    String outputPath, [
    SignatureUpgradeResult? upgrade,
  ]) {
    showDialog<void>(
      context: context,
      builder: (_) => SignedResultDialog(
        outputPath: outputPath,
        options: _options,
        onOpenFile: _openFile,
        onVerifyFile: _verifyFile,
        tsaLabel: tsaDisplayName(
          ref.read(settingsProvider).tsaConfig.serverUrl,
        ),
        timestamped: upgrade?.timestamped ?? false,
        warning: upgrade?.warning,
        warningDetail: upgrade?.detail,
      ),
    );
  }

  // ── Navigation helpers ──────────────────────────────────────────────────────

  Future<void> _openFile(String path) async {
    final l10n = AppLocalizations.of(context);
    final uri = Uri.file(path);
    if (!await launchUrl(uri)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.signCouldNotOpen),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _verifyFile(String path) {
    ref.read(pendingVerifyFileProvider.notifier).set(path);
    context.go('/verify');
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= AppConstants.mediumBreakpoint) {
            return _buildDesktopContent(context);
          }
          return _buildMobileContent(context);
        },
      ),
    );
  }

  // ── Mobile layout ───────────────────────────────────────────────────────────

  OcPageHeader _buildHeader(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    return OcPageHeader(
      title: l10n.signTitle,
      subtitle: l10n.signSubtitleFull,
      actions: [
        IconButton(
          icon: const Icon(Icons.layers_outlined),
          tooltip: l10n.batchSignTitle,
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const BatchSignPage()),
            );
          },
        ),
        IconButton(
          icon: const Icon(Icons.info_outline_rounded),
          tooltip: l10n.helpButtonTooltip,
          onPressed: () => OcHelpSheet.show(
            context,
            OcHelpSheet(
              title: l10n.helpSignTitle,
              icon: Icons.draw_rounded,
              iconColor: cs.primary,
              steps: [
                OcHelpStep(
                  title: l10n.helpSignStep1Title,
                  body: l10n.helpSignStep1Body,
                  icon: Icons.folder_open_rounded,
                ),
                OcHelpStep(
                  title: l10n.helpSignStep2Title,
                  body: l10n.helpSignStep2Body,
                  icon: Icons.tune_rounded,
                ),
                OcHelpStep(
                  title: l10n.helpSignStep3Title,
                  body: l10n.helpSignStep3Body,
                  icon: Icons.nfc_rounded,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMobileContent(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final recent = ref.watch(recentSignedFilesProvider);
    final enrolledCount = ref.watch(settingsProvider).enrolledCards.length;
    final hasCard = enrolledCount > 0;
    final hasMultipleCards = enrolledCount > 1;

    Widget body(Widget child) =>
        OcPageBody.sliver(child: SliverToBoxAdapter(child: child));

    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: CustomScrollView(
              slivers: [
                body(_buildHeader(context)),

                // Enrollment warning
                if (!hasCard) body(_buildEnrollmentBanner(context)),

                // Signer picker (only needed when several cards are enrolled)
                if (hasMultipleCards)
                  body(
                    const Padding(
                      padding: EdgeInsets.only(top: 16),
                      child: SignerBox(),
                    ),
                  ),

                // Document hero
                body(
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _buildDocumentHero(context),
                  ),
                ),

                // Filename + size caption (when file selected)
                if (_selectedFile != null)
                  body(
                    Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Column(
                        children: [
                          Text(
                            p.basename(_selectedFile!),
                            style: TextStyle(
                              fontFamily: 'Inter',
                              color: cs.onSurface,
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          OcMonoText(
                            _fileSizeCaption(_selectedFile!),
                            color: cs.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ],
                      ),
                    ),
                  ),

                // PDF signature placer (graphic sig)
                if (_options.graphicSignature &&
                    _options.format == SignatureFormat.pades &&
                    _selectedFile != null &&
                    _selectedFile!.toLowerCase().endsWith('.pdf'))
                  body(
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: PdfSignaturePlacer(
                        pdfPath: _selectedFile!,
                        page: _options.page,
                        sigX: _options.x,
                        sigY: _options.y,
                        sigW: _options.width,
                        sigH: _options.height,
                        imageData: _options.imageData,
                        alignedFieldName: _options.alignedFieldName,
                        includeDate: ref.watch(
                          settingsProvider.select((s) => s.includeDate),
                        ),
                        onChanged:
                            ({
                              required int page,
                              required double x,
                              required double y,
                              required double w,
                              required double h,
                              Uint8List? imageData,
                              required String? alignedFieldName,
                            }) {
                              setState(() {
                                _options = _options.copyWith(
                                  page: page,
                                  x: x,
                                  y: y,
                                  width: w,
                                  height: h,
                                  imageData: imageData,
                                  alignedFieldName: alignedFieldName,
                                  clearAlignedFieldName:
                                      alignedFieldName == null,
                                );
                              });
                            },
                      ),
                    ),
                  ),

                // Recently signed
                if (recent.isNotEmpty)
                  body(
                    Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: _buildRecentSection(context, recent),
                    ),
                  ),

                const SliverToBoxAdapter(child: SizedBox(height: 16)),
              ],
            ),
          ),
          _buildBottomPanel(context),
        ],
      ),
    );
  }

  Widget _buildEnrollmentBanner(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: theme.colorScheme.error.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.credit_card_off,
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.signNoCardEnrolled,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    l10n.signNoCardEnrolledBody,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => context.go('/cie'),
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
                foregroundColor: theme.colorScheme.onError,
                visualDensity: VisualDensity.compact,
              ),
              child: Text(l10n.signGoToCie),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDocumentHero(BuildContext context) {
    if (_selectedFile != null) {
      return _buildFauxFileCard(context);
    }
    return _buildEmptyDropZone(context);
  }

  Widget _buildEmptyDropZone(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);

    return DropTarget(
      onDragEntered: (_) => setState(() => _isDragging = true),
      onDragExited: (_) => setState(() => _isDragging = false),
      onDragDone: (details) {
        setState(() => _isDragging = false);
        if (details.files.isNotEmpty) {
          final path = details.files.first.path;
          setState(() {
            _selectedFile = path;
            if (!path.toLowerCase().endsWith('.pdf') &&
                _options.format == SignatureFormat.pades) {
              _options = _options.copyWith(
                format: SignatureFormat.cades,
                graphicSignature: false,
              );
            }
          });
        }
      },
      child: GestureDetector(
        onTap: _pickFile,
        child: DottedBorder(
          options: RoundedRectDottedBorderOptions(
            radius: const Radius.circular(18),
            dashPattern: const [8, 4],
            color: _isDragging ? cs.primary : cs.outline,
            strokeWidth: _isDragging ? 2.0 : 1.5,
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: _isDragging
                  ? cs.primary.withValues(alpha: 0.06)
                  : cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: Icon(
                    _isDragging
                        ? Icons.file_download_rounded
                        : Icons.cloud_upload_outlined,
                    key: ValueKey(_isDragging),
                    size: 44,
                    color: _isDragging ? cs.primary : cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.signDragAndDropHint,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    color: cs.onSurfaceVariant,
                    fontSize: 14,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: _pickFile,
                  icon: const Icon(Icons.folder_open_rounded, size: 16),
                  label: Text(l10n.commonSelectFile),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                  ),
                ),
                if (Platform.isAndroid) ...[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const PhoneHandoffPage(),
                      ),
                    ),
                    icon: const Icon(Icons.laptop_mac_rounded, size: 16),
                    label: Text(l10n.handoffEntryPhoneButton),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFauxFileCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final path = _selectedFile!;
    final ext = p.extension(path).replaceFirst('.', '').toUpperCase();
    final extColor = OcFileTile.colorFor(ext);

    return Column(
      children: [
        // File card visual
        Center(
          child: FractionallySizedBox(
            widthFactor: 0.78,
            child: AspectRatio(
              aspectRatio: 0.71,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      blurRadius: 60,
                      offset: const Offset(0, 30),
                      color: Colors.black.withValues(
                        alpha: cs.brightness == Brightness.dark ? 0.60 : 0.18,
                      ),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    children: [
                      // Faux page content
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 56),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Title bar (primaryDeep, 40% width)
                            FractionallySizedBox(
                              widthFactor: 0.40,
                              child: Container(
                                height: 10,
                                decoration: BoxDecoration(
                                  color: ColorSchemes.primaryDeep.withValues(
                                    alpha: 0.65,
                                  ),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            // 11 body lines
                            for (final w in [
                              0.92,
                              0.78,
                              0.85,
                              0.72,
                              0.88,
                              0.68,
                              0.82,
                              0.90,
                              0.75,
                              0.86,
                              0.70,
                            ])
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: FractionallySizedBox(
                                  widthFactor: w,
                                  child: Container(
                                    height: 7,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFD8D8D8),
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),

                      // SIGN HERE dashed box — bottom-right
                      Positioned(
                        right: 10,
                        bottom: 10,
                        child: DottedBorder(
                          options: const RoundedRectDottedBorderOptions(
                            radius: Radius.circular(4),
                            dashPattern: [4, 3],
                            color: ColorSchemes.primaryLight,
                            strokeWidth: 1.5,
                          ),
                          child: Container(
                            width: 92,
                            height: 36,
                            color: ColorSchemes.primaryLight.withValues(
                              alpha: 0.06,
                            ),
                            child: Center(
                              child: Text(
                                l10n.signPlacerSignHere,
                                style: TextStyle(
                                  fontFamily: 'JetBrainsMono',
                                  color: ColorSchemes.primaryLight,
                                  fontSize: 8,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.6,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),

                      // Format pill — top-right
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: extColor,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            ext,
                            style: TextStyle(
                              fontFamily: 'JetBrainsMono',
                              color: Colors.white,
                              fontSize: 8,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                      ),

                      // Clear button — top-left (40 px hit area)
                      Positioned(
                        top: 0,
                        left: 0,
                        child: IconButton(
                          tooltip: l10n.batchSignRemove,
                          onPressed: () => setState(() => _selectedFile = null),
                          style: IconButton.styleFrom(
                            minimumSize: const Size(40, 40),
                            backgroundColor: cs.surfaceContainerHighest
                                .withValues(alpha: 0.85),
                            foregroundColor: cs.onSurface,
                            padding: EdgeInsets.zero,
                          ),
                          icon: const Icon(Icons.close_rounded, size: 16),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBottomPanel(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Grab handle
          Container(
            width: 44,
            height: 4,
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              color: cs.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Format tabs
          _buildFormatTabs(context, cs),
          const SizedBox(height: 12),

          // Graphic signature toggle (PAdES + PDF only)
          if (_isPdfFile)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _buildQuickToggle(
                context,
                cs,
                label: l10n.signGraphicSignature,
                enabled: _options.format == SignatureFormat.pades,
                value:
                    _options.graphicSignature &&
                    _options.format == SignatureFormat.pades,
                onToggled: _onGraphicToggled,
              ),
            ),

          // Timestamp toggle
          _buildQuickToggle(
            context,
            cs,
            label: l10n.signAddTimestamp,
            enabled: _options.format.supportsTimestamp,
            value: _options.timestampRequested,
            subtitle: _options.format.supportsTimestamp
                ? null
                : l10n.signTimestampUnsupportedXades,
            onToggled: _onTimestampToggled,
          ),
          const SizedBox(height: 14),

          // Reader status (desktop windows that use the narrow layout)
          if (!Platform.isAndroid) ...[
            _buildReaderCallout(context, cs),
            const SizedBox(height: 14),
          ],

          // Sign CTA + reason it may be disabled
          _buildSignAction(context),
        ],
      ),
    );
  }

  /// The first unmet signing requirement, null when signing can start.
  SignBlocker? get _signBlocker => firstSignBlocker(
    hasDocument: _selectedFile != null,
    readerReady: _readerReady,
    card: ref.watch(settingsProvider).selectedCard,
  );

  /// Sign button with a one-line reason (and tooltip) when it is disabled.
  Widget _buildSignAction(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final blocker = _signBlocker;
    final reason = blocker == null ? null : signBlockerLabel(l10n, blocker);
    final enabled = blocker == null && !_isSigning && !_waitingCard;
    final button = OcGradientButton(
      label: l10n.signButton,
      icon: Icons.contactless_rounded,
      onPressed: enabled ? _startSigning : null,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        reason == null ? button : Tooltip(message: reason, child: button),
        if (reason != null) ...[
          const SizedBox(height: 8),
          Text(
            reason,
            key: const ValueKey('signDisabledReason'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Inter',
              color: cs.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildFormatTabs(BuildContext context, ColorScheme cs) {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<SignatureFormat>(
        key: const ValueKey('signFormatTabs'),
        showSelectedIcon: false,
        segments: [
          for (final format in SignatureFormat.values)
            ButtonSegment<SignatureFormat>(
              value: format,
              enabled:
                  !((format == SignatureFormat.pades && !_isPdfFile) ||
                      (format == SignatureFormat.xades && !_isXmlFile)),
              // "PAdES (PDF)" → "PAdES"
              label: Text(format.displayName.split(' ').first),
            ),
        ],
        selected: {_options.format},
        onSelectionChanged: (s) => _onFormatChanged(s.first),
      ),
    );
  }

  Widget _buildQuickToggle(
    BuildContext context,
    ColorScheme cs, {
    required String label,
    required bool enabled,
    required bool value,
    required ValueChanged<bool> onToggled,
    String? subtitle,
  }) {
    return Material(
      type: MaterialType.transparency,
      child: SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(
          label,
          style: TextStyle(
            fontFamily: 'Inter',
            color: enabled ? cs.onSurface : cs.onSurface.withValues(alpha: 0.5),
            fontWeight: FontWeight.w500,
            fontSize: 14,
          ),
        ),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle,
                key: const ValueKey('signToggleHint'),
                style: TextStyle(
                  fontFamily: 'Inter',
                  color: cs.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
        value: value,
        onChanged: enabled ? onToggled : null,
      ),
    );
  }

  // ── Desktop layout ──────────────────────────────────────────────────────────

  Widget _buildDesktopContent(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final settings = ref.watch(settingsProvider);
    final enrolledCard = settings.selectedCard;
    final hasCard = enrolledCard != null;
    final recent = ref.watch(recentSignedFilesProvider);

    return SafeArea(
      child: OcPageBody(
        maxWidth: 1440,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Left: Document queue ──────────────────────────────────
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Page heading ──────────────────────────────────────
                    _buildHeader(context),
                    const SizedBox(height: 20),

                    // Enrollment warning
                    if (!hasCard) ...[
                      _buildEnrollmentBanner(context),
                      const SizedBox(height: 20),
                    ],

                    // Document area
                    Container(
                      decoration: BoxDecoration(
                        color: cs.surfaceContainer,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: cs.outlineVariant),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          // Header row
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            color: cs.surfaceContainerHigh,
                            child: Row(
                              children: [
                                Expanded(
                                  child: OcSectionLabel(
                                    l10n.signColumnDocument,
                                  ),
                                ),
                                SizedBox(
                                  width: _col(context, _kColFormat),
                                  child: OcSectionLabel(l10n.signFormat),
                                ),
                                SizedBox(
                                  width: _col(context, _kColSize),
                                  child: OcSectionLabel(l10n.signColumnSize),
                                ),
                                SizedBox(
                                  width: _col(context, _kColStatus),
                                  child: OcSectionLabel(l10n.signColumnStatus),
                                ),
                                const SizedBox(width: 40),
                              ],
                            ),
                          ),

                          // File row (if selected)
                          if (_selectedFile != null) ...[
                            _buildDesktopFileRow(context, cs, l10n),
                            Divider(height: 1, color: cs.outlineVariant),
                          ],

                          // Drop hint row
                          GestureDetector(
                            onTap: _pickFile,
                            child: DropTarget(
                              onDragEntered: (_) =>
                                  setState(() => _isDragging = true),
                              onDragExited: (_) =>
                                  setState(() => _isDragging = false),
                              onDragDone: (details) {
                                setState(() => _isDragging = false);
                                if (details.files.isNotEmpty) {
                                  final path = details.files.first.path;
                                  setState(() {
                                    _selectedFile = path;
                                    if (!path.toLowerCase().endsWith('.pdf') &&
                                        _options.format ==
                                            SignatureFormat.pades) {
                                      _options = _options.copyWith(
                                        format: SignatureFormat.cades,
                                        graphicSignature: false,
                                      );
                                    }
                                  });
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 16,
                                ),
                                color: _isDragging
                                    ? cs.primary.withValues(alpha: 0.06)
                                    : Colors.transparent,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.add_circle_outline,
                                      size: 16,
                                      color: cs.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      l10n.signDragAndDropHint,
                                      style: TextStyle(
                                        fontFamily: 'Inter',
                                        color: cs.onSurfaceVariant,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // PDF placer (graphic sig)
                    if (_options.graphicSignature &&
                        _options.format == SignatureFormat.pades &&
                        _selectedFile != null &&
                        _selectedFile!.toLowerCase().endsWith('.pdf')) ...[
                      const SizedBox(height: 20),
                      PdfSignaturePlacer(
                        pdfPath: _selectedFile!,
                        page: _options.page,
                        sigX: _options.x,
                        sigY: _options.y,
                        sigW: _options.width,
                        sigH: _options.height,
                        imageData: _options.imageData,
                        alignedFieldName: _options.alignedFieldName,
                        includeDate: settings.includeDate,
                        onChanged:
                            ({
                              required int page,
                              required double x,
                              required double y,
                              required double w,
                              required double h,
                              Uint8List? imageData,
                              required String? alignedFieldName,
                            }) {
                              setState(() {
                                _options = _options.copyWith(
                                  page: page,
                                  x: x,
                                  y: y,
                                  width: w,
                                  height: h,
                                  imageData: imageData,
                                  alignedFieldName: alignedFieldName,
                                  clearAlignedFieldName:
                                      alignedFieldName == null,
                                );
                              });
                            },
                      ),
                    ],

                    // Recent files
                    if (recent.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      _buildRecentSection(context, recent),
                    ],
                  ],
                ),
              ),
            ),

            const SizedBox(width: 24),

            // ── Right: Signer + Options ───────────────────────────────
            SizedBox(
              width: 320,
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Signer card (picker when several cards are enrolled)
                    const SignerBox(),

                    const SizedBox(height: 16),

                    // Options card
                    OcSectionLabel(l10n.signOptionsTitle),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: cs.surfaceContainer,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: cs.outlineVariant),
                      ),
                      child: Column(
                        children: [
                          _OptionsRow(
                            icon: Icons.description_outlined,
                            label: l10n.signFormat,
                            value: _options.format.displayName.split(' ').first,
                          ),
                          Divider(height: 1, color: cs.outlineVariant),
                          _OptionsRow(
                            icon: Icons.schedule_rounded,
                            label: l10n.signAddTimestamp,
                            value: _options.timestampRequested
                                ? tsaDisplayName(settings.tsaConfig.serverUrl)
                                : l10n.signTimestampOff,
                          ),
                          Divider(height: 1, color: cs.outlineVariant),
                          _OptionsRow(
                            icon: Icons.folder_outlined,
                            label: l10n.signSaveTo,
                            value: settings.destinationFolder != null
                                ? p.basename(settings.destinationFolder!)
                                : l10n.signSaveToSameFolder,
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Format tabs (desktop)
                    _buildFormatTabs(context, cs),
                    const SizedBox(height: 10),

                    // Option toggles
                    if (_isPdfFile)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _buildQuickToggle(
                          context,
                          cs,
                          label: l10n.signGraphicSignature,
                          enabled: _options.format == SignatureFormat.pades,
                          value:
                              _options.graphicSignature &&
                              _options.format == SignatureFormat.pades,
                          onToggled: _onGraphicToggled,
                        ),
                      ),
                    _buildQuickToggle(
                      context,
                      cs,
                      label: l10n.signAddTimestamp,
                      enabled: _options.format.supportsTimestamp,
                      value: _options.timestampRequested,
                      subtitle: _options.format.supportsTimestamp
                          ? null
                          : l10n.signTimestampUnsupportedXades,
                      onToggled: _onTimestampToggled,
                    ),

                    const SizedBox(height: 14),

                    // Reader status callout
                    _buildReaderCallout(context, cs),

                    const SizedBox(height: 14),

                    // Sign CTA + reason it may be disabled
                    _buildSignAction(context),
                    if (!Platform.isAndroid &&
                        !_readerReady &&
                        _selectedFile != null &&
                        !_isSigning) ...[
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                DesktopHandoffPage(filePath: _selectedFile!),
                          ),
                        ),
                        icon: const Icon(Icons.smartphone_rounded, size: 18),
                        label: Text(l10n.handoffEntryDesktopButton),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const double _kColFormat = 100;
  static const double _kColSize = 100;
  static const double _kColStatus = 100;

  /// Table column width, grown with the text scale so headers don't break.
  double _col(BuildContext context, double base) =>
      base * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.6);

  Widget _buildDesktopFileRow(
    BuildContext context,
    ColorScheme cs,
    AppLocalizations l10n,
  ) {
    final path = _selectedFile!;
    final name = p.basename(path);
    final ext = p.extension(name).replaceFirst('.', '').toUpperCase();

    return Container(
      color: cs.primary.withValues(alpha: 0.06),
      padding: const EdgeInsets.only(left: 14, top: 6, bottom: 6),
      child: Row(
        children: [
          OcFileTile(extension: ext, width: 28, height: 34),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name,
              style: TextStyle(
                fontFamily: 'Inter',
                color: cs.onSurface,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: _col(context, _kColFormat),
            child: OcMonoText(
              _options.format.displayName.split(' ').first,
              fontSize: 11,
            ),
          ),
          SizedBox(
            width: _col(context, _kColSize),
            child: OcMonoText(_fileSizeCaption(path), fontSize: 11),
          ),
          SizedBox(
            width: _col(context, _kColStatus),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: _readerReady ? cs.valid : cs.onSurfaceVariant,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    _readerReady
                        ? l10n.signStatusReady
                        : l10n.signStatusWaiting,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      color: _readerReady ? cs.valid : cs.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 18),
            tooltip: l10n.batchSignRemove,
            onPressed: () => setState(() => _selectedFile = null),
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          ),
        ],
      ),
    );
  }

  Widget _buildReaderCallout(BuildContext context, ColorScheme cs) {
    final l10n = AppLocalizations.of(context);
    if (_readerReady) {
      // Reader present: show primary-tinted callout with green dot
      final readerLabel = Platform.isAndroid
          ? l10n.signNfcReady
          : l10n.signReaderName(_readerName!);
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.primary.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: cs.valid,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                readerLabel,
                style: TextStyle(
                  fontFamily: 'Inter',
                  color: cs.onSurface,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      // No reader on desktop: show muted callout
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: cs.onSurfaceVariant,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l10n.signNoReaderDetected,
                style: TextStyle(
                  fontFamily: 'Inter',
                  color: cs.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      );
    }
  }

  // ── Recent files ────────────────────────────────────────────────────────────

  Widget _buildRecentSection(BuildContext context, List<RecentFile> recent) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.signRecentlySigned,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: () =>
                  ref.read(recentSignedFilesProvider.notifier).clear(),
              icon: const Icon(Icons.delete_sweep, size: 18),
              label: Text(l10n.commonClearList),
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          clipBehavior: Clip.hardEdge,
          child: Column(
            children: [
              for (var i = 0; i < recent.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 56, endIndent: 16),
                _buildRecentTile(recent[i], theme, l10n),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRecentTile(
    RecentFile file,
    ThemeData theme,
    AppLocalizations l10n,
  ) {
    final extColor = _extColor(file.extension, theme);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: extColor.withValues(alpha: 0.12),
        child: Text(
          file.extension,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: extColor,
          ),
        ),
      ),
      title: Text(file.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        _formatRelative(file.addedAt, l10n),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => setState(() {
        _selectedFile = file.path;
        if (!file.path.toLowerCase().endsWith('.pdf') &&
            _options.format == SignatureFormat.pades) {
          _options = _options.copyWith(
            format: SignatureFormat.cades,
            graphicSignature: false,
          );
        }
      }),
    );
  }

  // ── Utilities ───────────────────────────────────────────────────────────────

  String _fileSizeCaption(String path) {
    try {
      final size = File(path).lengthSync();
      if (size < 1024) return '$size B';
      if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(0)} KB';
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    } catch (_) {
      return '';
    }
  }

  Color _extColor(String ext, ThemeData theme) {
    return switch (ext) {
      'PDF' => Colors.red.shade600,
      'P7M' || 'P7S' => Colors.blue.shade600,
      'XML' => Colors.orange.shade600,
      'DOC' || 'DOCX' => Colors.blue.shade400,
      'XLS' || 'XLSX' => Colors.green.shade600,
      _ => theme.colorScheme.primary,
    };
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

// ── Private helper widgets ──────────────────────────────────────────────────

/// Desktop options row: icon + label + mono value.
class _OptionsRow extends StatelessWidget {
  const _OptionsRow({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: cs.primary),
          const SizedBox(width: 10),
          Flexible(
            flex: 5,
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Inter',
                color: cs.onSurface,
                fontWeight: FontWeight.w500,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            flex: 6,
            child: Align(
              alignment: Alignment.centerRight,
              child: OcMonoText(
                value,
                fontSize: 11,
                color: cs.onSurfaceVariant,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
