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
import '../../core/theme/app_theme.dart';
import '../../core/theme/color_schemes.dart';
import '../../widgets/nfc_card_dialog.dart';
import '../../widgets/oc_file_tile.dart';
import '../../widgets/oc_gradient_button.dart';
import '../../widgets/oc_section_label.dart';
import '../../ffi/opencie_pkcs11.dart';
import '../../models/signature_options.dart';
import '../../providers/recent_files_provider.dart';
import '../../providers/settings_provider.dart';
import '../handoff/desktop_handoff_page.dart';
import '../handoff/phone_handoff_page.dart';
import '../../services/nfc_service.dart';
import '../../services/storage_service.dart';
import '../../widgets/oc_help_sheet.dart';
import 'batch_sign_page.dart';
import 'utils/signature_image_generator.dart';
import 'widgets/pdf_signature_placer.dart';
import 'widgets/sign_pin_dialog.dart';
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
  final _nfcNotifier =
      ValueNotifier<(bool, double, String)>((false, 0.0, ''));
  bool _nfcDialogOpen = false;

  /// PC/SC reader name (desktop only).
  String? _readerName;
  StreamSubscription<String?>? _readerSub;

  @override
  void initState() {
    super.initState();
    _subscribeReaders();
  }

  @override
  void dispose() {
    _nfcNotifier.dispose();
    _readerSub?.cancel();
    super.dispose();
  }

  bool get _isPdfFile =>
      _selectedFile?.toLowerCase().endsWith('.pdf') ?? false;

  bool get _isXmlFile =>
      _selectedFile?.toLowerCase().endsWith('.xml') ?? false;

  bool get _readerReady => Platform.isAndroid || _readerName != null;

  void _subscribeReaders() {
    if (Platform.isAndroid) return;
    _readerSub = OpenCiePkcs11.instance.watchReaders().listen((name) {
      if (mounted) setState(() => _readerName = name);
    });
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: false,
      type: FileType.any,
    );
    if (result != null && result.paths.isNotEmpty) {
      final path = result.paths.first;
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

    if (Platform.isAndroid) {
      final nfcAvailable = await NfcService.instance.isAvailable;
      if (!nfcAvailable && mounted) {
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.cieNfcNotAvailable),
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: l10n.nfcEnableButton,
              onPressed: NfcService.instance.openNfcSettings,
            ),
          ),
        );
        return;
      }
    }

    final pin = await _showPinDialog();
    if (pin == null) return;

    var options = _options;

    final isPdf = _selectedFile?.toLowerCase().endsWith('.pdf') ?? false;
    if (!isPdf && options.format == SignatureFormat.pades) {
      options = options.copyWith(
          format: SignatureFormat.cades, graphicSignature: false);
      setState(() => _options = options);
    }

    if (options.graphicSignature &&
        options.format == SignatureFormat.pades &&
        options.imageData == null) {
      try {
        final bytes = await generateDefaultSignatureImage();
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
            _cancelWaitCard();
            final l10n = AppLocalizations.of(context);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(l10n.signFailed('NFC tag failed')),
                behavior: SnackBarBehavior.floating,
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
            );
          }
        },
      );
    } else {
      _nfcNotifier.value = (false, 0.0, '');
      _showNfcDialog();
      await _executeSign(pin, options);
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
      ),
    ).whenComplete(() => _nfcDialogOpen = false);
  }

  void _closeNfcDialog() {
    if (_nfcDialogOpen && mounted) {
      Navigator.of(context, rootNavigator: true).pop();
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
      });
    }
  }

  Future<void> _executeSign(String pin, SignatureOptions options) async {
    if (_selectedFile == null) return;
    final l10n = AppLocalizations.of(context);

    setState(() => _isSigning = true);

    String? successPath;

    try {
      final file = _selectedFile!;
      final outputPath = await _resolveOutputPath(file, options);

      final result = await OpenCiePkcs11.instance.sign(
        inputPath: file,
        outputPath: outputPath,
        signatureType: options.format.nativeType,
        pin: pin,
        pan: '',
        page: options.graphicSignature ? options.page : 0,
        x: options.graphicSignature ? options.x : 0,
        y: options.graphicSignature ? options.y : 0,
        w: options.graphicSignature ? options.width : 0,
        h: options.graphicSignature ? options.height : 0,
        imageData: options.graphicSignature ? options.imageData : null,
        onProgress: (p) {
          _nfcNotifier.value =
              (false, p.percent / 100.0, l10n.localizeProgress(p.message));
        },
      );

      if (!mounted) return;

      if (result.isSuccess) {
        ref.read(recentSignedFilesProvider.notifier).add(file);
        successPath = outputPath;

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
            await _nfcChannel.invokeMethod<bool>(
                'scanMediaFile', {'path': outputPath});
          } catch (_) {}
        }
      } else if (result.isPinIncorrect) {
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
                l10n.signFailed(l10n.humanizeError(result.returnValue))),
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
      _showSignedResultDialog(successPath);
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
      String inputPath, SignatureOptions options) async {
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

  Future<String?> _showPinDialog() =>
      showDialog<String>(
        context: context,
        builder: (_) => const SignPinDialog(),
      );

  // ── Success dialog ──────────────────────────────────────────────────────────

  void _showSignedResultDialog(String outputPath) {
    showDialog<void>(
      context: context,
      builder: (_) => SignedResultDialog(
        outputPath: outputPath,
        options: _options,
        onOpenFile: _openFile,
        onVerifyFile: _verifyFile,
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

  Widget _buildMobileContent(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final recent = ref.watch(recentSignedFilesProvider);
    final hasCard =
        ref.watch(settingsProvider).enrolledCards.isNotEmpty;

    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: CustomScrollView(
              slivers: [
                // ── Page heading ──────────────────────────────────────────
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
                              Text(l10n.signTitle, style: AppTheme.displayBold(cs)),
                              const SizedBox(height: 6),
                              Text(
                                l10n.signSubtitleFull,
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
                          icon: const Icon(Icons.layers),
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
                                OcHelpStep(title: l10n.helpSignStep1Title, body: l10n.helpSignStep1Body, icon: Icons.folder_open_rounded),
                                OcHelpStep(title: l10n.helpSignStep2Title, body: l10n.helpSignStep2Body, icon: Icons.tune_rounded),
                                OcHelpStep(title: l10n.helpSignStep3Title, body: l10n.helpSignStep3Body, icon: Icons.nfc_rounded),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Enrollment warning
                if (!hasCard)
                  SliverToBoxAdapter(
                    child: _buildEnrollmentBanner(context),
                  ),

                // Document hero
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                    child: _buildDocumentHero(context),
                  ),
                ),

                // Filename + size caption (when file selected)
                if (_selectedFile != null)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding:
                          const EdgeInsets.fromLTRB(20, 14, 20, 0),
                      child: Column(
                        children: [
                          Text(
                            _selectedFile!.split('/').last,
                            style: TextStyle(fontFamily: 'Inter', 
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface,
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
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
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
                  SliverToBoxAdapter(
                    child: Padding(
                      padding:
                          const EdgeInsets.fromLTRB(20, 16, 20, 0),
                      child: PdfSignaturePlacer(
                        pdfPath: _selectedFile!,
                        page: _options.page,
                        sigX: _options.x,
                        sigY: _options.y,
                        sigW: _options.width,
                        sigH: _options.height,
                        imageData: _options.imageData,
                        onChanged: ({
                          required int page,
                          required double x,
                          required double y,
                          required double w,
                          required double h,
                          Uint8List? imageData,
                        }) {
                          setState(() {
                            _options = _options.copyWith(
                              page: page,
                              x: x,
                              y: y,
                              width: w,
                              height: h,
                              imageData: imageData,
                            );
                          });
                        },
                      ),
                    ),
                  ),

                // Recently signed
                if (recent.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                      child: _buildRecentSection(context, recent),
                    ),
                  ),

                const SliverToBoxAdapter(
                    child: SizedBox(height: 16)),
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
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: theme.colorScheme.error.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Icon(Icons.credit_card_off,
                color: theme.colorScheme.onErrorContainer),
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
                    color:
                        _isDragging ? cs.primary : cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.signDragAndDropHint,
                  style: TextStyle(fontFamily: 'Inter', 
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
                        horizontal: 14, vertical: 8),
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
                          horizontal: 14, vertical: 8),
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
    final path = _selectedFile!;
    final ext = path.split('.').last.toUpperCase();
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
                      color: Colors.black.withValues(alpha: 0.60),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    children: [
                      // Faux page content
                      Padding(
                        padding:
                            const EdgeInsets.fromLTRB(16, 16, 16, 56),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Title bar (primaryDeep, 40% width)
                            FractionallySizedBox(
                              widthFactor: 0.40,
                              child: Container(
                                height: 10,
                                decoration: BoxDecoration(
                                  color: ColorSchemes.primaryDeep
                                      .withValues(alpha: 0.65),
                                  borderRadius:
                                      BorderRadius.circular(3),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            // 11 body lines
                            for (final w in [
                              0.92, 0.78, 0.85, 0.72, 0.88,
                              0.68, 0.82, 0.90, 0.75, 0.86, 0.70
                            ])
                              Padding(
                                padding:
                                    const EdgeInsets.only(bottom: 6),
                                child: FractionallySizedBox(
                                  widthFactor: w,
                                  child: Container(
                                    height: 7,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFD8D8D8),
                                      borderRadius:
                                          BorderRadius.circular(2),
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
                            color: ColorSchemes.primary,
                            strokeWidth: 1.5,
                          ),
                          child: Container(
                            width: 92,
                            height: 36,
                            color: ColorSchemes.primary
                                .withValues(alpha: 0.06),
                            child: Center(
                              child: Text(
                                'SIGN HERE',
                                style: TextStyle(fontFamily: 'JetBrainsMono', 
                                  color: ColorSchemes.primary,
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
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: extColor,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            ext,
                            style: TextStyle(fontFamily: 'JetBrainsMono', 
                              color: Colors.white,
                              fontSize: 8,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                      ),

                      // Clear button — top-left
                      Positioned(
                        top: 4,
                        left: 4,
                        child: GestureDetector(
                          onTap: () =>
                              setState(() => _selectedFile = null),
                          child: Container(
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerHighest
                                  .withValues(alpha: 0.85),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(Icons.close_rounded,
                                size: 14,
                                color: cs.onSurface),
                          ),
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
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(28)),
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
                value: _options.graphicSignature &&
                    _options.format == SignatureFormat.pades,
                onToggled: _onGraphicToggled,
              ),
            ),

          // Timestamp toggle
          _buildQuickToggle(
            context,
            cs,
            label: l10n.signAddTimestamp,
            enabled: true,
            value: _options.addTimestamp,
            onToggled: _onTimestampToggled,
          ),
          const SizedBox(height: 14),

          // Sign CTA
          OcGradientButton(
            label: l10n.signButton,
            icon: Icons.contactless_rounded,
            onPressed:
                _selectedFile != null && !_isSigning && !_waitingCard
                    ? _startSigning
                    : null,
          ),
        ],
      ),
    );
  }

  Widget _buildFormatTabs(BuildContext context, ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        children: SignatureFormat.values.map((format) {
          final isSelected = _options.format == format;
          final isDisabled =
              (format == SignatureFormat.pades && !_isPdfFile) ||
              (format == SignatureFormat.xades && !_isXmlFile);
          return Expanded(
            child: GestureDetector(
              onTap: isDisabled ? null : () => _onFormatChanged(format),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: isSelected
                      ? cs.surfaceContainerHigh
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Center(
                  child: Text(
                    // "PAdES (PDF)" → "PAdES"
                    format.displayName.split(' ').first,
                    style: TextStyle(fontFamily: 'Inter', 
                      color: isDisabled
                          ? cs.onSurfaceVariant
                              .withValues(alpha: 0.35)
                          : isSelected
                              ? cs.onSurface
                              : cs.onSurfaceVariant,
                      fontWeight: isSelected
                          ? FontWeight.w700
                          : FontWeight.w400,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
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
  }) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.38,
      child: GestureDetector(
        onTap: enabled ? () => onToggled(!value) : null,
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(fontFamily: 'Inter', 
                  color: cs.onSurface,
                  fontWeight: FontWeight.w500,
                  fontSize: 14,
                ),
              ),
            ),
            _SignMiniToggle(value: value),
          ],
        ),
      ),
    );
  }

  // ── Desktop layout ──────────────────────────────────────────────────────────

  Widget _buildDesktopContent(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final settings = ref.watch(settingsProvider);
    final enrolledCard =
        settings.enrolledCards.isNotEmpty ? settings.enrolledCards.first : null;
    final hasCard = enrolledCard != null;
    final recent = ref.watch(recentSignedFilesProvider);

    return SafeArea(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Left: Document queue ──────────────────────────────────
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                  horizontal: 28, vertical: 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Page heading ──────────────────────────────────────
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l10n.signTitle, style: AppTheme.displayBold(cs)),
                            const SizedBox(height: 6),
                            Text(
                              l10n.signSubtitleFull,
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
                        icon: const Icon(Icons.layers),
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
                              OcHelpStep(title: l10n.helpSignStep1Title, body: l10n.helpSignStep1Body, icon: Icons.folder_open_rounded),
                              OcHelpStep(title: l10n.helpSignStep2Title, body: l10n.helpSignStep2Body, icon: Icons.tune_rounded),
                              OcHelpStep(title: l10n.helpSignStep3Title, body: l10n.helpSignStep3Body, icon: Icons.nfc_rounded),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // Enrollment warning
                  if (!hasCard) ...[
                    _buildEnrollmentBanner(context),
                    const SizedBox(height: 20),
                  ],

                  // Section label
                  OcSectionLabel('DOCUMENTO'),
                  const SizedBox(height: 12),

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
                              horizontal: 14, vertical: 10),
                          color: cs.surfaceContainerHigh,
                          child: Row(
                            children: [
                              Expanded(
                                  child: OcSectionLabel('DOCUMENTO')),
                              SizedBox(
                                  width: 100,
                                  child: OcSectionLabel('FORMATO')),
                              SizedBox(
                                  width: 90,
                                  child: OcSectionLabel('DIMENSIONE')),
                              SizedBox(
                                  width: 80,
                                  child: OcSectionLabel('STATO')),
                            ],
                          ),
                        ),

                        // File row (if selected)
                        if (_selectedFile != null) ...[
                          _buildDesktopFileRow(context, cs, l10n),
                          Divider(
                              height: 1, color: cs.outlineVariant),
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
                                final path =
                                    details.files.first.path;
                                setState(() {
                                  _selectedFile = path;
                                  if (!path
                                          .toLowerCase()
                                          .endsWith('.pdf') &&
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
                                  horizontal: 14, vertical: 16),
                              color: _isDragging
                                  ? cs.primary.withValues(alpha: 0.06)
                                  : Colors.transparent,
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.add_circle_outline,
                                      size: 16,
                                      color: cs.onSurfaceVariant),
                                  const SizedBox(width: 8),
                                  Text(
                                    l10n.signDragAndDropHint,
                                    style: TextStyle(fontFamily: 'Inter', 
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
                      onChanged: ({
                        required int page,
                        required double x,
                        required double y,
                        required double w,
                        required double h,
                        Uint8List? imageData,
                      }) {
                        setState(() {
                          _options = _options.copyWith(
                            page: page,
                            x: x,
                            y: y,
                            width: w,
                            height: h,
                            imageData: imageData,
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

          // ── Right: Signer + Options ───────────────────────────────
          SizedBox(
            width: 320,
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                  horizontal: 20, vertical: 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Signer card
                  OcSectionLabel('FIRMATARIO'),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainer,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: cs.outlineVariant),
                    ),
                    child: hasCard
                        ? Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: const LinearGradient(
                                    colors: ColorSchemes.chipGradient,
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                ),
                                child: Center(
                                  child: Text(
                                    (enrolledCard.displayName
                                            .isNotEmpty
                                        ? enrolledCard.displayName[0]
                                        : 'C'),
                                    style: TextStyle(fontFamily: 'Inter', 
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 15),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      enrolledCard.displayName,
                                      style: TextStyle(fontFamily: 'Inter', 
                                        color: cs.onSurface,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 14,
                                      ),
                                      maxLines: 1,
                                      overflow:
                                          TextOverflow.ellipsis,
                                    ),
                                    if (enrolledCard.serial
                                        .isNotEmpty)
                                      OcMonoText(
                                        enrolledCard.serial,
                                        color: cs.onSurfaceVariant,
                                        fontSize: 11,
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          )
                        : Row(
                            children: [
                              Icon(Icons.credit_card_off_rounded,
                                  color: cs.error, size: 20),
                              const SizedBox(width: 8),
                              Text(
                                l10n.signNoCardEnrolled,
                                style: TextStyle(fontFamily: 'Inter', 
                                  color: cs.error,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                  ),

                  const SizedBox(height: 16),

                  // Options card
                  OcSectionLabel('OPZIONI'),
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
                          value: _options.format.displayName
                              .split(' ')
                              .first,
                        ),
                        Divider(height: 1, color: cs.outlineVariant),
                        _OptionsRow(
                          icon: Icons.schedule_rounded,
                          label: l10n.signAddTimestamp,
                          value: _options.addTimestamp
                              ? 'FreeTSA'
                              : '—',
                        ),
                        Divider(height: 1, color: cs.outlineVariant),
                        _OptionsRow(
                          icon: Icons.folder_outlined,
                          label: 'Salva in',
                          value: ref
                                      .read(settingsProvider)
                                      .destinationFolder !=
                                  null
                              ? ref
                                  .read(settingsProvider)
                                  .destinationFolder!
                                  .split('/')
                                  .last
                              : '/OpenCIE',
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
                        enabled:
                            _options.format == SignatureFormat.pades,
                        value: _options.graphicSignature &&
                            _options.format == SignatureFormat.pades,
                        onToggled: _onGraphicToggled,
                      ),
                    ),
                  _buildQuickToggle(
                    context,
                    cs,
                    label: l10n.signAddTimestamp,
                    enabled: true,
                    value: _options.addTimestamp,
                    onToggled: _onTimestampToggled,
                  ),

                  const SizedBox(height: 14),

                  // Reader status callout
                  _buildReaderCallout(context, cs),

                  const SizedBox(height: 14),

                  // Sign CTA
                  OcGradientButton(
                    label: l10n.signButton,
                    icon: Icons.contactless_rounded,
                    onPressed: _selectedFile != null &&
                            !_isSigning &&
                            !_waitingCard &&
                            _readerReady
                        ? _startSigning
                        : null,
                  ),
                  if (!Platform.isAndroid &&
                      !_readerReady &&
                      _selectedFile != null &&
                      !_isSigning) ...[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => DesktopHandoffPage(
                            filePath: _selectedFile!,
                          ),
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
    );
  }

  Widget _buildDesktopFileRow(
      BuildContext context, ColorScheme cs, AppLocalizations l10n) {
    final path = _selectedFile!;
    final name = path.split('/').last;
    final ext = name.split('.').last.toUpperCase();

    return Container(
      color: cs.primary.withValues(alpha: 0.06),
      padding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          OcFileTile(extension: ext, width: 28, height: 34),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name,
              style: TextStyle(fontFamily: 'Inter', 
                  color: cs.onSurface,
                  fontWeight: FontWeight.w600,
                  fontSize: 13),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 100,
            child: OcMonoText(
              _options.format.displayName.split(' ').first,
              fontSize: 11,
            ),
          ),
          SizedBox(
            width: 90,
            child: OcMonoText(
              _fileSizeCaption(path),
              fontSize: 11,
            ),
          ),
           SizedBox(
             width: 80,
             child: Row(
               children: [
                 Container(
                     width: 6,
                     height: 6,
                     decoration: BoxDecoration(
                         color: _readerReady
                             ? ColorSchemes.valid
                             : cs.onSurfaceVariant,
                         shape: BoxShape.circle)),
                 const SizedBox(width: 6),
                 Text(
                   _readerReady ? 'Pronto' : 'In attesa',
                   style: TextStyle(fontFamily: 'Inter', 
                       color: _readerReady
                           ? ColorSchemes.valid
                           : cs.onSurfaceVariant,
                       fontSize: 12,
                       fontWeight: FontWeight.w600),
                 ),
               ],
             ),
           ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 16),
            onPressed: () => setState(() => _selectedFile = null),
            padding: EdgeInsets.zero,
            constraints:
                const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
  }

  Widget _buildReaderCallout(BuildContext context, ColorScheme cs) {
    if (_readerReady) {
      // Reader present: show primary-tinted callout with green dot
      final readerLabel = Platform.isAndroid
          ? 'NFC pronto'
          : 'Lettore: ${_readerName!}';
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
                color: ColorSchemes.valid,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                readerLabel,
                style: TextStyle(fontFamily: 'Inter', 
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
                'Nessun lettore rilevato',
                style: TextStyle(fontFamily: 'Inter', 
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

  Widget _buildRecentSection(
      BuildContext context, List<RecentFile> recent) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(l10n.signRecentlySigned,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            TextButton.icon(
              onPressed: () =>
                  ref.read(recentSignedFilesProvider.notifier).clear(),
              icon: const Icon(Icons.delete_sweep, size: 18),
              label: Text(l10n.commonClear),
              style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          clipBehavior: Clip.hardEdge,
          child: Column(
            children: [
              for (var i = 0; i < recent.length; i++) ...[
                if (i > 0)
                  const Divider(height: 1, indent: 56, endIndent: 16),
                _buildRecentTile(recent[i], theme, l10n),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRecentTile(
      RecentFile file, ThemeData theme, AppLocalizations l10n) {
    final extColor = _extColor(file.extension, theme);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: extColor.withValues(alpha: 0.12),
        child: Text(file.extension,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: extColor)),
      ),
      title: Text(file.fileName,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_formatRelative(file.addedAt, l10n),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
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

/// 28×16 mini toggle pill used in the bottom options panel.
class _SignMiniToggle extends StatelessWidget {
  const _SignMiniToggle({required this.value});
  final bool value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 28,
      height: 16,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: value ? cs.primary : cs.surfaceContainerHigh,
        border:
            value ? null : Border.all(color: cs.outlineVariant),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        alignment:
            value ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: 12,
          height: 12,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

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
      padding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: cs.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontFamily: 'Inter', 
                  color: cs.onSurface,
                  fontWeight: FontWeight.w500,
                  fontSize: 13),
            ),
          ),
          OcMonoText(value, fontSize: 11, color: cs.onSurfaceVariant),
        ],
      ),
    );
  }
}
