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
    final errorNotifier = widget.errorNotifier;
    if (errorNotifier == null) return _buildContent(context);
    return ValueListenableBuilder<String?>(
      valueListenable: errorNotifier,
      builder: (context, error, child) =>
          error != null ? _buildError(context, error) : child!,
      child: _buildContent(context),
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
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: widget.onDismissError,
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
