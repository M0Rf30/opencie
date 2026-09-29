// SPDX-License-Identifier: GPL-3.0-or-later
//
// Session-level protocol tests (OC-18): both sessions are wired together
// through an in-memory [FakeHandoffTransport] pair (no real WebRTC/QR/PIN
// UI involved), exercising the actual desktop<->phone state machines and
// wire messages. This is the missing coverage identified as the root cause
// that let OC-01/15/16/17 ship undetected.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:opencie/ffi/models/verify_info.dart';
import 'package:opencie/services/handoff/crypto.dart';
import 'package:opencie/services/handoff/descriptor.dart';
import 'package:opencie/services/handoff/desktop_handoff_session.dart';
import 'package:opencie/services/handoff/messages.dart';
import 'package:opencie/services/handoff/phone_handoff_session.dart';

import 'fake_transport.dart';

/// Derives a matching pair of [HandoffSession]s the same way the real
/// QR/SDP handshake would, without any WebRTC/QR involved.
Future<(HandoffSession, HandoffSession)> _pairedCryptoSessions() async {
  final ctx = Uint8List.fromList(utf8.encode('session-test-context'));
  final kpA = await HandoffCrypto.generateEphemeralKeyPair();
  final kpB = await HandoffCrypto.generateEphemeralKeyPair();
  final pubA = await kpA.extractPublicKey();
  final pubB = await kpB.extractPublicKey();
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

/// A signature verifier that always reports one fully valid signer —
/// stands in for the real native `cie_verify` call, which needs a real
/// PKCS#11 library/card and isn't available in a plain `flutter_test` run.
Future<List<VerifyInfo>> _alwaysValidVerify({required String inputPath}) async {
  return const [
    VerifyInfo(
      name: 'Synthetic',
      surname: 'Signer',
      commonName: 'Synthetic Test Signer',
      signingTime: '',
      certificateAuthority: '',
      certRevocationStatus: 0,
      isSignatureValid: true,
      isCertificateValid: true,
    ),
  ];
}

/// Fakes `path_provider` so [DesktopHandoffSession]'s temp-file
/// verification step (`getTemporaryDirectory()`) works under plain
/// `flutter_test` without a real platform channel.
class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getTemporaryPath() async => Directory.systemTemp.path;
}

String _tempPath(String name) =>
    '${Directory.systemTemp.path}/handoff_session_test_'
    '${DateTime.now().microsecondsSinceEpoch}_$name';

void main() {
  setUpAll(() {
    PathProviderPlatform.instance = _FakePathProviderPlatform();
  });

  group('Handoff session protocol (fake transport)', () {
    test(
      'happy path: bytes signed by the phone are exactly the bytes the desktop sent, '
      'and the desktop only writes them after a fake-valid verification',
      () async {
        final (sessionA, sessionB) = await _pairedCryptoSessions();
        final (transportA, transportB) = FakeHandoffTransport.pair();

        final srcBytes = Uint8List.fromList(
          utf8.encode('synthetic document body ' * 200),
        );
        final srcPath = _tempPath('src.txt');
        await File(srcPath).writeAsBytes(srcBytes);
        addTearDown(() async {
          try {
            await File(srcPath).delete();
          } catch (_) {}
        });

        final desktop = DesktopHandoffSession.forTesting(
          filePath: srcPath,
          transport: transportA,
          cryptoSession: sessionA,
          verify: _alwaysValidVerify,
        );
        final phone = PhoneHandoffSession.forTesting(
          transport: transportB,
          cryptoSession: sessionB,
        );
        addTearDown(desktop.dispose);
        addTearDown(phone.dispose);

        await desktop.sendDocument();
        await phone.states
            .firstWhere((s) => s == PhoneHandoffState.documentReady)
            .timeout(const Duration(seconds: 5));

        // The phone must sign exactly what it received, never a digest.
        expect(phone.documentBytes, equals(srcBytes));

        await phone.markPinOk();
        await desktop.states
            .firstWhere((s) => s == DesktopHandoffState.signing)
            .timeout(const Duration(seconds: 5));

        final signedBytes = Uint8List.fromList(
          utf8.encode('FAKE-SIGNED-ENVELOPE:') + srcBytes,
        );
        await phone.submitSignature(
          signedBytes: signedBytes,
          format: 'cades-bes',
        );

        await desktop.states
            .firstWhere((s) => s == DesktopHandoffState.done)
            .timeout(const Duration(seconds: 5));

        expect(desktop.signatureBytes, equals(signedBytes));
        final outPath = desktop.signedFilePath;
        expect(outPath, isNotNull);
        expect(await File(outPath!).readAsBytes(), equals(signedBytes));
        await File(outPath).delete();
      },
    );

    test(
      'phone rejects a document whose received bytes do not hash-match the descriptor',
      () async {
        final (sessionA, sessionB) = await _pairedCryptoSessions();
        final (transportA, transportB) = FakeHandoffTransport.pair();
        final phone = PhoneHandoffSession.forTesting(
          transport: transportB,
          cryptoSession: sessionB,
        );
        addTearDown(phone.dispose);

        final claimedBytes = Uint8List.fromList(
          List.filled(32, 0x41),
        ); // 'A'*32
        final descriptor = await HandoffDescriptorBuilder.fromBytes(
          bytes: claimedBytes,
          fileName: 'x.txt',
        );
        await transportA.send(
          await sealMessage(sessionA, descriptor.toMessage()),
        );

        // Same declared length, different content -> sha256 mismatch.
        final tamperedBytes = Uint8List.fromList(
          List.filled(32, 0x42),
        ); // 'B'*32
        expect(tamperedBytes.length, equals(claimedBytes.length));
        final chunk = DocumentChunkPayload(seq: 0, data: tamperedBytes);
        await transportA.send(await sealMessage(sessionA, chunk.toMessage()));

        final state = await phone.states
            .firstWhere((s) => s == PhoneHandoffState.error)
            .timeout(const Duration(seconds: 5));
        expect(state, PhoneHandoffState.error);
        expect(phone.errorMessage, contains('sha256 mismatch'));
        // Never signs a document it can't verify the integrity of.
        expect(phone.documentBytes, isNull);
      },
    );

    test(
      'desktop rejects signed_start/signed_chunk sha mismatch and never writes a file',
      () async {
        final (sessionA, sessionB) = await _pairedCryptoSessions();
        final (transportA, transportB) = FakeHandoffTransport.pair();

        final srcBytes = Uint8List.fromList(utf8.encode('small source doc'));
        final srcPath = _tempPath('src2.txt');
        await File(srcPath).writeAsBytes(srcBytes);
        addTearDown(() async {
          try {
            await File(srcPath).delete();
          } catch (_) {}
        });

        final desktop = DesktopHandoffSession.forTesting(
          filePath: srcPath,
          transport: transportA,
          cryptoSession: sessionA,
          verify: _alwaysValidVerify,
        );
        addTearDown(desktop.dispose);

        // No real phone: drive the desktop through the document send, then
        // straight to `signing` with a raw pin_ok frame. sendDocument()
        // already resolves with state == awaitingPin (set synchronously
        // before it returns), so assert that directly rather than
        // re-listening for a transition that already happened.
        await desktop.sendDocument();
        expect(desktop.state, DesktopHandoffState.awaitingPin);
        await transportB.send(
          await sealMessage(sessionB, PinOkPayload().toMessage()),
        );
        await desktop.states
            .firstWhere((s) => s == DesktopHandoffState.signing)
            .timeout(const Duration(seconds: 5));

        final claimedSigned = Uint8List.fromList(
          utf8.encode('claims-to-be-this'),
        );
        final start = SignedStartPayload(
          byteSize: claimedSigned.length,
          sha256Hex: List.filled(64, '0').join(), // wrong hash on purpose
          format: 'cades-bes',
        );
        await transportB.send(await sealMessage(sessionB, start.toMessage()));
        final chunk = SignedChunkPayload(seq: 0, data: claimedSigned);
        await transportB.send(await sealMessage(sessionB, chunk.toMessage()));

        final state = await desktop.states
            .firstWhere((s) => s == DesktopHandoffState.error)
            .timeout(const Duration(seconds: 5));
        expect(state, DesktopHandoffState.error);
        expect(desktop.errorMessage, contains('sha256 mismatch'));
        expect(desktop.signedFilePath, isNull);
      },
    );

    test(
      'desktop rejects pin_ok received before the document has finished sending',
      () async {
        final (sessionA, sessionB) = await _pairedCryptoSessions();
        final (transportA, transportB) = FakeHandoffTransport.pair();

        final srcPath = _tempPath('src3.txt');
        await File(srcPath).writeAsBytes(utf8.encode('doc'));
        addTearDown(() async {
          try {
            await File(srcPath).delete();
          } catch (_) {}
        });

        final desktop = DesktopHandoffSession.forTesting(
          filePath: srcPath,
          transport: transportA,
          cryptoSession: sessionA,
        );
        addTearDown(desktop.dispose);

        // Desktop is still awaitingSasConfirm — sendDocument() was never
        // called. A pin_ok this early is a protocol violation.
        expect(desktop.state, DesktopHandoffState.awaitingSasConfirm);
        await transportB.send(
          await sealMessage(sessionB, PinOkPayload().toMessage()),
        );

        final state = await desktop.states
            .firstWhere((s) => s == DesktopHandoffState.error)
            .timeout(const Duration(seconds: 5));
        expect(state, DesktopHandoffState.error);
        expect(desktop.errorMessage, contains('pin_ok'));
      },
    );

    test(
      'phone rejects a document_chunk received before any descriptor',
      () async {
        final (sessionA, sessionB) = await _pairedCryptoSessions();
        final (transportA, transportB) = FakeHandoffTransport.pair();
        final phone = PhoneHandoffSession.forTesting(
          transport: transportB,
          cryptoSession: sessionB,
        );
        addTearDown(phone.dispose);

        expect(phone.state, PhoneHandoffState.awaitingSasConfirm);
        final chunk = DocumentChunkPayload(seq: 0, data: Uint8List(4));
        await transportA.send(await sealMessage(sessionA, chunk.toMessage()));

        final state = await phone.states
            .firstWhere((s) => s == PhoneHandoffState.error)
            .timeout(const Duration(seconds: 5));
        expect(state, PhoneHandoffState.error);
        expect(phone.errorMessage, contains('document_chunk'));
      },
    );

    test(
      'an abrupt peer disconnect (no graceful abort message) aborts both sides',
      () async {
        final (sessionA, sessionB) = await _pairedCryptoSessions();
        final (transportA, transportB) = FakeHandoffTransport.pair();

        final srcPath = _tempPath('src4.txt');
        await File(srcPath).writeAsBytes(utf8.encode('doc'));
        addTearDown(() async {
          try {
            await File(srcPath).delete();
          } catch (_) {}
        });

        final desktop = DesktopHandoffSession.forTesting(
          filePath: srcPath,
          transport: transportA,
          cryptoSession: sessionA,
        );
        final phone = PhoneHandoffSession.forTesting(
          transport: transportB,
          cryptoSession: sessionB,
        );
        addTearDown(desktop.dispose);
        addTearDown(phone.dispose);

        await desktop.sendDocument();
        await phone.states
            .firstWhere((s) => s == PhoneHandoffState.documentReady)
            .timeout(const Duration(seconds: 5));

        // Simulate the desktop app being killed / Wi-Fi dropping: neither
        // side ever sends an `abort` frame. Subscribe to both `error`
        // transitions *before* triggering it — otherwise whichever session
        // reacts first can finish, dispose, and close its state stream
        // before the other `firstWhere` even starts listening.
        final dFuture = desktop.states
            .firstWhere((s) => s == DesktopHandoffState.error)
            .timeout(const Duration(seconds: 5));
        final pFuture = phone.states
            .firstWhere((s) => s == PhoneHandoffState.error)
            .timeout(const Duration(seconds: 5));
        transportA.simulateDisconnect();
        final dState = await dFuture;
        final pState = await pFuture;

        expect(dState, DesktopHandoffState.error);
        expect(pState, PhoneHandoffState.error);
        expect(desktop.errorMessage, contains('peer connection lost'));
        expect(phone.errorMessage, contains('peer connection lost'));

        // The phone must not let the user PIN+sign for a vanished desktop.
        expect(phone.state, isNot(PhoneHandoffState.signing));
      },
    );

    test(
      'desktop refuses to start a transfer for a file exceeding the hard size cap, '
      'and the phone never observes anything',
      () async {
        final (sessionA, sessionB) = await _pairedCryptoSessions();
        final (transportA, transportB) = FakeHandoffTransport.pair();

        final oversizePath = _tempPath('oversize.bin');
        final oversized = Uint8List(HandoffLimits.maxDocumentBytes + 1);
        await File(oversizePath).writeAsBytes(oversized);
        addTearDown(() async {
          try {
            await File(oversizePath).delete();
          } catch (_) {}
        });

        final desktop = DesktopHandoffSession.forTesting(
          filePath: oversizePath,
          transport: transportA,
          cryptoSession: sessionA,
        );
        final phone = PhoneHandoffSession.forTesting(
          transport: transportB,
          cryptoSession: sessionB,
        );
        addTearDown(desktop.dispose);
        addTearDown(phone.dispose);

        await expectLater(desktop.sendDocument(), throwsA(isA<StateError>()));
        expect(desktop.state, DesktopHandoffState.error);
        expect(desktop.errorMessage, contains('handoff limit'));

        // Give any (unwanted) message a chance to arrive before asserting
        // the phone never left its initial post-pairing state.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(phone.state, PhoneHandoffState.awaitingSasConfirm);
      },
    );
  });
}
