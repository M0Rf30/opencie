// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/core/l10n/app_localizations.dart';
import 'package:opencie/features/verify/verify_page.dart';
import 'package:opencie/providers/recent_files_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('VerifyPage recent files', () {
    testWidgets('tapping an entry whose file is gone removes it', (
      tester,
    ) async {
      const missing = '/run/user/1000/doc/0000/expired.pdf.p7m';
      SharedPreferences.setMockInitialValues({
        'opencie_recent_verify_files': jsonEncode([
          {'path': missing, 'addedAt': DateTime(2026, 3, 7).toIso8601String()},
        ]),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const VerifyPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('expired.pdf.p7m'));
      await tester.pumpAndSettle();

      expect(container.read(recentFilesProvider), isEmpty);
      expect(find.text('expired.pdf.p7m'), findsNothing);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(l10n.commonRecentFileMissing), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('opencie_recent_verify_files'), '[]');
    });
  });
}
