// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'crypto.dart';
import 'messages.dart';
import 'pairing.dart';
import 'qr_payload.dart';

/// Phone-side state machine for the QR-paired desktop signing handoff.
enum PhoneHandoffState {
  /// Waiting for the user to scan QR1 (desktop offer).
  idle,

  /// Building answer SDP from the offer; ICE-gathering.
  preparingAnswer,

  /// QR2 ready; user shows it on the phone for the desktop to scan.
  showingQr,

  /// Channel open; waiting for the user to confirm SAS matches and accept
  /// the document descriptor.
  awaitingSasConfirm,

  /// Descriptor received; user must approve the document and enter the PIN.
  descriptorReceived,

  /// PIN accepted by the user; handing off to the existing FFI sign() path.
  signing,

  /// Signature sent over the channel; flow complete.
  done,

  /// Aborted or failed.
  error,
}

class PhoneHandoffSession {
  PhoneHandoffSession();

  HandoffPairing? _pairing;
  SimpleKeyPair? _myKeyPair;
  HandoffSession? _session;
  StreamSubscription<Uint8List>? _msgSub;

  PhoneHandoffState _state = PhoneHandoffState.idle;
  final _stateCtl = StreamController<PhoneHandoffState>.broadcast();

  String? _qr2Wire;
  List<String>? _sasWords;
  DescriptorPayload? _descriptor;
  String? _errorMessage;

  PhoneHandoffState get state => _state;
  Stream<PhoneHandoffState> get states => _stateCtl.stream;
  String? get qr2Wire => _qr2Wire;
  List<String>? get sasWords => _sasWords;
  DescriptorPayload? get descriptor => _descriptor;
  String? get errorMessage => _errorMessage;

  void _transition(PhoneHandoffState next, {String? error}) {
    if (_state == next) return;
    _state = next;
    if (error != null) _errorMessage = error;
    if (!_stateCtl.isClosed) _stateCtl.add(next);
  }

  /// Step 1: phone scanned QR1; produce the answer SDP and QR2 payload.
  Future<String> startFromQr1(String qr1Wire) async {
    if (_state != PhoneHandoffState.idle) {
      throw StateError('startFromQr1 in wrong state $_state');
    }
    _transition(PhoneHandoffState.preparingAnswer);
    try {
      final qr1 = HandoffQrPayload.decode(qr1Wire);
      if (qr1.role != 'offer') {
        throw const FormatException('QR1: role is not "offer"');
      }
      if (!qr1.isFresh()) {
        throw const FormatException('QR1: stale payload');
      }

      _myKeyPair = await HandoffCrypto.generateEphemeralKeyPair();
      _pairing = HandoffPairing.answerer();
      final answerSdp = await _pairing!.createAnswerAndGather(qr1.sdp);

      final pub = await _myKeyPair!.extractPublicKey();
      final qr2 = HandoffQrPayload(
        role: 'answer',
        sdp: answerSdp,
        publicKey: Uint8List.fromList(pub.bytes),
      ).encode();
      _qr2Wire = qr2;

      // Derive AEAD session + SAS now that we have both halves.
      final ctx = _handshakeContext(qr1Wire, qr2);
      _session = await HandoffCrypto.deriveSession(
        myKeyPair: _myKeyPair!,
        peerPublicKey: qr1.publicKey,
        handshakeContext: ctx,
      );
      _sasWords = _session!.sasWords;

      // Listen for descriptor / abort frames.
      _msgSub = _pairing!.messages.listen(_onIncomingFrame);

      // Wait for the desktop to finish setRemoteDescription and the channel
      // to open. Done in background so the UI can render QR2 immediately.
      _pairing!.channelOpen
          .then((_) {
            if (_state == PhoneHandoffState.showingQr ||
                _state == PhoneHandoffState.preparingAnswer) {
              _transition(PhoneHandoffState.awaitingSasConfirm);
            }
          })
          .catchError((_) {});

      _transition(PhoneHandoffState.showingQr);
      return qr2;
    } catch (e) {
      _transition(PhoneHandoffState.error, error: 'startFromQr1: $e');
      rethrow;
    }
  }

  /// User confirmed SAS matches and approved the document descriptor.
  /// The phone performs the FFI sign call (caller passes [signBytes]) and
  /// the resulting CMS is sent back over the channel.
  Future<void> submitSignature({
    required Uint8List cmsBytes,
    String? format,
  }) async {
    if (_state != PhoneHandoffState.signing &&
        _state != PhoneHandoffState.descriptorReceived) {
      throw StateError('submitSignature in wrong state $_state');
    }
    final session = _session;
    final pairing = _pairing;
    if (session == null || pairing == null) {
      throw StateError('Session not derived');
    }
    try {
      _transition(PhoneHandoffState.signing);
      final sig = SignaturePayload(cmsBytes: cmsBytes, format: format);
      final env = await sealMessage(session, sig.toMessage());
      await pairing.send(env);
      _transition(PhoneHandoffState.done);
    } catch (e) {
      _transition(PhoneHandoffState.error, error: 'submitSignature: $e');
      rethrow;
    }
  }

  /// Notify the desktop that the user accepted the PIN; helps the desktop UI
  /// show progress before the signature arrives.
  Future<void> markPinOk({int? attemptsLeft}) async {
    final session = _session;
    final pairing = _pairing;
    if (session == null || pairing == null) return;
    try {
      final env = await sealMessage(
        session,
        PinOkPayload(attemptsLeft: attemptsLeft).toMessage(),
      );
      await pairing.send(env);
      _transition(PhoneHandoffState.signing);
    } catch (e) {
      debugPrint('PhoneHandoffSession.markPinOk: failed to send pin_ok: $e');
    }
  }

  Future<void> abort([String? reason]) async {
    final session = _session;
    final pairing = _pairing;
    if (session != null && pairing != null) {
      try {
        final env = await sealMessage(
          session,
          AbortPayload(reason: reason).toMessage(),
        );
        await pairing.send(env);
      } catch (e) {
        // Best-effort: if we can't send the abort the peer will time out.
        debugPrint('PhoneHandoffSession.abort: failed to send abort frame: $e');
      }
    }
    await dispose();
  }

  Future<void> _onIncomingFrame(Uint8List bytes) async {
    final session = _session;
    if (session == null) return;
    final msg = await openMessage(session, bytes);
    if (msg == null) {
      _transition(PhoneHandoffState.error, error: 'tampered frame');
      await dispose();
      return;
    }
    switch (msg.type) {
      case HandoffMessageType.descriptor:
        try {
          _descriptor = DescriptorPayload.fromJson(msg.data);
          _transition(PhoneHandoffState.descriptorReceived);
        } catch (e) {
          _transition(PhoneHandoffState.error, error: 'bad descriptor: $e');
        }
        break;
      case HandoffMessageType.abort:
        final reason = AbortPayload.fromJson(msg.data).reason;
        _transition(
          PhoneHandoffState.error,
          error: 'desktop aborted: ${reason ?? "(no reason)"}',
        );
        await dispose();
        break;
      case HandoffMessageType.pinOk:
      case HandoffMessageType.signature:
        // These are phone→desktop directions; ignore on the phone side.
        break;
    }
  }

  Future<void> dispose() async {
    await _msgSub?.cancel();
    _msgSub = null;
    _session?.destroy();
    _session = null;
    try {
      _myKeyPair?.destroy();
    } catch (_) {
      // Best-effort cleanup: key material may already be zeroed; ignore.
    }
    _myKeyPair = null;
    await _pairing?.dispose();
    _pairing = null;
    if (!_stateCtl.isClosed) await _stateCtl.close();
  }

  Uint8List _handshakeContext(String qr1, String qr2) {
    final builder = BytesBuilder()
      ..add(qr1.codeUnits)
      ..add(const [0x1f])
      ..add(qr2.codeUnits);
    return builder.toBytes();
  }
}
