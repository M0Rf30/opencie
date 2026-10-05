// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/l10n/app_localizations.dart';

/// Dialog that collects the 6-digit CAN (Card Access Number) printed on the
/// front of the CIE, used for the PACE chip read. It is never persisted:
/// the caller uses it for one read and discards it.
///
/// Pops with the entered CAN [String] on submit, or null on cancel.
/// [errorMessage] (e.g. "Wrong CAN" after a rejected attempt) is shown above
/// the field so the user can retype it.
class CieCanDialog extends StatefulWidget {
  const CieCanDialog({super.key, this.errorMessage, this.cancelLabel});

  final String? errorMessage;

  /// Label of the dismiss button (defaults to "Cancel"; enrolment passes
  /// "Skip" since the step is optional).
  final String? cancelLabel;

  static Future<String?> show(
    BuildContext context, {
    String? errorMessage,
    String? cancelLabel,
  }) => showDialog<String>(
    context: context,
    builder: (_) =>
        CieCanDialog(errorMessage: errorMessage, cancelLabel: cancelLabel),
  );

  @override
  State<CieCanDialog> createState() => _CieCanDialogState();
}

class _CieCanDialogState extends State<CieCanDialog> {
  static const _canLength = 6;
  final _ctrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _ctrl.clear();
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      Navigator.pop(context, _ctrl.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      icon: const Icon(Icons.credit_card_outlined),
      title: Text(l10n.cieReadChipAction),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.errorMessage != null) ...[
              Text(
                widget.errorMessage!,
                key: const ValueKey('canErrorText'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
              const SizedBox(height: 12),
            ],
            Text(l10n.cieCanDialogBody),
            const SizedBox(height: 16),
            TextFormField(
              key: const ValueKey('canField'),
              controller: _ctrl,
              keyboardType: TextInputType.number,
              maxLength: _canLength,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onFieldSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: l10n.cieCanLabel,
                prefixIcon: const Icon(Icons.pin),
              ),
              validator: (v) => (v == null || v.length != _canLength)
                  ? l10n.cieCanMust6Digits
                  : null,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.cancelLabel ?? l10n.commonCancel),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.cieCanReadButton)),
      ],
    );
  }
}
