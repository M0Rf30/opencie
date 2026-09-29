// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/signature_options.dart';

/// Resolves the output path for a signed file based on input path and format.
///
/// Uses `package:path` throughout so the returned path uses the correct
/// separator on every platform (notably Windows, where `/` is not a valid
/// path separator).
Future<String> resolveSignedOutputPath(
  String inputPath,
  SignatureFormat format,
) async {
  final inputName = p.basename(inputPath);
  final baseName = format == SignatureFormat.pades
      ? inputName
      : _stripSignatureExtension(inputName);
  final signedName = format == SignatureFormat.pades
      ? _addSignedSuffix(baseName)
      : '$baseName${format.extension}';

  if (Platform.isAndroid) {
    // App-private documents directory; SAF export (if configured) happens
    // as a separate copy step after signing, so this only needs to be a
    // writable app-local path.
    final outputDir = await getApplicationDocumentsDirectory();
    return p.join(outputDir.path, signedName);
  }

  return p.join(p.dirname(inputPath), signedName);
}

String _addSignedSuffix(String name) {
  final lastDot = name.lastIndexOf('.');
  if (lastDot < 0) return '${name}_signed';
  final base = name.substring(0, lastDot);
  final ext = name.substring(lastDot);
  return '${base}_signed$ext';
}

String _stripSignatureExtension(String name) {
  const extensions = ['.p7m', '.xml'];
  for (final ext in extensions) {
    if (name.toLowerCase().endsWith(ext)) {
      return name.substring(0, name.length - ext.length);
    }
  }
  return name;
}
