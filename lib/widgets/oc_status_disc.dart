// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../core/theme/color_schemes.dart';

/// Status hero disc — outer translucent ring + inner solid circle with icon.
///
/// Used by Verify (valid/invalid) and Sign Success.
class OcStatusDisc extends StatelessWidget {
  const OcStatusDisc({
    super.key,
    required this.tone,
    required this.icon,
    this.size = 92,
  });

  final OcStatusTone tone;
  final Widget icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = switch (tone) {
      OcStatusTone.valid => ColorSchemes.valid,
      OcStatusTone.invalid => ColorSchemes.invalid,
      OcStatusTone.warning => ColorSchemes.accent,
    };
    final innerSize = size * (64 / 92);

    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.14),
              border: Border.all(
                color: color.withValues(alpha: 0.4),
                width: 1,
              ),
            ),
          ),
          Container(
            width: innerSize,
            height: innerSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.3),
                  blurRadius: 24,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Center(child: icon),
          ),
        ],
      ),
    );
  }
}

enum OcStatusTone { valid, invalid, warning }

/// Halo ring that pulses around the success disc.
class OcDiscHalo extends StatefulWidget {
  const OcDiscHalo({super.key, required this.size, this.color});

  final double size;
  final Color? color;

  @override
  State<OcDiscHalo> createState() => _OcDiscHaloState();
}

class _OcDiscHaloState extends State<OcDiscHalo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? ColorSchemes.valid;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, _) {
        final t = Curves.easeOut.transform(_ctrl.value);
        final scale = 1.0 + t * 0.4;
        final alpha = (1 - t) * 0.45;
        return Transform.scale(
          scale: scale,
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: color.withValues(alpha: alpha),
                width: 2,
              ),
            ),
          ),
        );
      },
    );
  }
}
