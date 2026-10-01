// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// Biometric unlock abstraction (fakeable in tests).
abstract class BiometricAuth {
  /// Whether biometric unlock can be offered on this device right now.
  Future<bool> isAvailable();

  /// Prompts the user. Returns false on cancel, failure or any error.
  Future<bool> authenticate(String reason);
}

/// local_auth backed implementation. Linux has no local_auth support, so
/// biometrics are never offered there.
class LocalBiometricAuth implements BiometricAuth {
  LocalBiometricAuth();

  final LocalAuthentication _auth = LocalAuthentication();

  static bool get _platformSupported =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isWindows;

  @override
  Future<bool> isAvailable() async {
    if (!_platformSupported) return false;
    try {
      if (!await _auth.isDeviceSupported()) return false;
      // Windows Hello does not enumerate biometric types; device support
      // is the signal there.
      if (Platform.isWindows) return true;
      if (!await _auth.canCheckBiometrics) return false;
      return (await _auth.getAvailableBiometrics()).isNotEmpty;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    if (!_platformSupported) return false;
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        // Biometrics only (no device PIN/pattern fallback) except on
        // Windows, where Hello is the only available mechanism.
        biometricOnly: !Platform.isWindows,
      );
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
