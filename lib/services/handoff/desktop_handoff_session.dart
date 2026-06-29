// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'audit_log.dart';
import 'crypto.dart';
import 'descriptor.dart';
import 'messages.dart';
import 'pairing.dart';
import 'qr_payload.dart';

/// Desktop-side state machine for the QR-paired phone signing handoff.
enum DesktopHandoffState {
  /// Initial state. UI should call [start].
  idle,

  /// Generating offer SDP and ICE-gathering.
  preparingOffer,

  /// QR1 ready; waiting for the user to feed in the phone's QR2 payload.
  showingQr,

  /// QR2 received, applying answer SDP, waiting for the data channel to open.
  connecting,

  /// Channel open, SAS ready, waiting for the user to confirm match on phone
  /// (and to read the matching SAS on this desktop).
  awaitingSasConfirm,

  /// Descriptor sent, waiting for `pin_ok`.
  descriptorSent,

  /// Phone reported PIN accepted, waiting for the signature frame.
  signing,

  /// Signature received and audited; UI can write the signed file.
  done,

  /// Aborted or failed. Inspect [DesktopHandoffSession.errorMessage].
  error,
}

class DesktopHandoffSession {
  DesktopHandoffSession({required this.filePath});

  /// Path to the local file the user wants signed. Bytes never leave the
  /// desktop; only descriptor + hash do.
  final String filePath;

  HandoffPairing? _pairing;
  SimpleKeyPair? _myKeyPair;
  HandoffSession? _session;
  StreamSubscription<Uint8List>? _msgSub;
  DescriptorPayload? _descriptor;
  Uint8List? _signatureBytes;

  DesktopHandoffState _state = DesktopHandoffState.idle;
  final _stateCtl = StreamController<DesktopHandoffState>.broadcast();

  String? _qr1Wire;
  List<String>? _sasWords;
  String? _errorMessage;

  DesktopHandoffState get state => _state;
  Stream<DesktopHandoffState> get states => _stateCtl.stream;
  String? get qr1Wire => _qr1Wire;
  List<String>? get sasWords => _sasWords;
  DescriptorPayload? get descriptor => _descriptor;
  Uint8List? get signatureBytes => _signatureBytes;
  String? get errorMessage => _errorMessage;

  void _transition(DesktopHandoffState next, {String? error}) {
    if (_state == next) return;
    _state = next;
    if (error != null) _errorMessage = error;
    if (!_stateCtl.isClosed) _stateCtl.add(next);
  }

  /// Step 1: build the offer SDP, generate the X25519 keypair, return the
  /// QR1 string the UI should render.
  Future<String> start() async {
    _transition(DesktopHandoffState.preparingOffer);
    try {
      _myKeyPair = await HandoffCrypto.generateEphemeralKeyPair();
      _pairing = HandoffPairing.offerer();
      final offerSdp = await _pairing!.createOfferAndGather();

      final pub = await _myKeyPair!.extractPublicKey();
      final qr1 = HandoffQrPayload(
        role: 'offer',
        sdp: offerSdp,
        publicKey: Uint8List.fromList(pub.bytes),
      ).encode();
      _qr1Wire = qr1;
      _transition(DesktopHandoffState.showingQr);
      return qr1;
    } catch (e) {
      _transition(DesktopHandoffState.error, error: 'start: $e');
      rethrow;
    }
  }

  /// Step 2: caller passes the QR2 payload string read by the desktop webcam
  /// (or pasted by the user).
  Future<void> acceptQr2(String wire) async {
    if (_state != DesktopHandoffState.showingQr) {
      throw StateError('acceptQr2 in wrong state $_state');
    }
    final pairing = _pairing;
    final myKp = _myKeyPair;
    final qr1 = _qr1Wire;
    if (pairing == null || myKp == null || qr1 == null) {
      throw StateError('Session not started');
    }
    try {
      final qr2 = HandoffQrPayload.decode(wire);
      if (qr2.role != 'answer') {
        throw const FormatException('QR2: role is not "answer"');
      }
      if (!qr2.isFresh()) {
        throw const FormatException('QR2: stale payload');
      }
      _transition(DesktopHandoffState.connecting);

      // Derive AEAD session + SAS. Handshake context binds both QR payloads
      // so an attacker can't substitute one without changing SAS.
      final ctx = _handshakeContext(qr1, wire);
      _session = await HandoffCrypto.deriveSession(
        myKeyPair: myKp,
        peerPublicKey: qr2.publicKey,
        handshakeContext: ctx,
      );
      _sasWords = _session!.sasWords;

      await pairing.acceptAnswer(qr2.sdp);
      await pairing.channelOpen.timeout(const Duration(seconds: 30));

      // Subscribe to incoming messages.
      _msgSub = pairing.messages.listen(_onIncomingFrame);

      _transition(DesktopHandoffState.awaitingSasConfirm);
    } catch (e) {
      _transition(DesktopHandoffState.error, error: 'acceptQr2: $e');
      await abort('qr2-error');
      rethrow;
    }
  }

  /// Step 3: user confirmed SAS matches. Build descriptor (SHA-256 + thumb),
  /// send to phone.
  Future<void> sendDescriptor() async {
    if (_state != DesktopHandoffState.awaitingSasConfirm) {
      throw StateError('sendDescriptor in wrong state $_state');
    }
    final pairing = _pairing;
    final session = _session;
    if (pairing == null || session == null) {
      throw StateError('Session not derived');
    }
    try {
      _descriptor = await HandoffDescriptorBuilder.fromFile(filePath);
      final env = await sealMessage(session, _descriptor!.toMessage());
      await pairing.send(env);
      _transition(DesktopHandoffState.descriptorSent);
    } catch (e) {
      _transition(DesktopHandoffState.error, error: 'sendDescriptor: $e');
      rethrow;
    }
  }

  /// User abort or session teardown.
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
        debugPrint(
          'DesktopHandoffSession.abort: failed to send abort frame: $e',
        );
      }
    }
    await _writeAudit(outcome: 'aborted', error: reason);
    await dispose();
  }

  Future<void> _onIncomingFrame(Uint8List bytes) async {
    final session = _session;
    if (session == null) return;
    final msg = await openMessage(session, bytes);
    if (msg == null) {
      _transition(DesktopHandoffState.error, error: 'tampered frame received');
      await dispose();
      return;
    }
    switch (msg.type) {
      case HandoffMessageType.pinOk:
        _transition(DesktopHandoffState.signing);
        break;
      case HandoffMessageType.signature:
        try {
          final sig = SignaturePayload.fromJson(msg.data);
          _signatureBytes = sig.cmsBytes;
          _transition(DesktopHandoffState.done);
          await _writeAudit(outcome: 'success', format: sig.format);
        } catch (e) {
          _transition(
            DesktopHandoffState.error,
            error: 'bad signature payload: $e',
          );
        }
        break;
      case HandoffMessageType.abort:
        final reason = AbortPayload.fromJson(msg.data).reason;
        _transition(
          DesktopHandoffState.error,
          error: 'phone aborted: ${reason ?? "(no reason)"}',
        );
        await _writeAudit(outcome: 'aborted', error: reason);
        await dispose();
        break;
      case HandoffMessageType.descriptor:
        // Should never come from the phone.
        break;
    }
  }

  Future<void> _writeAudit({
    required String outcome,
    String? format,
    String? error,
  }) async {
    final desc = _descriptor;
    if (desc == null) return;
    await HandoffAuditLog.append(
      HandoffAuditEntry(
        timestamp: DateTime.now().toUtc(),
        fileName: desc.fileName,
        sha256Hex: desc.sha256Hex,
        byteSize: desc.byteSize,
        signatureFormat: format,
        peerSasWords: _sasWords,
        outcome: outcome,
        errorMessage: error,
      ),
    );
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

  /// Binds both QR payloads into the HKDF context so an attacker can't swap
  /// one without changing the SAS.
  Uint8List _handshakeContext(String qr1, String qr2) {
    final builder = BytesBuilder()
      ..add(qr1.codeUnits)
      ..add(const [0x1f]) // unit separator
      ..add(qr2.codeUnits);
    return builder.toBytes();
  }
}
