// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/constants/app_constants.dart';
import '../core/l10n/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../widgets/oc_mark.dart';
import 'app_router.dart';

/// Adaptive shell — NavigationRail desktop / NavigationBar mobile.
class ShellPage extends StatelessWidget {
  const ShellPage({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  List<AppDestination> _destinations(AppLocalizations l10n) => [
    AppDestination(
      label: l10n.navSign,
      icon: Icons.draw_outlined,
      selectedIcon: Icons.draw,
    ),
    AppDestination(
      label: l10n.navVerify,
      icon: Icons.verified_user_outlined,
      selectedIcon: Icons.verified_user,
    ),
    AppDestination(
      label: l10n.navTimestamp,
      icon: Icons.schedule_outlined,
      selectedIcon: Icons.schedule,
    ),
    AppDestination(
      label: l10n.navCieManagement,
      icon: Icons.credit_card_outlined,
      selectedIcon: Icons.credit_card,
    ),
    AppDestination(
      label: l10n.navSettings,
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
    ),
  ];

  void _onDestinationSelected(int index) {
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isExpanded = width >= AppConstants.expandedBreakpoint;
    final isMedium = width >= AppConstants.mediumBreakpoint;

    final l10n = AppLocalizations.of(context);
    final destinations = _destinations(l10n);
    final cs = Theme.of(context).colorScheme;

    // Mobile: bottom navigation bar
    if (!isMedium) {
      return Scaffold(
        body: SafeArea(bottom: false, child: navigationShell),
        bottomNavigationBar: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: cs.outlineVariant),
            ),
          ),
          child: NavigationBar(
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected: _onDestinationSelected,
            labelBehavior:
                NavigationDestinationLabelBehavior.alwaysShow,
            destinations: destinations.map((d) {
              return NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selectedIcon),
                label: d.label,
              );
            }).toList(),
          ),
        ),
      );
    }

    // Desktop / tablet: navigation rail
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            extended: isExpanded,
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected: _onDestinationSelected,
            minWidth: 80,
            minExtendedWidth: 220,
            leading: Padding(
              padding: EdgeInsets.fromLTRB(
                isExpanded ? 18 : 0,
                20,
                isExpanded ? 18 : 0,
                12,
              ),
              child: isExpanded
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const OcMark(size: 30),
                        const SizedBox(width: 12),
                        Text(
                          'OpenCIE',
                          style: AppTheme.headlineBold(cs).copyWith(
                            fontSize: 18,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ],
                    )
                  : const OcMark(size: 30),
            ),
            destinations: destinations.map((d) {
              return NavigationRailDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selectedIcon),
                label: Text(d.label),
              );
            }).toList(),
          ),
          VerticalDivider(
            thickness: 1,
            width: 1,
            color: cs.outlineVariant,
          ),
          Expanded(child: navigationShell),
        ],
      ),
    );
  }
}
