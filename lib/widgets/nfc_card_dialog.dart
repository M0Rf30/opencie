// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../core/l10n/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/color_schemes.dart';
import 'oc_pulse_rings.dart';

/// Shared NFC card dialog used by sign, change-PIN, and unblock-PIN flows.
///
/// State is driven by [notifier]: (isWaiting, progress 0–1, progressMessage).
///
/// • [isWaiting] == true  → pulsing NFC rings + "tap your card" body, Cancel button
/// • [isWaiting] == false → linear progress + [processingTitle]
///
/// [processingTitle] is shown once the card is detected and the native call
/// is running (e.g. "Signing…", "Changing PIN…", "Unblocking PIN…").
class NfcCardDialog extends StatefulWidget {
  const NfcCardDialog({
    super.key,
    required this.notifier,
    required this.processingTitle,
    this.onCancel,
    this.errorNotifier,
    this.onDismissError,
    this.onRetry,
    this.continueLabel,
    this.nfcDisabledNotifier,
    this.onOpenNfcSettings,
    this.onDismissNfcDisabled,
  });

  /// (isWaiting, progress 0–1, progressMessage)
  final ValueNotifier<(bool, double, String)> notifier;

  /// Title shown while the native operation is running (after card tap).
  final String processingTitle;

  /// Called when the user taps Cancel while waiting for the card.
  /// Only rendered when [isWaiting] is true; may be null on desktop.
  final VoidCallback? onCancel;

  /// Non-null value replaces the waiting/processing content with a
  /// classified-failure view — same dialog shell, an error icon, the
  /// message, and a dismiss button in place of Cancel/progress. Null (the
  /// default) preserves the normal waiting/processing flow unchanged.
  final ValueListenable<String?>? errorNotifier;

  /// Called when the user dismisses the error view shown via
  /// [errorNotifier]. Should be provided whenever [errorNotifier] is.
  final VoidCallback? onDismissError;

  /// When non-null, shown alongside [onDismissError] as a "Retry" action on
  /// the [errorNotifier] view — re-runs just the failed step (e.g. a chip
  /// read) rather than closing the dialog outright. Null (the default)
  /// preserves the plain dismiss-only error view.
  final VoidCallback? onRetry;

  /// Overrides the dismiss button's label on the [errorNotifier] view when
  /// [onRetry] is set (e.g. "Continue without photo/MRZ" instead of
  /// "Close"), so the two actions read as real alternatives. Ignored when
  /// [onRetry] is null.
  final String? continueLabel;

  /// True while Android NFC is off. Takes priority over [errorNotifier]:
  /// there is no point starting a card session, or showing a card-read
  /// error, while the radio itself is disabled. Null (the default)
  /// preserves the normal flow unchanged.
  final ValueListenable<bool>? nfcDisabledNotifier;

  /// Called when the user taps the "enable NFC" action in the
  /// [nfcDisabledNotifier] view. Should open the platform NFC settings
  /// screen (typically `NfcService.instance.openNfcSettings`).
  final VoidCallback? onOpenNfcSettings;

  /// Called when the user dismisses the [nfcDisabledNotifier] view.
  /// Should be provided whenever [nfcDisabledNotifier] is.
  final VoidCallback? onDismissNfcDisabled;

  @override
  State<NfcCardDialog> createState() => _NfcCardDialogState();
}

class _NfcCardDialogState extends State<NfcCardDialog> {
  // Screen-reader progress announcements: announce coarse milestones
  // instead of the raw per-tick progress the FFI layer emits.
  int _lastMilestone = -1;
  bool _readStarted = false;

  @override
  void initState() {
    super.initState();
    widget.notifier.addListener(_onProgressChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onProgressChanged());
  }

  @override
  void dispose() {
    widget.notifier.removeListener(_onProgressChanged);
    super.dispose();
  }

  void _onProgressChanged() {
    if (!mounted || !MediaQuery.accessibleNavigationOf(context)) return;
    final (waiting, progress, _) = widget.notifier.value;
    if (waiting) return;
    final l10n = AppLocalizations.of(context);
    if (!_readStarted) {
      _readStarted = true;
      _lastMilestone = 0;
      SemanticsService.sendAnnouncement(
        View.of(context),
        l10n.cieReadStarted,
        TextDirection.ltr,
      );
      return;
    }
    // Throttled to 25% steps — never announce on every percentage tick.
    final milestone = ((progress * 100).clamp(0, 100).round() ~/ 25) * 25;
    if (milestone <= _lastMilestone) return;
    _lastMilestone = milestone;
    SemanticsService.sendAnnouncement(
      View.of(context),
      milestone >= 100 ? l10n.cieReadComplete : l10n.cieReadProgress(milestone),
      TextDirection.ltr,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBackAttempt();
      },
      child: _buildDialogContent(context),
    );
  }

  /// Routes a back-gesture / system-pop attempt through the same
  /// cancel/dismiss-error callbacks a button tap would use, so callers'
  /// busy flags and NFC sessions are always cleaned up consistently
  /// regardless of how the user tries to leave the dialog.
  void _handleBackAttempt() {
    if (widget.nfcDisabledNotifier?.value == true) {
      widget.onDismissNfcDisabled?.call();
      return;
    }
    if (widget.errorNotifier?.value != null) {
      widget.onDismissError?.call();
      return;
    }
    final (waiting, _, _) = widget.notifier.value;
    if (waiting) {
      widget.onCancel?.call();
    }
    // Else: mid-processing (card tapped, native call running) with no
    // cancel affordance — intentionally not poppable.
  }

  Widget _buildDialogContent(BuildContext context) {
    final errorNotifier = widget.errorNotifier;
    final content = errorNotifier == null
        ? _buildContent(context)
        : ValueListenableBuilder<String?>(
            valueListenable: errorNotifier,
            builder: (context, error, child) =>
                error != null ? _buildError(context, error) : child!,
            child: _buildContent(context),
          );

    final nfcDisabledNotifier = widget.nfcDisabledNotifier;
    if (nfcDisabledNotifier == null) return content;
    return ValueListenableBuilder<bool>(
      valueListenable: nfcDisabledNotifier,
      builder: (context, disabled, child) =>
          disabled ? _buildNfcDisabled(context) : child!,
      child: content,
    );
  }

  /// Inline "NFC is off" view — same rounded-container shell as the
  /// normal content, shown instead of starting/continuing a card session
  /// while Android NFC is disabled. Takes priority over [_buildError].
  Widget _buildNfcDisabled(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 360),
        decoration: BoxDecoration(
          color: cs.surfaceContainer,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: cs.error.withValues(alpha: 0.14),
                ),
                child: Icon(
                  Icons.nfc_rounded,
                  color: cs.error,
                  size: 84 * 0.48,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                l10n.nfcUxDisabledTitle,
                style: AppTheme.headlineBold(cs),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: Text(
                  l10n.nfcUxDisabledBody,
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: widget.onOpenNfcSettings,
                  icon: const Icon(Icons.settings_outlined),
                  label: Text(l10n.nfcEnableButton),
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: widget.onDismissNfcDisabled,
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: cs.outlineVariant),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(l10n.commonClose),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Classified-failure view — same rounded-container shell as the normal
  /// content, swapped for a static error icon, the [message], and a
  /// dismiss button in place of Cancel/progress.
  Widget _buildError(BuildContext context, String message) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 360),
        decoration: BoxDecoration(
          color: cs.surfaceContainer,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: cs.error.withValues(alpha: 0.14),
                ),
                child: Icon(
                  Icons.error_outline_rounded,
                  color: cs.error,
                  size: 84 * 0.48,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                message,
                style: AppTheme.headlineBold(cs),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              if (widget.onRetry != null) ...[
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const ValueKey('nfcCardDialogRetry'),
                    onPressed: widget.onRetry,
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: Text(l10n.commonRetry),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  key: const ValueKey('nfcCardDialogDismiss'),
                  onPressed: widget.onDismissError,
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: cs.outlineVariant),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(widget.continueLabel ?? l10n.commonClose),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);

    return ValueListenableBuilder<(bool, double, String)>(
      valueListenable: widget.notifier,
      builder: (context, value, _) {
        final (waiting, progress, message) = value;
        final percent = (progress * 100).clamp(0, 100).round();

        final caption = widget.processingTitle.toUpperCase();

        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 360),
            decoration: BoxDecoration(
              color: cs.surfaceContainer,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                // ── Radial-wash background ──────────────────────────────────
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

                // ── Content column ──────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 28,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Mono caption
                      Text(
                        caption,
                        style: AppTheme.monoCaption(cs),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),

                      // ── Rings + glow chip ─────────────────────────────────
                      SizedBox(
                        width: 180,
                        height: 180,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            const OcPulseRings(size: 180, ringCount: 4),
                            OcGlowChip(
                              size: 84,
                              icon: Icons.contactless_rounded,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),

                      // ── Title ─────────────────────────────────────────────
                      Text(
                        waiting
                            ? l10n.wizardPlaceCardTitle
                            : widget.processingTitle,
                        style: AppTheme.headlineBold(cs),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),

                      // ── Subtitle / progress ───────────────────────────────
                      if (waiting)
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 280),
                          child: Text(
                            l10n.cieHoldCardBody,
                            style: TextStyle(
                              fontSize: 13,
                              color: cs.onSurfaceVariant,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        )
                      else ...[
                        if (message.isNotEmpty) ...[
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 280),
                            child: Text(
                              message,
                              style: TextStyle(
                                fontSize: 13,
                                color: cs.onSurfaceVariant,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                          const SizedBox(height: 12),
                        ] else
                          const SizedBox(height: 12),
                        // Determinate when progress > 0, else indeterminate
                        Semantics(
                          liveRegion: true,
                          label: l10n.cieReadProgress(percent),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: progress > 0 ? progress : null,
                              minHeight: 4,
                              backgroundColor: cs.primary.withValues(
                                alpha: 0.14,
                              ),
                              valueColor: AlwaysStoppedAnimation<Color>(
                                cs.primary,
                              ),
                            ),
                          ),
                        ),
                      ],

                      // ── Cancel button ─────────────────────────────────────
                      if (waiting && widget.onCancel != null) ...[
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton(
                            onPressed: widget.onCancel,
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(color: cs.outlineVariant),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            child: Text(l10n.commonCancel),
                          ),
                        ),
                      ],
                    ],
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
