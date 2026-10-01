// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// Shared page layout metrics.
class OcPageMetrics {
  OcPageMetrics._();

  /// Widest content column; wider windows get centred whitespace.
  static const double maxWidth = 1100;

  /// Width above which the desktop padding applies.
  static const double desktopBreakpoint = 600;

  /// Horizontal page padding: 20 on phones, 28 on desktop.
  static double paddingFor(double width) =>
      width >= desktopBreakpoint ? 28 : 20;

  /// Left/right inset that centres a [maxWidth] column inside [width] while
  /// keeping at least the regular page padding.
  static double sideInset(
    double width, [
    double maxWidth = OcPageMetrics.maxWidth,
  ]) => math.max(paddingFor(width), (width - maxWidth) / 2);
}

/// Centred, width-limited page body with the shared horizontal padding.
///
/// Use the default constructor inside a box scroll view and [OcPageBody.sliver]
/// inside a `CustomScrollView`.
class OcPageBody extends StatelessWidget {
  const OcPageBody({
    super.key,
    required this.child,
    this.maxWidth = OcPageMetrics.maxWidth,
  }) : sliver = false;

  const OcPageBody.sliver({
    super.key,
    required this.child,
    this.maxWidth = OcPageMetrics.maxWidth,
  }) : sliver = true;

  /// Box widget, or a sliver when constructed with [OcPageBody.sliver].
  final Widget child;
  final double maxWidth;
  final bool sliver;

  @override
  Widget build(BuildContext context) {
    if (sliver) {
      return SliverLayoutBuilder(
        builder: (context, constraints) {
          final side = OcPageMetrics.sideInset(
            constraints.crossAxisExtent,
            maxWidth,
          );
          return SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: side),
            sliver: child,
          );
        },
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = OcPageMetrics.sideInset(constraints.maxWidth, maxWidth);
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: side),
          child: child,
        );
      },
    );
  }
}

/// Page title block: display title, subtitle and trailing action buttons.
class OcPageHeader extends StatelessWidget {
  const OcPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final top = OcPageMetrics.paddingFor(MediaQuery.sizeOf(context).width);
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: AppTheme.displayBold(cs),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    subtitle!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}
