// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants/app_constants.dart';
import '../core/l10n/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../services/pin_throttle.dart';
import '../services/screen_guard.dart';
import 'oc_section_label.dart';

/// Reusable PIN entry dialog widget.
class PinEntryDialog extends StatefulWidget {
  const PinEntryDialog({
    super.key,
    this.maxLength = AppConstants.ciePinLength,
    this.title,
  });

  final int maxLength;
  final String? title;

  /// Show the PIN entry dialog and return the entered PIN or null if cancelled.
  static Future<String?> show(
    BuildContext context, {
    int maxLength = AppConstants.ciePinLength,
    String? title,
  }) => showDialog<String>(
    context: context,
    builder: (_) => PinEntryDialog(maxLength: maxLength, title: title),
  );

  @override
  State<PinEntryDialog> createState() => _PinEntryDialogState();
}

class _PinEntryDialogState extends State<PinEntryDialog> {
  late FocusNode _keyboardFocus;
  String _pin = '';
  Timer? _lockTimer;

  @override
  void initState() {
    super.initState();
    _keyboardFocus = FocusNode();
    ScreenGuard.protect();
    if (PinThrottle.isLocked) {
      _startLockTimer();
    }
  }

  void _startLockTimer() {
    _lockTimer?.cancel();
    _lockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (!PinThrottle.isLocked) {
        timer.cancel();
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _lockTimer?.cancel();
    _keyboardFocus.dispose();
    ScreenGuard.unprotect();
    super.dispose();
  }

  void _appendDigit(String digit) {
    if (PinThrottle.isLocked) {
      return;
    }
    if (_pin.length < widget.maxLength) {
      setState(() {
        _pin += digit;
      });
    }
  }

  void _backspace() {
    if (PinThrottle.isLocked) {
      return;
    }
    if (_pin.isNotEmpty) {
      setState(() {
        _pin = _pin.substring(0, _pin.length - 1);
      });
    }
  }

  void _submitIfReady() {
    if (PinThrottle.isLocked) {
      return;
    }
    if (_pin.length == widget.maxLength) {
      Navigator.pop(context, _pin);
    }
  }

  void _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.backspace) {
      _backspace();
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _submitIfReady();
    } else if (key == LogicalKeyboardKey.escape) {
      Navigator.pop(context);
    } else {
      final label = key.keyLabel;
      if (label.length == 1 &&
          label.codeUnitAt(0) >= 0x30 &&
          label.codeUnitAt(0) <= 0x39) {
        _appendDigit(label);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final screenWidth = MediaQuery.of(context).size.width;
    final isDesktop = screenWidth >= AppConstants.mediumBreakpoint;

    final tileW = isDesktop ? 26.0 : 32.0;
    final tileH = isDesktop ? 34.0 : 44.0;
    final tileDotSize = isDesktop ? 12.0 : 14.0;
    final numpadRatio = isDesktop ? 2.2 : 1.5;
    final pinLength = _pin.length;
    final remaining = PinThrottle.remaining;
    final locked = remaining > Duration.zero;
    final lockSeconds = locked ? (remaining.inMilliseconds / 1000).ceil() : 0;

    return KeyboardListener(
      focusNode: _keyboardFocus,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        backgroundColor: cs.surfaceContainer,
        insetPadding: EdgeInsets.symmetric(
          horizontal: isDesktop ? 40 : 24,
          vertical: 40,
        ),
        child: Semantics(
          label: 'PIN entry dialog',
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: isDesktop ? 360 : double.infinity,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Top bar: close button
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.pop(context),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                      ),
                      const Spacer(),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Lock icon tile
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: cs.outlineVariant),
                    ),
                    child: Icon(
                      Icons.lock_outline_rounded,
                      size: 26,
                      color: cs.primary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  OcSectionLabel('PIN'),
                  const SizedBox(height: 12),

                  // Title
                  Text(
                    widget.title ?? l10n.signEnterPin,
                    style: AppTheme.displayBold(cs).copyWith(fontSize: 22),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),

                  // PIN tiles
                  Semantics(
                    label: '$pinLength of ${widget.maxLength} digits entered',
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(widget.maxLength, (i) {
                          final filled = i < pinLength;
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 280),
                            width: tileW,
                            height: tileH,
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            decoration: BoxDecoration(
                              color: filled
                                  ? cs.primary
                                  : cs.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: filled ? cs.primary : cs.outlineVariant,
                                width: 2,
                              ),
                            ),
                            child: filled
                                ? Center(
                                    child: Container(
                                      width: tileDotSize,
                                      height: tileDotSize,
                                      decoration: BoxDecoration(
                                        color: cs.onPrimary,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  )
                                : null,
                          );
                        }),
                      ),
                    ),
                  ),
                  if (locked) ...[
                    const SizedBox(height: 12),
                    Text(
                      l10n.pinLockedWait(lockSeconds),
                      style: TextStyle(color: cs.error, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 24),

                  // Numpad
                  AbsorbPointer(
                    absorbing: locked,
                    child: Opacity(
                      opacity: locked ? 0.4 : 1.0,
                      child: GridView.count(
                        crossAxisCount: 3,
                        childAspectRatio: numpadRatio,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          ...List.generate(9, (i) {
                            final digit = (i + 1).toString();
                            return _NumpadButton(
                              label: digit,
                              semanticLabel: 'digit $digit',
                              onPressed: () {
                                _appendDigit(digit);
                                _keyboardFocus.requestFocus();
                              },
                            );
                          }),
                          _NumpadButton(
                            label: '⌫',
                            semanticLabel: 'backspace',
                            onPressed: () {
                              _backspace();
                              _keyboardFocus.requestFocus();
                            },
                          ),
                          _NumpadButton(
                            label: '0',
                            semanticLabel: 'digit 0',
                            onPressed: () {
                              _appendDigit('0');
                              _keyboardFocus.requestFocus();
                            },
                          ),
                          _NumpadButton(
                            label: '✓',
                            semanticLabel: 'confirm',
                            onPressed: _submitIfReady,
                            isSubmit: true,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NumpadButton extends StatelessWidget {
  const _NumpadButton({
    required this.label,
    required this.onPressed,
    this.semanticLabel,
    this.isSubmit = false,
  });

  final String label;
  final VoidCallback onPressed;
  final String? semanticLabel;
  final bool isSubmit;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Semantics(
        label: semanticLabel ?? label,
        button: true,
        enabled: true,
        onTap: onPressed,
        child: Material(
          color: isSubmit ? cs.primary : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(12),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: isSubmit ? cs.onPrimary : cs.onSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
