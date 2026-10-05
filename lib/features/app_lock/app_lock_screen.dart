// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../services/app_lock/app_lock_controller.dart';
import '../../services/app_lock/app_lock_service.dart';
import '../../widgets/oc_mark.dart';
import 'passcode_pad.dart';

/// mm:ss rendering of a lockout duration.
String formatLockout(Duration d) {
  final total = d.inSeconds + (d.inMilliseconds % 1000 > 0 ? 1 : 0);
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}

/// Full-screen, fully opaque lock screen.
class AppLockScreen extends ConsumerStatefulWidget {
  const AppLockScreen({super.key});

  @override
  ConsumerState<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends ConsumerState<AppLockScreen> {
  Timer? _ticker;
  Duration _remaining = Duration.zero;

  @override
  void initState() {
    super.initState();
    _refreshRemaining();
    // Prompt biometrics once per lock, after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _promptBiometric();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _refreshRemaining() {
    final left = ref.read(appLockServiceProvider).throttleRemaining;
    setState(() => _remaining = left);
    _ticker?.cancel();
    if (left > Duration.zero) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        final r = ref.read(appLockServiceProvider).throttleRemaining;
        setState(() => _remaining = r);
        if (r == Duration.zero) _ticker?.cancel();
      });
    }
  }

  Future<void> _promptBiometric() async {
    final reason = AppLocalizations.of(context).appLockBiometricReason;
    await ref.read(appLockProvider.notifier).tryBiometric(reason);
  }

  Future<String?> _submit(String code) async {
    final l10n = AppLocalizations.of(context);
    final result = await ref
        .read(appLockProvider.notifier)
        .submitPasscode(code);
    if (!mounted) return null;
    switch (result) {
      case UnlockOk():
        return null;
      case UnlockWrong():
        _refreshRemaining();
        return result.lockedFor > Duration.zero ? null : l10n.appLockWrong;
      case UnlockThrottled():
        _refreshRemaining();
        return null;
    }
  }

  Future<void> _forgot() async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.appLockForgot),
        content: Text(l10n.appLockForgotBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.appLockCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.appLockResetButton),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await ref.read(appLockProvider.notifier).resetAppData();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(appLockProvider);
    final showBio = state.config.biometrics && state.biometricsAvailable;
    return Material(
      color: cs.surface,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const OcMark(size: 56),
                const SizedBox(height: 16),
                Text(
                  l10n.appLockLockedTitle,
                  style: AppTheme.headlineBold(cs).copyWith(fontSize: 22),
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.appLockEnterToUnlock,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                PasscodePad(
                  onSubmit: _submit,
                  enabled: _remaining == Duration.zero,
                  statusText: _remaining > Duration.zero
                      ? l10n.appLockTryAgainIn(formatLockout(_remaining))
                      : null,
                  leftAction: showBio
                      ? IconButton(
                          key: const ValueKey('app-lock-biometric'),
                          tooltip: l10n.appLockUseBiometrics,
                          onPressed: _promptBiometric,
                          icon: const Icon(Icons.fingerprint, size: 30),
                        )
                      : null,
                ),
                const SizedBox(height: 12),
                TextButton(
                  key: const ValueKey('app-lock-forgot'),
                  onPressed: _forgot,
                  child: Text(l10n.appLockForgot),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
