// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/signature_options.dart';

/// Resolves the output path for a signed file based on input path and format.
///
/// On desktop the file goes to [destinationFolder] when set, otherwise next
/// to the input. On Android it always goes to app-private storage; the SAF
/// export to the configured folder is a separate copy step after signing.
///
/// Uses `package:path` throughout so the returned path uses the correct
/// separator on every platform (notably Windows, where `/` is not a valid
/// path separator).
Future<String> resolveSignedOutputPath(
  String inputPath,
  SignatureFormat format, {
  String? destinationFolder,
}) async {
  final outputDir = Platform.isAndroid
      ? (await getApplicationDocumentsDirectory()).path
      : destinationFolder ?? p.dirname(inputPath);
  final outputPath = p.join(outputDir, signedFileName(inputPath, format));

  // Re-signing `a.p7m` as CAdES (or `a.xml` as XAdES) maps back to the
  // input's own name; writing there would destroy the input mid-read.
  return p.equals(outputPath, inputPath)
      ? uniqueFilePath(outputPath)
      : outputPath;
}

/// [desired] if no file exists there, otherwise the first free
/// `name (1).ext`, `name (2).ext`, … in the same folder.
String uniqueFilePath(String desired) {
  if (!File(desired).existsSync()) return desired;
  final dir = p.dirname(desired);
  final ext = p.extension(desired);
  final baseNoExt = p.basenameWithoutExtension(desired);
  for (var i = 1; ; i++) {
    final candidate = p.join(dir, '$baseNoExt ($i)$ext');
    if (!File(candidate).existsSync()) return candidate;
  }
}

/// File name of the signed counterpart of [inputPath]: `name_signed.pdf`
/// for PAdES, `name<ext>` with the format extension otherwise (an existing
/// signature extension is replaced, not stacked).
String signedFileName(String inputPath, SignatureFormat format) {
  final inputName = p.basename(inputPath);
  if (format == SignatureFormat.pades) return _addSignedSuffix(inputName);
  return '${_stripSignatureExtension(inputName)}${format.extension}';
}

/// True when [path] lives in the xdg-document-portal FUSE mount, i.e. a file
/// a sandboxed (Flatpak) app received through the file chooser portal.
///
/// The portal exports single files: other files created next to them stay
/// inside the portal and never reach the host folder, so a signed file must
/// not be written "next to" such an input.
bool isDocumentPortalPath(String path, {String? runtimeDir}) {
  final normalized = p.posix.normalize(path);
  final xdgRuntime = runtimeDir ?? Platform.environment['XDG_RUNTIME_DIR'];
  if (xdgRuntime != null &&
      xdgRuntime.isNotEmpty &&
      p.posix.isWithin(p.posix.join(xdgRuntime, 'doc'), normalized)) {
    return true;
  }
  return _portalMount.hasMatch(normalized);
}

final _portalMount = RegExp(r'^/run/(user/\d+|flatpak)/doc/');

String _addSignedSuffix(String name) {
  final lastDot = name.lastIndexOf('.');
  if (lastDot < 0) return '${name}_signed';
  final base = name.substring(0, lastDot);
  final ext = name.substring(lastDot);
  return '${base}_signed$ext';
}

const _signatureExtensions = ['.p7m', '.p7s', '.xml'];

String _stripSignatureExtension(String name) {
  final lower = name.toLowerCase();
  for (final ext in _signatureExtensions) {
    if (lower.endsWith(ext)) {
      return name.substring(0, name.length - ext.length);
    }
  }
  return name;
}
