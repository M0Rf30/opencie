// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/app_localizations.dart';
import '../../services/app_lock/app_lock_controller.dart';
import '../../services/app_lock/app_lock_service.dart';
import '../../widgets/oc_action_row.dart';
import '../../widgets/oc_section_label.dart';
import 'passcode_flow_dialog.dart';

String appLockTimeoutLabel(AutoLockTimeout t, AppLocalizations l10n) =>
    switch (t) {
      AutoLockTimeout.immediately => l10n.appLockTimeoutImmediately,
      AutoLockTimeout.oneMinute => l10n.appLockTimeout1m,
      AutoLockTimeout.fiveMinutes => l10n.appLockTimeout5m,
      AutoLockTimeout.oneHour => l10n.appLockTimeout1h,
      AutoLockTimeout.fiveHours => l10n.appLockTimeout5h,
    };

/// Settings > Security: app lock switch, passcode, auto-lock, biometrics.
class AppLockSettingsSection extends ConsumerWidget {
  const AppLockSettingsSection({super.key});

  Future<void> _toggle(BuildContext context, WidgetRef ref, bool on) async {
    if (on) {
      await showPasscodeFlow(context, PasscodeFlowMode.create);
    } else {
      final ok = await showPasscodeFlow(context, PasscodeFlowMode.verify);
      if (ok) await ref.read(appLockProvider.notifier).disable();
    }
  }

  Future<void> _toggleBiometrics(
    BuildContext context,
    WidgetRef ref,
    bool on,
  ) async {
    final ctrl = ref.read(appLockProvider.notifier);
    if (on) {
      final reason = AppLocalizations.of(context).appLockBiometricReason;
      ctrl.biometricBusy = true;
      final ok = await ref.read(biometricAuthProvider).authenticate(reason);
      ctrl.biometricBusy = false;
      if (!ok) return;
    }
    await ctrl.setBiometrics(on);
  }

  Future<void> _pickTimeout(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final current = ref.read(appLockProvider).config.timeout;
    final picked = await showDialog<AutoLockTimeout>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l10n.appLockAutoLock),
        children: [
          for (final t in AutoLockTimeout.values)
            ListTile(
              key: ValueKey('app-lock-timeout-${t.name}'),
              title: Text(appLockTimeoutLabel(t, l10n)),
              trailing: t == current ? const Icon(Icons.check) : null,
              onTap: () => Navigator.of(ctx).pop(t),
            ),
        ],
      ),
    );
    if (picked != null) {
      await ref.read(appLockProvider.notifier).setTimeout(picked);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final st = ref.watch(appLockProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OcSectionLabel(l10n.appLockSecurityTitle),
        const SizedBox(height: 8),
        OcGroupCard(
          children: [
            OcActionRow(
              leadingIcon: Icons.lock_outline,
              title: l10n.appLockSwitchTitle,
              subtitle: l10n.appLockSwitchSubtitle,
              onTap: () => _toggle(context, ref, !st.enabled),
              trailing: Switch.adaptive(
                key: const ValueKey('app-lock-switch'),
                value: st.enabled,
                onChanged: (v) => _toggle(context, ref, v),
              ),
            ),
            if (st.enabled) ...[
              OcActionRow(
                leadingIcon: Icons.password_outlined,
                title: l10n.appLockChangePasscode,
                subtitle: l10n.appLockPasscodeLabel,
                onTap: () => showPasscodeFlow(context, PasscodeFlowMode.change),
              ),
              OcActionRow(
                leadingIcon: Icons.timer_outlined,
                title: l10n.appLockAutoLock,
                subtitle: appLockTimeoutLabel(st.config.timeout, l10n),
                onTap: () => _pickTimeout(context, ref),
              ),
              if (st.biometricsAvailable)
                OcActionRow(
                  leadingIcon: Icons.fingerprint,
                  title: l10n.appLockBiometrics,
                  subtitle: l10n.appLockBiometricsSubtitle,
                  trailing: Switch.adaptive(
                    key: const ValueKey('app-lock-biometrics-switch'),
                    value: st.config.biometrics,
                    onChanged: (v) => _toggleBiometrics(context, ref, v),
                  ),
                ),
              OcActionRow(
                leadingIcon: Icons.lock_clock_outlined,
                title: l10n.appLockLockNow,
                onTap: () => ref.read(appLockProvider.notifier).lock(),
              ),
            ],
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text(
            l10n.appLockNotCardPin,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}
