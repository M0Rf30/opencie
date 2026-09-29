// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'audit_log.dart';
import 'crypto.dart';
import 'descriptor.dart';
import 'messages.dart';
import 'pairing.dart';
import 'qr_payload.dart';
import '../../ffi/opencie_pkcs11.dart';
import '../../ffi/models/verify_info.dart';

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

  /// Descriptor + document chunks are being streamed to the phone.
  sendingDocument,

  /// Document fully sent; waiting for the phone user to enter the PIN
  /// (`pin_ok`).
  awaitingPin,

  /// `pin_ok` received; waiting for the signed-document frames.
  signing,

  /// Signed document fully received; verifying the embedded signature
  /// before writing it to disk.
  verifying,

  /// Signature verified and written to disk; UI can open the file.
  done,

  /// Aborted or failed. Inspect [DesktopHandoffSession.errorMessage].
  error,
}

class DesktopHandoffSession {
  DesktopHandoffSession({
    required this.filePath,
    @visibleForTesting
    Future<List<VerifyInfo>> Function({required String inputPath})? verify,
  }) : _verify = verify ?? OpenCiePkcs11.instance.verify;

  /// Test-only constructor: skips the QR/SDP/ECDH handshake entirely and
  /// wires the session directly onto a pre-established transport + crypto
  /// session, landing in [DesktopHandoffState.awaitingSasConfirm]. Used by
  /// session-level protocol tests with an in-memory fake transport.
  @visibleForTesting
  DesktopHandoffSession.forTesting({
    required this.filePath,
    required HandoffTransport transport,
    required HandoffSession cryptoSession,
    List<String>? sasWords,
    Future<List<VerifyInfo>> Function({required String inputPath})? verify,
  }) : _verify = verify ?? OpenCiePkcs11.instance.verify {
    _pairing = transport;
    _session = cryptoSession;
    _sasWords = sasWords ?? cryptoSession.sasWords;
    _msgSub = transport.messages.listen(_onIncomingFrame);
    _pairingSub = transport.states.listen(_onTransportState);
    _transition(DesktopHandoffState.awaitingSasConfirm);
  }

  /// Path to the local file the user wants signed. Bytes never leave the
  /// desktop; only descriptor + hash do.
  final String filePath;

  /// Verifies a candidate signed document before it's trusted/written to
  /// disk. Defaults to the real native PKCS#11 verify path; overridable in
  /// tests so session-level protocol tests don't need a real card/library.
  final Future<List<VerifyInfo>> Function({required String inputPath}) _verify;

  HandoffTransport? _pairing;
  SimpleKeyPair? _myKeyPair;
  HandoffSession? _session;
  StreamSubscription<Uint8List>? _msgSub;
  StreamSubscription<HandoffPairingState>? _pairingSub;
  DescriptorPayload? _descriptor;

  BytesBuilder? _signedBuilder;
  SignedStartPayload? _signedStart;
  int _signedChunksReceived = 0;
  int _signedBytesReceived = 0;

  Uint8List? _signatureBytes;
  String? _signatureFormat;
  String? _signedFilePath;

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
  String? get signedFilePath => _signedFilePath;
  String? get errorMessage => _errorMessage;

  void _transition(DesktopHandoffState next, {String? error}) {
    if (_state == next) return;
    _state = next;
    if (error != null) _errorMessage = error;
    if (!_stateCtl.isClosed) _stateCtl.add(next);
  }

  /// Step 1: build the offer SDP, generate the X25519 keypair, return the
  /// QR1 string the UI should render.
  ///
  /// May also be called again while in [DesktopHandoffState.showingQr] (or
  /// [DesktopHandoffState.idle]) to mint a fresh QR1 — e.g. because the
  /// user waited long enough that the original went stale. This tears down
  /// any in-progress pairing attempt and starts over.
  Future<String> start() async {
    if (_state != DesktopHandoffState.idle &&
        _state != DesktopHandoffState.showingQr) {
      throw StateError('start in wrong state $_state');
    }
    if (_state == DesktopHandoffState.showingQr) {
      // Refreshing an existing QR1: tear down the stale pairing attempt
      // first so we don't leak a peer connection.
      await _pairingSub?.cancel();
      _pairingSub = null;
      await _msgSub?.cancel();
      _msgSub = null;
      await _pairing?.dispose();
      _pairing = null;
      try {
        _myKeyPair?.destroy();
      } catch (_) {
        // Best-effort cleanup: key material may already be zeroed; ignore.
      }
      _myKeyPair = null;
      _state = DesktopHandoffState.idle;
    }
    _transition(DesktopHandoffState.preparingOffer);
    try {
      _myKeyPair = await HandoffCrypto.generateEphemeralKeyPair();
      final pairing = HandoffPairing.offerer();
      final offerSdp = await pairing.createOfferAndGather();
      _pairing = pairing;

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
    if (pairing is! HandoffPairing || myKp == null || qr1 == null) {
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

      // Subscribe to incoming messages and transport liveness.
      _msgSub = pairing.messages.listen(_onIncomingFrame);
      _pairingSub = pairing.states.listen(_onTransportState);

      _transition(DesktopHandoffState.awaitingSasConfirm);
    } catch (e) {
      _transition(DesktopHandoffState.error, error: 'acceptQr2: $e');
      await abort('qr2-error');
      rethrow;
    }
  }

  /// Reacts to transport-level liveness changes (ICE/data-channel failure or
  /// close) that aren't part of the signing protocol itself. If the peer
  /// vanishes mid-flow, the session must not sit forever in `awaitingPin`/
  /// `signing` — surface an error and tear down.
  void _onTransportState(HandoffPairingState s) {
    if (s != HandoffPairingState.failed && s != HandoffPairingState.closed) {
      return;
    }
    if (_state == DesktopHandoffState.done ||
        _state == DesktopHandoffState.error) {
      return;
    }
    _transition(DesktopHandoffState.error, error: 'peer connection lost');
    unawaited(_writeAudit(outcome: 'aborted', error: 'peer connection lost'));
    unawaited(dispose());
  }

  /// Step 3: user confirmed SAS matches. Sends the document descriptor
  /// followed by the actual document bytes, chunked, over the AEAD channel.
  Future<void> sendDocument() async {
    if (_state != DesktopHandoffState.awaitingSasConfirm) {
      throw StateError('sendDocument in wrong state $_state');
    }
    final pairing = _pairing;
    final session = _session;
    if (pairing == null || session == null) {
      throw StateError('Session not derived');
    }
    try {
      final file = File(filePath);
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty || bytes.length > HandoffLimits.maxDocumentBytes) {
        throw StateError(
          'document size ${bytes.length} exceeds handoff limit '
          '(${HandoffLimits.maxDocumentBytes})',
        );
      }
      _descriptor = await HandoffDescriptorBuilder.fromBytes(
        bytes: bytes,
        fileName: filePath,
      );

      _transition(DesktopHandoffState.sendingDocument);
      await pairing.send(await sealMessage(session, _descriptor!.toMessage()));

      final total = HandoffLimits.totalChunksFor(bytes.length);
      for (var seq = 0; seq < total; seq++) {
        final start = seq * HandoffLimits.chunkBytes;
        final end = (start + HandoffLimits.chunkBytes < bytes.length)
            ? start + HandoffLimits.chunkBytes
            : bytes.length;
        final chunk = DocumentChunkPayload(
          seq: seq,
          data: Uint8List.sublistView(bytes, start, end),
        );
        await pairing.send(await sealMessage(session, chunk.toMessage()));
      }
      _transition(DesktopHandoffState.awaitingPin);
    } catch (e) {
      _transition(DesktopHandoffState.error, error: 'sendDocument: $e');
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
    if (_state != DesktopHandoffState.done) {
      _transition(DesktopHandoffState.error, error: reason ?? 'aborted');
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
        if (_state != DesktopHandoffState.awaitingPin) {
          _transition(
            DesktopHandoffState.error,
            error: 'unexpected pin_ok in state $_state',
          );
          await dispose();
          return;
        }
        _transition(DesktopHandoffState.signing);
        break;
      case HandoffMessageType.signedStart:
        if (_state != DesktopHandoffState.signing) {
          _transition(
            DesktopHandoffState.error,
            error: 'unexpected signed_start in state $_state',
          );
          await dispose();
          return;
        }
        try {
          _signedStart = SignedStartPayload.fromJson(msg.data);
          _signedBuilder = BytesBuilder();
          _signedChunksReceived = 0;
          _signedBytesReceived = 0;
        } catch (e) {
          _transition(
            DesktopHandoffState.error,
            error: 'bad signed_start payload: $e',
          );
          await dispose();
        }
        break;
      case HandoffMessageType.signedChunk:
        await _handleSignedChunk(msg.data);
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
      case HandoffMessageType.documentChunk:
        // Desktop → phone directions only; a peer sending these is either
        // buggy or hostile.
        _transition(
          DesktopHandoffState.error,
          error: 'unexpected ${msg.type} received from phone',
        );
        await dispose();
        break;
    }
  }

  Future<void> _handleSignedChunk(Map<String, dynamic> data) async {
    final start = _signedStart;
    final builder = _signedBuilder;
    if (_state != DesktopHandoffState.signing ||
        start == null ||
        builder == null) {
      _transition(
        DesktopHandoffState.error,
        error: 'unexpected signed_chunk in state $_state',
      );
      await dispose();
      return;
    }
    try {
      final chunk = SignedChunkPayload.fromJson(data);
      if (chunk.seq != _signedChunksReceived) {
        throw StateError(
          'out-of-order signed_chunk (got ${chunk.seq}, expected $_signedChunksReceived)',
        );
      }
      builder.add(chunk.data);
      _signedChunksReceived++;
      _signedBytesReceived += chunk.data.lengthInBytes;
      if (_signedBytesReceived > HandoffLimits.maxDocumentBytes ||
          _signedBytesReceived > start.byteSize) {
        throw StateError('signed document exceeds declared/allowed size');
      }
      if (_signedBytesReceived < start.byteSize) {
        return; // more chunks to come
      }

      final full = builder.toBytes();
      final hash = await Sha256().hash(full);
      final hex = _hex(hash.bytes);
      if (hex != start.sha256Hex) {
        throw StateError('signed document sha256 mismatch');
      }
      _transition(DesktopHandoffState.verifying);
      await _verifyAndFinish(full, start.format);
    } catch (e) {
      _transition(
        DesktopHandoffState.error,
        error: 'signature transfer failed: $e',
      );
      await _writeAudit(outcome: 'failed', error: '$e');
      await dispose();
    }
  }

  /// Verifies the returned signature actually validates (parses as a
  /// signed document with at least one cryptographically valid signature)
  /// before writing anything to disk, and never clobbers an existing
  /// output file.
  Future<void> _verifyAndFinish(Uint8List bytes, String? format) async {
    File? tempFile;
    try {
      final tempDir = await getTemporaryDirectory();
      final tempPath = p.join(
        tempDir.path,
        'handoff_verify_${DateTime.now().microsecondsSinceEpoch}.p7m',
      );
      tempFile = File(tempPath);
      await tempFile.writeAsBytes(bytes, flush: true);

      final infos = await _verify(inputPath: tempPath);
      if (infos.isEmpty || !infos.any((i) => i.isSignatureValid)) {
        throw StateError('no valid signature found in the returned document');
      }

      final outPath = _uniqueOutputPath(_desiredOutputPath());
      await File(outPath).writeAsBytes(bytes, flush: true);

      _signatureBytes = bytes;
      _signatureFormat = format;
      _signedFilePath = outPath;
      _transition(DesktopHandoffState.done);
      await _writeAudit(outcome: 'success', format: format);
    } catch (e) {
      _transition(
        DesktopHandoffState.error,
        error: 'signature verification failed: $e',
      );
      await _writeAudit(outcome: 'failed', error: '$e');
    } finally {
      try {
        if (tempFile != null && await tempFile.exists()) {
          await tempFile.delete();
        }
      } catch (_) {
        // Best-effort cleanup.
      }
    }
  }

  String _desiredOutputPath() =>
      p.join(p.dirname(filePath), '${p.basename(filePath)}.p7m');

  /// Never overwrites an existing file: appends " (1)", " (2)", … before the
  /// extension until a free name is found.
  String _uniqueOutputPath(String desired) {
    if (!File(desired).existsSync()) return desired;
    final dir = p.dirname(desired);
    final ext = p.extension(desired);
    final baseNoExt = p.basenameWithoutExtension(desired);
    var i = 1;
    while (true) {
      final candidate = p.join(dir, '$baseNoExt ($i)$ext');
      if (!File(candidate).existsSync()) return candidate;
      i++;
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
        signatureFormat: format ?? _signatureFormat,
        peerSasWords: _sasWords,
        outcome: outcome,
        errorMessage: error,
      ),
    );
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

  /// Binds both QR payloads into the HKDF context so an attacker can't swap
  /// one without changing the SAS.
  Uint8List _handshakeContext(String qr1, String qr2) {
    final builder = BytesBuilder()
      ..add(qr1.codeUnits)
      ..add(const [0x1f]) // unit separator
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
