// SPDX-License-Identifier: GPL-3.0-or-later
//
// Offscreen renderer for the README / Flathub screenshots.
//
//   fvm flutter test --tags screenshots test/screenshots
//
// Renders the real app (OpenCieApp -> router -> ShellPage + pages) with all
// state faked: in-memory SharedPreferences, in-memory secure storage, a fake
// reader stream and mocked package info. Nothing here reads the user's real
// settings, keyring or ~/.CIEPKI, and no network call is made.
@Tags(['screenshots'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:opencie/app.dart';
import 'package:opencie/ffi/opencie_pkcs11.dart';
import 'package:opencie/router/shell_page.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _size = Size(1918, 1036);
const _titleBarHeight = 56.0;
const _outDir = 'docs/screenshots';

Future<void> _loadFont(String family, List<Future<ByteData>> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(f);
  }
  await loader.load();
}

Future<ByteData> _file(String path) async =>
    ByteData.sublistView(await File(path).readAsBytes());

/// Opt-in guard: the dart_test.yaml tag system cannot both exclude a tag by
/// default and re-include it from the CLI, so the default `flutter test` run
/// skips this file unless OPENCIE_SCREENSHOTS is set.
final bool _enabled = Platform.environment['OPENCIE_SCREENSHOTS'] == '1';

Future<void> _loadFonts() async {
  // Bundled app fonts.
  await _loadFont('Inter', [
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold'])
      _file('assets/fonts/Inter-$w.ttf'),
  ]);
  await _loadFont('JetBrainsMono', [
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold'])
      _file('assets/fonts/JetBrainsMono-$w.ttf'),
  ]);
  // Flutter SDK material fonts.
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) throw StateError('FLUTTER_ROOT not set');
  final mf = '$root/bin/cache/artifacts/material_fonts';
  await _loadFont('MaterialIcons', [_file('$mf/MaterialIcons-Regular.otf')]);
  await _loadFont('Roboto', [
    for (final w in ['Regular', 'Medium', 'Bold']) _file('$mf/Roboto-$w.ttf'),
  ]);
}

/// Fully fake settings blob: one fake card, no secrets.
Map<String, Object> _fakePrefs() {
  final now = DateTime.now();
  final settings = {
    'locale': 'it',
    'themeMode': 'dark',
    'uiScale': 1.0,
    'checkForUpdates': true,
    'updateCheckConsentAsked': true,
    'tsaConfig': {
      'serverUrl': 'https://freetsa.org/tsr',
      'username': '',
      'autoSummerTime': true,
    },
    'proxyConfig': <String, Object>{},
    'enrolledCards': [
      {
        'pan': '0000000000000000',
        'name': 'MARIO ROSSI',
        'serial': 'RSSMRA80A01H501Z',
        'subject': 'CN=RSSMRA80A01H501Z/MARIO ROSSI',
        'issuer': 'CN=CIE Fittizia (esempio)',
        'certSerial': '0A1B2C3D4E5F',
        'keyAlgorithm': 'RSA',
        'notBefore': '2024-01-15T00:00:00.000',
        'notAfter': '2034-01-15T00:00:00.000',
      },
    ],
  };
  String recent(List<(String, DateTime)> files) => jsonEncode([
    for (final f in files)
      {'path': '/tmp/${f.$1}', 'addedAt': f.$2.toIso8601String()},
  ]);
  return {
    'opencie_settings': jsonEncode(settings),
    // Avoid the update check network call: pretend it ran just now.
    'update_check_last_ms': now.millisecondsSinceEpoch,
    'opencie_recent_sign_files': recent([
      ('contratto.pdf', DateTime(2026, 3, 7, 10, 30)),
      ('relazione.pdf', DateTime(2026, 3, 6, 16, 5)),
      ('preventivo.pdf', DateTime(2026, 3, 5, 9, 12)),
    ]),
    'opencie_recent_verify_files': recent([
      ('contratto_firmato.pdf.p7m', DateTime(2026, 3, 7, 10, 31)),
      ('relazione_firmata.pdf', DateTime(2026, 3, 7, 9, 2)),
      ('preventivo_firmato.pdf.p7m', DateTime(2026, 3, 6, 17, 40)),
      ('fattura_firmata.pdf', DateTime(2026, 3, 6, 11, 8)),
      ('preventivo.pdf', DateTime(2026, 3, 5, 9, 15)),
    ]),
  };
}

/// Mock desktop window title bar (the real captures included the WM one).
class _TitleBar extends StatelessWidget {
  const _TitleBar();

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData i) => Container(
      width: 28,
      height: 28,
      margin: const EdgeInsets.only(right: 8),
      decoration: const BoxDecoration(
        color: Color(0x1FFFFFFF),
        shape: BoxShape.circle,
      ),
      child: Icon(i, size: 14, color: Colors.white),
    );
    return Container(
      height: _titleBarHeight,
      color: const Color(0xFF242424),
      child: Stack(
        alignment: Alignment.center,
        children: [
          const Text(
            'OpenCIE',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              decoration: TextDecoration.none,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  btn(Icons.remove),
                  btn(Icons.crop_square),
                  btn(Icons.close),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    if (_enabled) await _loadFonts();
  });

  testWidgets('render README screenshots', skip: !_enabled, (tester) async {
    // --- isolate every external dependency ------------------------------
    SharedPreferences.setMockInitialValues(_fakePrefs());
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
    PackageInfo.setMockInitialValues(
      appName: 'OpenCIE',
      packageName: 'io.github.m0rf30.opencie',
      version: '0.4.3',
      buildNumber: '10',
      buildSignature: '',
    );
    OpenCiePkcs11.debugWatchReaders = () =>
        Stream.value('ACS ACR122U PICC Interface 00 00');
    addTearDown(() => OpenCiePkcs11.debugWatchReaders = null);

    tester.view.physicalSize = _size;
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.localesTestValue = const [Locale('it')];
    tester.platformDispatcher.localeTestValue = const Locale('it');
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearLocalesTestValue();
    });

    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: const [
              _TitleBar(),
              Expanded(child: ProviderScope(child: OpenCieApp())),
            ],
          ),
        ),
      ),
    );

    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> capture(String name) async {
      await settle();
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final ui.Image img = await boundary.toImage();
        final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
        File(
          '$_outDir/$name.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }

    Future<void> go(String location) async {
      final ctx = tester.element(find.byType(ShellPage));
      GoRouter.of(ctx).go(location);
      await settle();
    }

    await settle();
    // Router starts on /sign (one enrolled card).
    expect(find.byType(ShellPage), findsOneWidget);

    await capture('sign');
    await go('/verify');
    await capture('verify');
    await go('/cie');
    await capture('cie');
    await go('/settings');
    await capture('settings');
  });
}
