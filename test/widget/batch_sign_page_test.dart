// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/core/l10n/app_localizations.dart';
import 'package:opencie/features/sign/batch_sign_page.dart';
import 'package:opencie/widgets/oc_page.dart';

void main() {
  group('BatchSignPage', () {
    testWidgets('Renders without crash and shows empty state', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: BatchSignPage()),
          ),
        ),
      );

      // Verify the page renders
      expect(find.byType(BatchSignPage), findsOneWidget);

      // Verify empty state is shown
      expect(find.byIcon(Icons.cloud_upload_outlined), findsOneWidget);

      // Verify "Add Files" button is present
      expect(find.byType(ElevatedButton), findsWidgets);
    });

    testWidgets('page header shows the title and a back button', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: BatchSignPage()),
          ),
        ),
      );

      // The page header shows the localised title and a back button.
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(l10n.batchSignTitle), findsOneWidget);
      expect(find.byType(OcPageHeader), findsOneWidget);
      expect(find.byTooltip(l10n.commonBack), findsOneWidget);
    });
  });
}
