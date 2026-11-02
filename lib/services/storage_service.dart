// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

class StorageService {
  static const _channel = MethodChannel('io.github.m0rf30.opencie/storage');

  /// Hosts `scanMediaFile` on the Android side.
  static const _nfcChannel = MethodChannel('io.github.m0rf30.opencie/nfc');

  static Future<String?> getDefaultOutputDir() async {
    if (!Platform.isAndroid) return null;
    return _channel.invokeMethod<String>('getDefaultOutputDir');
  }

  static Future<String?> pickOutputFolder() async {
    if (!Platform.isAndroid) return null;
    return _channel.invokeMethod<String>('pickOutputFolder');
  }

  static Future<String?> writeFileToTreeUri({
    required String treeUri,
    required String sourcePath,
    required String fileName,
    required String mimeType,
  }) async {
    if (!Platform.isAndroid) return null;
    return _channel.invokeMethod<String>('writeFileToTreeUri', {
      'treeUri': treeUri,
      'sourcePath': sourcePath,
      'fileName': fileName,
      'mimeType': mimeType,
    });
  }

  /// Android only: copies a signed file from app-private storage into the
  /// SAF folder [treeUri] (when the user configured one) and registers it
  /// with the media scanner. Best-effort: on failure the file stays in
  /// app-private storage, reachable from the result UI.
  static Future<void> publishSignedFile(String path, {String? treeUri}) async {
    if (!Platform.isAndroid) return;
    if (treeUri != null) {
      try {
        await writeFileToTreeUri(
          treeUri: treeUri,
          sourcePath: path,
          fileName: p.basename(path),
          mimeType: mimeTypeFor(path),
        );
      } catch (e) {
        debugPrint('StorageService.publishSignedFile: SAF copy failed ($e)');
      }
    }
    try {
      await _nfcChannel.invokeMethod<bool>('scanMediaFile', {'path': path});
    } catch (e) {
      debugPrint('StorageService.publishSignedFile: media scan failed ($e)');
    }
  }

  /// MIME type of a document or signature file, by extension.
  static String mimeTypeFor(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.pdf':
        return 'application/pdf';
      case '.p7m':
        return 'application/pkcs7-mime';
      case '.xml':
        return 'application/xml';
      default:
        return 'application/octet-stream';
    }
  }

  static Future<bool> canWriteToSafTree(String treeUri) async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('canWriteToSafTree', {
          'treeUri': treeUri,
        }) ??
        false;
  }
}
