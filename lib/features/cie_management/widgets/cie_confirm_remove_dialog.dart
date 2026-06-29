// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../../core/l10n/app_localizations.dart';
import '../../../models/enrolled_card.dart';

class CieConfirmRemoveDialog extends StatelessWidget {
  const CieConfirmRemoveDialog({
    super.key,
    required this.card,
    required this.onConfirm,
  });

  final EnrolledCard card;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      icon: const Icon(Icons.remove_circle_outline),
      title: Text(l10n.cieRemoveDialogTitle),
      content: Text(l10n.cieRemoveConfirm(card.displayName, card.pan)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () {
            Navigator.pop(context);
            onConfirm();
          },
          child: Text(l10n.cieRemoveButton),
        ),
      ],
    );
  }
}
