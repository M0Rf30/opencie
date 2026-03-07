// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../models/signature_options.dart';

/// Resolves the output path for a signed file based on input path and format.
Future<String> resolveSignedOutputPath(
  String inputPath,
  SignatureFormat format,
) async {
  final inputFile = File(inputPath);
  final inputName = inputFile.uri.pathSegments.last;
  final baseName = format == SignatureFormat.pades
      ? inputName
      : _stripSignatureExtension(inputName);
  final signedName = format == SignatureFormat.pades
      ? _addSignedSuffix(baseName)
      : '$baseName${format.extension}';

  if (Platform.isAndroid) {
    final outputDir = await getApplicationDocumentsDirectory();
    return '${outputDir.path}/$signedName';
  }

  return '${inputFile.parent.path}/$signedName';
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
