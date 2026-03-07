// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/login_page.dart';
import '../features/auth/profile_page.dart';
import '../features/cie_management/cie_management_page.dart';
import '../features/settings/settings_page.dart';
import '../features/sign/sign_page.dart';
import '../features/timestamp/timestamp_page.dart';
import '../features/verify/verify_page.dart';
import 'shell_page.dart';

/// Application navigation routes.
///
/// Uses [StatefulShellRoute] to maintain each tab's state independently.
class AppRouter {
  AppRouter._();

  static final _rootNavigatorKey = GlobalKey<NavigatorState>();
  static final _shellNavigatorKeys = List.generate(
    5,
    (_) => GlobalKey<NavigatorState>(),
  );

  static GoRouter create({
    String initialLocation = '/sign',
    String issuer = 'https://idp.example/',
    String clientId = 'opencie-client',
  }) => GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: '/login',
        builder: (context, state) => LoginPage(
          issuer: issuer,
          clientId: clientId,
        ),
      ),
      GoRoute(
        path: '/profile',
        builder: (context, state) => const ProfilePage(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return ShellPage(navigationShell: navigationShell);
        },
        branches: [
          StatefulShellBranch(
            navigatorKey: _shellNavigatorKeys[0],
            routes: [
              GoRoute(
                path: '/sign',
                builder: (context, state) => const SignPage(),
              ),
            ],
          ),
           StatefulShellBranch(
             navigatorKey: _shellNavigatorKeys[1],
             routes: [
               GoRoute(
                 path: '/verify',
                 builder: (context, state) => const VerifyPage(),
               ),
             ],
           ),
           StatefulShellBranch(
             navigatorKey: _shellNavigatorKeys[2],
             routes: [
               GoRoute(
                 path: '/timestamp',
                 builder: (context, state) => const TimestampPage(),
               ),
             ],
           ),
           StatefulShellBranch(
             navigatorKey: _shellNavigatorKeys[3],
             routes: [
               GoRoute(
                 path: '/cie',
                 builder: (context, state) => const CieManagementPage(),
               ),
             ],
           ),
           StatefulShellBranch(
             navigatorKey: _shellNavigatorKeys[4],
             routes: [
               GoRoute(
                 path: '/settings',
                 builder: (context, state) => const SettingsPage(),
               ),
             ],
           ),
        ],
      ),
    ],
  );
}


/// Navigation destinations — shared between NavigationRail and NavigationBar.
class AppDestination {
  const AppDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}
