// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

/// RFC 3161 PKIStatus values.
enum TspStatus {
  granted(0),
  grantedWithMods(1),
  rejection(2),
  waiting(3),
  revocationWarning(4),
  revocationNotification(5);

  const TspStatus(this.value);
  final int value;

  static TspStatus fromValue(int v) =>
      TspStatus.values.firstWhere((s) => s.value == v, orElse: () => TspStatus.rejection);
}

/// RFC 3161 TimeStampReq data.
class TspRequest {
  const TspRequest({
    required this.messageImprintHash,
    required this.hashAlgorithmOid,
    this.nonce,
    this.reqCertReq = false,
    this.policyOid,
  });

  /// Hash of the data to be timestamped (e.g., 32 bytes for SHA-256).
  final Uint8List messageImprintHash;

  /// OID of the hash algorithm (e.g., Oid.sha256).
  final String hashAlgorithmOid;

  /// Optional nonce (8-16 random bytes).
  final Uint8List? nonce;

  /// Request TSA certificate in response.
  final bool reqCertReq;

  /// Optional TSA policy OID.
  final String? policyOid;
}

/// RFC 3161 TimeStampResp data.
class TspResponse {
  const TspResponse({
    required this.status,
    this.statusStrings = const [],
    this.failInfo,
    this.timeStampToken,
    this.genTime,
    this.messageImprintHashOid,
    this.messageImprintHash,
    this.respNonce,
  });

  /// Status code (granted, rejection, etc.).
  final TspStatus status;

  /// Optional human-readable status strings.
  final List<String> statusStrings;

  /// Optional PKIFailureInfo bits.
  final int? failInfo;

  /// DER-encoded TimeStampToken (CMS SignedData) if status is granted.
  final Uint8List? timeStampToken;

  /// Parsed genTime from TSTInfo (if available).
  final DateTime? genTime;

  /// Parsed messageImprint hash algorithm OID from TSTInfo.
  final String? messageImprintHashOid;

  /// Parsed messageImprint hash from TSTInfo.
  final Uint8List? messageImprintHash;

  /// Parsed nonce from TSTInfo (if present).
  final Uint8List? respNonce;

  /// Convenience: true if status is granted or grantedWithMods.
  bool get isSuccess => status == TspStatus.granted || status == TspStatus.grantedWithMods;
}
