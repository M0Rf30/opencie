// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/l10n/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../services/app_lock/app_lock_service.dart';

/// Row of dots showing how many digits have been typed.
class PasscodeDots extends StatelessWidget {
  const PasscodeDots({required this.count, this.error = false, super.key});

  final int count;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = error ? cs.error : cs.primary;
    final shown = math.max(count, AppLockService.minLength);
    return Semantics(
      label: AppLocalizations.of(context).appLockDigitsEntered(count),
      excludeSemantics: true,
      child: SizedBox(
        height: 20,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < shown; i++)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 6),
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < count ? color : Colors.transparent,
                  border: Border.all(
                    color: i < count ? color : cs.outline,
                    width: 1.5,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Numeric keypad with dots, shake-on-error and physical keyboard support.
///
/// [onSubmit] receives the typed digits and returns an error message to show
/// (and shake for), or null on success.
class PasscodePad extends StatefulWidget {
  const PasscodePad({
    required this.onSubmit,
    this.enabled = true,
    this.statusText,
    this.leftAction,
    this.minLength = AppLockService.minLength,
    this.maxLength = AppLockService.maxLength,
    super.key,
  });

  final Future<String?> Function(String code) onSubmit;
  final bool enabled;

  /// Replaces the error line, e.g. a lockout countdown.
  final String? statusText;

  /// Widget in the bottom-left key slot (biometrics button).
  final Widget? leftAction;
  final int minLength;
  final int maxLength;

  @override
  State<PasscodePad> createState() => _PasscodePadState();
}

class _PasscodePadState extends State<PasscodePad>
    with SingleTickerProviderStateMixin {
  final _focus = FocusNode(debugLabel: 'passcode-pad');
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );
  String _code = '';
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _focus.dispose();
    _shake.dispose();
    super.dispose();
  }

  bool get _active => widget.enabled && !_busy;

  void _digit(String d) {
    if (!_active || _code.length >= widget.maxLength) return;
    setState(() {
      _code += d;
      _error = null;
    });
  }

  void _backspace() {
    if (!_active || _code.isEmpty) return;
    setState(() {
      _code = _code.substring(0, _code.length - 1);
      _error = null;
    });
  }

  Future<void> _submit() async {
    if (!_active || _code.length < widget.minLength) return;
    final code = _code;
    setState(() => _busy = true);
    final err = await widget.onSubmit(code);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _code = '';
      _error = err;
    });
    if (err != null) _shake.forward(from: 0);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final ch = event.character;
    if (ch != null && ch.length == 1 && RegExp(r'^[0-9]$').hasMatch(ch)) {
      _digit(ch);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace) {
      _backspace();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _submit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final message = widget.statusText ?? _error;
    final isError = message != null;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _shake,
            builder: (context, child) {
              final dx =
                  math.sin(_shake.value * math.pi * 6) *
                  12 *
                  (1 - _shake.value);
              return Transform.translate(offset: Offset(dx, 0), child: child);
            },
            child: PasscodeDots(count: _code.length, error: isError),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 36,
            child: Center(
              child: isError
                  ? Text(
                      message,
                      key: const ValueKey('passcode-pad-message'),
                      textAlign: TextAlign.center,
                      style: AppTheme.monoCaption(cs, color: cs.error),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 8),
          for (final row in const [
            ['1', '2', '3'],
            ['4', '5', '6'],
            ['7', '8', '9'],
          ])
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [for (final d in row) _key(d, () => _digit(d))],
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _slot(widget.leftAction),
              _key('0', () => _digit('0')),
              _slot(
                _code.isEmpty
                    ? null
                    : IconButton(
                        key: const ValueKey('passcode-pad-backspace'),
                        tooltip: l10n.appLockDelete,
                        onPressed: _active ? _backspace : null,
                        icon: const Icon(Icons.backspace_outlined),
                      ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FilledButton(
            key: const ValueKey('passcode-pad-submit'),
            onPressed: _active && _code.length >= widget.minLength
                ? _submit
                : null,
            child: Text(l10n.appLockConfirmKey),
          ),
        ],
      ),
    );
  }

  Widget _slot(Widget? child) =>
      SizedBox(width: 84, height: 64, child: Center(child: child));

  Widget _key(String digit, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 84,
      height: 64,
      child: Center(
        child: Material(
          color: cs.surfaceContainerHighest,
          shape: const CircleBorder(),
          child: InkWell(
            key: ValueKey('passcode-key-$digit'),
            customBorder: const CircleBorder(),
            onTap: _active ? onTap : null,
            child: SizedBox(
              width: 56,
              height: 56,
              child: Center(
                child: Text(
                  digit,
                  style: AppTheme.headlineBold(cs).copyWith(fontSize: 22),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
