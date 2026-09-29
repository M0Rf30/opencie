// SPDX-License-Identifier: GPL-3.0-or-later

import '../core/constants/app_constants.dart';

/// Why a candidate PIN was refused, or null when acceptable.
enum PinWeakness {
  tooShort,
  notNumeric,
  allSameDigit,
  sequential,
  repeatedPair,
}

/// Returns the first problem found, or null if the PIN is acceptable.
///
/// Accepts either the full 8-digit CIE PIN or just its last 4 digits: the
/// card design lets a native caller cache the first 4 digits across
/// re-entries within the same session and only require the remaining 4
/// (see `cie_sign_csp.cpp`'s PIN-prefix handling), so a bare 4-digit entry
/// is a legitimate length here, not a typo.
///
/// Rules are checked in order: length, then digit-only, then all-same-digit,
/// then a strictly monotonic run of consecutive digits (no wrap-around, so
/// `89012345` is not flagged as sequential), then a 2- or 4-digit group
/// repeated to fill the PIN.
PinWeakness? validateCiePin(String pin) {
  if (pin.length != 4 && pin.length != AppConstants.ciePinLength) {
    return PinWeakness.tooShort;
  }
  if (!RegExp(r'^[0-9]+$').hasMatch(pin)) {
    return PinWeakness.notNumeric;
  }
  if (pin.split('').every((c) => c == pin[0])) {
    return PinWeakness.allSameDigit;
  }

  final digits = pin.codeUnits;
  var ascending = true;
  var descending = true;
  for (var i = 1; i < digits.length; i++) {
    final step = digits[i] - digits[i - 1];
    if (step != 1) ascending = false;
    if (step != -1) descending = false;
  }
  if (ascending || descending) {
    return PinWeakness.sequential;
  }

  final half = pin.length ~/ 2;
  final quarter = pin.length ~/ 4;
  final pairGroup = pin.substring(0, quarter);
  final fourGroup = pin.substring(0, half);
  if (List.filled(4, pairGroup).join() == pin ||
      List.filled(2, fourGroup).join() == pin) {
    return PinWeakness.repeatedPair;
  }

  return null;
}
