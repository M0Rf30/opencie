// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Lifecycle events for [HandoffPairing].
enum HandoffPairingState {
  idle,
  gatheringIce,
  awaitingAnswer,
  awaitingOffer,
  connecting,
  connected,
  closed,
  failed,
}

/// Transport abstraction consumed by [DesktopHandoffSession] and
/// [PhoneHandoffSession]: a bidirectional binary channel with lifecycle
/// state. [HandoffPairing] (real WebRTC) implements it directly; tests use
/// an in-memory fake so the signing protocol/state machine can be
/// exercised without a real peer connection.
abstract class HandoffTransport {
  Stream<HandoffPairingState> get states;
  Stream<Uint8List> get messages;
  Future<void> get channelOpen;
  Future<void> send(Uint8List bytes);
  Future<void> dispose();
}

/// One side of the desktop ↔ phone WebRTC P2P signing channel.
///
/// This class only owns the transport: peer connection, ICE gathering,
/// data channel, and JSON-encodable SDP exchange. Crypto and wire framing
/// live in `crypto.dart` and `messages.dart`.
///
/// Typical usage (desktop / offerer):
/// ```
/// final p = HandoffPairing.offerer();
/// final offerSdp = await p.createOfferAndGather();
/// // show QR with offerSdp + ephemeral pubkey
/// // scan QR2 → answerSdp
/// await p.acceptAnswer(answerSdp);
/// // p.messages will start emitting once peer opens the channel
/// ```
///
/// Typical usage (phone / answerer):
/// ```
/// final p = HandoffPairing.answerer();
/// final answerSdp = await p.createAnswerAndGather(remoteOfferSdp);
/// // show QR2 with answerSdp + ephemeral pubkey + sas commit
/// // p.messages will start emitting once channel opens
/// ```
class HandoffPairing implements HandoffTransport {
  HandoffPairing._({required this.isOfferer});

  factory HandoffPairing.offerer() => HandoffPairing._(isOfferer: true);

  factory HandoffPairing.answerer() => HandoffPairing._(isOfferer: false);

  /// Whether this side initiates the offer (desktop) or replies with an
  /// answer (phone).
  final bool isOfferer;

  /// STUN-only configuration. No TURN — keeping infra-free per design.
  static const Map<String, dynamic> _config = {
    'iceServers': [
      {
        'urls': [
          'stun:stun.l.google.com:19302',
          'stun:stun1.l.google.com:19302',
          'stun:stun2.l.google.com:19302',
          'stun:stun3.l.google.com:19302',
          'stun:stun4.l.google.com:19302',
        ],
      },
    ],
    'sdpSemantics': 'unified-plan',
  };

  static const String _channelLabel = 'opencie-handoff';

  /// flutter_webrtc defaults to `OfferToReceiveAudio/Video: true`, which
  /// adds audio + video m-sections (dozens of codec lines, every ICE
  /// candidate repeated per section) to an SDP that only needs the data
  /// channel. On Linux that produced a ~9 KB offer, far past the ~2.3 KB a
  /// QR code can hold, so QR1 failed to render at all.
  static const Map<String, dynamic> _dataOnlyConstraints = {
    'mandatory': {'OfferToReceiveAudio': false, 'OfferToReceiveVideo': false},
    'optional': <Map<String, dynamic>>[],
  };

  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  HandoffPairingState _state = HandoffPairingState.idle;
  final _stateCtl = StreamController<HandoffPairingState>.broadcast();
  final _messagesCtl = StreamController<Uint8List>.broadcast();
  final _channelOpen = Completer<void>();

  /// Current pairing lifecycle state.
  HandoffPairingState get state => _state;

  /// Stream of state transitions. Useful for UI progress indicators.
  @override
  Stream<HandoffPairingState> get states => _stateCtl.stream;

  /// Binary frames received over the data channel. The crypto layer above
  /// is responsible for decoding `seal`/`open` envelopes.
  @override
  Stream<Uint8List> get messages => _messagesCtl.stream;

  /// Resolves once the underlying [RTCDataChannel] reaches the open state.
  @override
  Future<void> get channelOpen => _channelOpen.future;

  void _transition(HandoffPairingState next) {
    if (_state == next) return;
    _state = next;
    if (!_stateCtl.isClosed) _stateCtl.add(next);
  }

  Future<RTCPeerConnection> _ensurePc() async {
    final existing = _pc;
    if (existing != null) return existing;

    final pc = await createPeerConnection(_config);
    pc.onConnectionState = (s) {
      switch (s) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
          _transition(HandoffPairingState.connecting);
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _transition(HandoffPairingState.connected);
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          _transition(HandoffPairingState.closed);
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          _transition(HandoffPairingState.failed);
          break;
        default:
          break;
      }
    };
    pc.onDataChannel = (channel) {
      if (channel.label == _channelLabel) {
        _attachDataChannel(channel);
      }
    };
    _pc = pc;
    return pc;
  }

  void _attachDataChannel(RTCDataChannel channel) {
    _dc = channel;
    channel.onDataChannelState = (s) {
      if (s == RTCDataChannelState.RTCDataChannelOpen &&
          !_channelOpen.isCompleted) {
        _channelOpen.complete();
      }
    };
    channel.onMessage = (msg) {
      if (msg.isBinary && !_messagesCtl.isClosed) {
        _messagesCtl.add(msg.binary);
      }
    };
  }

  /// Desktop side: create offer, wait for ICE gathering to complete,
  /// return the full SDP suitable for embedding in a QR.
  ///
  /// Throws [StateError] if called on an answerer.
  Future<String> createOfferAndGather() async {
    if (!isOfferer) {
      throw StateError('createOfferAndGather can only be called on offerer');
    }
    final pc = await _ensurePc();

    // Pre-create an outbound binary data channel before the offer so the
    // SDP carries the SCTP transport.
    final init = RTCDataChannelInit()
      ..ordered = true
      ..binaryType = 'binary';
    final dc = await pc.createDataChannel(_channelLabel, init);
    _attachDataChannel(dc);

    final offer = await pc.createOffer(_dataOnlyConstraints);
    await pc.setLocalDescription(offer);
    _transition(HandoffPairingState.gatheringIce);

    final localSdp = await _waitForIceGatheringComplete(pc);
    _transition(HandoffPairingState.awaitingAnswer);
    return localSdp;
  }

  /// Desktop side: feed back the SDP that came in via QR2.
  Future<void> acceptAnswer(String remoteAnswerSdp) async {
    if (!isOfferer) {
      throw StateError('acceptAnswer can only be called on offerer');
    }
    final pc = await _ensurePc();
    await pc.setRemoteDescription(
      RTCSessionDescription(remoteAnswerSdp, 'answer'),
    );
  }

  /// Phone side: consume offer SDP, create answer, wait for ICE,
  /// return the answer SDP suitable for QR2.
  Future<String> createAnswerAndGather(String remoteOfferSdp) async {
    if (isOfferer) {
      throw StateError('createAnswerAndGather can only be called on answerer');
    }
    final pc = await _ensurePc();
    _transition(HandoffPairingState.awaitingOffer);
    await pc.setRemoteDescription(
      RTCSessionDescription(remoteOfferSdp, 'offer'),
    );
    final answer = await pc.createAnswer(_dataOnlyConstraints);
    await pc.setLocalDescription(answer);
    _transition(HandoffPairingState.gatheringIce);
    final localSdp = await _waitForIceGatheringComplete(pc);
    _transition(HandoffPairingState.connecting);
    return localSdp;
  }

  /// High-water mark for [RTCDataChannel.bufferedAmount]: once the SCTP
  /// send buffer is at or above this many bytes, [send] waits for it to
  /// drain before handing over more data. Without this, chunked document
  /// transfers (up to `HandoffLimits.maxDocumentBytes`) could be queued
  /// into the data channel far faster than the wire can carry them,
  /// ballooning memory and risking transport-level backpressure errors.
  static const int _maxBufferedAmount = 256 * 1024; // 256 KiB

  /// Send a binary frame on the data channel. The frame is opaque to the
  /// transport; AEAD framing happens in the crypto layer above.
  @override
  Future<void> send(Uint8List bytes) async {
    final dc = _dc;
    if (dc == null) {
      throw StateError('Data channel not yet established');
    }
    await _waitForBufferDrain(dc);
    await dc.send(RTCDataChannelMessage.fromBinary(bytes));
  }

  /// Polls [RTCDataChannel.bufferedAmount] until it drops back under
  /// [_maxBufferedAmount]. Polling (rather than `onBufferedAmountLow`) keeps
  /// this self-contained and easy to reason about for a channel that's
  /// otherwise driven by a simple sequential chunk loop.
  Future<void> _waitForBufferDrain(RTCDataChannel dc) async {
    while (true) {
      int buffered;
      try {
        buffered = await dc.getBufferedAmount();
      } catch (_) {
        buffered = dc.bufferedAmount ?? 0;
      }
      if (buffered <= _maxBufferedAmount) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// Tear everything down. Safe to call multiple times.
  @override
  Future<void> dispose() async {
    try {
      await _dc?.close();
    } catch (e) {
      debugPrint('HandoffPairing.dispose: failed to close data channel: $e');
    }
    try {
      await _pc?.close();
      await _pc?.dispose();
    } catch (e) {
      debugPrint('HandoffPairing.dispose: failed to close peer connection: $e');
    }
    _dc = null;
    _pc = null;
    _transition(HandoffPairingState.closed);
    if (!_stateCtl.isClosed) await _stateCtl.close();
    if (!_messagesCtl.isClosed) await _messagesCtl.close();
  }

  /// Waits for ICE gathering to complete and returns the final SDP. Polls
  /// instead of relying on `onIceGatheringState` because some platform
  /// adapters skip the `complete` notification when gathering is fast.
  Future<String> _waitForIceGatheringComplete(
    RTCPeerConnection pc, {
    Duration timeout = const Duration(seconds: 8),
    Duration tick = const Duration(milliseconds: 100),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (pc.iceGatheringState ==
          RTCIceGatheringState.RTCIceGatheringStateComplete) {
        break;
      }
      await Future<void>.delayed(tick);
    }
    final desc = await pc.getLocalDescription();
    if (desc == null || desc.sdp == null) {
      throw StateError('Local description is missing after ICE gathering');
    }
    return compactSdpForQr(desc.sdp!);
  }

  /// Shrinks [sdp] for QR transport by dropping TCP ICE candidates. The data
  /// channel runs over UDP; TCP host candidates roughly double the candidate
  /// lines on multi-homed machines (IPv4 + several IPv6 addresses). If the
  /// SDP has no UDP candidate at all, it's returned unchanged so pairing can
  /// still fall back to TCP.
  @visibleForTesting
  static String compactSdpForQr(String sdp) {
    final lines = sdp.split('\r\n');
    bool isCandidate(String l) => l.startsWith('a=candidate:');
    bool isTcp(String l) =>
        l.split(' ').elementAtOrNull(2)?.toLowerCase() == 'tcp';
    final hasUdp = lines.any((l) => isCandidate(l) && !isTcp(l));
    if (!hasUdp) return sdp;
    return lines.where((l) => !(isCandidate(l) && isTcp(l))).join('\r\n');
  }
}
