// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../core/theme/color_schemes.dart';

/// Concentric pulsing rings used by the NFC overlay — expanding outward,
/// fading to transparent as they grow.
class OcPulseRings extends StatefulWidget {
  const OcPulseRings({
    super.key,
    this.size = 220,
    this.ringCount = 4,
    this.color,
  });

  final double size;
  final int ringCount;
  final Color? color;

  @override
  State<OcPulseRings> createState() => _OcPulseRingsState();
}

class _OcPulseRingsState extends State<OcPulseRings>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? ColorSchemes.primary;
    return SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, _) {
          return Stack(
            alignment: Alignment.center,
            children: List.generate(widget.ringCount, (i) {
              final delayed = (_ctrl.value + i / widget.ringCount) % 1.0;
              final t = Curves.easeOut.transform(delayed);
              final scale = 0.4 + t * 0.6;
              final alpha = (1.0 - t) * 0.55;
              return Transform.scale(
                scale: scale,
                child: Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: color.withValues(alpha: alpha),
                      width: 1.5,
                    ),
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

/// Glowing chip with subtle rocking motion — center of the NFC overlay.
class OcGlowChip extends StatefulWidget {
  const OcGlowChip({super.key, this.size = 100, required this.icon});

  final double size;
  final IconData icon;

  @override
  State<OcGlowChip> createState() => _OcGlowChipState();
}

class _OcGlowChipState extends State<OcGlowChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, _) {
        final t = Curves.easeInOut.transform(_ctrl.value);
        final angle = (t - 0.5) * 0.052; // ±~1.5°
        final glow = 0.3 + t * 0.35;
        return Transform.rotate(
          angle: angle,
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: ColorSchemes.chipGradient,
              ),
              boxShadow: [
                BoxShadow(
                  color: ColorSchemes.primary.withValues(alpha: glow),
                  blurRadius: 32 + t * 12,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Icon(
              widget.icon,
              color: Colors.white,
              size: widget.size * 0.48,
            ),
          ),
        );
      },
    );
  }
}
