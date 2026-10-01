// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Stored form of the app passcode: the passcode itself is never kept.
class PasscodeRecord {
  const PasscodeRecord({
    required this.salt,
    required this.hash,
    required this.iterations,
    this.version = PasscodeHasher.currentVersion,
  });

  final Uint8List salt;
  final Uint8List hash;
  final int iterations;
  final int version;

  Map<String, dynamic> toJson() => {
    'salt': base64Encode(salt),
    'hash': base64Encode(hash),
    'iterations': iterations,
    'version': version,
  };

  /// Returns null for malformed or unsupported records.
  static PasscodeRecord? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final salt = base64Decode(map['salt'] as String);
      final hash = base64Decode(map['hash'] as String);
      final iterations = map['iterations'] as int;
      final version = map['version'] as int;
      if (salt.isEmpty ||
          hash.length != PasscodeHasher.hashLength ||
          iterations < 1 ||
          version != PasscodeHasher.currentVersion) {
        return null;
      }
      return PasscodeRecord(
        salt: salt,
        hash: hash,
        iterations: iterations,
        version: version,
      );
    } catch (_) {
      return null;
    }
  }
}

/// PBKDF2-HMAC-SHA256 passcode derivation with a random per-record salt.
class PasscodeHasher {
  const PasscodeHasher({
    this.iterations = defaultIterations,
    this.useIsolate = true,
    Random? random,
  }) : _random = random;

  static const int currentVersion = 1;
  static const int saltLength = 16;
  static const int hashLength = 32;

  /// OWASP-aligned order of magnitude; ~0.3-1 s on a mid-range phone, run
  /// off the UI isolate.
  static const int defaultIterations = 210000;

  final int iterations;

  /// Derive on a background isolate (disable in tests to stay in the fake
  /// async zone).
  final bool useIsolate;
  final Random? _random;

  Uint8List _newSalt() {
    final rnd = _random ?? Random.secure();
    return Uint8List.fromList(
      List<int>.generate(saltLength, (_) => rnd.nextInt(256)),
    );
  }

  Future<PasscodeRecord> create(String passcode) async {
    final salt = _newSalt();
    final hash = await _derive(passcode, salt, iterations);
    return PasscodeRecord(salt: salt, hash: hash, iterations: iterations);
  }

  Future<bool> verify(PasscodeRecord record, String passcode) async {
    final candidate = await _derive(passcode, record.salt, record.iterations);
    return constantTimeEquals(candidate, record.hash);
  }

  Future<Uint8List> _derive(String passcode, Uint8List salt, int rounds) {
    if (!useIsolate) return _pbkdf2(passcode, salt, rounds);
    return Isolate.run(() => _pbkdf2(passcode, salt, rounds));
  }

  /// Compares without early exit on the first differing byte.
  static bool constantTimeEquals(List<int> a, List<int> b) {
    var diff = a.length ^ b.length;
    final n = min(a.length, b.length);
    for (var i = 0; i < n; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

Future<Uint8List> _pbkdf2(String passcode, Uint8List salt, int rounds) async {
  final algorithm = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: rounds,
    bits: PasscodeHasher.hashLength * 8,
  );
  final key = await algorithm.deriveKeyFromPassword(
    password: passcode,
    nonce: salt,
  );
  return Uint8List.fromList(await key.extractBytes());
}
