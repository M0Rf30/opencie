// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../../core/l10n/app_localizations.dart';
import '../../../models/enrolled_card.dart';

class CieCertificateDialog extends StatelessWidget {
  const CieCertificateDialog({super.key, required this.card});

  final EnrolledCard card;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    String fmtDate(DateTime? d) {
      if (d == null) return '—';
      return '${d.day.toString().padLeft(2, '0')}/'
          '${d.month.toString().padLeft(2, '0')}/'
          '${d.year}';
    }

    final mq = MediaQuery.of(context);
    return AlertDialog(
      icon: const Icon(Icons.badge),
      title: Text(l10n.cieCertDialogTitle),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 360,
          maxHeight: mq.size.height * 0.55,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (card.name.trim().isNotEmpty)
                _certRow(l10n.cieNameLabel, card.name.trim(), theme),
              _certRow('PAN', card.pan, theme),
              if (card.serial.trim().isNotEmpty)
                _certRow(l10n.cieSerialLabel, card.serial.trim(), theme),
              if (card.subject != null)
                _certRow(l10n.cieSubjectLabel, card.subject!, theme),
              if (card.issuer != null)
                _certRow(l10n.cieIssuerLabel, card.issuer!, theme),
              if (card.certSerial != null)
                _certRow(l10n.cieCertSerialLabel, card.certSerial!, theme),
              if (card.keyAlgorithm != null)
                _certRow(l10n.cieKeyLabel, card.keyAlgorithm!, theme),
              _certRow(l10n.cieValidFromLabel, fmtDate(card.notBefore), theme),
              _certRow(l10n.cieValidToLabel, fmtDate(card.notAfter), theme),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonClose)),
      ],
    );
  }
}

Widget _certRow(String label, String value, ThemeData theme) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 64,
          child: Text(label,
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        Expanded(
            child: Text(value,
                style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    fontFamily: 'JetBrainsMono'))),
      ],
    ),
  );
}
