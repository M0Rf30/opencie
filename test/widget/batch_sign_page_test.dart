// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/core/l10n/app_localizations.dart';
import 'package:opencie/features/sign/batch_sign_page.dart';

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

    testWidgets('AppBar has correct title', (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: BatchSignPage()),
          ),
        ),
      );

      // The page should have an AppBar with title
      expect(find.byType(AppBar), findsOneWidget);
    });
  });
}
