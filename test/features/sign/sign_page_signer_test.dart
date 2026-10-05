// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:opencie/core/l10n/app_localizations.dart';
import 'package:opencie/features/sign/sign_page.dart';
import 'package:opencie/providers/settings_provider.dart';

/// Synthetic enrolled cards (fake names / fiscal codes).
const _cards = [
  ('0000000000000000', 'MARIO ROSSI', 'RSSMRA80A01H501Z'),
  ('1111111111111111', 'GIULIA BIANCHI', 'BNCGLI85M41F205X'),
  ('2222222222222222', 'LUCA VERDI', 'VRDLCU90C12L219K'),
];

Future<ProviderContainer> _pumpSignPage(
  WidgetTester tester, {
  required Size size,
  required int cardCount,
  String? selectedPan,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  SharedPreferences.setMockInitialValues({
    'opencie_settings': jsonEncode({
      'enrolledCards': [
        for (final c in _cards.take(cardCount))
          {'pan': c.$1, 'name': c.$2, 'serial': c.$3},
      ],
    }),
  });
  FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({
    'opencie_selected_card': ?selectedPan,
  });

  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: const Scaffold(body: SignPage()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return container;
}

String _shownSigner(WidgetTester tester) => tester
    .widget<Text>(
      find
          .descendant(
            of: find.byKey(const ValueKey('signerPicker')),
            matching: find.byKey(const ValueKey('signerName')),
          )
          .first,
    )
    .data!;

void main() {
  const desktop = Size(1400, 900);
  const phone = Size(400, 900);

  group('SignPage signer picker', () {
    testWidgets('desktop: menu lists every card and picking one changes the '
        'signer and the shared selection', (tester) async {
      final container = await _pumpSignPage(
        tester,
        size: desktop,
        cardCount: 3,
      );

      expect(_shownSigner(tester), 'MARIO ROSSI');

      await tester.tap(find.byKey(const ValueKey('signerPicker')));
      await tester.pumpAndSettle();

      for (final c in _cards) {
        expect(find.byKey(ValueKey('signerOption_${c.$1}')), findsOneWidget);
      }

      await tester.tap(
        find.byKey(const ValueKey('signerOption_2222222222222222')),
      );
      await tester.pumpAndSettle();

      expect(_shownSigner(tester), 'LUCA VERDI');
      expect(
        container.read(settingsProvider).selectedCard?.pan,
        '2222222222222222',
      );
      expect(container.read(settingsProvider).signPan, '');
      expect(find.byKey(const ValueKey('signerPresentHint')), findsOneWidget);
    });

    testWidgets('phone: a bottom sheet lists every card and picking one '
        'changes the signer', (tester) async {
      final container = await _pumpSignPage(tester, size: phone, cardCount: 3);

      expect(_shownSigner(tester), 'MARIO ROSSI');

      await tester.tap(find.byKey(const ValueKey('signerPicker')));
      await tester.pumpAndSettle();

      expect(find.text('Sign with'), findsOneWidget);
      for (final c in _cards) {
        expect(find.byKey(ValueKey('signerOption_${c.$1}')), findsOneWidget);
      }

      await tester.tap(
        find.byKey(const ValueKey('signerOption_1111111111111111')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Sign with'), findsNothing);
      expect(_shownSigner(tester), 'GIULIA BIANCHI');
      expect(
        container.read(settingsProvider).selectedCard?.pan,
        '1111111111111111',
      );
    });

    testWidgets('shows the persisted selected card on start', (tester) async {
      await _pumpSignPage(
        tester,
        size: desktop,
        cardCount: 3,
        selectedPan: '1111111111111111',
      );

      expect(_shownSigner(tester), 'GIULIA BIANCHI');
    });

    testWidgets('a single card is shown without a picker', (tester) async {
      await _pumpSignPage(tester, size: desktop, cardCount: 1);

      expect(find.byKey(const ValueKey('signerPicker')), findsNothing);
      expect(find.text('MARIO ROSSI'), findsOneWidget);
      expect(find.text('RSSMRA80A01H501Z'), findsOneWidget);
    });
  });

  group('SignPage disabled reason', () {
    testWidgets('names the first unmet requirement under the Sign button', (
      tester,
    ) async {
      await _pumpSignPage(tester, size: desktop, cardCount: 1);

      final reason = tester.widget<Text>(
        find.byKey(const ValueKey('signDisabledReason')),
      );
      expect(reason.data, 'Select a document');
    });

    testWidgets('narrow layout shows the reason too', (tester) async {
      await _pumpSignPage(tester, size: phone, cardCount: 1);

      expect(find.byKey(const ValueKey('signDisabledReason')), findsOneWidget);
    });
  });
}
