// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/l10n/app_localizations.dart';
import '../../../services/pin_policy.dart';

/// Dialog that collects the 8-digit CIE PIN for enrolment.
///
/// Pops with the entered PIN [String] on submit, or [null] on cancel.
class CieEnrollDialog extends StatefulWidget {
  const CieEnrollDialog({super.key});

  @override
  State<CieEnrollDialog> createState() => _CieEnrollDialogState();
}

class _CieEnrollDialogState extends State<CieEnrollDialog> {
  final _pinCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _pinCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      final pin = _pinCtrl.text;
      Navigator.pop(context, pin);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      icon: const Icon(Icons.add_card),
      title: Text(l10n.cieEnrolDialogTitle),
      content: Form(
        key: _formKey,
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _pinCtrl,
          builder: (_, val, _) => TextFormField(
            controller: _pinCtrl,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 8,
            autofocus: true,
            textInputAction: TextInputAction.done,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onFieldSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: l10n.ciePinAll8Digits,
              prefixIcon: const Icon(Icons.pin),
              suffixIcon: val.text.length == 8
                  ? const Icon(Icons.check_circle_rounded, color: Colors.green)
                  : null,
            ),
            validator: (v) {
              if (v == null || v.length != 8) return l10n.ciePinMust8Digits;
              final weakness = validateCiePin(v);
              return weakness == null ? null : _weaknessMessage(l10n, weakness);
            },
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.cieEnrolButton)),
      ],
    );
  }
}

String _weaknessMessage(AppLocalizations l10n, PinWeakness weakness) =>
    switch (weakness) {
      PinWeakness.tooShort => l10n.ciePinWeakTooShort,
      PinWeakness.notNumeric => l10n.ciePinWeakNotNumeric,
      PinWeakness.allSameDigit => l10n.ciePinWeakAllSameDigit,
      PinWeakness.sequential => l10n.ciePinWeakSequential,
      PinWeakness.repeatedPair => l10n.ciePinWeakRepeatedPair,
    };
