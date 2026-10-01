// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../core/theme/color_schemes.dart';

/// Filled primary action button with a vertical gradient and glow shadow.
class OcGradientButton extends StatelessWidget {
  const OcGradientButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.expand = true,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final disabled = onPressed == null;
    const padV = 15.0;
    final fg = disabled ? cs.onSurface.withValues(alpha: 0.38) : cs.onPrimary;

    final child = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        mouseCursor: disabled ? SystemMouseCursors.forbidden : null,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: disabled ? cs.onSurface.withValues(alpha: 0.12) : null,
            border: disabled
                ? Border.all(color: cs.outline.withValues(alpha: 0.5))
                : null,
            gradient: disabled
                ? null
                : LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: cs.ctaGradient,
                  ),
            boxShadow: disabled
                ? null
                : [
                    BoxShadow(
                      color: cs.primary.withValues(alpha: 0.35),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
          ),
          padding: EdgeInsets.symmetric(horizontal: 18, vertical: padV),
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 20, color: fg),
                const SizedBox(width: 10),
              ],
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    color: fg,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    letterSpacing: 0.1,
                  ),
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return expand ? SizedBox(width: double.infinity, child: child) : child;
  }
}
