// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';


import '../core/theme/app_theme.dart';

/// Generic action row inside a grouped surface card.
///
/// Used in CIE management (Cambia PIN, Sblocca con PUK, …) and Settings rows.
class OcActionRow extends StatelessWidget {
  const OcActionRow({
    super.key,
    this.leadingIcon,
    this.leading,
    required this.title,
    this.subtitle,
    this.subtitleMono = false,
    this.trailing,
    this.onTap,
    this.tone,
  });

  final IconData? leadingIcon;
  final Widget? leading;
  final String title;
  final String? subtitle;
  final bool subtitleMono;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final iconColor = tone ?? cs.primary;
    const padV = 14.0;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: padV),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (leading != null)
              leading!
            else if (leadingIcon != null) ...[
              Icon(leadingIcon, size: 22, color: iconColor),
            ],
            if (leading != null || leadingIcon != null)
              const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(fontFamily: 'Inter', 
                      color: cs.onSurface,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: subtitleMono
                          ? AppTheme.monoBody(cs, color: cs.onSurfaceVariant)
                              .copyWith(fontSize: 11)
                          : TextStyle(fontFamily: 'Inter', 
                              color: cs.onSurfaceVariant,
                              fontSize: 12,
                            ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 12),
              trailing!,
            ] else if (onTap != null) ...[
              const SizedBox(width: 12),
              Icon(Icons.chevron_right_rounded,
                  color: cs.onSurfaceVariant, size: 22),
            ],
          ],
        ),
      ),
    );
  }
}

/// Wraps multiple action rows in a grouped surface card with hairline dividers.
class OcGroupCard extends StatelessWidget {
  const OcGroupCard({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final separated = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        separated.add(Divider(
          height: 1,
          thickness: 1,
          color: cs.outlineVariant,
          indent: 14,
          endIndent: 14,
        ));
      }
      separated.add(children[i]);
    }
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: separated),
    );
  }
}
