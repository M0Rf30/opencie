// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/core/l10n/app_localizations.dart';
import 'package:opencie/features/sign/widgets/signed_result_dialog.dart';
import 'package:opencie/models/signature_options.dart';
import 'package:opencie/services/sign/signature_upgrader.dart';

Future<void> _pump(
  WidgetTester tester, {
  required SignatureOptions options,
  bool timestamped = false,
  SignatureUpgradeWarning? warning,
  String? warningDetail,
  Locale locale = const Locale('en'),
}) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      home: Scaffold(
        body: SignedResultDialog(
          outputPath: '/tmp/doc_signed.pdf',
          options: options,
          onOpenFile: (_) async {},
          onVerifyFile: (_) {},
          tsaLabel: 'FreeTSA',
          timestamped: timestamped,
          warning: warning,
          warningDetail: warningDetail,
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('SignedResultDialog timestamp reporting', () {
    testWidgets('shows the TSA only when a timestamp was really applied', (
      tester,
    ) async {
      await _pump(
        tester,
        options: const SignatureOptions(addTimestamp: true),
        timestamped: true,
      );

      expect(find.text('FreeTSA'), findsOneWidget);
      expect(find.textContaining('· TSA'), findsOneWidget);
      expect(find.byKey(const ValueKey('signedResultWarning')), findsNothing);
    });

    testWidgets('a requested but failed timestamp is not reported as TSA', (
      tester,
    ) async {
      await _pump(
        tester,
        options: const SignatureOptions(addTimestamp: true),
        timestamped: false,
        warning: SignatureUpgradeWarning.timestampFailed,
        warningDetail: 'TspException: HTTP 500',
      );

      expect(find.text('FreeTSA'), findsNothing);
      expect(find.textContaining('· TSA'), findsNothing);
      expect(find.byKey(const ValueKey('signedResultWarning')), findsOneWidget);
      expect(
        find.textContaining('the timestamp could not be added'),
        findsOneWidget,
      );
      expect(find.textContaining('TspException: HTTP 500'), findsOneWidget);
    });

    testWidgets('revocation warning accompanies an applied timestamp', (
      tester,
    ) async {
      await _pump(
        tester,
        options: const SignatureOptions(addTimestamp: true),
        timestamped: true,
        warning: SignatureUpgradeWarning.revocationUnavailable,
      );

      expect(find.text('FreeTSA'), findsOneWidget);
      expect(find.textContaining('revocation data'), findsOneWidget);
    });

    testWidgets('warning is localized (Italian)', (tester) async {
      await _pump(
        tester,
        options: const SignatureOptions(addTimestamp: true),
        warning: SignatureUpgradeWarning.timestampFailed,
        warningDetail: 'x',
        locale: const Locale('it'),
      );

      expect(
        find.textContaining('non è stato possibile aggiungere'),
        findsOneWidget,
      );
    });

    testWidgets('no timestamp requested: no TSA, no warning', (tester) async {
      await _pump(tester, options: const SignatureOptions());

      expect(find.text('FreeTSA'), findsNothing);
      expect(find.byKey(const ValueKey('signedResultWarning')), findsNothing);
    });
  });
}
