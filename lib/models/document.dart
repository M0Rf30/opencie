// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:path/path.dart' as p;

/// Represents a document loaded for signing, verification, etc.
class Document {
  Document({required this.path})
    : name = p.basename(path),
      extension = p.extension(path).toLowerCase().replaceFirst('.', ''),
      size = File(path).existsSync() ? File(path).lengthSync() : 0;

  final String path;
  final String name;
  final String extension;
  final int size;

  bool get isPdf => extension == 'pdf';
  bool get isP7m => extension == 'p7m';
  bool get isP7e => extension == 'p7e';
  bool get isXml => extension == 'xml';

  /// Human-readable file size.
  String get formattedSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Document && path == other.path;

  @override
  int get hashCode => path.hashCode;
}
