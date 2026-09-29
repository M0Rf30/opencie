// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:opencie/core/l10n/app_localizations.dart';
import 'package:opencie/features/cie_management/cie_management_page.dart';

/// Synthetic (non-real) enrolled-card fixture. PAN/serial are placeholders,
/// not a real CIE.
Map<String, Object?> _cardJson({
  required String pan,
  bool withChipData = false,
}) => {
  'pan': pan,
  'name': 'Test User',
  'serial': 'SERIAL-$pan',
  if (withChipData) 'mrzSurname': 'ROSSI',
  if (withChipData) 'photoBytes': base64Encode([1, 2, 3, 4]),
};

Future<void> _pumpPage(
  WidgetTester tester,
  List<Map<String, Object?>> cards,
) async {
  SharedPreferences.setMockInitialValues({
    'opencie_settings': jsonEncode({'enrolledCards': cards}),
  });
  FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const CieManagementPage(),
      ),
    ),
  );
  // Settle the async settings load; native reader-watch/NFC-availability
  // calls surface as stream/platform-channel errors in the test sandbox
  // (no native lib / plugin registered) but don't block the widget tree
  // from building once settings resolve.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('CieManagementPage "Read chip data" action (chip-read-ux)', () {
    testWidgets('appears for a card missing MRZ/photo', (tester) async {
      await _pumpPage(tester, [_cardJson(pan: '1111222233334444')]);

      expect(find.byKey(const ValueKey('readChipDataAction')), findsWidgets);
    });

    testWidgets('does not appear once MRZ + photo are both present', (
      tester,
    ) async {
      await _pumpPage(tester, [
        _cardJson(pan: '1111222233334444', withChipData: true),
      ]);

      expect(find.byKey(const ValueKey('readChipDataAction')), findsNothing);
    });
  });
}
