// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/l10n/app_localizations.dart';
import 'core/theme/app_theme.dart';
import 'ffi/opencie_pkcs11.dart';
import 'providers/settings_provider.dart';
import 'router/app_router.dart';

/// Helper to compute visual density based on UI scale
VisualDensity _densityFor(double scale) {
  if (scale <= 0.9) return VisualDensity.compact;
  if (scale >= 1.3) return const VisualDensity(horizontal: 2, vertical: 2);
  return VisualDensity.standard;
}

class OpenCieApp extends ConsumerStatefulWidget {
  const OpenCieApp({super.key});

  @override
  ConsumerState<OpenCieApp> createState() => _OpenCieAppState();
}

class _OpenCieAppState extends ConsumerState<OpenCieApp> {
  GoRouter? _router;

  @override
  void initState() {
    super.initState();
    // Initialize the native library's app-private data directory on Android.
    // No-op on desktop. Best-effort: failures don't block app startup.
    OpenCiePkcs11.instance.initDataDir().catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);

    if (_router == null && settings.isLoaded) {
      _router = AppRouter.create(
        initialLocation: settings.enrolledCards.isEmpty ? '/cie' : '/sign',
        issuer: settings.oidcIssuer,
        clientId: settings.oidcClientId,
      );
    }

    if (_router == null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light.copyWith(
          visualDensity: _densityFor(settings.uiScale),
        ),
        darkTheme: AppTheme.dark.copyWith(
          visualDensity: _densityFor(settings.uiScale),
        ),
        themeMode: settings.themeMode,
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    return MaterialApp.router(
      title: 'OpenCIE',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light.copyWith(
        visualDensity: _densityFor(settings.uiScale),
      ),
      darkTheme: AppTheme.dark.copyWith(
        visualDensity: _densityFor(settings.uiScale),
      ),
      themeMode: settings.themeMode,
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(settings.uiScale)),
          child: child!,
        );
      },
      routerConfig: _router!,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
    );
  }
}
