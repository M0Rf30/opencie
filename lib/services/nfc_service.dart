// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:flutter/services.dart';

/// NFC service for CIE card communication on Android.
///
/// Uses a platform MethodChannel to communicate with [MainActivity], which
/// manages NFC reader mode and forwards tag events to [CieNfcBridge] → JNI.
///
/// On desktop platforms, CIE is accessed via PC/SC (handled by the native
/// library directly), so this service is Android-only.
class NfcService {
  NfcService._() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static final instance = NfcService._();

  static const _channel = MethodChannel('io.github.m0rf30.opencie/nfc');

  /// Callback invoked when an NFC tag (CIE card) is discovered.
  /// The [success] parameter indicates whether the tag was connected
  /// and passed to the native library successfully.
  VoidCallback? _onTagDiscovered;
  VoidCallback? _onTagFailed;

  /// Handle method calls FROM the platform side (tag discovery events).
  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onTagDiscovered') {
      final args = call.arguments as Map?;
      final success = args?['success'] as bool? ?? false;
      if (success) {
        _onTagDiscovered?.call();
      } else {
        _onTagFailed?.call();
      }
    }
  }

  /// Whether NFC is available and enabled on this device.
  Future<bool> get isAvailable async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _channel.invokeMethod<bool>('isNfcAvailable');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Start listening for NFC tags (CIE cards).
  ///
  /// When a tag is detected, [onTagDiscovered] is called. The native side
  /// handles connecting the IsoDep and passing it to the PKCS#11 library
  /// via JNI — the Dart side just needs to know the tag is ready.
  Future<bool> startSession({
    VoidCallback? onTagDiscovered,
    VoidCallback? onTagFailed,
  }) async {
    if (!Platform.isAndroid) return false;

    _onTagDiscovered = onTagDiscovered;
    _onTagFailed = onTagFailed;

    try {
      final result = await _channel.invokeMethod<bool>('startNfcSession');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Stop the current NFC session and clear the native tag reference.
  Future<void> stopSession() async {
    if (!Platform.isAndroid) return;

    _onTagDiscovered = null;
    _onTagFailed = null;

    try {
      await _channel.invokeMethod<void>('stopNfcSession');
    } on PlatformException {
      // Best-effort cleanup.
    }
  }

  /// Whether a CIE card is currently connected via NFC.
  Future<bool> get isTagConnected async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _channel.invokeMethod<bool>('isTagConnected');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Clear the native tag reference (call when operation completes).
  Future<void> clearTag() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('clearTag');
    } on PlatformException {
      // Best-effort cleanup.
    }
  }

  /// Open the Android NFC settings screen so the user can enable NFC.
  Future<void> openNfcSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('openNfcSettings');
    } on PlatformException {
      // Best-effort.
    }
  }
}
