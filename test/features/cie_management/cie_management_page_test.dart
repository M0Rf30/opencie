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
import 'package:opencie/providers/settings_provider.dart';

/// Synthetic (non-real) enrolled-card fixture. PAN/serial are placeholders,
/// not a real CIE.
Map<String, Object?> _cardJson({
  required String pan,
  String name = 'Test User',
  bool withChipData = false,
  String? notAfter,
}) => {
  'pan': pan,
  'name': name,
  'serial': 'SERIAL-$pan',
  'notAfter': ?notAfter,
  if (withChipData) 'mrzSurname': 'ROSSI',
  if (withChipData) 'photoBytes': base64Encode([1, 2, 3, 4]),
};

Future<ProviderContainer> _pumpPage(
  WidgetTester tester,
  List<Map<String, Object?>> cards, {
  Size size = const Size(800, 600),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  SharedPreferences.setMockInitialValues({
    'opencie_settings': jsonEncode({'enrolledCards': cards}),
  });
  FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});

  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
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
  return container;
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

  group('CieManagementPage multi-card layouts', () {
    final twoCards = [
      _cardJson(pan: '1111222233334444', name: 'MARIO ROSSI'),
      _cardJson(pan: '5555666677778888', name: 'GIULIA BIANCHI'),
    ];

    testWidgets('one card keeps the single-card layout (no list rows)', (
      tester,
    ) async {
      await _pumpPage(tester, [
        _cardJson(pan: '1111222233334444'),
      ], size: const Size(1400, 900));

      expect(find.byKey(const ValueKey('cardList')), findsNothing);
      expect(
        find.byKey(const ValueKey('cardRow_1111222233334444')),
        findsNothing,
      );
    });

    testWidgets('desktop: list on the left, selecting a row switches the '
        'detail and the shared selection', (tester) async {
      final container = await _pumpPage(
        tester,
        twoCards,
        size: const Size(1400, 900),
      );

      expect(find.byKey(const ValueKey('cardList')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('cardRow_1111222233334444')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('cardRow_5555666677778888')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('addCardButton')), findsOneWidget);
      // Default: the first card is the detail (its masked PAN is on the
      // card visual).
      expect(find.text('1111 •••• 4444'), findsOneWidget);
      expect(find.text('5555 •••• 8888'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('cardRow_5555666677778888')));
      // Not pumpAndSettle: the reader prompt animates forever.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('5555 •••• 8888'), findsOneWidget);
      expect(find.text('1111 •••• 4444'), findsNothing);
      expect(
        container.read(settingsProvider).selectedCard?.pan,
        '5555666677778888',
      );
    });

    testWidgets('phone: rows list the cards and tapping one opens its '
        'detail page', (tester) async {
      final container = await _pumpPage(
        tester,
        twoCards,
        size: const Size(400, 900),
      );

      expect(
        find.byKey(const ValueKey('cardRow_1111222233334444')),
        findsOneWidget,
      );
      // No detail on the list page itself.
      expect(find.text('1111 •••• 4444'), findsNothing);

      await tester.ensureVisible(
        find.byKey(const ValueKey('cardRow_5555666677778888')),
      );
      await tester.tap(find.byKey(const ValueKey('cardRow_5555666677778888')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('5555 •••• 8888'), findsOneWidget);
      expect(
        container.read(settingsProvider).selectedCard?.pan,
        '5555666677778888',
      );

      await tester.tap(find.byType(BackButton));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.byType(AppBar), findsNothing);
      expect(
        find.byKey(const ValueKey('cardRow_1111222233334444')),
        findsOneWidget,
      );
    });
  });

  group('CieManagementPage header and expiry', () {
    testWidgets('card count is folded into the subtitle, not a caption', (
      tester,
    ) async {
      await _pumpPage(tester, [
        _cardJson(pan: '1111222233334444'),
        _cardJson(pan: '5555666677778888'),
      ], size: const Size(1400, 900));

      expect(find.text('CIE Management'), findsOneWidget);
      expect(
        find.text('Manage your electronic identity card · 2 cards'),
        findsOneWidget,
      );
      expect(find.text('2 cards enrolled'), findsNothing);
    });

    testWidgets('an expired card shows a warning in the detail pane', (
      tester,
    ) async {
      await _pumpPage(tester, [
        _cardJson(pan: '1111222233334444', notAfter: '2020-01-01T00:00:00.000'),
        _cardJson(pan: '5555666677778888'),
      ], size: const Size(1400, 900));

      expect(find.byKey(const ValueKey('expiredCardBanner')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('cardRow_5555666677778888')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('expiredCardBanner')), findsNothing);
    });
  });
}
