// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';


import '../core/theme/app_theme.dart';

/// Big tappable radio card — used in format selector and TSA picker.
class OcRadioCard extends StatelessWidget {
  const OcRadioCard({
    super.key,
    required this.title,
    required this.selected,
    this.subtitle,
    this.body,
    this.badge,
    this.disabled = false,
    this.disabledNote,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final String? body;
  final String? badge;
  final bool selected;
  final bool disabled;
  final String? disabledNote;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final borderColor = selected ? cs.primary : cs.outlineVariant;
    final bg = selected
        ? cs.primary.withValues(alpha: 0.08)
        : cs.surfaceContainer;

    return Opacity(
      opacity: disabled ? 0.55 : 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: disabled ? null : onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: borderColor,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Radio(selected: selected, color: cs.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              style: TextStyle(fontFamily: 'Inter', 
                                color: cs.onSurface,
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                              ),
                            ),
                          ),
                          if (badge != null) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: cs.primary,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                badge!,
                                style: TextStyle(fontFamily: 'Inter', 
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 9,
                                  letterSpacing: 0.4,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle!,
                          style: AppTheme.monoBody(cs,
                              color: cs.onSurfaceVariant)
                              .copyWith(fontSize: 11),
                        ),
                      ],
                      if (body != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          body!,
                          style: TextStyle(fontFamily: 'Inter', 
                              color: cs.onSurfaceVariant, fontSize: 12),
                        ),
                      ],
                      if (disabled && disabledNote != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          '· $disabledNote',
                          style: AppTheme.monoBody(cs, color: cs.error)
                              .copyWith(fontSize: 11),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Radio extends StatelessWidget {
  const _Radio({required this.selected, required this.color});
  final bool selected;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? color : cs.outlineVariant,
          width: 2,
        ),
      ),
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: selected ? 8 : 0,
          height: selected ? 8 : 0,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
          ),
        ),
      ),
    );
  }
}
