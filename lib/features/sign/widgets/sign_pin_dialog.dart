// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../widgets/oc_gradient_button.dart';
import '../../../widgets/oc_section_label.dart';

/// On-screen PIN-entry dialog. Returns the 4-digit PIN string via
/// [Navigator.pop] or null on cancellation.
class SignPinDialog extends StatefulWidget {
  const SignPinDialog({super.key});

  @override
  State<SignPinDialog> createState() => _SignPinDialogState();
}

class _SignPinDialogState extends State<SignPinDialog> {
  final _controller = TextEditingController();
  final _keyboardFocus = FocusNode();
  static const _maxPin = 4;

  @override
  void dispose() {
    _controller.dispose();
    _keyboardFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final screenWidth = MediaQuery.of(context).size.width;
    final isDesktop = screenWidth >= AppConstants.mediumBreakpoint;
    final pinLength = _controller.text.length;

    // ── Desktop tile + numpad dimensions (≈25 % smaller) ──────────
    final tileW = isDesktop ? 36.0 : 56.0;
    final tileH = isDesktop ? 44.0 : 64.0;
    final tileDotSize = isDesktop ? 18.0 : 24.0;
    // childAspectRatio: wider on desktop so keys stay ~48 px tall.
    final numpadRatio = isDesktop ? 2.2 : 1.5;

    // ── Input handlers ─────────────────────────────────────────────
    void appendDigit(String digit) {
      if (_controller.text.length < _maxPin) {
        _controller.text += digit;
        setState(() {});
      }
    }

    void backspace() {
      if (_controller.text.isNotEmpty) {
        _controller.text = _controller.text.substring(
          0,
          _controller.text.length - 1,
        );
        setState(() {});
      }
    }

    void submitIfReady() {
      if (_controller.text.length == _maxPin) {
        Navigator.pop(context, _controller.text);
      }
    }

    // ── Keyboard handler ───────────────────────────────────────────
    void onKeyEvent(KeyEvent event) {
      if (event is! KeyDownEvent) return;
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.backspace) {
        backspace();
      } else if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        submitIfReady();
      } else if (key == LogicalKeyboardKey.escape) {
        Navigator.pop(context);
      } else {
        // Accept digit keys from both top-row (0x30–0x39) and numpad.
        final label = key.keyLabel;
        if (label.length == 1 &&
            label.codeUnitAt(0) >= 0x30 &&
            label.codeUnitAt(0) <= 0x39) {
          appendDigit(label);
        }
      }
    }

    return KeyboardListener(
      focusNode: _keyboardFocus,
      autofocus: true,
      onKeyEvent: onKeyEvent,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        backgroundColor: cs.surfaceContainer,
        insetPadding: EdgeInsets.symmetric(
          horizontal: isDesktop ? 40 : 24,
          vertical: 40,
        ),
        child: ConstrainedBox(
          // Cap dialog width to 360 on desktop; unconstrained on mobile.
          constraints: BoxConstraints(
            maxWidth: isDesktop ? 360 : double.infinity,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Top bar: close + step indicator
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
                    OcSectionLabel('PASSO 01 / 03'),
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
                OcSectionLabel('PIN DELLA CARTA'),
                const SizedBox(height: 12),

                // Title
                Text(
                  l10n.signEnterPinTitle,
                  style: AppTheme.displayBold(cs).copyWith(fontSize: 22),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.signPinLast4Helper,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),

                // PIN tiles (size adapts to desktop/mobile)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(_maxPin, (i) {
                    final filled = i < pinLength;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOutBack,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: tileW,
                      height: tileH,
                      decoration: BoxDecoration(
                        color: filled ? cs.primary : cs.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: filled ? cs.primary : cs.outlineVariant,
                          width: 1.5,
                        ),
                      ),
                      child: Center(
                        child: filled
                            ? Text(
                                '•',
                                style: TextStyle(
                                  color: cs.onPrimary,
                                  fontSize: tileDotSize,
                                  fontWeight: FontWeight.w800,
                                ),
                              )
                            : null,
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 20),

                // Numpad grid (aspect ratio adapts to desktop/mobile)
                GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: 3,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: numpadRatio,
                  children: [
                    for (final key in [
                      '1',
                      '2',
                      '3',
                      '4',
                      '5',
                      '6',
                      '7',
                      '8',
                      '9',
                      '',
                      '0',
                      '⌫',
                    ])
                      if (key.isEmpty)
                        const SizedBox.shrink()
                      else
                        _NumpadKey(
                          label: key,
                          onTap: () {
                            if (key == '⌫') {
                              backspace();
                            } else {
                              appendDigit(key);
                            }
                          },
                        ),
                  ],
                ),
                const SizedBox(height: 14),

                // Confirm button
                OcGradientButton(
                  label: l10n.signButton,
                  icon: Icons.check_rounded,
                  onPressed: pinLength == _maxPin ? submitIfReady : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Numpad digit key used in the PIN dialog.
class _NumpadKey extends StatelessWidget {
  const _NumpadKey({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainer,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Inter',
              color: cs.onSurface,
              fontSize: label == '⌫' ? 18 : 22,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
