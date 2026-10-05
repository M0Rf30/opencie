// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/core/l10n/app_localizations.dart';
import 'package:opencie/router/app_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpAt(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: AppRouter.create(initialLocation: '/settings'),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  group('ShellPage layout', () {
    testWidgets('phone portrait uses the bottom navigation bar', (
      tester,
    ) async {
      await _pumpAt(tester, const Size(393, 873));
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone landscape uses a compact rail without overflow', (
      tester,
    ) async {
      // Redmi Note 12 Pro 5G (redwood) in landscape.
      await _pumpAt(tester, const Size(873, 393));
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.extended, isFalse);
      expect(rail.leading, isNull);
      expect(rail.labelType, NavigationRailLabelType.selected);
      expect(tester.takeException(), isNull);
    });

    testWidgets('narrow landscape (720x360) also gets the rail', (
      tester,
    ) async {
      await _pumpAt(tester, const Size(720, 360));
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
