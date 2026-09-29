// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/core/l10n/app_localizations.dart';
import 'package:opencie/widgets/nfc_card_dialog.dart';

Future<void> _pumpDialog(
  WidgetTester tester, {
  required ValueNotifier<(bool, double, String)> notifier,
  required VoidCallback onCancel,
  ValueNotifier<String?>? errorNotifier,
  VoidCallback? onDismissError,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () {
                showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => NfcCardDialog(
                    notifier: notifier,
                    processingTitle: 'Signing',
                    onCancel: onCancel,
                    errorNotifier: errorNotifier,
                    onDismissError: onDismissError,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  group('NfcCardDialog back-gesture routing (OC-26)', () {
    testWidgets('a pop attempt while waiting for a card invokes onCancel', (
      WidgetTester tester,
    ) async {
      final notifier = ValueNotifier<(bool, double, String)>((true, 0.0, ''));
      var cancelled = false;

      await _pumpDialog(
        tester,
        notifier: notifier,
        onCancel: () => cancelled = true,
      );

      expect(find.byType(NfcCardDialog), findsOneWidget);

      // Simulate a system back-gesture / Navigator.maybePop on the dialog
      // route instead of tapping the Cancel button.
      final dynamic state = tester.state(find.byType(Navigator).first);
      await state.maybePop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        cancelled,
        isTrue,
        reason:
            'back gesture must route through the same cancel path '
            'a Cancel-button tap uses, so callers reset their busy flags',
      );
    });

    testWidgets(
      'a pop attempt while an error is shown invokes onDismissError',
      (WidgetTester tester) async {
        final notifier = ValueNotifier<(bool, double, String)>((
          false,
          0.5,
          '',
        ));
        final errorNotifier = ValueNotifier<String?>('boom');
        var dismissed = false;

        await _pumpDialog(
          tester,
          notifier: notifier,
          onCancel: () {},
          errorNotifier: errorNotifier,
          onDismissError: () => dismissed = true,
        );

        final dynamic state = tester.state(find.byType(Navigator).first);
        await state.maybePop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(dismissed, isTrue);
      },
    );
  });
}
