// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:opencie/services/handoff/crypto.dart';
import 'package:opencie/services/handoff/pgp_wordlist.dart';

/// Derives a matching pair of [HandoffSession]s by performing X25519 ECDH
/// between two fresh ephemeral key pairs under the same [handshakeContext].
Future<(HandoffSession, HandoffSession)> _matchingSessions({
  Uint8List? handshakeContext,
}) async {
  final ctx =
      handshakeContext ?? Uint8List.fromList(utf8.encode('test-context'));
  final kpA = await HandoffCrypto.generateEphemeralKeyPair();
  final kpB = await HandoffCrypto.generateEphemeralKeyPair();
  final SimplePublicKey pubA = await kpA.extractPublicKey();
  final SimplePublicKey pubB = await kpB.extractPublicKey();
  final sessionA = await HandoffCrypto.deriveSession(
    myKeyPair: kpA,
    peerPublicKey: pubB.bytes,
    handshakeContext: ctx,
  );
  final sessionB = await HandoffCrypto.deriveSession(
    myKeyPair: kpB,
    peerPublicKey: pubA.bytes,
    handshakeContext: ctx,
  );
  return (sessionA, sessionB);
}

void main() {
  group('HandoffCrypto / HandoffSession', () {
    test('seal->open round-trip returns original plaintext', () async {
      final (sessionA, sessionB) = await _matchingSessions();
      final plaintext = utf8.encode('Hello, CIE!');
      final envelope = await sessionA.seal(plaintext);
      final recovered = await sessionB.open(envelope);
      expect(recovered, equals(Uint8List.fromList(plaintext)));
      sessionA.destroy();
      sessionB.destroy();
    });

    test('seal->open with non-empty AAD round-trips correctly', () async {
      final (sessionA, sessionB) = await _matchingSessions();
      final plaintext = utf8.encode('signed payload');
      final aad = utf8.encode('desktop-to-phone');
      final envelope = await sessionA.seal(plaintext, aad: aad);
      final recovered = await sessionB.open(envelope, aad: aad);
      expect(recovered, equals(Uint8List.fromList(plaintext)));
      sessionA.destroy();
      sessionB.destroy();
    });

    test('opening a tampered ciphertext (flipped byte) returns null', () async {
      final (sessionA, sessionB) = await _matchingSessions();
      final envelope = await sessionA.seal(utf8.encode('tamper target'));
      // Wire layout: nonce(12) | mac(16) | ciphertext; flip first CT byte.
      expect(envelope.length, greaterThan(28));
      final tampered = Uint8List.fromList(envelope);
      tampered[28] ^= 0xFF;
      final result = await sessionB.open(tampered);
      expect(result, isNull);
      sessionA.destroy();
      sessionB.destroy();
    });

    test('opening with wrong AAD returns null', () async {
      final (sessionA, sessionB) = await _matchingSessions();
      final envelope = await sessionA.seal(
        utf8.encode('aad-bound message'),
        aad: utf8.encode('correct-aad'),
      );
      final result = await sessionB.open(
        envelope,
        aad: utf8.encode('wrong-aad'),
      );
      expect(result, isNull);
      sessionA.destroy();
      sessionB.destroy();
    });

    test('opening with missing AAD when seal used AAD returns null', () async {
      final (sessionA, sessionB) = await _matchingSessions();
      final envelope = await sessionA.seal(
        utf8.encode('aad required'),
        aad: utf8.encode('some-aad'),
      );
      final result = await sessionB.open(envelope); // no aad
      expect(result, isNull);
      sessionA.destroy();
      sessionB.destroy();
    });

    test(
      'envelope shorter than 28 bytes returns null without throwing',
      () async {
        final (sessionA, _) = await _matchingSessions();
        // nonce(12) + mac(16) = 28 bytes minimum; 10 bytes is too short.
        final result = await sessionA.open(Uint8List(10));
        expect(result, isNull);
        sessionA.destroy();
      },
    );

    test('SAS words are identical on both paired sessions', () async {
      final ctx = Uint8List.fromList([0x00, 0x01, 0x02, 0x03]);
      final (sessionA, sessionB) = await _matchingSessions(
        handshakeContext: ctx,
      );
      expect(sessionA.sasWords, equals(sessionB.sasWords));
      sessionA.destroy();
      sessionB.destroy();
    });

    test('SAS words list has exactly 4 entries from PGP word lists', () async {
      final (session, _) = await _matchingSessions();
      expect(session.sasWords, hasLength(4));
      // Even-position (index 0, 2) from pgpWordlistEven; odd from pgpWordlistOdd.
      expect(pgpWordlistEven, contains(session.sasWords[0]));
      expect(pgpWordlistOdd, contains(session.sasWords[1]));
      expect(pgpWordlistEven, contains(session.sasWords[2]));
      expect(pgpWordlistOdd, contains(session.sasWords[3]));
      session.destroy();
    });

    test(
      'SAS words differ for distinct ECDH pairs (distinct shared secrets)',
      () async {
        final ctx = Uint8List.fromList([0xAA, 0xBB]);
        final (s1, _) = await _matchingSessions(handshakeContext: ctx);
        final (s2, _) = await _matchingSessions(handshakeContext: ctx);
        // Different ECDH key pairs → different shared secrets → different SAS.
        // P(collision) ≈ 2^-128; false positives are astronomically improbable.
        expect(s1.sasWords, isNot(equals(s2.sasWords)));
        s1.destroy();
        s2.destroy();
      },
    );

    test(
      'SAS words differ for two independent ECDH pairings (same context)',
      () async {
        // Derive two INDEPENDENT sessions under the same handshake context.
        // Different X25519 shared secrets → different HKDF outputs → different SAS.
        // Same context isolates the effect of the ECDH key material alone.
        final ctx = Uint8List.fromList([0x11, 0x22, 0x33]);
        final kpA1 = await HandoffCrypto.generateEphemeralKeyPair();
        final kpB1 = await HandoffCrypto.generateEphemeralKeyPair();
        final SimplePublicKey pub1 = await kpB1.extractPublicKey();
        final kpA2 = await HandoffCrypto.generateEphemeralKeyPair();
        final kpB2 = await HandoffCrypto.generateEphemeralKeyPair();
        final SimplePublicKey pub2 = await kpB2.extractPublicKey();
        final s1 = await HandoffCrypto.deriveSession(
          myKeyPair: kpA1,
          peerPublicKey: pub1.bytes,
          handshakeContext: ctx,
        );
        final s2 = await HandoffCrypto.deriveSession(
          myKeyPair: kpA2,
          peerPublicKey: pub2.bytes,
          handshakeContext: ctx,
        );
        // P(collision) ≈ 2^-256; false positive is not a realistic concern.
        expect(s1.sasWords, isNot(equals(s2.sasWords)));
        s1.destroy();
        s2.destroy();
      },
    );

    test('destroy() completes without throwing', () async {
      final (session, _) = await _matchingSessions();
      expect(session.destroy, returnsNormally);
    });
  });
}
