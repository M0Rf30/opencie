// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

/// Parsed metadata from a CRL, plus the original DER bytes.
class CrlData {
  CrlData({
    required this.rawCrl, // Original DER bytes — preserved for DSS embedding
    required this.issuerDn, // Subject DN of the issuer (DER bytes of the Name SEQUENCE)
    required this.thisUpdate, // When this CRL was issued
    this.nextUpdate, // When the next CRL is expected (optional per RFC 5280)
    this.sourceUrl, // URL it was fetched from (informational)
  });

  final Uint8List rawCrl;
  final Uint8List issuerDn;
  final DateTime thisUpdate;
  final DateTime? nextUpdate;
  final String? sourceUrl;

  /// True if `nextUpdate` is in the future. Null nextUpdate is treated as expired (conservative).
  bool isFresh(DateTime now) {
    final n = nextUpdate;
    if (n == null) return false;
    return n.isAfter(now);
  }
}

/// Exception thrown by CRL client on transport/protocol errors.
class CrlException implements Exception {
  CrlException(this.message);
  final String message;

  @override
  String toString() => 'CrlException: $message';
}
