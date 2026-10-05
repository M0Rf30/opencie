// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../services/app_lock/app_lock_controller.dart';
import '../../services/app_lock/app_lock_service.dart';
import '../../services/secure_store.dart';
import 'app_lock_screen.dart' show formatLockout;
import 'passcode_pad.dart';

enum PasscodeFlowMode {
  /// Choose and confirm a new app passcode (enables the lock).
  create,

  /// Verify the current passcode, then choose a new one.
  change,

  /// Verify the current passcode only (used to turn the lock off).
  verify,
}

/// Shows the app-passcode setup / change / verify dialog. Resolves to true
/// when the flow completed.
Future<bool> showPasscodeFlow(
  BuildContext context,
  PasscodeFlowMode mode,
) async {
  final r = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PasscodeFlowDialog(mode: mode),
  );
  return r ?? false;
}

enum _Step { current, choose, confirm }

class PasscodeFlowDialog extends ConsumerStatefulWidget {
  const PasscodeFlowDialog({required this.mode, super.key});

  final PasscodeFlowMode mode;

  @override
  ConsumerState<PasscodeFlowDialog> createState() => _PasscodeFlowDialogState();
}

class _PasscodeFlowDialogState extends ConsumerState<PasscodeFlowDialog> {
  late _Step _step = widget.mode == PasscodeFlowMode.create
      ? _Step.choose
      : _Step.current;
  String? _first;
  String? _notice;

  Future<String?> _onCode(String code) async {
    final l10n = AppLocalizations.of(context);
    final ctrl = ref.read(appLockProvider.notifier);
    switch (_step) {
      case _Step.current:
        final r = await ctrl.verifyCurrent(code);
        if (!mounted) return null;
        switch (r) {
          case UnlockOk():
            if (widget.mode == PasscodeFlowMode.verify) {
              Navigator.of(context).pop(true);
            } else {
              setState(() => _step = _Step.choose);
            }
            return null;
          case UnlockWrong():
            return r.lockedFor > Duration.zero
                ? l10n.appLockTryAgainIn(formatLockout(r.lockedFor))
                : l10n.appLockWrong;
          case UnlockThrottled():
            return l10n.appLockTryAgainIn(formatLockout(r.remaining));
        }
      case _Step.choose:
        setState(() {
          _first = code;
          _notice = null;
          _step = _Step.confirm;
        });
        return null;
      case _Step.confirm:
        if (code != _first) {
          setState(() {
            _first = null;
            _notice = l10n.appLockMismatch;
            _step = _Step.choose;
          });
          return null;
        }
        try {
          await ctrl.setPasscode(code);
        } on SecureStoreException {
          if (!mounted) return null;
          setState(() {
            _first = null;
            _notice = l10n.appLockStorageError;
            _step = _Step.choose;
          });
          return null;
        }
        if (mounted) Navigator.of(context).pop(true);
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final title = switch (_step) {
      _Step.current =>
        widget.mode == PasscodeFlowMode.verify
            ? l10n.appLockDisableTitle
            : l10n.appLockEnterCurrent,
      _Step.choose => l10n.appLockChooseTitle,
      _Step.confirm => l10n.appLockConfirmTitle,
    };
    final hint = _step == _Step.choose ? l10n.appLockChooseHint : null;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: AppTheme.headlineBold(cs).copyWith(fontSize: 20),
              ),
              if (_step != _Step.current) ...[
                const SizedBox(height: 4),
                Text(
                  l10n.appLockPasscodeLabel,
                  style: AppTheme.monoCaption(cs),
                ),
              ],
              if (hint != null) ...[
                const SizedBox(height: 8),
                Text(
                  hint,
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
              if (_notice != null) ...[
                const SizedBox(height: 8),
                Text(
                  _notice!,
                  key: const ValueKey('passcode-flow-notice'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.error),
                ),
              ],
              const SizedBox(height: 16),
              PasscodePad(key: ValueKey(_step), onSubmit: _onCode),
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(l10n.appLockCancel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
