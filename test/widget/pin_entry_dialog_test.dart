// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/core/l10n/app_localizations.dart';
import 'package:opencie/widgets/pin_entry_dialog.dart';

Future<void> _pumpDialog(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => PinEntryDialog.show(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _tapDigit(WidgetTester tester, String digit) async {
  await tester.tap(find.text(digit));
  await tester.pump();
}

void main() {
  group('PinEntryDialog live feedback (IO-09)', () {
    testWidgets('shows a running x/8 digit counter with no digits entered', (
      WidgetTester tester,
    ) async {
      await _pumpDialog(tester);
      expect(find.text('0/8'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
    });

    testWidgets('updates the counter as digits are typed', (
      WidgetTester tester,
    ) async {
      await _pumpDialog(tester);
      await _tapDigit(tester, '4');
      await _tapDigit(tester, '0');
      expect(find.text('2/8'), findsOneWidget);
    });

    testWidgets(
      'shows a check once a valid 4-digit prefix PIN is entered, without '
      'popping the dialog',
      (WidgetTester tester) async {
        await _pumpDialog(tester);
        for (final d in ['4', '0', '3', '9']) {
          await _tapDigit(tester, d);
        }
        expect(find.text('4/8'), findsOneWidget);
        expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
        // A 4-digit PIN is a legitimate cached-prefix re-entry length, but
        // the dialog itself only submits on the confirm tap, not on
        // reaching length 4 implicitly via more typing.
        expect(find.byType(PinEntryDialog), findsOneWidget);
      },
    );

    testWidgets(
      'shows a check for any full-length PIN, even one a new-PIN policy '
      'would call weak (the card PIN is what it is)',
      (WidgetTester tester) async {
        await _pumpDialog(tester);
        for (final d in ['1', '2', '3', '4', '5', '6', '7', '8']) {
          await _tapDigit(tester, d);
        }
        expect(find.text('8/8'), findsOneWidget);
        expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      },
    );

    testWidgets('no check for a length that is neither 4 nor 8', (
      WidgetTester tester,
    ) async {
      await _pumpDialog(tester);
      for (final d in ['4', '0', '3', '9', '1']) {
        await _tapDigit(tester, d);
      }
      expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
    });

    testWidgets('shows a check for an acceptable full 8-digit PIN', (
      WidgetTester tester,
    ) async {
      await _pumpDialog(tester);
      for (final d in ['4', '0', '3', '9', '1', '8', '2', '7']) {
        await _tapDigit(tester, d);
      }
      expect(find.text('8/8'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    });
  });
}
