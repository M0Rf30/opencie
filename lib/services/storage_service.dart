// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'package:flutter/services.dart';

class StorageService {
  static const _channel = MethodChannel('io.github.m0rf30.opencie/storage');

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

  static Future<bool> canWriteToSafTree(String treeUri) async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('canWriteToSafTree', {
          'treeUri': treeUri,
        }) ??
        false;
  }
}
