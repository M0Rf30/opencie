// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:typed_data';

import 'package:opencie/services/handoff/pairing.dart';

/// Shared plumbing between a linked pair of [FakeHandoffTransport]s: two
/// one-directional message pipes and two one-directional state-event
/// streams (so either side can observe the other's simulated
/// connect/disconnect without needing a real WebRTC stack).
class _FakeLink {
  final aToB = StreamController<Uint8List>.broadcast();
  final bToA = StreamController<Uint8List>.broadcast();
  final stateA = StreamController<HandoffPairingState>.broadcast();
  final stateB = StreamController<HandoffPairingState>.broadcast();
}

/// An in-memory [HandoffTransport] used to wire two [DesktopHandoffSession]/
/// [PhoneHandoffSession] instances together in tests without a real WebRTC
/// peer connection. The channel is "open" from construction — tests skip
/// straight to `.forTesting()` session constructors, which land in
/// `awaitingSasConfirm`.
class FakeHandoffTransport implements HandoffTransport {
  FakeHandoffTransport._(this._link, this._isA);

  final _FakeLink _link;
  final bool _isA;
  bool _closed = false;

  /// Builds a connected pair: `a.send()` is observed by `b.messages`, and
  /// vice versa.
  static (FakeHandoffTransport, FakeHandoffTransport) pair() {
    final link = _FakeLink();
    return (
      FakeHandoffTransport._(link, true),
      FakeHandoffTransport._(link, false),
    );
  }

  @override
  Stream<Uint8List> get messages =>
      _isA ? _link.bToA.stream : _link.aToB.stream;

  @override
  Stream<HandoffPairingState> get states =>
      _isA ? _link.stateA.stream : _link.stateB.stream;

  @override
  Future<void> get channelOpen => Future.value();

  @override
  Future<void> send(Uint8List bytes) async {
    if (_closed) {
      throw StateError('FakeHandoffTransport: send() after close/dispose');
    }
    (_isA ? _link.aToB : _link.bToA).add(bytes);
  }

  /// Simulates the underlying transport dying abruptly (peer app killed,
  /// network drop, etc.) — both ends observe a `failed` state, without a
  /// graceful `abort` message ever being delivered. Used to test that both
  /// sessions notice a vanished peer via transport liveness, not just via
  /// the abort protocol message.
  void simulateDisconnect() {
    if (_closed) return;
    _closed = true;
    if (!_link.stateA.isClosed) _link.stateA.add(HandoffPairingState.failed);
    if (!_link.stateB.isClosed) _link.stateB.add(HandoffPairingState.failed);
  }

  @override
  Future<void> dispose() async {
    _closed = true;
    final myStates = _isA ? _link.stateA : _link.stateB;
    if (!myStates.isClosed) myStates.add(HandoffPairingState.closed);
  }
}
