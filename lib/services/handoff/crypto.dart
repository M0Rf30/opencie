// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'pgp_wordlist.dart';

/// X25519 + HKDF-SHA256 + ChaCha20-Poly1305 primitives for the
/// QR-paired desktop ↔ phone signing handoff.
///
/// One side of the channel calls [generateEphemeralKeyPair] to obtain a
/// fresh keypair, exchanges the public key over the QR code, then uses
/// [deriveSession] with the peer's public key to obtain a [HandoffSession]
/// with an AEAD key and a 4-word SAS.
class HandoffCrypto {
  HandoffCrypto._();

  static final _x25519 = Cryptography.instance.x25519();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  /// Generates a fresh ephemeral X25519 keypair. Caller must `dispose()`
  /// the [SimpleKeyPair] when the session ends so private bytes are zeroed.
  static Future<SimpleKeyPair> generateEphemeralKeyPair() {
    return _x25519.newKeyPair();
  }

  /// Derives an AEAD session key + SAS bytes from the peer's public key.
  ///
  /// `myKeyPair` is consumed (private scalar wiped after the ECDH).
  static Future<HandoffSession> deriveSession({
    required SimpleKeyPair myKeyPair,
    required List<int> peerPublicKey,
    required Uint8List handshakeContext,
  }) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: SimplePublicKey(peerPublicKey, type: KeyPairType.x25519),
    );

    // AEAD session key from the shared secret + per-session context.
    final sessionKey = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: handshakeContext,
      info: utf8.encode('opencie-handoff-aead-v1'),
    );

    // SAS bytes derived from the same shared secret with a different label.
    final sasMaterial = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: handshakeContext,
      info: utf8.encode('opencie-handoff-sas-v1'),
    );
    final sasBytes = await sasMaterial.extractBytes();

    // Wipe the raw shared secret; sessionKey + sasMaterial carry forward.
    shared.destroy();

    return HandoffSession._(
      sessionKey: sessionKey,
      sasWords: _bytesToSasWords(sasBytes),
    );
  }

  /// Converts the first 4 bytes of [sasBytes] into 4 PGP biometric words.
  static List<String> _bytesToSasWords(List<int> sasBytes) {
    return [
      pgpWordlistEven[sasBytes[0]],
      pgpWordlistOdd[sasBytes[1]],
      pgpWordlistEven[sasBytes[2]],
      pgpWordlistOdd[sasBytes[3]],
    ];
  }
}

/// A derived handoff session: AEAD key + 4-word SAS.
///
/// Both sides should hold this object only for the duration of the signing
/// flow and call [destroy] on teardown so secret bytes are wiped.
class HandoffSession {
  HandoffSession._({required this.sessionKey, required this.sasWords});

  final SecretKey sessionKey;
  final List<String> sasWords;

  static final _aead = Chacha20.poly1305Aead();

  /// Encrypts [plaintext] under this session's AEAD key.
  ///
  /// A fresh 12-byte nonce is generated per call by the AEAD; the returned
  /// envelope contains nonce, ciphertext, and MAC packed for the wire.
  Future<Uint8List> seal(
    List<int> plaintext, {
    List<int> aad = const [],
  }) async {
    final box = await _aead.encrypt(plaintext, secretKey: sessionKey, aad: aad);
    final nonce = Uint8List.fromList(box.nonce);
    final ct = Uint8List.fromList(box.cipherText);
    final mac = Uint8List.fromList(box.mac.bytes);
    final out = BytesBuilder()
      ..add(nonce)
      ..add(mac)
      ..add(ct);
    return out.toBytes();
  }

  /// Decrypts a wire envelope produced by [seal]. Returns null on tamper.
  Future<Uint8List?> open(
    List<int> envelope, {
    List<int> aad = const [],
  }) async {
    if (envelope.length < 12 + 16) return null;
    final nonce = envelope.sublist(0, 12);
    final mac = envelope.sublist(12, 28);
    final ct = envelope.sublist(28);
    try {
      final pt = await _aead.decrypt(
        SecretBox(ct, nonce: nonce, mac: Mac(mac)),
        secretKey: sessionKey,
        aad: aad,
      );
      return Uint8List.fromList(pt);
    } catch (e) {
      // AEAD decryption/authentication failed — indicates tampering or a corrupt
      // frame, not a transient error. The caller maps null to an error state.
      debugPrint(
        'HandoffSession.open: AEAD decryption failed (possible tamper or corrupt frame): $e',
      );
      return null;
    }
  }

  /// Wipes secret material. Call once when the signing flow ends.
  void destroy() {
    sessionKey.destroy();
  }
}
