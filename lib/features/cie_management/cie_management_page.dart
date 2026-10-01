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
import '../../models/enrolled_card_utils.dart';
import '../../models/enrolled_card.dart';
import '../../providers/settings_provider.dart';
import '../../services/ltv/asn1/x509_cert.dart';
import '../../services/nfc_service.dart';
import '../../widgets/nfc_card_dialog.dart';
import '../../widgets/pin_entry_dialog.dart';
import '../../widgets/oc_card_avatar.dart';
import '../../widgets/oc_pulse_rings.dart';
import '../../widgets/oc_action_row.dart';
import '../../widgets/oc_gradient_button.dart';
import '../../widgets/oc_help_sheet.dart';
import '../../widgets/oc_page.dart';
import '../../widgets/oc_section_label.dart';
import '../../services/cie_error.dart';
import '../../services/pin_throttle.dart';
import '../../services/cie_chip_reader.dart';
import 'cert_refresh.dart';
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
  } catch (e) {
    debugPrint(
      '_enrichCardWithCert: cert fetch failed ($e), keeping card as-is',
    );
    return card;
  }
}

/// Read MRZ + photo from the chip and return the outcome (what was read,
/// and why not when incomplete). Never throws: chip-read failures are
/// reported through [ChipReadOutcome.errorKind] rather than an exception,
/// so callers can offer a retry instead of silently saving a partial card.
Future<ChipReadOutcome> _readChip(
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
  } catch (e) {
    debugPrint('_readChip: chip read failed ($e), keeping card as-is');
    return ChipReadOutcome(
      card: card,
      mrzRead: false,
      photoRead: false,
      errorKind: CieErrorKind.cardCommunicationError,
    );
  }
}

/// True for [CieErrorKind]s that reflect the card's own PIN verification
/// outcome (63Cx/6983 status words) rather than a transport failure.
/// Retrying a chip read after one of these would re-run the PIN verify
/// step and risk burning an extra wrong-PIN attempt, so callers must stop
/// and surface the error instead of offering Retry — see PIN safety rules.
bool isPinStatusErrorKind(CieErrorKind? kind) {
  switch (kind) {
    case CieErrorKind.wrongPin:
    case CieErrorKind.pinBlocked:
    case CieErrorKind.wrongPinFormat:
    case CieErrorKind.pinExpired:
      return true;
    default:
      return false;
  }
}

/// Shows the chip-read-incomplete state (missing MRZ and/or photo) as a
/// standalone [NfcCardDialog] error view. When [allowRetry] is true (the
/// default) a Retry action is shown alongside "Continue without"; pass
/// false for a plain dismiss-only error view (e.g. after a PIN-status
/// failure, where retrying would risk an extra wrong-PIN attempt).
/// Returns true when the user chose Retry. Shared by the wizard and the
/// post-enrolment dialog flow, and by the card-page "Read chip data"
/// action.
Future<bool> showChipReadIncompleteDialog(
  BuildContext context,
  String message, {
  bool allowRetry = true,
}) async {
  if (!context.mounted) return false;
  final l10n = AppLocalizations.of(context);
  final notifier = ValueNotifier<(bool, double, String)>((false, 1.0, ''));
  final errorNotifier = ValueNotifier<String?>(message);
  var retry = false;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => NfcCardDialog(
      notifier: notifier,
      processingTitle: '',
      errorNotifier: errorNotifier,
      onDismissError: () =>
          Navigator.of(dialogContext, rootNavigator: true).pop(),
      onRetry: allowRetry
          ? () {
              retry = true;
              Navigator.of(dialogContext, rootNavigator: true).pop();
            }
          : null,
      continueLabel: allowRetry ? l10n.cieReadContinueWithout : null,
    ),
  );
  notifier.dispose();
  errorNotifier.dispose();
  return retry;
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
  bool _certRefreshDone = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkNfc();
    _refreshMissingCerts();
  }

  /// One-shot, per-page-lifetime refresh of certificate fields for cards
  /// that were enrolled while cert enrichment failed (e.g. legacy pkcs11
  /// cache format). No-op when the native lib can't produce a cert
  /// (getCertificate throws/returns null — already caught internally by
  /// [_enrichCardWithCert]), so this is safe in widget tests too.
  Future<void> _refreshMissingCerts() async {
    if (_certRefreshDone) return;
    _certRefreshDone = true;
    final cards = ref.read(settingsProvider).enrolledCards;
    final updated = await refreshMissingCertData(
      cards,
      fetchCert: _enrichCardWithCert,
    );
    if (updated == null || !mounted) return;
    ref
        .read(settingsProvider.notifier)
        .update((s) => s.copyWith(enrolledCards: updated));
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
        if (mounted) {
          setState(() {
            _readerName = name;
            _readerChecked = true;
          });
        }
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

    // NFC availability guard (Android only). Rather than a SnackBar-and-bail,
    // open the dialog in its inline "NFC is off" state so the user gets an
    // in-context settings shortcut without losing the operation they picked.
    final nfcDisabledNotifier = ValueNotifier<bool>(false);
    if (Platform.isAndroid) {
      final available = await NfcService.instance.isAvailable;
      if (!available && mounted) {
        nfcDisabledNotifier.value = true;
      }
    }

    setState(() => _isProcessing = true);
    // (isWaiting, progress 0-1, progressMessage)
    final nfcNotifier = ValueNotifier<(bool, double, String)>((
      Platform.isAndroid,
      0.0,
      '',
    ));
    // Non-null once a classified failure needs to be shown inline in the
    // dialog (currently: NFC tag-read failure) instead of a SnackBar.
    final errorNotifier = ValueNotifier<String?>(null);
    bool dialogOpen = false;
    var cleanedUp = false;

    void closeDialog() {
      if (dialogOpen && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    // Idempotent: resets `_isProcessing` and disposes the notifiers exactly
    // once, however the dialog ends up closing (Cancel, dismiss-error,
    // successful/failed operation, or a back-gesture/Navigator pop that
    // bypasses all of the above).
    void finishNfc() {
      if (cleanedUp) return;
      cleanedUp = true;
      nfcNotifier.dispose();
      errorNotifier.dispose();
      nfcDisabledNotifier.dispose();
      if (mounted) setState(() => _isProcessing = false);
    }

    if (mounted) {
      dialogOpen = true;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => NfcCardDialog(
          notifier: nfcNotifier,
          processingTitle: processingTitle,
          onCancel: () async {
            await NfcService.instance.stopSession();
            closeDialog();
          },
          errorNotifier: errorNotifier,
          onDismissError: closeDialog,
          nfcDisabledNotifier: nfcDisabledNotifier,
          onOpenNfcSettings: NfcService.instance.openNfcSettings,
          onDismissNfcDisabled: closeDialog,
        ),
      ).whenComplete(() {
        dialogOpen = false;
        // Safety net: whatever closed the dialog route (including a
        // back-gesture/Navigator pop that bypassed onCancel and
        // onDismissError), make sure the busy flag and NFC session
        // are still cleaned up.
        finishNfc();
      });
    }

    Future<void> runOperation() async {
      final l10n = AppLocalizations.of(context);
      try {
        await operation((percent, message) {
          nfcNotifier.value = (false, percent, l10n.localizeProgress(message));
        });
      } finally {
        if (Platform.isAndroid) await NfcService.instance.stopSession();
        closeDialog();
        // dialogFuture's whenComplete calls finishNfc() once the route is
        // actually gone; nothing further to do here.
      }
    }

    if (nfcDisabledNotifier.value) {
      // Dialog is open showing the inline "NFC is off" state; the user
      // must dismiss it (via `closeDialog` → `finishNfc`) and retry once
      // NFC is back on — no session to start or card to wait for yet.
      return;
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
        if (mounted) {
          errorNotifier.value = cieErrorMessage(
            AppLocalizations.of(context),
            CieErrorKind.cardCommunicationError,
          );
        }
        completer.complete();
      },
    );
    await completer.future;
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }

  void _showSuccessSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  /// Reads MRZ + photo, retrying (bounded, transport failures only — see
  /// [ChipReadOutcome.errorKind], which [CieChipReader.readAndEnrich] never
  /// sets from a PIN status word) until the read is complete or the user
  /// picks "Continue without". Each attempt is a full fresh PACE/DH + SM
  /// session via [_withNfc] (re-tap on Android, same reader session on
  /// desktop).
  Future<ChipReadOutcome> _readChipWithRetry({
    required EnrolledCard card,
    required String pin,
    required String processingTitle,
  }) async {
    const maxRetries = 2;
    var outcome = ChipReadOutcome(card: card, mrzRead: false, photoRead: false);
    for (var attempt = 0; ; attempt++) {
      await _withNfc(processingTitle, (onProgress) async {
        outcome = await _readChip(
          outcome.card,
          pin,
          onProgress: (p) => onProgress(p.percent / 100.0, p.message),
        );
      });
      if (outcome.isComplete || attempt >= maxRetries || !mounted) break;
      final l10n = AppLocalizations.of(context);
      final pinStatusError = isPinStatusErrorKind(outcome.errorKind);
      final message = pinStatusError
          ? cieErrorMessage(l10n, outcome.errorKind!)
          : (Platform.isAndroid
                ? l10n.cieReadIncompleteNfc
                : l10n.cieReadIncompletePcsc);
      if (outcome.errorKind == CieErrorKind.wrongPin) {
        PinThrottle.recordFailure();
      }
      final wantsRetry = await showChipReadIncompleteDialog(
        context,
        message,
        allowRetry: !pinStatusError,
      );
      if (pinStatusError || !wantsRetry) break;
    }
    return outcome;
  }

  /// Card-page "Read chip data" action for an already-enrolled card
  /// missing MRZ/photo: asks for the PIN (shared [PinEntryDialog] +
  /// [PinThrottle]), reads the chip with the same bounded retry as
  /// enrolment, and upserts the result by PAN.
  Future<void> _readChipForCard(EnrolledCard card) async {
    if (_isProcessing) return;
    final l10n = AppLocalizations.of(context);
    final pin = await PinEntryDialog.show(
      context,
      title: l10n.cieReadChipAction,
    );
    if (pin == null || !mounted) return;

    final outcome = await _readChipWithRetry(
      card: card,
      pin: pin,
      processingTitle: l10n.cieReadingChip,
    );

    if (!mounted) return;
    final cards = upsertEnrolledCard(
      ref.read(settingsProvider).enrolledCards,
      outcome.card,
    );
    ref
        .read(settingsProvider.notifier)
        .update((s) => s.copyWith(enrolledCards: cards));
    if (outcome.isComplete) {
      _showSuccessSnackBar(l10n.cieEnrolledSuccess(outcome.card.displayName));
    }
  }

  Future<void> _showEnrollDialog() async {
    final pin = await showDialog<String>(
      context: context,
      builder: (_) => const CieEnrollDialog(),
    );
    if (pin == null || !mounted) return;

    final l10n = AppLocalizations.of(context);
    EnrolledCard? enrolledCard;

    // Phase 1 — enrol (0–40%) + cert (40–50%). Same shape on desktop and
    // Android: on Android the NFC session ends here; on desktop the card
    // stays on the reader so phase 2 below runs immediately after.
    await _withNfc(l10n.cieEnrollingProgress, (onProgress) async {
      final result = await OpenCiePkcs11.instance.enable(
        pan: '',
        pin: pin,
        onProgress: (p) => onProgress(p.percent / 100.0 * 0.40, p.message),
      );
      if (result.isSuccess && result.enrolledPan != null) {
        PinThrottle.reset();
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
        if (classifyCieError(
              result.returnValue,
              nativeErrorKind: result.nativeErrorKind,
            ) ==
            CieErrorKind.wrongPin) {
          PinThrottle.recordFailure();
        }
        _showErrorSnackBar(
          cieErrorMessage(
            l10n,
            classifyCieError(
              result.returnValue,
              nativeErrorKind: result.nativeErrorKind,
            ),
            remainingAttempts: result.remainingAttempts,
          ),
        );
      }
    });

    if (enrolledCard != null) {
      // Phase 2 — chip read, with bounded retry on transport failures.
      final outcome = await _readChipWithRetry(
        card: enrolledCard!,
        pin: pin,
        processingTitle: l10n.cieReadingChip,
      );
      enrolledCard = outcome.card;
    }

    if (enrolledCard == null) return;

    // Persist the fully-enriched card. Merges into any existing entry
    // with the same PAN (re-enrolment) so a partial read doesn't wipe
    // out previously-captured fields such as the MRZ photo.
    final card = enrolledCard!;
    final cards = upsertEnrolledCard(
      ref.read(settingsProvider).enrolledCards,
      card,
    );
    ref
        .read(settingsProvider.notifier)
        .update(
          (s) => s.copyWith(enrolledCards: cards, selectedCardPan: card.pan),
        );
    _showSuccessSnackBar(l10n.cieEnrolledSuccess(card.displayName));
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
            ref.read(settingsProvider).enrolledCards,
          )..removeWhere((c) => c.pan == card.pan);
          ref
              .read(settingsProvider.notifier)
              .update((s) => s.copyWith(enrolledCards: cards));
          _showSuccessSnackBar(
            rv == 0
                ? l10n.cieRemovedSuccess(card.displayName)
                : l10n.cieRemoveFailed(l10n.humanizeError(rv)),
          );
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
          onProgress: (p) => onProgress(p.percent / 100.0, p.message),
        );
        if (result.isSuccess) {
          PinThrottle.reset();
          _showSuccessSnackBar(l10n.ciePinChanged);
        } else {
          if (classifyCieError(
                result.returnValue,
                nativeErrorKind: result.nativeErrorKind,
              ) ==
              CieErrorKind.wrongPin) {
            PinThrottle.recordFailure();
          }
          _showErrorSnackBar(
            cieErrorMessage(
              l10n,
              classifyCieError(
                result.returnValue,
                nativeErrorKind: result.nativeErrorKind,
              ),
              remainingAttempts: result.remainingAttempts,
            ),
          );
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
          onProgress: (p) => onProgress(p.percent / 100.0, p.message),
        );
        if (result.isSuccess) {
          PinThrottle.reset();
          _showSuccessSnackBar(l10n.ciePinUnblocked);
        } else {
          if (classifyCieError(
                result.returnValue,
                nativeErrorKind: result.nativeErrorKind,
              ) ==
              CieErrorKind.wrongPin) {
            PinThrottle.recordFailure();
          }
          _showErrorSnackBar(
            cieErrorMessage(
              l10n,
              classifyCieError(
                result.returnValue,
                nativeErrorKind: result.nativeErrorKind,
              ),
            ),
          );
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
            : _buildMainContent(key: const ValueKey('main'), cards: cards),
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
        OcPageBody.sliver(
          child: SliverToBoxAdapter(child: _buildPageHeader(0)),
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
                    l10n.cieNoCardsEnrolled,
                    style: AppTheme.displayBold(cs),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    l10n.cieEmptyBody,
                    style: TextStyle(
                      fontFamily: 'Inter',
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
        final isDesktop = constraints.maxWidth >= AppConstants.mediumBreakpoint;
        final selected =
            ref.watch(settingsProvider).selectedCard ?? cards.first;
        if (cards.length > 1) {
          return isDesktop
              ? _buildMasterDetail(cards, selected)
              : _buildCardList(cards);
        }
        if (isDesktop) return _buildDesktopSingleCard(cards.first);
        return _buildMobileScroll(cards);
      },
    );
  }

  /// Title, subtitle (with the card count folded in) and help button shared
  /// by every layout. Callers place it inside an [OcPageBody].
  Widget _buildPageHeader(int cardCount) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    return OcPageHeader(
      title: l10n.cieTitle,
      subtitle: cardCount > 0
          ? l10n.cieSubtitleWithCount(l10n.cieSubtitle, cardCount)
          : l10n.cieSubtitle,
      actions: [
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
                OcHelpStep(
                  title: l10n.helpCieStep1Title,
                  body: l10n.helpCieStep1Body,
                  icon: Icons.nfc_rounded,
                ),
                OcHelpStep(
                  title: l10n.helpCieStep2Title,
                  body: l10n.helpCieStep2Body,
                  icon: Icons.pin_rounded,
                ),
                OcHelpStep(
                  title: l10n.helpCieStep3Title,
                  body: l10n.helpCieStep3Body,
                  icon: Icons.lock_open_rounded,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMobileScroll(List<EnrolledCard> cards) {
    final l10n = AppLocalizations.of(context);
    Widget body(Widget child) => OcPageBody.sliver(
      maxWidth: 760,
      child: SliverToBoxAdapter(child: child),
    );
    return CustomScrollView(
      slivers: [
        body(_buildPageHeader(cards.length)),
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
        OcPageBody.sliver(
          maxWidth: 760,
          child: SliverList(
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
                  onReadChip: () => _readChipForCard(cards[i]),
                ),
              ),
              childCount: cards.length,
            ),
          ),
        ),
        body(
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
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
        body(
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 32),
            child: _NfcPromptCard(
              nfcAvailable: Platform.isAndroid ? _nfcAvailable : null,
              readerName: Platform.isAndroid ? null : _readerName,
              readerChecked: !Platform.isAndroid && _readerChecked,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDesktopSingleCard(EnrolledCard card) {
    final l10n = AppLocalizations.of(context);
    return OcPageBody(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildPageHeader(1),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 24, 0, 24),
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
                                nfcAvailable: Platform.isAndroid
                                    ? _nfcAvailable
                                    : null,
                                readerName: Platform.isAndroid
                                    ? null
                                    : _readerName,
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
                            Expanded(
                              child: SingleChildScrollView(
                                child: _CieActions(
                                  card: card,
                                  onChangePin: _showChangePinDialog,
                                  onUnblockPin: _showUnblockPinDialog,
                                  onInspectCertificate: () =>
                                      _showCertificateDialog(context, card),
                                  onRemove: () => _confirmRemove(context, card),
                                  onReadChip: () => _readChipForCard(card),
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            OutlinedButton.icon(
                              onPressed: _isProcessing
                                  ? null
                                  : _showEnrollDialog,
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
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Multi-card layouts (2+ cards)
  // ---------------------------------------------------------------------------

  /// Selects [card] as the active one (shared with the sign page's signer).
  void _selectCard(EnrolledCard card) {
    ref.read(settingsProvider.notifier).selectCard(card.pan);
  }

  Widget _buildAddCardButton() {
    final l10n = AppLocalizations.of(context);
    return OutlinedButton.icon(
      key: const ValueKey('addCardButton'),
      onPressed: _isProcessing ? null : _showEnrollDialog,
      icon: const Icon(Icons.add_card_rounded),
      label: Text(l10n.cieAddCard),
      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
    );
  }

  /// Full detail for one card: visual, status tiles, actions and reader
  /// prompt. Two columns when [wide], one stacked column otherwise.
  Widget _buildCardDetail(EnrolledCard card, {required bool wide}) {
    final nfcPrompt = _NfcPromptCard(
      nfcAvailable: Platform.isAndroid ? _nfcAvailable : null,
      readerName: Platform.isAndroid ? null : _readerName,
      readerChecked: !Platform.isAndroid && _readerChecked,
    );
    final actions = _CieActions(
      card: card,
      onChangePin: _showChangePinDialog,
      onUnblockPin: _showUnblockPinDialog,
      onInspectCertificate: () => _showCertificateDialog(context, card),
      onRemove: () => _confirmRemove(context, card),
      onReadChip: () => _readChipForCard(card),
    );
    final expired = cardValidity(card) == CardValidity.expired;
    final warning = expired
        ? Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: _ExpiredCardBanner(),
          )
        : const SizedBox.shrink();
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                warning,
                _CieHero(card: card),
                const SizedBox(height: 16),
                _CieStats(card: card),
                const SizedBox(height: 16),
                nfcPrompt,
              ],
            ),
          ),
          const SizedBox(width: 28),
          Expanded(flex: 6, child: actions),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        warning,
        _CieHero(card: card),
        const SizedBox(height: 16),
        _CieStats(card: card),
        const SizedBox(height: 16),
        actions,
        const SizedBox(height: 16),
        nfcPrompt,
      ],
    );
  }

  /// Desktop master/detail: compact card list on the left, the selected
  /// card's detail on the right.
  Widget _buildMasterDetail(List<EnrolledCard> cards, EnrolledCard selected) {
    final cs = Theme.of(context).colorScheme;
    return OcPageBody(
      maxWidth: 1440,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildPageHeader(cards.length),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 20, 0, 20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 340,
                    child: ListView(
                      key: const ValueKey('cardList'),
                      padding: const EdgeInsets.only(right: 4),
                      children: [
                        for (final c in cards)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _CardListRow(
                              card: c,
                              selected: c.pan == selected.pan,
                              onTap: () => _selectCard(c),
                            ),
                          ),
                        const SizedBox(height: 6),
                        _buildAddCardButton(),
                      ],
                    ),
                  ),
                  const SizedBox(width: 20),
                  VerticalDivider(width: 1, color: cs.outlineVariant),
                  const SizedBox(width: 20),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final wide = constraints.maxWidth >= 720;
                        return SingleChildScrollView(
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 1000),
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 180),
                                child: KeyedSubtree(
                                  key: ValueKey('detail_${selected.pan}'),
                                  child: _buildCardDetail(selected, wide: wide),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Compact/medium layout for 2+ cards: a list of compact rows; tapping a
  /// row selects the card and opens its detail on a pushed page.
  Widget _buildCardList(List<EnrolledCard> cards) {
    final selectedPan = ref.watch(settingsProvider).selectedCard?.pan;
    Widget body(Widget child) => OcPageBody.sliver(
      maxWidth: 760,
      child: SliverToBoxAdapter(child: child),
    );
    return CustomScrollView(
      slivers: [
        body(_buildPageHeader(cards.length)),
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
        OcPageBody.sliver(
          maxWidth: 760,
          child: SliverList.separated(
            itemCount: cards.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) => _CardListRow(
              card: cards[i],
              selected: cards[i].pan == selectedPan,
              showChevron: true,
              onTap: () => _openCardDetail(cards[i]),
            ),
          ),
        ),
        body(
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 8),
            child: _buildAddCardButton(),
          ),
        ),
        body(
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 32),
            child: _NfcPromptCard(
              nfcAvailable: Platform.isAndroid ? _nfcAvailable : null,
              readerName: Platform.isAndroid ? null : _readerName,
              readerChecked: !Platform.isAndroid && _readerChecked,
            ),
          ),
        ),
      ],
    );
  }

  void _openCardDetail(EnrolledCard card) {
    _selectCard(card);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _CardDetailPage(
          pan: card.pan,
          bodyBuilder: (context, current) => ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [_buildCardDetail(current, wide: false)],
          ),
        ),
      ),
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
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'REPUBBLICA ITALIANA',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
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
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'Inter',
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
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

  String get _serialLabel {
    if (card.certSerial != null && card.certSerial!.isNotEmpty) {
      return card.certSerial!;
    }
    final s = card.serial;
    if (s.isEmpty) return '';
    return s.length > 8 ? s.substring(s.length - 8) : s;
  }

  String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/'
      '${d.year}';

  String get _expiryLabel {
    final d = card.mrzExpiry ?? card.notAfter;
    if (d == null) return '—';
    return _formatDate(d);
  }

  String get _lastUsedLabel {
    final d = card.lastUsed;
    if (d == null) return '—';
    return _formatDate(d);
  }

  Color? _expiryColor(BuildContext context) {
    final d = card.mrzExpiry ?? card.notAfter;
    if (d == null) return null;
    final cs = Theme.of(context).colorScheme;
    return switch (cardValidity(card)) {
      CardValidity.expired => cs.invalid,
      CardValidity.expiring => cs.tertiary,
      CardValidity.active => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final validity = cardValidity(card);
    return GridView(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        mainAxisExtent: 72,
      ),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        _StatCard(
          label: l10n.cieStatLabelStatus,
          value: validity == CardValidity.active
              ? l10n.cieStatValueActive
              : _validityLabel(l10n, validity).toUpperCase(),
          valueColor: _validityColor(Theme.of(context).colorScheme, validity),
        ),
        _StatCard(
          label: l10n.cieStatLabelSerial,
          value: _serialLabel.isNotEmpty ? _serialLabel : '—',
        ),
        _StatCard(
          label: l10n.cieStatLabelExpiry,
          value: _expiryLabel,
          valueColor: _expiryColor(context),
        ),
        _StatCard(label: l10n.cieStatLabelLastUsed, value: _lastUsedLabel),
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
    this.onReadChip,
  });

  final EnrolledCard card;
  final VoidCallback onChangePin;
  final VoidCallback onUnblockPin;
  final VoidCallback onInspectCertificate;
  final VoidCallback onRemove;

  /// Non-null only when [card.missingChipData]: reads MRZ + photo from
  /// the chip (PIN-gated) and upserts the card in place.
  final VoidCallback? onReadChip;

  String get _shortSerial {
    final s = card.serial;
    if (s.isEmpty) return '';
    return s.length > 8 ? s.substring(s.length - 8) : s;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return OcGroupCard(
      children: [
        OcActionRow(
          leadingIcon: Icons.lock_outline,
          title: l10n.cieChangePinButton,
          subtitle: l10n.cieChangePinSubtitle,
          onTap: onChangePin,
        ),
        OcActionRow(
          leadingIcon: Icons.fingerprint_outlined,
          title: l10n.cieActionUnblock,
          subtitle: l10n.cieUnblockPinSubtitle,
          onTap: onUnblockPin,
        ),
        OcActionRow(
          leadingIcon: Icons.shield_outlined,
          title: l10n.cieViewCertificate,
          subtitle: _shortSerial.isNotEmpty
              ? 'X.509 leaf · ${_shortSerial.toUpperCase()}'
              : l10n.cieViewCertificateSubtitle,
          subtitleMono: _shortSerial.isNotEmpty,
          onTap: onInspectCertificate,
        ),
        if (card.missingChipData && onReadChip != null)
          OcActionRow(
            key: const ValueKey('readChipDataAction'),
            leadingIcon: Icons.credit_card_outlined,
            title: AppLocalizations.of(context).cieReadChipAction,
            subtitle: AppLocalizations.of(context).cieReadChipActionHint,
            onTap: onReadChip,
          ),
        OcActionRow(
          leadingIcon: Icons.remove_circle_outline,
          title: l10n.cieActionRemove,
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
    this.onReadChip,
  });

  final EnrolledCard card;
  final VoidCallback onRemove;
  final VoidCallback onChangePin;
  final VoidCallback onUnblockPin;
  final VoidCallback onInspectCertificate;
  final VoidCallback? onReadChip;

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
          onReadChip: onReadChip,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Multi-card list row, validity chip and pushed detail page
// ---------------------------------------------------------------------------

String _validityLabel(AppLocalizations l10n, CardValidity v) => switch (v) {
  CardValidity.active => l10n.cieCardStatusActive,
  CardValidity.expiring => l10n.cieCardStatusExpiring,
  CardValidity.expired => l10n.cieCardStatusExpired,
};

Color _validityColor(ColorScheme cs, CardValidity v) => switch (v) {
  CardValidity.active => cs.valid,
  CardValidity.expiring => cs.tertiary,
  CardValidity.expired => cs.invalid,
};

String _formatCardDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/'
    '${d.month.toString().padLeft(2, '0')}/'
    '${d.year}';

/// Small pill with a colour dot and the card's validity label.
class _ValidityChip extends StatelessWidget {
  const _ValidityChip({required this.validity});

  final CardValidity validity;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final color = _validityColor(Theme.of(context).colorScheme, validity);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            _validityLabel(l10n, validity),
            style: TextStyle(
              fontFamily: 'Inter',
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// One compact row of the multi-card list: avatar, name, fiscal code,
/// expiry and a validity chip. The selected row is outlined and tinted.
class _CardListRow extends StatelessWidget {
  const _CardListRow({
    required this.card,
    required this.selected,
    required this.onTap,
    this.showChevron = false,
  });

  final EnrolledCard card;
  final bool selected;
  final VoidCallback onTap;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final id = cardFiscalCode(card) ?? card.serial;
    final expiry = cardExpiry(card);
    final radius = BorderRadius.circular(14);
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: Material(
        color: selected
            ? cs.primary.withValues(alpha: 0.10)
            : cs.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: selected ? cs.primary : cs.outline.withValues(alpha: 0.5),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          key: ValueKey('cardRow_${card.pan}'),
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                OcCardAvatar(card: card, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        card.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          color: cs.onSurface,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      if (id.isNotEmpty)
                        OcMonoText(
                          id,
                          color: cs.onSurfaceVariant,
                          fontSize: 11,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      if (expiry != null)
                        OcMonoText(
                          l10n.cieCardExpiresOn(_formatCardDate(expiry)),
                          color: cs.onSurfaceVariant,
                          fontSize: 11,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _ValidityChip(validity: cardValidity(card)),
                if (showChevron) ...[
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Warning shown in the card detail when the card has expired.
class _ExpiredCardBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('expiredCardBanner'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.error.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: cs.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              AppLocalizations.of(context).cieErrorCardExpired,
              style: TextStyle(
                fontFamily: 'Inter',
                color: cs.onErrorContainer,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pushed detail page for one card (compact/medium multi-card layout).
/// Follows the live settings: if the card is removed (from here) the page
/// closes itself.
class _CardDetailPage extends ConsumerWidget {
  const _CardDetailPage({required this.pan, required this.bodyBuilder});

  final String pan;
  final Widget Function(BuildContext context, EnrolledCard card) bodyBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cards = ref.watch(settingsProvider).enrolledCards;
    final idx = cards.indexWhere((c) => c.pan == pan);
    if (idx < 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      });
      return const Scaffold();
    }
    final card = cards[idx];
    return Scaffold(
      appBar: AppBar(
        title: Text(
          card.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: bodyBuilder(context, card),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Stat card (2-col grid item)
// ---------------------------------------------------------------------------

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value, this.valueColor});

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
    final readerReady = isDesktop
        ? widget.readerName != null
        : widget.nfcAvailable == true;
    final wasReady = isDesktop
        ? old.readerName != null
        : old.nfcAvailable == true;

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

    EnrolledCard? pendingCard;
    try {
      final l10n = AppLocalizations.of(context);
      // Helper to update wizard progress bar + message.
      void setProgress(double frac, String msg) {
        if (mounted) {
          setState(() {
            _enrollProgress = frac;
            _enrollMessage = msg;
          });
        }
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
        PinThrottle.reset();
        var card = EnrolledCard(
          pan: result.enrolledPan!,
          name: result.enrolledName ?? '',
          serial: result.enrolledSerial ?? '',
        );
        // Cert fetch: 40–50%
        setProgress(0.42, l10n.cieProgressReadCertificate);
        card = await _enrichCardWithCert(card);
        setProgress(0.50, l10n.cieProgressReadCertificate);

        // On desktop the card stays on the reader — read chip data
        // immediately, retrying (bounded) if the RF link drops mid-read.
        // On Android the NFC session is stopped in the finally block
        // below; chip reading runs as phase 2 after this block, prompting
        // a second tap (same as _showEnrollDialog).
        if (!Platform.isAndroid) {
          final outcome = await _readChipWithRetryLoop(
            card,
            pin,
            (frac, msg) => setProgress(0.50 + frac * 0.50, msg),
          );
          card = outcome.card;
        }

        pendingCard = card;
      } else {
        if (classifyCieError(
              result.returnValue,
              nativeErrorKind: result.nativeErrorKind,
            ) ==
            CieErrorKind.wrongPin) {
          PinThrottle.recordFailure();
        }
        setState(() {
          _enrollError = cieErrorMessage(
            l10n,
            classifyCieError(
              result.returnValue,
              nativeErrorKind: result.nativeErrorKind,
            ),
            remainingAttempts: result.remainingAttempts,
          );
        });
      }
    } finally {
      if (Platform.isAndroid && (widget.nfcAvailable ?? false)) {
        await NfcService.instance.stopSession();
      }
      if (mounted) setState(() => _enrolling = false);
    }

    if (pendingCard == null) return;

    if (Platform.isAndroid) {
      // Phase 2 — prompt a second tap and read the chip, instead of
      // skipping it: same behaviour as _showEnrollDialog's phase 2.
      pendingCard = await _enrolChipReadPhase2(pendingCard, pin);
    }

    if (!mounted) return;
    _pendingCard = pendingCard;
    setState(() => _step = _WizardStep.success);
    _successCtrl.forward();
  }

  /// Reads MRZ + photo, retrying (bounded to 2 attempts) via the shared
  /// [showChipReadIncompleteDialog] Retry / "Continue without" prompt when
  /// the read comes back incomplete. [setProgress] receives 0–1 fraction
  /// and a localized message, already offset by the caller.
  Future<ChipReadOutcome> _readChipWithRetryLoop(
    EnrolledCard card,
    String pin,
    void Function(double frac, String msg) setProgress,
  ) async {
    const maxRetries = 2;
    var outcome = ChipReadOutcome(card: card, mrzRead: false, photoRead: false);
    final l10n = AppLocalizations.of(context);
    for (var attempt = 0; ; attempt++) {
      outcome = await _readChip(
        outcome.card,
        pin,
        onProgress: (p) =>
            setProgress(p.percent / 100.0, l10n.localizeProgress(p.message)),
      );
      if (outcome.isComplete || attempt >= maxRetries || !mounted) break;
      final pinStatusError = isPinStatusErrorKind(outcome.errorKind);
      final message = pinStatusError
          ? cieErrorMessage(l10n, outcome.errorKind!)
          : (Platform.isAndroid
                ? l10n.cieReadIncompleteNfc
                : l10n.cieReadIncompletePcsc);
      if (outcome.errorKind == CieErrorKind.wrongPin) {
        PinThrottle.recordFailure();
      }
      final wantsRetry = await showChipReadIncompleteDialog(
        context,
        message,
        allowRetry: !pinStatusError,
      );
      if (pinStatusError || !wantsRetry) break;
    }
    return outcome;
  }

  /// Android phase 2 of enrolment: prompts a second card tap and reads
  /// MRZ + photo (with the same bounded retry as [_showEnrollDialog]).
  /// Returns [card] enriched with whatever was read; unchanged if NFC is
  /// unavailable, the widget is disposed, or all retries are exhausted.
  Future<EnrolledCard> _enrolChipReadPhase2(
    EnrolledCard card,
    String pin,
  ) async {
    if (!(widget.nfcAvailable ?? false) || !mounted) return card;
    final l10n = AppLocalizations.of(context);
    final completer = Completer<void>();
    var outcome = ChipReadOutcome(card: card, mrzRead: false, photoRead: false);

    setState(() {
      _enrolling = true;
      _enrollProgress = 0;
      _enrollMessage = l10n.wizardPlaceCardTitle;
    });

    NfcService.instance.startSession(
      onTagDiscovered: () async {
        if (completer.isCompleted) return;
        outcome = await _readChipWithRetryLoop(outcome.card, pin, (frac, msg) {
          if (mounted) {
            setState(() {
              _enrollProgress = frac;
              _enrollMessage = msg;
            });
          }
        });
        await NfcService.instance.stopSession();
        if (!completer.isCompleted) completer.complete();
      },
    );

    await completer.future;
    if (mounted) setState(() => _enrolling = false);
    return outcome.card;
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
      final cards = upsertEnrolledCard(
        ref.read(settingsProvider).enrolledCards,
        card,
      );
      ref
          .read(settingsProvider.notifier)
          .update((s) => s.copyWith(enrolledCards: cards));
    } else {
      widget.onSkip();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final canGoBack =
        _step == _WizardStep.detectReader ||
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
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).backButtonTooltip,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
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
                            parent: anim,
                            curve: Curves.easeOut,
                          ),
                          child: SlideTransition(
                            position:
                                Tween<Offset>(
                                  begin: const Offset(0.04, 0),
                                  end: Offset.zero,
                                ).animate(
                                  CurvedAnimation(
                                    parent: anim,
                                    curve: Curves.easeOut,
                                  ),
                                ),
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
              colors: [theme.colorScheme.primary, theme.colorScheme.tertiary],
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
          child: const Icon(
            Icons.credit_card_rounded,
            color: Colors.white,
            size: 52,
          ),
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
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 44),
        FilledButton.icon(
          onPressed: () => setState(() => _step = _WizardStep.detectReader),
          icon: const Icon(Icons.arrow_forward_rounded),
          label: Text(l10n.wizardGetStarted),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        ),
        const SizedBox(height: 12),
        TextButton(onPressed: widget.onSkip, child: Text(l10n.wizardSkip)),
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _buildDetectReader() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final isDesktop = widget.nfcAvailable == null;
    final readerReady = isDesktop
        ? widget.readerName != null
        : widget.nfcAvailable == true;
    final icon = isDesktop ? Icons.usb_rounded : Icons.contactless_rounded;

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
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.65),
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
              minimumSize: const Size.fromHeight(52),
            ),
          )
        else if (!isDesktop)
          FilledButton.icon(
            onPressed: () => NfcService.instance.openNfcSettings(),
            icon: const Icon(Icons.settings_outlined),
            label: Text(AppLocalizations.of(context).nfcEnableButton),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
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
    final deviceLabel = isDesktop
        ? (widget.readerName ?? l10n.wizardSmartCardReader)
        : 'NFC';
    final deviceIcon = isDesktop
        ? Icons.usb_rounded
        : Icons.contactless_rounded;

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
              child: Icon(
                deviceIcon,
                color: theme.colorScheme.primary,
                size: 18,
              ),
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
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
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
                    ? const Icon(
                        Icons.check_circle_rounded,
                        color: Colors.green,
                      )
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
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        ),
        const SizedBox(height: 12),
        TextButton(onPressed: widget.onSkip, child: Text(l10n.wizardSkip)),
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
              OcGlowChip(size: 80, icon: Icons.contactless_rounded),
            ],
          ),
        ),
        const SizedBox(height: 28),
        Text(
          _enrolling
              ? l10n.cieEnrollingProgress
              : (isPcsc
                    ? l10n.wizardPlaceCardTitlePcsc
                    : l10n.wizardPlaceCardTitle),
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
            const SizedBox(height: 4),
          ],
          if (_enrollProgress >= 0.5) ...[
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Text(
                l10n.cieReadKeepStill,
                style: TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: cs.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 8),
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
                Icon(
                  Icons.error_outline_rounded,
                  color: theme.colorScheme.onErrorContainer,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _enrollError!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
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
              minimumSize: const Size.fromHeight(52),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => setState(() => _step = _WizardStep.enrol),
            child: Text(l10n.wizardPlaceCardBack),
          ),
        ] else ...[
          Text(
            isPcsc ? l10n.wizardPlaceCardBodyPcsc : l10n.wizardPlaceCardBody,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
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
            child: const Icon(
              Icons.check_rounded,
              color: Colors.white,
              size: 54,
            ),
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
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
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
          if (card.missingChipData) ...[
            const SizedBox(height: 16),
            Container(
              key: const ValueKey('chipDataMissingHint'),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    color: theme.colorScheme.onErrorContainer,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      AppLocalizations.of(context).cieReadChipActionHint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
        const SizedBox(height: 48),
        FilledButton.icon(
          onPressed: _finish,
          icon: const Icon(Icons.check_circle_outline_rounded),
          label: Text(AppLocalizations.of(context).wizardDone),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
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

    final showEnableButton = !isDesktop && widget.nfcAvailable == false;

    return Card(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: Row(
          children: [
            AnimatedBuilder(
              animation: _controller,
              builder: (context, child) =>
                  Opacity(opacity: 0.4 + _controller.value * 0.6, child: child),
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
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    statusText,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
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
