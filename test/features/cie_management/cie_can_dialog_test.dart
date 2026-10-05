// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/core/l10n/app_localizations.dart';
import 'package:opencie/features/cie_management/widgets/cie_can_dialog.dart';

Future<void> _open(
  WidgetTester tester,
  void Function(String?) onResult, {
  String? error,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async =>
              onResult(await CieCanDialog.show(context, errorMessage: error)),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('rejects non-6-digit input and returns a valid CAN', (
    tester,
  ) async {
    String? result;
    var done = false;
    await _open(tester, (r) {
      result = r;
      done = true;
    });

    await tester.enterText(find.byKey(const ValueKey('canField')), '12ab34');
    await tester.tap(find.text('Read'));
    await tester.pump();
    expect(find.text('The CAN must be exactly 6 digits'), findsOneWidget);
    expect(done, isFalse);

    await tester.enterText(find.byKey(const ValueKey('canField')), '123456');
    await tester.tap(find.text('Read'));
    await tester.pumpAndSettle();
    expect(result, '123456');
  });

  testWidgets('shows the wrong-CAN error for re-entry', (tester) async {
    await _open(tester, (_) {}, error: 'Wrong CAN');
    expect(find.byKey(const ValueKey('canErrorText')), findsOneWidget);
    expect(find.text('Wrong CAN'), findsOneWidget);
  });
}
