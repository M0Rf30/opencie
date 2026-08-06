// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/foundation.dart';

/// In-memory, process-lifetime back-off for repeated failed CIE PIN entry.
///
/// The first [_freeAttempts] failures are free, then each further failure
/// adds a 30-second step, capped at 90 seconds.
///
/// This only throttles re-entry in the UI; it does not talk to the card and
/// is unrelated to the card's own PIN-attempt counter.
class PinThrottle {
  PinThrottle._();

  static const int _freeAttempts = 4;
  static const int _stepSeconds = 30;
  static const int _maxLockSeconds = 90;

  /// Failure count beyond which the lockout no longer grows (90s is reached
  /// at `_freeAttempts + _maxLockSeconds / _stepSeconds` failures).
  static const int _maxFailureCount =
      _freeAttempts + (_maxLockSeconds ~/ _stepSeconds);

  static int _failureCount = 0;
  static DateTime? _lockedUntil;

  /// Overridable clock source; tests may replace this to avoid real sleeps.
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  /// Remaining lockout, or [Duration.zero] when entry is allowed now.
  static Duration get remaining {
    final lockedUntil = _lockedUntil;
    if (lockedUntil == null) {
      return Duration.zero;
    }
    final left = lockedUntil.difference(clock());
    return left.isNegative ? Duration.zero : left;
  }

  static bool get isLocked => remaining > Duration.zero;

  /// Record a rejected PIN; escalates the lockout per the back-off curve.
  static void recordFailure() {
    if (_failureCount < _maxFailureCount) {
      _failureCount++;
    }
    if (_failureCount <= _freeAttempts) {
      return;
    }
    final steps = _failureCount - _freeAttempts;
    final seconds = steps * _stepSeconds > _maxLockSeconds
        ? _maxLockSeconds
        : steps * _stepSeconds;
    _lockedUntil = clock().add(Duration(seconds: seconds));
  }

  /// Clear all state after a successful verification.
  static void reset() {
    _failureCount = 0;
    _lockedUntil = null;
  }
}
