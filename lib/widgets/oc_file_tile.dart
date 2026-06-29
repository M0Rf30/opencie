// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

/// Document file-type tile (mini paper) — used in headers and rows.
///
/// Renders a small white "page" with a colored 3-letter ext label, e.g. PDF,
/// P7M, XML.
class OcFileTile extends StatelessWidget {
  const OcFileTile({
    super.key,
    required this.extension,
    this.width = 38,
    this.height = 46,
  });

  final String extension;
  final double width;
  final double height;

  static Color colorFor(String ext) {
    switch (ext.toLowerCase()) {
      case 'pdf':
        return const Color(0xFFE53935);
      case 'p7m':
      case 'p7s':
        return const Color(0xFF1E88E5);
      case 'xml':
        return const Color(0xFFFB8C00);
      case 'doc':
      case 'docx':
        return const Color(0xFF42A5F5);
      case 'xls':
      case 'xlsx':
        return const Color(0xFF43A047);
      default:
        return const Color(0xFF1A4B8E);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ext = extension.toUpperCase();
    final color = colorFor(ext);

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white, Color(0xFFE0E5EC)],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Text(
            ext.length > 4 ? ext.substring(0, 4) : ext,
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 9,
              letterSpacing: 0.4,
            ),
          ),
        ),
      ),
    );
  }
}
