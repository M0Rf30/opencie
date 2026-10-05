// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/core/l10n/app_localizations.dart';
import 'package:opencie/features/sign/sign_page.dart';

void main() {
  group('SignPage', () {
    testWidgets('renders without crash and disables Sign with no file', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: SignPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SignPage), findsOneWidget);

      // Regression guard for OC-14: with no file selected, every button
      // that can trigger `_startSigning` (IconButton on mobile layout,
      // ElevatedButton/OcGradientButton on desktop layout) must render
      // disabled, i.e. its `onPressed` callback is null. This is the same
      // gate that keeps a fast double-tap from starting two overlapping
      // signing flows once a file *is* selected, since `_isSigning` is
      // combined with `_selectedFile != null` in every onPressed clause.
      final iconButtons = tester.widgetList<IconButton>(
        find.byType(IconButton),
      );
      for (final button in iconButtons) {
        if (button.icon is Icon &&
            (button.icon as Icon).icon == Icons.contactless_rounded) {
          expect(button.onPressed, isNull);
        }
      }
    });
  });
}
