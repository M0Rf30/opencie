// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// Mono uppercase caption used everywhere as a "tag" — section headers,
/// progress indicators ("FIRMA · 1 / 4"), and metric labels.
class OcSectionLabel extends StatelessWidget {
  const OcSectionLabel(this.text, {super.key, this.color, this.dense = false});

  final String text;
  final Color? color;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = dense
        ? AppTheme.monoCaption(cs, color: color)
        : AppTheme.monoSection(cs, color: color);
    return Text(text.toUpperCase(), style: style);
  }
}

/// Mono regular text used for paths, hashes, fiscal codes, dates.
class OcMonoText extends StatelessWidget {
  const OcMonoText(
    this.text, {
    super.key,
    this.color,
    this.fontSize = 12,
    this.weight,
    this.maxLines,
    this.overflow,
  });

  final String text;
  final Color? color;
  final double fontSize;
  final FontWeight? weight;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Text(
      text,
      maxLines: maxLines,
      overflow: overflow,
      style: AppTheme.monoBody(cs, color: color).copyWith(
        fontSize: fontSize,
        fontWeight: weight,
      ),
    );
  }
}
