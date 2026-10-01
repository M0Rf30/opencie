// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/l10n/app_localizations.dart';
import '../services/update_checker.dart';

/// Shows a non-blocking "update available" banner with a download /
/// release-notes action and a dismiss action. Never downloads anything.
///
/// [recordDismissal] persists the dismissed version so automatic checks stop
/// prompting for it.
void showUpdateBanner(
  ScaffoldMessengerState messenger,
  AppLocalizations l10n,
  UpdateInfo info, {
  bool recordDismissal = true,
}) {
  final flatpak = UpdateChecker.detectChannel() == UpdateChannel.flatpak;
  messenger
    ..hideCurrentMaterialBanner()
    ..showMaterialBanner(
      MaterialBanner(
        leading: const Icon(Icons.system_update_alt),
        content: Text(
          flatpak
              ? l10n.updateAvailableFlatpakMessage(info.version)
              : l10n.updateAvailableMessage(info.version),
        ),
        actions: [
          TextButton(
            onPressed: () {
              launchUrl(
                Uri.parse(info.url),
                mode: LaunchMode.externalApplication,
              );
            },
            child: Text(
              flatpak
                  ? l10n.updateActionReleaseNotes
                  : l10n.updateActionDownload,
            ),
          ),
          TextButton(
            onPressed: () {
              if (recordDismissal) UpdateChecker.dismiss(info.version);
              messenger.hideCurrentMaterialBanner();
            },
            child: Text(l10n.updateActionDismiss),
          ),
        ],
      ),
    );
}
