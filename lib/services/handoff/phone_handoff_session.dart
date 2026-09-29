// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'crypto.dart';
import 'document_preview.dart';
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

  /// Channel open; waiting for the user to confirm SAS matches.
  awaitingSasConfirm,

  /// SAS confirmed; descriptor received, document chunks streaming in and
  /// being validated against the descriptor's SHA-256.
  receivingDocument,

  /// Document fully received and verified; own preview rendered from the
  /// actual bytes. User must approve and enter the PIN.
  documentReady,

  /// PIN accepted by the user; handing off to the existing FFI sign() path.
  signing,

  /// Signed document is being chunked back to the desktop.
  sendingSignature,

  /// Signature sent over the channel; flow complete.
  done,

  /// Aborted or failed.
  error,
}

class PhoneHandoffSession {
  PhoneHandoffSession();

  /// Test-only constructor: skips the QR/SDP/ECDH handshake entirely and
  /// wires the session directly onto a pre-established transport + crypto
  /// session, landing in [PhoneHandoffState.awaitingSasConfirm]. Used by
  /// session-level protocol tests with an in-memory fake transport.
  @visibleForTesting
  PhoneHandoffSession.forTesting({
    required HandoffTransport transport,
    required HandoffSession cryptoSession,
    List<String>? sasWords,
  }) {
    _pairing = transport;
    _session = cryptoSession;
    _sasWords = sasWords ?? cryptoSession.sasWords;
    _msgSub = transport.messages.listen(_onIncomingFrame);
    _pairingSub = transport.states.listen(_onTransportState);
    _transition(PhoneHandoffState.awaitingSasConfirm);
  }

  HandoffTransport? _pairing;
  SimpleKeyPair? _myKeyPair;
  HandoffSession? _session;
  StreamSubscription<Uint8List>? _msgSub;
  StreamSubscription<HandoffPairingState>? _pairingSub;

  PhoneHandoffState _state = PhoneHandoffState.idle;
  final _stateCtl = StreamController<PhoneHandoffState>.broadcast();

  String? _qr2Wire;
  List<String>? _sasWords;
  DescriptorPayload? _descriptor;
  String? _errorMessage;

  BytesBuilder? _docBuilder;
  int _docChunksReceived = 0;
  int _docBytesReceived = 0;
  Uint8List? _documentBytes;
  DocumentPreview? _preview;

  PhoneHandoffState get state => _state;
  Stream<PhoneHandoffState> get states => _stateCtl.stream;
  String? get qr2Wire => _qr2Wire;
  List<String>? get sasWords => _sasWords;
  DescriptorPayload? get descriptor => _descriptor;
  String? get errorMessage => _errorMessage;

  /// The actual document bytes, available once [PhoneHandoffState.documentReady]
  /// is reached. Already verified against the descriptor's SHA-256 — this is
  /// what gets written to a temp file and signed, never the digest alone.
  Uint8List? get documentBytes => _documentBytes;

  /// Preview rendered from [documentBytes] (never from peer-supplied
  /// material), available once [PhoneHandoffState.documentReady] is reached.
  DocumentPreview? get preview => _preview;

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
      final pairing = HandoffPairing.answerer();
      final answerSdp = await pairing.createAnswerAndGather(qr1.sdp);

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

      // Listen for descriptor / document / abort frames and transport
      // liveness.
      _msgSub = pairing.messages.listen(_onIncomingFrame);
      _pairingSub = pairing.states.listen(_onTransportState);

      // Wait for the desktop to finish setRemoteDescription and the channel
      // to open. Done in background so the UI can render QR2 immediately.
      pairing.channelOpen
          .then((_) {
            if (_state == PhoneHandoffState.showingQr ||
                _state == PhoneHandoffState.preparingAnswer) {
              _transition(PhoneHandoffState.awaitingSasConfirm);
            }
          })
          .catchError((_) {});

      _pairing = pairing;
      _transition(PhoneHandoffState.showingQr);
      return qr2;
    } catch (e) {
      _transition(PhoneHandoffState.error, error: 'startFromQr1: $e');
      rethrow;
    }
  }

  /// Reacts to transport-level liveness changes. If the desktop vanishes
  /// mid-flow, the phone must not let the user PIN+sign for it — surface an
  /// error and tear down instead of hanging.
  void _onTransportState(HandoffPairingState s) {
    if (s != HandoffPairingState.failed && s != HandoffPairingState.closed) {
      return;
    }
    if (_state == PhoneHandoffState.done || _state == PhoneHandoffState.error) {
      return;
    }
    _transition(PhoneHandoffState.error, error: 'peer connection lost');
    unawaited(dispose());
  }

  /// User confirmed SAS matches and approved the document descriptor.
  /// The phone performs the FFI sign call (caller passes [signedBytes],
  /// produced by signing [documentBytes] — the actual document, not its
  /// digest) and chunks the result back over the channel.
  Future<void> submitSignature({
    required Uint8List signedBytes,
    String? format,
  }) async {
    if (_state != PhoneHandoffState.signing) {
      throw StateError('submitSignature in wrong state $_state');
    }
    final session = _session;
    final pairing = _pairing;
    if (session == null || pairing == null) {
      throw StateError('Session not derived');
    }
    if (signedBytes.isEmpty) {
      throw StateError('empty signed document');
    }
    if (signedBytes.length > HandoffLimits.maxDocumentBytes) {
      throw StateError('signed document exceeds handoff limit');
    }
    try {
      _transition(PhoneHandoffState.sendingSignature);
      final hash = await Sha256().hash(signedBytes);
      final start = SignedStartPayload(
        byteSize: signedBytes.length,
        sha256Hex: _hex(hash.bytes),
        format: format,
      );
      await pairing.send(await sealMessage(session, start.toMessage()));

      final total = HandoffLimits.totalChunksFor(signedBytes.length);
      for (var seq = 0; seq < total; seq++) {
        final s = seq * HandoffLimits.chunkBytes;
        final e = (s + HandoffLimits.chunkBytes < signedBytes.length)
            ? s + HandoffLimits.chunkBytes
            : signedBytes.length;
        final chunk = SignedChunkPayload(
          seq: seq,
          data: Uint8List.sublistView(signedBytes, s, e),
        );
        await pairing.send(await sealMessage(session, chunk.toMessage()));
      }
      _transition(PhoneHandoffState.done);
    } catch (e) {
      _transition(PhoneHandoffState.error, error: 'submitSignature: $e');
      rethrow;
    }
  }

  /// Notify the desktop that the user accepted the PIN; helps the desktop UI
  /// show progress before the signature arrives.
  Future<void> markPinOk({int? attemptsLeft}) async {
    if (_state != PhoneHandoffState.documentReady) {
      return;
    }
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
    if (_state != PhoneHandoffState.done) {
      _transition(PhoneHandoffState.error, error: reason ?? 'aborted');
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
        if (_state != PhoneHandoffState.awaitingSasConfirm) {
          _transition(
            PhoneHandoffState.error,
            error: 'unexpected descriptor in state $_state',
          );
          await dispose();
          return;
        }
        try {
          _descriptor = DescriptorPayload.fromJson(msg.data);
          _docBuilder = BytesBuilder();
          _docChunksReceived = 0;
          _docBytesReceived = 0;
          _transition(PhoneHandoffState.receivingDocument);
        } catch (e) {
          _transition(PhoneHandoffState.error, error: 'bad descriptor: $e');
          await dispose();
        }
        break;
      case HandoffMessageType.documentChunk:
        await _handleDocumentChunk(msg.data);
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
      case HandoffMessageType.signedStart:
      case HandoffMessageType.signedChunk:
        // Phone → desktop directions only; a peer sending these is either
        // buggy or hostile.
        _transition(
          PhoneHandoffState.error,
          error: 'unexpected ${msg.type} received from desktop',
        );
        await dispose();
        break;
    }
  }

  Future<void> _handleDocumentChunk(Map<String, dynamic> data) async {
    final desc = _descriptor;
    final builder = _docBuilder;
    if (_state != PhoneHandoffState.receivingDocument ||
        desc == null ||
        builder == null) {
      _transition(
        PhoneHandoffState.error,
        error: 'unexpected document_chunk in state $_state',
      );
      await dispose();
      return;
    }
    try {
      final chunk = DocumentChunkPayload.fromJson(data);
      if (chunk.seq != _docChunksReceived) {
        throw StateError(
          'out-of-order document_chunk (got ${chunk.seq}, expected $_docChunksReceived)',
        );
      }
      builder.add(chunk.data);
      _docChunksReceived++;
      _docBytesReceived += chunk.data.lengthInBytes;
      if (_docBytesReceived > HandoffLimits.maxDocumentBytes ||
          _docBytesReceived > desc.byteSize) {
        throw StateError('document exceeds declared/allowed size');
      }
      if (_docBytesReceived < desc.byteSize) {
        return; // more chunks to come
      }

      final full = builder.toBytes();
      final hash = await Sha256().hash(full);
      final hex = _hex(hash.bytes);
      if (hex != desc.sha256Hex) {
        throw StateError('document sha256 mismatch — refusing to sign');
      }
      _documentBytes = full;
      _preview = await DocumentPreviewBuilder.fromBytes(
        full,
        mimeType: desc.mimeType,
      );
      _transition(PhoneHandoffState.documentReady);
    } catch (e) {
      _transition(
        PhoneHandoffState.error,
        error: 'document transfer failed: $e',
      );
      await dispose();
    }
  }

  Future<void> dispose() async {
    await _pairingSub?.cancel();
    _pairingSub = null;
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

  static String _hex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
