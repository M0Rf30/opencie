// SPDX-FileCopyrightText: 2026 Gianluca Boiano
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
  VoidCallback? onRetry,
  String? continueLabel,
  ValueNotifier<bool>? nfcDisabledNotifier,
  VoidCallback? onOpenNfcSettings,
  VoidCallback? onDismissNfcDisabled,
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
                    onRetry: onRetry,
                    continueLabel: continueLabel,
                    nfcDisabledNotifier: nfcDisabledNotifier,
                    onOpenNfcSettings: onOpenNfcSettings,
                    onDismissNfcDisabled: onDismissNfcDisabled,
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

  group(
    'NfcCardDialog chip-read-incomplete Retry / Continue (chip-read-ux)',
    () {
      testWidgets(
        'shows Retry and a continue-without button when onRetry is set, and '
        'Retry invokes onRetry',
        (WidgetTester tester) async {
          final notifier = ValueNotifier<(bool, double, String)>((
            false,
            1.0,
            '',
          ));
          final errorNotifier = ValueNotifier<String?>(
            'The chip read did not finish.',
          );
          var retried = false;
          var dismissed = false;

          await _pumpDialog(
            tester,
            notifier: notifier,
            onCancel: () {},
            errorNotifier: errorNotifier,
            onDismissError: () => dismissed = true,
            onRetry: () => retried = true,
            continueLabel: 'Continue without',
          );

          expect(
            find.byKey(const ValueKey('nfcCardDialogRetry')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('nfcCardDialogDismiss')),
            findsOneWidget,
          );
          expect(find.text('Continue without'), findsOneWidget);

          await tester.tap(find.byKey(const ValueKey('nfcCardDialogRetry')));
          await tester.pump();

          expect(retried, isTrue);
          expect(dismissed, isFalse);
        },
      );

      testWidgets(
        'tapping the dismiss button invokes onDismissError, not onRetry',
        (WidgetTester tester) async {
          final notifier = ValueNotifier<(bool, double, String)>((
            false,
            1.0,
            '',
          ));
          final errorNotifier = ValueNotifier<String?>('incomplete');
          var retried = false;
          var dismissed = false;

          await _pumpDialog(
            tester,
            notifier: notifier,
            onCancel: () {},
            errorNotifier: errorNotifier,
            onDismissError: () => dismissed = true,
            onRetry: () => retried = true,
            continueLabel: 'Continue without',
          );

          await tester.tap(find.byKey(const ValueKey('nfcCardDialogDismiss')));
          await tester.pump();

          expect(dismissed, isTrue);
          expect(retried, isFalse);
        },
      );

      testWidgets(
        'no Retry button when onRetry is null (plain dismiss error)',
        (WidgetTester tester) async {
          final notifier = ValueNotifier<(bool, double, String)>((
            false,
            1.0,
            '',
          ));
          final errorNotifier = ValueNotifier<String?>('boom');

          await _pumpDialog(
            tester,
            notifier: notifier,
            onCancel: () {},
            errorNotifier: errorNotifier,
            onDismissError: () {},
          );

          expect(
            find.byKey(const ValueKey('nfcCardDialogRetry')),
            findsNothing,
          );
        },
      );
    },
  );

  group('NfcCardDialog NFC-disabled inline state (IO-10)', () {
    testWidgets('shows the inline settings button instead of the waiting '
        'view when NFC is off', (WidgetTester tester) async {
      final notifier = ValueNotifier<(bool, double, String)>((true, 0.0, ''));
      final nfcDisabledNotifier = ValueNotifier<bool>(true);
      var openedSettings = false;

      await _pumpDialog(
        tester,
        notifier: notifier,
        onCancel: () {},
        nfcDisabledNotifier: nfcDisabledNotifier,
        onOpenNfcSettings: () => openedSettings = true,
        onDismissNfcDisabled: () {},
      );

      expect(find.byIcon(Icons.nfc_rounded), findsOneWidget);

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pump();
      expect(openedSettings, isTrue);
    });

    testWidgets(
      'a pop attempt while NFC is disabled invokes onDismissNfcDisabled',
      (WidgetTester tester) async {
        final notifier = ValueNotifier<(bool, double, String)>((true, 0.0, ''));
        final nfcDisabledNotifier = ValueNotifier<bool>(true);
        var dismissed = false;

        await _pumpDialog(
          tester,
          notifier: notifier,
          onCancel: () {},
          nfcDisabledNotifier: nfcDisabledNotifier,
          onOpenNfcSettings: () {},
          onDismissNfcDisabled: () => dismissed = true,
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
