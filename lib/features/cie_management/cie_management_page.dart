// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';
import 'dart:math' show min, max;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';


import '../../core/constants/app_constants.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/l10n/app_localizations_ext.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/color_schemes.dart';
import '../../ffi/opencie_pkcs11.dart';
import '../../models/enrolled_card.dart';
import '../../providers/settings_provider.dart';
import '../../services/ltv/asn1/x509_cert.dart';
import '../../services/nfc_service.dart';
import '../../widgets/nfc_card_dialog.dart';
import '../../widgets/oc_pulse_rings.dart';
import '../../widgets/oc_action_row.dart';
import '../../widgets/oc_gradient_button.dart';
import '../../widgets/oc_help_sheet.dart';
import '../../widgets/oc_section_label.dart';
import '../../services/cie_chip_reader.dart';
import 'widgets/cie_certificate_dialog.dart';
import 'widgets/cie_change_pin_dialog.dart';
import 'widgets/cie_confirm_remove_dialog.dart';
import 'widgets/cie_enroll_dialog.dart';
import 'widgets/cie_unblock_pin_dialog.dart';

/// Fetch the DER certificate for [card] from the native library and return
/// a copy enriched with X.509 fields (notAfter, issuer, subject, etc.).
/// Returns the original card unchanged if the cert cannot be retrieved.
Future<EnrolledCard> _enrichCardWithCert(EnrolledCard card) async {
  try {
    final der = await OpenCiePkcs11.instance.getCertificate(card.pan);
    if (der == null) return card;
    final info = X509CertInfo.fromDer(der);
    if (info == null) return card;
    return card.copyWith(
      notBefore: info.notBefore,
      notAfter: info.notAfter,
      issuer: info.issuer,
      subject: info.subject,
      certSerial: info.serial,
      keyAlgorithm: info.keyAlgorithm,
    );
  } catch (e, _) {
    return card;
  }
}

/// Read MRZ + photo from the chip and return an enriched card.
/// Returns the original card unchanged if chip reading fails.
Future<EnrolledCard> _enrichCardWithChip(
  EnrolledCard card,
  String pin, {
  ValueChanged<CieProgress>? onProgress,
}) async {
  try {
    return await CieChipReader.readAndEnrich(
      card: card,
      pin: pin,
      onProgress: onProgress,
    );
  } catch (_) {
    return card;
  }
}

class CieManagementPage extends ConsumerStatefulWidget {
  const CieManagementPage({super.key});

  @override
  ConsumerState<CieManagementPage> createState() => _CieManagementPageState();
}

class _CieManagementPageState extends ConsumerState<CieManagementPage>
    with WidgetsBindingObserver {
  bool _isProcessing = false;
  bool _nfcAvailable = false;
  String? _readerName;
  bool _readerChecked = false;
  bool _wizardSkipped = false;
  StreamSubscription<String?>? _readerSub;


  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkNfc();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check NFC availability when the user returns from the Settings screen.
    if (state == AppLifecycleState.resumed) {
      _checkNfc();
    }
  }

  Future<void> _checkNfc() async {
    if (Platform.isAndroid) {
      final available = await NfcService.instance.isAvailable;
      if (mounted) setState(() => _nfcAvailable = available);
    } else {
      _readerSub = OpenCiePkcs11.instance.watchReaders().listen((name) {
        if (mounted) setState(() { _readerName = name; _readerChecked = true; });
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _readerSub?.cancel();

    super.dispose();
  }

  /// Runs [operation] with a proper NFC card-tap flow on Android.
  ///
  /// On Android:
  ///   1. Checks NFC availability — shows snackbar + settings link if disabled.
  ///   2. Shows the [NfcCardDialog] in "waiting for card" mode with [processingTitle].
  ///   3. Starts the NFC reader session and waits for a card tap.
  ///   4. On tap → transitions dialog to "processing" mode and calls [operation].
  ///
  /// On desktop (PC/SC) the card must already be on the reader; the dialog
  /// jumps straight to processing mode and [operation] is called immediately.
  Future<void> _withNfc(
    String processingTitle,
    Future<void> Function(void Function(double, String) onProgress) operation,
  ) async {
    if (_isProcessing) return;

    // NFC availability guard (Android only).
    if (Platform.isAndroid) {
      final available = await NfcService.instance.isAvailable;
      if (!available && mounted) {
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.cieNfcNotAvailable),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: l10n.nfcEnableButton,
            onPressed: NfcService.instance.openNfcSettings,
          ),
        ));
        return;
      }
    }

    setState(() => _isProcessing = true);

    // (isWaiting, progress 0-1, progressMessage)
    final nfcNotifier =
        ValueNotifier<(bool, double, String)>((Platform.isAndroid, 0.0, ''));
    bool dialogOpen = false;
    Future<void>? dialogFuture;

    void closeDialog() {
      if (dialogOpen && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    if (mounted) {
      dialogOpen = true;
      dialogFuture = showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => NfcCardDialog(
          notifier: nfcNotifier,
          processingTitle: processingTitle,
          onCancel: () async {
            await NfcService.instance.stopSession();
            closeDialog();
            // Dispose only after the dialog route is fully gone.
            dialogFuture?.whenComplete(nfcNotifier.dispose);
            if (mounted) setState(() => _isProcessing = false);
          },
        ),
      ).whenComplete(() => dialogOpen = false);
    }

    Future<void> runOperation() async {
      final l10n = AppLocalizations.of(context);
      try {
        await operation((percent, message) {
          nfcNotifier.value =
              (false, percent, l10n.localizeProgress(message));
        });
      } finally {
        if (Platform.isAndroid) await NfcService.instance.stopSession();
        closeDialog();
        // Dispose only after the dialog route is fully gone.
        dialogFuture?.whenComplete(nfcNotifier.dispose);
        if (mounted) setState(() => _isProcessing = false);
      }
    }

    if (!Platform.isAndroid) {
      // Desktop: card already on reader, run immediately.
      await runOperation();
      return;
    }

    // Android: wait for card tap, then run operation.
    final completer = Completer<void>();
    await NfcService.instance.startSession(
      onTagDiscovered: () async {
        if (!mounted) {
          completer.complete();
          return;
        }
        // Transition dialog from "waiting" → "processing".
        nfcNotifier.value = (false, 0.0, '');
        await runOperation();
        completer.complete();
      },
      onTagFailed: () async {
        await NfcService.instance.stopSession();
        closeDialog();
        nfcNotifier.dispose();
        if (mounted) {
          setState(() => _isProcessing = false);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context).errCardError),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.error,
          ));
        }
        completer.complete();
      },
    );
    await completer.future;
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      backgroundColor: Theme.of(context).colorScheme.error,
    ));
  }

  void _showSuccessSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _showEnrollDialog() async {
    final pin = await showDialog<String>(
      context: context,
      builder: (_) => const CieEnrollDialog(),
    );
    if (pin == null || !mounted) return;

    final l10n = AppLocalizations.of(context);
    EnrolledCard? enrolledCard;

    if (!Platform.isAndroid) {
      // Desktop: single NFC session — enrol (0–40%), cert
      // (40–50%), chip read (50–100%).
      await _withNfc(l10n.cieEnrollingProgress, (onProgress) async {
        final result = await OpenCiePkcs11.instance.enable(
          pan: '',
          pin: pin,
          // cie_enable reports 0–100; map to 0–0.40
          onProgress: (p) =>
              onProgress(p.percent / 100.0 * 0.40, p.message),
        );
        if (result.isSuccess && result.enrolledPan != null) {
          var card = EnrolledCard(
            pan: result.enrolledPan!,
            name: result.enrolledName ?? '',
            serial: result.enrolledSerial ?? '',
          );
          // Cert fetch: 40–50%
          onProgress(0.42, l10n.cieEnrollingProgress);
          card = await _enrichCardWithCert(card);
          onProgress(0.50, l10n.cieEnrollingProgress);
          // Chip read: 50–100%
          card = await _enrichCardWithChip(card, pin,
              onProgress: (p) =>
                  onProgress(0.50 + p.percent / 100.0 * 0.50, p.message));
          enrolledCard = card;
        } else if (!result.isSuccess) {
          _showErrorSnackBar(
              result.isPinIncorrect
                  ? result.remainingAttempts != null
                      ? l10n.cieIncorrectPinAttempts(result.remainingAttempts!)
                      : l10n.signIncorrectPin
                  : result.isPinLocked
                      ? l10n.ciePinLockedUsePuk
                      : l10n.cieEnrolmentFailed(l10n.humanizeError(result.returnValue)));
        }
      });
    } else {
      // Android: Phase 1 — enrol (0–40%) + cert (40–50%).
      await _withNfc(l10n.cieEnrollingProgress, (onProgress) async {
        final result = await OpenCiePkcs11.instance.enable(
          pan: '',
          pin: pin,
          onProgress: (p) =>
              onProgress(p.percent / 100.0 * 0.40, p.message),
        );
        if (result.isSuccess && result.enrolledPan != null) {
          var card = EnrolledCard(
            pan: result.enrolledPan!,
            name: result.enrolledName ?? '',
            serial: result.enrolledSerial ?? '',
          );
          onProgress(0.42, l10n.cieEnrollingProgress);
          card = await _enrichCardWithCert(card);
          onProgress(0.50, l10n.cieEnrollingProgress);
          enrolledCard = card;
        } else if (!result.isSuccess) {
          _showErrorSnackBar(
              result.isPinIncorrect
                  ? result.remainingAttempts != null
                      ? l10n.cieIncorrectPinAttempts(result.remainingAttempts!)
                      : l10n.signIncorrectPin
                  : result.isPinLocked
                      ? l10n.ciePinLockedUsePuk
                      : l10n.cieEnrolmentFailed(l10n.humanizeError(result.returnValue)));
        }
      });

      if (enrolledCard != null) {
        // Phase 2 — chip read (0–100% of second dialog).
        var card = enrolledCard!;
        await _withNfc(l10n.cieReadingChip, (onProgress) async {
          card = await _enrichCardWithChip(card, pin,
              onProgress: (p) =>
                  onProgress(p.percent / 100.0, p.message));
        });
        enrolledCard = card;
      }
    }

    if (enrolledCard == null) return;

    // Persist the fully-enriched card.
    final card = enrolledCard!;
    final cards =
        List<EnrolledCard>.from(ref.read(settingsProvider).enrolledCards);
    final idx = cards.indexWhere((c) => c.pan == card.pan);
    if (idx >= 0) {
      cards[idx] = card;
    } else {
      cards.add(card);
    }
    ref.read(settingsProvider.notifier).update(
          (s) => s.copyWith(enrolledCards: cards),
        );
    _showSuccessSnackBar(
        l10n.cieEnrolledSuccess(card.displayName));
  }

  void _confirmRemove(BuildContext context, EnrolledCard card) {
    final l10n = AppLocalizations.of(context);
    showDialog<void>(
      context: context,
      builder: (_) => CieConfirmRemoveDialog(
        card: card,
        onConfirm: () {
          final rv = OpenCiePkcs11.instance.disable(card.pan);
          final cards = List<EnrolledCard>.from(
              ref.read(settingsProvider).enrolledCards)
            ..removeWhere((c) => c.pan == card.pan);
          ref
              .read(settingsProvider.notifier)
              .update((s) => s.copyWith(enrolledCards: cards));
          _showSuccessSnackBar(rv == 0
              ? l10n.cieRemovedSuccess(card.displayName)
              : l10n.cieRemoveFailed(l10n.humanizeError(rv)));
        },
      ),
    );
  }

  void _showChangePinDialog() {
    showDialog<(String, String)>(
      context: context,
      builder: (_) => const CieChangePinDialog(),
    ).then((result) {
      if (result == null || !mounted) return;
      final (currentPin, newPin) = result;
      final l10n = AppLocalizations.of(context);
      _withNfc(l10n.cieChangingPinProgress, (onProgress) async {
        final result = await OpenCiePkcs11.instance.changePin(
          currentPin: currentPin,
          newPin: newPin,
          onProgress: (p) =>
              onProgress(p.percent / 100.0, p.message),
        );
        if (result.isSuccess) {
          _showSuccessSnackBar(l10n.ciePinChanged);
        } else {
          _showErrorSnackBar(result.isPinIncorrect
              ? result.remainingAttempts != null
                  ? l10n.cieIncorrectPinAttempts(result.remainingAttempts!)
                  : l10n.signIncorrectPin
              : result.isPinLocked
                  ? l10n.ciePinLockedUsePuk
                  : l10n.ciePinChangeFailed(l10n.humanizeError(result.returnValue)));
        }
      });
    });
  }

  void _showUnblockPinDialog() {
    showDialog<(String, String)>(
      context: context,
      builder: (_) => const CieUnblockPinDialog(),
    ).then((result) {
      if (result == null || !mounted) return;
      final (puk, newPin) = result;
      final l10n = AppLocalizations.of(context);
      _withNfc(l10n.cieUnblockingPinProgress, (onProgress) async {
        final result = await OpenCiePkcs11.instance.unblockPin(
          puk: puk,
          newPin: newPin,
          onProgress: (p) =>
              onProgress(p.percent / 100.0, p.message),
        );
        if (result.isSuccess) {
          _showSuccessSnackBar(l10n.ciePinUnblocked);
        } else {
          _showErrorSnackBar(
              l10n.cieUnblockFailed(l10n.humanizeError(result.returnValue)));
        }
      });
    });
  }

  void _showCertificateDialog(BuildContext context, EnrolledCard card) {
    showDialog<void>(
      context: context,
      builder: (_) => CieCertificateDialog(card: card),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final cards = settings.enrolledCards;
    final showWizard = cards.isEmpty && !_wizardSkipped;

    return Scaffold(
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 400),
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
          child: child,
        ),
        child: showWizard
            ? _EnrolmentWizard(
                key: const ValueKey('wizard'),
                readerName: Platform.isAndroid ? null : _readerName,
                readerChecked: !Platform.isAndroid && _readerChecked,
                nfcAvailable: Platform.isAndroid ? _nfcAvailable : null,
                onSkip: () => setState(() => _wizardSkipped = true),
              )
            : cards.isEmpty
                ? _buildEmptyState(key: const ValueKey('empty'))
                : _buildMainContent(
                    key: const ValueKey('main'),
                    cards: cards,
                  ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  Widget _buildEmptyState({Key? key}) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    return CustomScrollView(
      key: key,
      slivers: [
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
                      Text(l10n.cieTitle, style: AppTheme.displayBold(cs)),
                      const SizedBox(height: 6),
                      Text(
                        l10n.cieSubtitle,
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
                      title: l10n.helpCieTitle,
                      icon: Icons.credit_card_rounded,
                      iconColor: cs.primary,
                      steps: [
                        OcHelpStep(title: l10n.helpCieStep1Title, body: l10n.helpCieStep1Body, icon: Icons.nfc_rounded),
                        OcHelpStep(title: l10n.helpCieStep2Title, body: l10n.helpCieStep2Body, icon: Icons.pin_rounded),
                        OcHelpStep(title: l10n.helpCieStep3Title, body: l10n.helpCieStep3Body, icon: Icons.lock_open_rounded),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.credit_card_outlined,
                    size: 64,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Nessuna carta registrata',
                    style: AppTheme.displayBold(cs),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Registra la tua CIE per iniziare a firmare documenti',
                    style: TextStyle(fontFamily: 'Inter', 
                      color: cs.onSurfaceVariant,
                      fontSize: 13,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  OcGradientButton(
                    label: AppLocalizations.of(context).cieAddCard,
                    icon: Icons.add_rounded,
                    onPressed: _isProcessing ? null : _showEnrollDialog,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Main content
  // ---------------------------------------------------------------------------

  Widget _buildMainContent({Key? key, required List<EnrolledCard> cards}) {
    return LayoutBuilder(
      key: key,
      builder: (context, constraints) {
        final isDesktop =
            constraints.maxWidth >= AppConstants.mediumBreakpoint;
        if (isDesktop && cards.length == 1) {
          return _buildDesktopSingleCard(cards.first);
        } else if (isDesktop) {
          return _buildMobileScroll(cards, maxWidth: 720);
        }
        return _buildMobileScroll(cards);
      },
    );
  }

  Widget _buildMobileScroll(List<EnrolledCard> cards, {double? maxWidth}) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final cardCount = cards.length;
    final cardLabel = cardCount == 1
        ? l10n.cieCardsEnrolled(1)
        : l10n.cieCardsEnrolledPlural(cardCount);
    final scrollView = CustomScrollView(
      slivers: [
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
                      Text(l10n.cieTitle, style: AppTheme.displayBold(cs)),
                      const SizedBox(height: 6),
                      Text(
                        l10n.cieSubtitle,
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
                if (cardCount > 0)
                  Text(
                    cardLabel,
                    style: AppTheme.monoCaption(cs, color: cs.onSurfaceVariant),
                  ),
                IconButton(
                  icon: const Icon(Icons.info_outline_rounded),
                  tooltip: l10n.helpButtonTooltip,
                  onPressed: () => OcHelpSheet.show(
                    context,
                    OcHelpSheet(
                      title: l10n.helpCieTitle,
                      icon: Icons.credit_card_rounded,
                      iconColor: cs.primary,
                      steps: [
                        OcHelpStep(title: l10n.helpCieStep1Title, body: l10n.helpCieStep1Body, icon: Icons.nfc_rounded),
                        OcHelpStep(title: l10n.helpCieStep2Title, body: l10n.helpCieStep2Body, icon: Icons.pin_rounded),
                        OcHelpStep(title: l10n.helpCieStep3Title, body: l10n.helpCieStep3Body, icon: Icons.lock_open_rounded),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: _CieHeroCard(
                  card: cards[i],
                  onRemove: () => _confirmRemove(context, cards[i]),
                  onChangePin: _showChangePinDialog,
                  onUnblockPin: _showUnblockPinDialog,
                  onInspectCertificate: () =>
                      _showCertificateDialog(context, cards[i]),
                ),
              ),
              childCount: cards.length,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: OutlinedButton.icon(
              onPressed: _isProcessing ? null : _showEnrollDialog,
              icon: const Icon(Icons.add_card_rounded),
              label: Text(l10n.cieAddCard),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            child: _NfcPromptCard(
              nfcAvailable: Platform.isAndroid ? _nfcAvailable : null,
              readerName: Platform.isAndroid ? null : _readerName,
              readerChecked: !Platform.isAndroid && _readerChecked,
            ),
          ),
        ),
      ],
    );
    if (maxWidth != null) {
      return Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: scrollView,
        ),
      );
    }
    return scrollView;
  }

  Widget _buildDesktopSingleCard(EnrolledCard card) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 8, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.cieTitle, style: AppTheme.displayBold(cs)),
                    const SizedBox(height: 6),
                    Text(
                      l10n.cieSubtitle,
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
              Text(
                l10n.cieCardsEnrolled(1),
                style: AppTheme.monoCaption(cs, color: cs.onSurfaceVariant),
              ),
              IconButton(
                icon: const Icon(Icons.info_outline_rounded),
                tooltip: l10n.helpButtonTooltip,
                onPressed: () => OcHelpSheet.show(
                  context,
                  OcHelpSheet(
                    title: l10n.helpCieTitle,
                    icon: Icons.credit_card_rounded,
                    iconColor: cs.primary,
                    steps: [
                      OcHelpStep(title: l10n.helpCieStep1Title, body: l10n.helpCieStep1Body, icon: Icons.nfc_rounded),
                      OcHelpStep(title: l10n.helpCieStep2Title, body: l10n.helpCieStep2Body, icon: Icons.pin_rounded),
                      OcHelpStep(title: l10n.helpCieStep3Title, body: l10n.helpCieStep3Body, icon: Icons.lock_open_rounded),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 5,
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _CieHero(card: card),
                            const SizedBox(height: 16),
                            _CieStats(card: card),
                            const SizedBox(height: 16),
                            _NfcPromptCard(
                              nfcAvailable:
                                  Platform.isAndroid ? _nfcAvailable : null,
                              readerName:
                                  Platform.isAndroid ? null : _readerName,
                              readerChecked:
                                  !Platform.isAndroid && _readerChecked,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 32),
                    Expanded(
                      flex: 6,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(l10n.cieTitle, style: AppTheme.displayBold(cs)),
                          const SizedBox(height: 6),
                          Text(
                            l10n.cieSubtitle,
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 13,
                              fontWeight: FontWeight.w400,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 20),
                          Expanded(
                            child: SingleChildScrollView(
                              child: _CieActions(
                                card: card,
                                onChangePin: _showChangePinDialog,
                                onUnblockPin: _showUnblockPinDialog,
                                onInspectCertificate: () =>
                                    _showCertificateDialog(context, card),
                                onRemove: () => _confirmRemove(context, card),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          OutlinedButton.icon(
                            onPressed:
                                _isProcessing ? null : _showEnrollDialog,
                            icon: const Icon(Icons.add_card_rounded),
                            label: Text(l10n.cieAddCard),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(48),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// CIE card sub-widgets
// Three focused widgets that can be composed independently per breakpoint.
// ---------------------------------------------------------------------------

/// The physical card hero — gradient container with tilt, chip, PAN.
/// Height is fixed at 200 px on every breakpoint per design spec.
class _CieHero extends StatelessWidget {
  const _CieHero({required this.card});

  final EnrolledCard card;

  String get _maskedPan {
    final p = card.pan;
    if (p.length <= 8) return p;
    final prefix = p.substring(0, min(4, p.length));
    final suffix = p.substring(max(0, p.length - 4));
    return '$prefix •••• $suffix';
  }

  @override
  Widget build(BuildContext context) {
    return Transform(
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.001)
        ..rotateX(-0.07),
      child: Container(
        height: 200,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: ColorSchemes.cieCardGradient,
          ),
          boxShadow: [
            BoxShadow(
              blurRadius: 50,
              offset: const Offset(0, 20),
              color: const Color(0xFF0D2B55).withValues(alpha: 0.6),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            // Shine overlay
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment(-0.7, -0.7),
                      end: Alignment(0.7, 0.7),
                      colors: [
                        Colors.transparent,
                        Color(0x1AFFFFFF),
                        Colors.transparent,
                      ],
                      stops: [0.30, 0.45, 0.60],
                    ),
                  ),
                ),
              ),
            ),
            // Card content
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'REPUBBLICA ITALIANA',
                            style: TextStyle(
                              fontFamily: 'JetBrainsMono',
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 9,
                              letterSpacing: 1.6,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'Carta d\'Identità Elettronica',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                       const Spacer(),
                       if (card.photoBytes != null)
                         ClipRRect(
                           borderRadius: BorderRadius.circular(6),
                           child: Image.memory(
                             card.photoBytes!,
                             width: 44,
                             height: 56,
                             fit: BoxFit.cover,
                              errorBuilder: (context, error, stack) => const Icon(
                               Icons.contactless_rounded,
                               size: 24,
                               color: Colors.white,
                             ),
                           ),
                         )
                       else
                         const Icon(
                           Icons.contactless_rounded,
                           size: 24,
                           color: Colors.white,
                         ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Gold chip
                      Container(
                        width: 38,
                        height: 28,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          gradient: const LinearGradient(
                            colors: ColorSchemes.cieChipGradient,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _maskedPan,
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono',
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: 4),
                       if (card.displayName.trim().isNotEmpty)
                         Text(
                           card.displayName.trim().toUpperCase(),
                           style: TextStyle(
                             fontFamily: 'JetBrainsMono',
                             color: Colors.white.withValues(alpha: 0.85),
                             fontSize: 11,
                           ),
                         ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 2×2 stats grid (STATO / SERIALE / SCADENZA / ULTIMO USO).
class _CieStats extends StatelessWidget {
  const _CieStats({required this.card});

  final EnrolledCard card;

  String get _shortSerial {
    final s = card.serial;
    if (s.isEmpty) return '';
    return s.length > 8 ? s.substring(s.length - 8) : s;
  }

  String get _expiryLabel {
    final d = card.mrzExpiry ?? card.notAfter;
    if (d == null) return '—';
    return '${d.day.toString().padLeft(2, '0')}/'
        '${d.month.toString().padLeft(2, '0')}/'
        '${d.year}';
  }

  Color? _expiryColor(BuildContext context) {
    final d = card.mrzExpiry ?? card.notAfter;
    if (d == null) return null;
    final now = DateTime.now();
    if (d.isBefore(now)) return ColorSchemes.invalid;
    if (d.isBefore(now.add(const Duration(days: 90)))) {
      return Theme.of(context).colorScheme.error;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      childAspectRatio: 2.4,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        _StatCard(
            label: 'STATO', value: 'ATTIVA', valueColor: ColorSchemes.valid),
        _StatCard(
          label: 'SERIALE',
          value: _shortSerial.isNotEmpty ? _shortSerial : '—',
        ),
        _StatCard(
          label: 'SCADENZA',
          value: _expiryLabel,
          valueColor: _expiryColor(context),
        ),
        _StatCard(label: 'ULTIMO USO', value: '—'),
      ],
    );
  }
}

/// OcGroupCard with the four CIE action rows.
class _CieActions extends StatelessWidget {
  const _CieActions({
    required this.card,
    required this.onChangePin,
    required this.onUnblockPin,
    required this.onInspectCertificate,
    required this.onRemove,
  });

  final EnrolledCard card;
  final VoidCallback onChangePin;
  final VoidCallback onUnblockPin;
  final VoidCallback onInspectCertificate;
  final VoidCallback onRemove;

  String get _shortSerial {
    final s = card.serial;
    if (s.isEmpty) return '';
    return s.length > 8 ? s.substring(s.length - 8) : s;
  }

  @override
  Widget build(BuildContext context) {
    return OcGroupCard(
      children: [
        OcActionRow(
          leadingIcon: Icons.lock_outline,
          title: 'Cambia PIN',
          subtitle: 'Modifica il PIN della CIE',
          onTap: onChangePin,
        ),
        OcActionRow(
          leadingIcon: Icons.fingerprint_outlined,
          title: 'Sblocca con PUK',
          subtitle: 'Ripristina il PIN bloccato',
          onTap: onUnblockPin,
        ),
        OcActionRow(
          leadingIcon: Icons.shield_outlined,
          title: 'Ispeziona certificato',
          subtitle: _shortSerial.isNotEmpty
              ? 'X.509 leaf · ${_shortSerial.toUpperCase()}'
              : 'Visualizza il certificato X.509',
          subtitleMono: _shortSerial.isNotEmpty,
          onTap: onInspectCertificate,
        ),
        OcActionRow(
          leadingIcon: Icons.remove_circle_outline,
          title: 'Rimuovi carta',
          tone: Theme.of(context).colorScheme.error,
          onTap: onRemove,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// CIE hero card — mobile composite (hero + stats + actions stacked)
// ---------------------------------------------------------------------------

class _CieHeroCard extends StatelessWidget {
  const _CieHeroCard({
    required this.card,
    required this.onRemove,
    required this.onChangePin,
    required this.onUnblockPin,
    required this.onInspectCertificate,
  });

  final EnrolledCard card;
  final VoidCallback onRemove;
  final VoidCallback onChangePin;
  final VoidCallback onUnblockPin;
  final VoidCallback onInspectCertificate;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CieHero(card: card),
        const SizedBox(height: 12),
        _CieStats(card: card),
        const SizedBox(height: 12),
        _CieActions(
          card: card,
          onChangePin: onChangePin,
          onUnblockPin: onUnblockPin,
          onInspectCertificate: onInspectCertificate,
          onRemove: onRemove,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Stat card (2-col grid item)
// ---------------------------------------------------------------------------

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          OcSectionLabel(label, dense: true),
          const SizedBox(height: 4),
          OcMonoText(
            value,
            fontSize: 14,
            weight: FontWeight.w700,
            color: valueColor,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Enrolment wizard
// ---------------------------------------------------------------------------

enum _WizardStep { welcome, detectReader, enrol, waitCard, success }

class _EnrolmentWizard extends ConsumerStatefulWidget {
  const _EnrolmentWizard({
    super.key,
    required this.readerName,
    required this.readerChecked,
    required this.nfcAvailable,
    required this.onSkip,
  });

  final String? readerName;
  final bool readerChecked;
  final bool? nfcAvailable;
  final VoidCallback onSkip;

  @override
  ConsumerState<_EnrolmentWizard> createState() => _EnrolmentWizardState();
}

class _EnrolmentWizardState extends ConsumerState<_EnrolmentWizard>
    with TickerProviderStateMixin {
  _WizardStep _step = _WizardStep.welcome;
  bool _autoAdvancing = false;

  final _pinCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  String? _pin;
  bool _enrolling = false;
  double _enrollProgress = 0;
  String _enrollMessage = '';
  String? _enrollError;
  EnrolledCard? _pendingCard;

  late final AnimationController _successCtrl;
  late final Animation<double> _successScale;

  @override
  void initState() {
    super.initState();
    _successCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _successScale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.15), weight: 60),
      TweenSequenceItem(tween: Tween(begin: 1.15, end: 0.92), weight: 20),
      TweenSequenceItem(tween: Tween(begin: 0.92, end: 1.0), weight: 20),
    ]).animate(CurvedAnimation(parent: _successCtrl, curve: Curves.easeOut));
  }

  @override
  void didUpdateWidget(_EnrolmentWizard old) {
    super.didUpdateWidget(old);
    if (_step != _WizardStep.detectReader || _autoAdvancing) return;

    final isDesktop = widget.nfcAvailable == null;
    final readerReady =
        isDesktop ? widget.readerName != null : widget.nfcAvailable == true;
    final wasReady =
        isDesktop ? old.readerName != null : old.nfcAvailable == true;

    if (readerReady && !wasReady) {
      _autoAdvancing = true;
      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted) {
          setState(() {
            _step = _WizardStep.enrol;
            _autoAdvancing = false;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _pinCtrl.clear();
    _pinCtrl.dispose();
    _successCtrl.dispose();
    super.dispose();
  }

  void _startWaitingForCard() {
    if (!Platform.isAndroid || !(widget.nfcAvailable ?? false)) {
      _enrol();
      return;
    }
    NfcService.instance.startSession(
      onTagDiscovered: () {
        if (mounted && !_enrolling) _enrol();
      },
    );
  }

  Future<void> _enrol() async {
    final pin = _pin;
    _pin = null;
    if (pin == null) return;

    setState(() {
      _enrolling = true;
      _enrollError = null;
      _enrollProgress = 0;
      _enrollMessage = '';
    });

    try {
      final l10n = AppLocalizations.of(context);
      // Helper to update wizard progress bar + message.
      void setProgress(double frac, String msg) {
        if (mounted) setState(() { _enrollProgress = frac; _enrollMessage = msg; });
      }

      final result = await OpenCiePkcs11.instance.enable(
        pan: '',
        pin: pin,
        // cie_enable reports 0–100; map to 0–0.40 so cert+chip have room.
        onProgress: (p) => setProgress(
          p.percent / 100.0 * 0.40,
          l10n.localizeProgress(p.message),
        ),
      );
      if (result.isSuccess && result.enrolledPan != null) {
        var pendingCard = EnrolledCard(
          pan: result.enrolledPan!,
          name: result.enrolledName ?? '',
          serial: result.enrolledSerial ?? '',
        );
        // Cert fetch: 40–50%
        setProgress(0.42, l10n.cieProgressReadCertificate);
        pendingCard = await _enrichCardWithCert(pendingCard);
        setProgress(0.50, l10n.cieProgressReadCertificate);

        // On desktop the card stays on the reader — read chip data immediately.
        // On Android the NFC session is stopped in the finally block below;
        // chip reading is skipped here and can be triggered later.
        if (!Platform.isAndroid) {
          // Chip read: 50–100%
          pendingCard = await _enrichCardWithChip(pendingCard, pin,
            onProgress: (p) => setProgress(
              0.50 + p.percent / 100.0 * 0.50,
              l10n.localizeProgress(p.message),
            ),
          );
        }

        _pendingCard = pendingCard;
        setState(() => _step = _WizardStep.success);
        _successCtrl.forward();
      } else {
        setState(() {
          _enrollError = result.isPinIncorrect
              ? result.remainingAttempts != null
                  ? l10n.cieIncorrectPinAttempts(result.remainingAttempts!)
                  : l10n.signIncorrectPin
              : result.isPinLocked
                  ? l10n.ciePinLockedUsePuk
                  : l10n.cieEnrolmentFailed(l10n.humanizeError(result.returnValue));
        });
      }
    } finally {
      if (Platform.isAndroid && (widget.nfcAvailable ?? false)) {
        await NfcService.instance.stopSession();
      }
      if (mounted) setState(() => _enrolling = false);
    }
  }

  /// Navigate back one wizard step. No-op on welcome/success.
  void _goBack() {
    switch (_step) {
      case _WizardStep.detectReader:
        setState(() => _step = _WizardStep.welcome);
      case _WizardStep.enrol:
        setState(() => _step = _WizardStep.detectReader);
      case _WizardStep.waitCard:
        if (_enrolling) return; // can't go back while enrolling
        if (Platform.isAndroid) NfcService.instance.stopSession();
        setState(() {
          _step = _WizardStep.enrol;
          _enrollError = null;
        });
      case _WizardStep.welcome:
      case _WizardStep.success:
        break;
    }
  }

  void _finish() {
    final card = _pendingCard;
    if (card != null) {
      final cards =
          List<EnrolledCard>.from(ref.read(settingsProvider).enrolledCards);
      cards.add(card);
      ref.read(settingsProvider.notifier).update(
            (s) => s.copyWith(enrolledCards: cards),
          );
    } else {
      widget.onSkip();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final canGoBack = _step == _WizardStep.detectReader ||
        _step == _WizardStep.enrol ||
        (_step == _WizardStep.waitCard && !_enrolling);
    return KeyboardListener(
      focusNode: FocusNode(),
      autofocus: true,
      onKeyEvent: (event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          _goBack();
        }
      },
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 360),
            decoration: BoxDecoration(
              color: cs.surfaceContainer,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                // ── Radial-wash background ──────────────────────────────
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: const Alignment(0, -0.3),
                          radius: 1.1,
                          colors: [
                            ColorSchemes.primary.withValues(alpha: 0.18),
                            Colors.transparent,
                          ],
                          stops: const [0.0, 0.6],
                        ),
                      ),
                    ),
                  ),
                ),
                // ── Back button ─────────────────────────────────────────
                if (canGoBack)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: IconButton(
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: _goBack,
                      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    ),
                  ),
                // ── Content column ──────────────────────────────────────
                Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 28,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildStepDots(),
                    const SizedBox(height: 8),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 350),
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: CurvedAnimation(
                            parent: anim, curve: Curves.easeOut),
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0.04, 0),
                            end: Offset.zero,
                          ).animate(CurvedAnimation(
                              parent: anim, curve: Curves.easeOut)),
                          child: child,
                        ),
                      ),
                      child: switch (_step) {
                        _WizardStep.welcome => _buildWelcome(),
                        _WizardStep.detectReader => _buildDetectReader(),
                        _WizardStep.enrol => _buildEnrol(),
                        _WizardStep.waitCard => _buildWaitCard(),
                        _WizardStep.success => _buildSuccess(),
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    );
  }

  Widget _buildStepDots() {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: _WizardStep.values.map((s) {
        final isActive = s == _step;
        final isPast = s.index < _step.index;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: isActive ? 24 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: isActive || isPast
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildWelcome() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    return Column(
      key: const ValueKey('welcome'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 40),
        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                theme.colorScheme.primary,
                theme.colorScheme.tertiary,
              ],
            ),
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.primary.withValues(alpha: 0.28),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: const Icon(Icons.credit_card_rounded,
              color: Colors.white, size: 52),
        ),
        const SizedBox(height: 36),
        Text(
          l10n.wizardSetupTitle,
          style: AppTheme.headlineBold(cs),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(
          Platform.isAndroid
              ? l10n.wizardSetupBodyNfc
              : l10n.wizardSetupBodyDesktop,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 44),
        FilledButton.icon(
          onPressed: () => setState(() => _step = _WizardStep.detectReader),
          icon: const Icon(Icons.arrow_forward_rounded),
          label: Text(l10n.wizardGetStarted),
          style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52)),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: widget.onSkip,
          child: Text(l10n.wizardSkip),
        ),
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _buildDetectReader() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final isDesktop = widget.nfcAvailable == null;
    final readerReady =
        isDesktop ? widget.readerName != null : widget.nfcAvailable == true;
    final icon =
        isDesktop ? Icons.usb_rounded : Icons.contactless_rounded;

    final String headline;
    final String statusText;
    final String? hintText;

    if (isDesktop) {
      headline = l10n.wizardSmartCardReader;
      if (readerReady) {
        statusText = widget.readerName!;
        hintText = null;
      } else if (!widget.readerChecked) {
        statusText = l10n.wizardScanningReaders;
        hintText = l10n.wizardReadersSupported;
      } else {
        statusText = l10n.wizardNoReaderDetected;
        hintText = l10n.wizardConnectReader;
      }
    } else {
      headline = 'NFC';
      statusText = readerReady
          ? l10n.wizardNfcReady
          : l10n.wizardNfcUnavailable;
      hintText = null;
    }

    return Column(
      key: const ValueKey('detectReader'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 32),
        SizedBox(
          width: 168,
          height: 168,
          child: Stack(
            alignment: Alignment.center,
            children: [
              const OcPulseRings(size: 168, ringCount: 4),
              OcGlowChip(size: 80, icon: icon),
            ],
          ),
        ),
        const SizedBox(height: 28),
        Text(
          headline,
          style: AppTheme.headlineBold(cs),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 10),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: Text(
            statusText,
            key: ValueKey(statusText),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: readerReady
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
              fontWeight: readerReady ? FontWeight.w600 : null,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        if (hintText != null) ...[
          const SizedBox(height: 6),
          Text(
            hintText,
            style: theme.textTheme.bodySmall?.copyWith(
              color:
                  theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.65),
            ),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 40),
        if (readerReady)
          FilledButton.icon(
            onPressed: () => setState(() => _step = _WizardStep.enrol),
            icon: const Icon(Icons.arrow_forward_rounded),
            label: Text(AppLocalizations.of(context).wizardNext),
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52)),
          )
        else if (!isDesktop)
          FilledButton.icon(
            onPressed: () => NfcService.instance.openNfcSettings(),
            icon: const Icon(Icons.settings_outlined),
            label: Text(AppLocalizations.of(context).nfcEnableButton),
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52)),
          ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: widget.onSkip,
          child: Text(AppLocalizations.of(context).wizardSkip),
        ),
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _buildEnrol() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final isDesktop = widget.nfcAvailable == null;
    final deviceLabel =
        isDesktop ? (widget.readerName ?? l10n.wizardSmartCardReader) : 'NFC';
    final deviceIcon =
        isDesktop ? Icons.usb_rounded : Icons.contactless_rounded;

    return Column(
      key: const ValueKey('enrol'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 28),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(deviceIcon,
                  color: theme.colorScheme.primary, size: 18),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                deviceLabel,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text(
          l10n.wizardEnrolTitle,
          style: AppTheme.headlineBold(cs),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          l10n.wizardEnrolBody,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 28),
        Form(
          key: _formKey,
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _pinCtrl,
            builder: (_, val, _) => TextFormField(
              controller: _pinCtrl,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 8,
              autofocus: true,
              textInputAction: TextInputAction.done,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onFieldSubmitted: (_) {
                if (_formKey.currentState?.validate() ?? false) {
                  setState(() {
                    _pin = _pinCtrl.text;
                    _step = _WizardStep.waitCard;
                    _enrollError = null;
                  });
                  _startWaitingForCard();
                }
              },
              decoration: InputDecoration(
                labelText: l10n.ciePinAll8Digits,
                prefixIcon: const Icon(Icons.pin_rounded),
                suffixIcon: val.text.length == 8
                    ? const Icon(Icons.check_circle_rounded,
                        color: Colors.green)
                    : null,
              ),
              validator: (v) =>
                  v != null && v.length == 8 ? null : l10n.ciePinMust8Digits,
            ),
          ),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: () {
            if (_formKey.currentState?.validate() ?? false) {
              setState(() {
                _pin = _pinCtrl.text;
                _step = _WizardStep.waitCard;
                _enrollError = null;
              });
              _startWaitingForCard();
            }
          },
          icon: const Icon(Icons.arrow_forward_rounded),
          label: Text(l10n.wizardNext),
          style:
              FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: widget.onSkip,
          child: Text(l10n.wizardSkip),
        ),
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _buildWaitCard() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final hasError = _enrollError != null && !_enrolling;
    final isPcsc = !Platform.isAndroid;

    return Column(
      key: const ValueKey('waitCard'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.cieEnrollingProgress.toUpperCase(),
          style: AppTheme.monoCaption(cs),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: 168,
          height: 168,
          child: Stack(
            alignment: Alignment.center,
            children: [
              OcPulseRings(
                size: 168,
                ringCount: 4,
                color: hasError ? theme.colorScheme.error : null,
              ),
              OcGlowChip(
                size: 80,
                icon: Icons.contactless_rounded,
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        Text(
          _enrolling
              ? l10n.cieEnrollingProgress
              : (isPcsc ? l10n.wizardPlaceCardTitlePcsc : l10n.wizardPlaceCardTitle),
          style: AppTheme.headlineBold(cs),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        if (_enrolling) ...[
          if (_enrollMessage.isNotEmpty) ...[
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Text(
                _enrollMessage,
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 12),
          ] else
            const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _enrollProgress > 0 ? _enrollProgress : null,
              minHeight: 4,
              backgroundColor: cs.primary.withValues(alpha: 0.14),
              valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
            ),
          ),
        ] else if (hasError) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline_rounded,
                    color: theme.colorScheme.onErrorContainer, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _enrollError!,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () {
              setState(() => _enrollError = null);
              _startWaitingForCard();
            },
            icon: const Icon(Icons.refresh_rounded),
            label: Text(l10n.wizardPlaceCardRetry),
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52)),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => setState(() => _step = _WizardStep.enrol),
            child: Text(l10n.wizardPlaceCardBack),
          ),
        ] else ...[
          Text(
            isPcsc ? l10n.wizardPlaceCardBodyPcsc : l10n.wizardPlaceCardBody,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => setState(() => _step = _WizardStep.enrol),
            child: Text(l10n.wizardPlaceCardBack),
          ),
        ],
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _buildSuccess() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final card = _pendingCard;
    const green = Color(0xFF2E7D32);

    return Column(
      key: const ValueKey('success'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 48),
        ScaleTransition(
          scale: _successScale,
          child: Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              color: green,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: green.withValues(alpha: 0.35),
                  blurRadius: 28,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: const Icon(Icons.check_rounded,
                color: Colors.white, size: 54),
          ),
        ),
        const SizedBox(height: 32),
        Text(
          AppLocalizations.of(context).wizardEnrolled,
          style: AppTheme.headlineBold(cs).copyWith(color: green),
          textAlign: TextAlign.center,
        ),
        if (card != null) ...[
          const SizedBox(height: 12),
          if (card.name.trim().isNotEmpty)
            Text(
              card.name.trim(),
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
          const SizedBox(height: 4),
          Text(
            card.pan,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFamily: 'JetBrainsMono',
            ),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 48),
        FilledButton.icon(
          onPressed: _finish,
          icon: const Icon(Icons.check_circle_outline_rounded),
          label: Text(AppLocalizations.of(context).wizardDone),
          style:
              FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        ),
        const SizedBox(height: 40),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// NFC prompt card
// ---------------------------------------------------------------------------

class _NfcPromptCard extends StatefulWidget {
  const _NfcPromptCard({
    this.nfcAvailable,
    this.readerName,
    this.readerChecked = false,
  });

  final bool? nfcAvailable;
  final String? readerName;
  final bool readerChecked;

  @override
  State<_NfcPromptCard> createState() => _NfcPromptCardState();
}

class _NfcPromptCardState extends State<_NfcPromptCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final bool isDesktop = widget.nfcAvailable == null;

    final String title;
    final String statusText;
    final Color iconColor;

    if (isDesktop) {
      title = l10n.cieSmartCardReaderTitle;
      if (!widget.readerChecked) {
        statusText = l10n.cieCheckingReaders;
        iconColor = theme.colorScheme.onSurfaceVariant;
      } else if (widget.readerName == null) {
        statusText = l10n.cieNoReaderConnected;
        iconColor = theme.colorScheme.error;
      } else {
        statusText = widget.readerName!;
        iconColor = theme.colorScheme.primary;
      }
    } else {
      title = l10n.cieNfcReaderTitle;
      if (widget.nfcAvailable!) {
        statusText = l10n.cieNfcAvailable;
        iconColor = theme.colorScheme.primary;
      } else {
        statusText = l10n.cieNfcNotAvailable;
        iconColor = theme.colorScheme.onSurfaceVariant;
      }
    }

    final showEnableButton =
        !isDesktop && widget.nfcAvailable == false;

    return Card(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: Row(
          children: [
            AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => Opacity(
                opacity: 0.4 + _controller.value * 0.6,
                child: child,
              ),
              child: Icon(
                isDesktop ? Icons.usb : Icons.contactless,
                size: 40,
                color: iconColor,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(statusText,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            if (showEnableButton) ...[
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: () => NfcService.instance.openNfcSettings(),
                child: Text(l10n.nfcEnableButton),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
