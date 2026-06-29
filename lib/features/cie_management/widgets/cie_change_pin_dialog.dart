// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/l10n/app_localizations.dart';

/// Dialog that collects current PIN + new PIN for a PIN-change operation.
///
/// Pops with a `(currentPin, newPin)` record on submit, or [null] on cancel.
class CieChangePinDialog extends StatefulWidget {
  const CieChangePinDialog({super.key});

  @override
  State<CieChangePinDialog> createState() => _CieChangePinDialogState();
}

class _CieChangePinDialogState extends State<CieChangePinDialog> {
  final _curCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _repCtrl = TextEditingController();
  final _curFocus = FocusNode();
  final _newFocus = FocusNode();
  final _repFocus = FocusNode();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _curFocus.dispose();
    _newFocus.dispose();
    _repFocus.dispose();
    _curCtrl.dispose();
    _newCtrl.dispose();
    _repCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      final currentPin = _curCtrl.text;
      final newPin = _newCtrl.text;
      Navigator.pop(context, (currentPin, newPin));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      icon: const Icon(Icons.pin),
      title: Text(l10n.cieChangePinDialogTitle),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _curCtrl,
              builder: (_, val, _) => TextFormField(
                controller: _curCtrl,
                focusNode: _curFocus,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 8,
                autofocus: true,
                textInputAction: TextInputAction.next,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onFieldSubmitted: (_) => _newFocus.requestFocus(),
                decoration: InputDecoration(
                  labelText: l10n.cieCurrentPin8Digits,
                  prefixIcon: const Icon(Icons.lock),
                  suffixIcon: val.text.length == 8
                      ? const Icon(
                          Icons.check_circle_rounded,
                          color: Colors.green,
                        )
                      : null,
                ),
                validator: (v) =>
                    v != null && v.length == 8 ? null : l10n.ciePinMust8Digits,
              ),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _newCtrl,
              builder: (_, val, _) => TextFormField(
                controller: _newCtrl,
                focusNode: _newFocus,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 8,
                textInputAction: TextInputAction.next,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onFieldSubmitted: (_) => _repFocus.requestFocus(),
                decoration: InputDecoration(
                  labelText: l10n.cieNewPin8Digits,
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: val.text.length == 8
                      ? const Icon(
                          Icons.check_circle_rounded,
                          color: Colors.green,
                        )
                      : null,
                ),
                validator: (v) =>
                    v != null && v.length == 8 ? null : l10n.ciePinMust8Digits,
              ),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _repCtrl,
              builder: (_, val, _) => TextFormField(
                controller: _repCtrl,
                focusNode: _repFocus,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 8,
                textInputAction: TextInputAction.done,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onFieldSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: l10n.cieRepeatPin,
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: val.text.isNotEmpty && val.text == _newCtrl.text
                      ? const Icon(
                          Icons.check_circle_rounded,
                          color: Colors.green,
                        )
                      : null,
                ),
                validator: (v) =>
                    v == _newCtrl.text ? null : l10n.ciePinsDoNotMatch,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.cieChangePinButton)),
      ],
    );
  }
}
