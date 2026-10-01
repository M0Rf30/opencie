// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:opencie/core/constants/app_constants.dart';
import 'package:opencie/core/l10n/app_localizations.dart';
import 'package:opencie/features/timestamp/timestamp_page.dart';

Future<void> _pump(WidgetTester tester, String tsaUrl) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  SharedPreferences.setMockInitialValues({
    'opencie_settings': jsonEncode({
      'tsaConfig': {'serverUrl': tsaUrl},
    }),
  });
  FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});

  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const TimestampPage()),
      GoRoute(
        path: '/settings',
        builder: (_, _) => const Scaffold(body: Text('settings-page')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('default FreeTSA: shows its name and the non-qualified warning', (
    tester,
  ) async {
    await _pump(tester, AppConstants.defaultTsaUrl);
    expect(
      find.textContaining('FreeTSA · https://freetsa.org/tsr'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('timestampFreeTsaWarning')),
      findsOneWidget,
    );
  });

  testWidgets('configured qualified TSA: shows its name, no warning', (
    tester,
  ) async {
    await _pump(tester, AppConstants.qualifiedTsaProviders['Namirial']!);
    expect(
      find.textContaining(
        'Namirial · ${AppConstants.qualifiedTsaProviders['Namirial']}',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('freetsa.org'), findsNothing);
    expect(find.byKey(const ValueKey('timestampFreeTsaWarning')), findsNothing);
  });

  testWidgets('Configure navigates to the settings page', (tester) async {
    await _pump(tester, AppConstants.defaultTsaUrl);
    await tester.tap(find.byKey(const ValueKey('timestampConfigure')));
    await tester.pumpAndSettle();
    expect(find.text('settings-page'), findsOneWidget);
  });
}
