// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/core/l10n/app_localizations.dart';
import 'package:opencie/features/app_lock/app_lock_gate.dart';
import 'package:opencie/services/app_lock/app_lock_controller.dart';
import 'package:opencie/services/app_lock/app_lock_service.dart';
import 'package:opencie/services/app_lock/biometric_auth.dart';
import 'package:opencie/services/app_lock/passcode_hasher.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryStorage implements AppLockStorage {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

class _NoBiometrics implements BiometricAuth {
  @override
  Future<bool> isAvailable() async => false;
  @override
  Future<bool> authenticate(String reason) async => false;
}

final navKey = GlobalKey<NavigatorState>();

Future<void> _pump(WidgetTester tester, AppLockService service) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appLockServiceProvider.overrideWithValue(service),
        biometricAuthProvider.overrideWithValue(_NoBiometrics()),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        navigatorKey: navKey,
        builder: (context, child) =>
            AppLockGate(isDesktop: false, child: child!),
        home: const Scaffold(body: Text('secret content')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String digits) async {
  for (final d in digits.split('')) {
    await tester.tap(find.byKey(ValueKey('passcode-key-$d')));
    await tester.pump();
  }
  await tester.tap(find.byKey(const ValueKey('passcode-pad-submit')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppLockService> enabledService() async {
    final s = AppLockService(
      storage: _MemoryStorage(),
      hasher: const PasscodeHasher(iterations: 1000, useIsolate: false),
    );
    await s.setPasscode('1234');
    await s.saveConfig(const AppLockConfig(enabled: true));
    return s;
  }

  testWidgets('lock screen covers content at start when enabled', (
    tester,
  ) async {
    await tester.runAsync(() async {});
    final service = await tester.runAsync(enabledService);
    await _pump(tester, service!);
    expect(find.byKey(const ValueKey('passcode-key-1')), findsOneWidget);
    expect(find.text('OpenCIE is locked'), findsOneWidget);
    expect(find.text('secret content'), findsNothing);
  });

  testWidgets('correct passcode unlocks', (tester) async {
    final service = await tester.runAsync(enabledService);
    await _pump(tester, service!);
    await _type(tester, '1234');
    expect(find.text('secret content'), findsOneWidget);
    expect(find.byKey(const ValueKey('passcode-key-1')), findsNothing);
  });

  testWidgets('wrong passcode shows an error and stays locked', (tester) async {
    final service = await tester.runAsync(enabledService);
    await _pump(tester, service!);
    await _type(tester, '9999');
    expect(find.text('Wrong passcode'), findsOneWidget);
    expect(find.text('secret content'), findsNothing);
    expect(find.byKey(const ValueKey('passcode-key-1')), findsOneWidget);
  });

  testWidgets('no lock screen when the lock is disabled', (tester) async {
    final service = AppLockService(storage: _MemoryStorage());
    await _pump(tester, service);
    expect(find.text('secret content'), findsOneWidget);
    expect(find.text('OpenCIE is locked'), findsNothing);
  });

  testWidgets('backgrounding with "immediately" locks again', (tester) async {
    final service = await tester.runAsync(() async {
      final s = await enabledService();
      await s.saveConfig(
        const AppLockConfig(
          enabled: true,
          timeout: AutoLockTimeout.immediately,
        ),
      );
      return s;
    });
    await _pump(tester, service!);
    await _type(tester, '1234');
    expect(find.text('secret content'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pumpAndSettle();
    expect(find.text('OpenCIE is locked'), findsOneWidget);
    expect(find.text('secret content'), findsNothing);
  });

  testWidgets('dialog shown while locked stays hidden under the lock', (
    tester,
  ) async {
    final service = await tester.runAsync(enabledService);
    await _pump(tester, service!);
    var tapped = false;
    showDialog<void>(
      context: navKey.currentContext!,
      builder: (_) => AlertDialog(
        content: const Text('late dialog'),
        actions: [
          TextButton(
            onPressed: () => tapped = true,
            child: const Text('dialog-button'),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('late dialog'), findsNothing);
    expect(find.text('OpenCIE is locked'), findsOneWidget);
    // Not hit-testable: the dialog sits inside an Offstage subtree.
    expect(
      find.ancestor(
        of: find.text('dialog-button', skipOffstage: false),
        matching: find.byWidgetPredicate((w) => w is Offstage && w.offstage),
      ),
      findsWidgets,
    );
    expect(tapped, isFalse);
    // After unlocking, the queued dialog becomes visible again.
    await _type(tester, '1234');
    expect(find.text('late dialog'), findsOneWidget);
  });
}
