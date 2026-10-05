// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import '../../../core/l10n/app_localizations.dart';
import '../../../services/sign/signature_upgrader.dart';

/// Localized, user-facing text for a post-sign upgrade [warning]. [detail]
/// (technical, never localized) is appended for a failed timestamp, flattened
/// to a single short line.
String upgradeWarningText(
  AppLocalizations l10n,
  SignatureUpgradeWarning warning, {
  String? detail,
}) {
  switch (warning) {
    case SignatureUpgradeWarning.timestampFailed:
      return l10n.signWarnTimestampFailed(_oneLine(detail));
    case SignatureUpgradeWarning.revocationUnavailable:
      return l10n.signWarnRevocationUnavailable;
  }
}

String _oneLine(String? detail) {
  final flat = (detail ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.isEmpty) return '—';
  return flat.length <= 160 ? flat : '${flat.substring(0, 157)}…';
}
