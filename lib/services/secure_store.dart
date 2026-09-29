// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Thrown when a secure-storage operation fails at the platform layer
/// (locked keyring, missing Secret Service, corrupted entry, ...).
class SecureStoreException implements Exception {
  SecureStoreException(this.message, this.cause);
  final String message;
  final Object cause;
  @override
  String toString() => 'SecureStoreException: $message ($cause)';
}

/// Encrypted key-value storage backed by the OS keystore — Android Keystore,
/// the Secret Service on Linux (via libsecret), Keychain on macOS/iOS, ...
///
/// A platform failure (locked keyring, no Secret Service running, a
/// corrupted entry) must never crash the app or wedge login. Every
/// operation surfaces a [SecureStoreException] instead of failing silently
/// or pretending the store is empty — callers are expected to catch it and
/// distinguish "the store is unavailable" from "there is nothing stored":
/// a `null` return from [read] with no exception means the key is genuinely
/// absent, while a thrown [SecureStoreException] means the store couldn't
/// be reached at all and its content is unknown.
class SecureStore {
  SecureStore._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  static Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } on PlatformException catch (e) {
      throw SecureStoreException(
        'Failed to read "$key" from secure storage',
        e,
      );
    }
  }

  static Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } on PlatformException catch (e) {
      throw SecureStoreException('Failed to write "$key" to secure storage', e);
    }
  }

  static Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } on PlatformException catch (e) {
      throw SecureStoreException(
        'Failed to delete "$key" from secure storage',
        e,
      );
    }
  }
}
