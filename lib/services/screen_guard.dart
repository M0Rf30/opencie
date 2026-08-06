// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:flutter/services.dart';

/// Blocks screenshots and screen recording while a sensitive screen (e.g.
/// PIN entry) is on screen, by toggling Android's
/// `WindowManager.LayoutParams.FLAG_SECURE` via a native MethodChannel.
///
/// No-op on every non-Android platform (desktop has no equivalent OS-level
/// capture block). Calls are reference-counted so nested protected surfaces
/// (e.g. a PIN dialog shown above an already-protected route) don't clear
/// the flag until the outermost caller unprotects.
class ScreenGuard {
  ScreenGuard._();

  static const MethodChannel _channel = MethodChannel(
    'io.github.m0rf30.opencie/screen',
  );

  static int _refCount = 0;

  /// Blocks screenshots/recording while sensitive content is on screen.
  static Future<void> protect() async {
    if (!Platform.isAndroid) {
      return;
    }
    _refCount++;
    if (_refCount != 1) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('protect');
    } on MissingPluginException {
      // Older host APK without the channel — silently skip.
    } on PlatformException {
      // Native side failed to toggle the flag — never crash the caller.
    }
  }

  /// Restores normal capture behaviour.
  static Future<void> unprotect() async {
    if (!Platform.isAndroid) {
      return;
    }
    if (_refCount == 0) {
      return;
    }
    _refCount--;
    if (_refCount != 0) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('unprotect');
    } on MissingPluginException {
      // Older host APK without the channel — silently skip.
    } on PlatformException {
      // Native side failed to clear the flag — never crash the caller.
    }
  }
}
