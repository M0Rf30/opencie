// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

/// RFC 6960 OCSPResponseStatus values.
enum OcspResponseStatus {
  successful(0),
  malformedRequest(1),
  internalError(2),
  tryLater(3),
  sigRequired(5),
  unauthorized(6);

  const OcspResponseStatus(this.value);
  final int value;

  static OcspResponseStatus fromValue(int v) =>
      OcspResponseStatus.values.firstWhere(
        (s) => s.value == v,
        orElse: () => OcspResponseStatus.internalError,
      );
}

/// CertStatus from RFC 6960:
/// CertStatus ::= CHOICE {
///   good                [0] IMPLICIT NULL,
///   revoked             [1] IMPLICIT RevokedInfo,
///   unknown             [2] IMPLICIT UnknownInfo
/// }
enum OcspCertStatus { good, revoked, unknown }

/// Identifies a certificate in an OCSP request/response.
/// CertID ::= SEQUENCE {
///   hashAlgorithm   AlgorithmIdentifier,
///   issuerNameHash  OCTET STRING,
///   issuerKeyHash   OCTET STRING,
///   serialNumber    INTEGER
/// }
class OcspCertId {
  const OcspCertId({
    required this.hashAlgorithmOid,
    required this.issuerNameHash,
    required this.issuerKeyHash,
    required this.serialNumber,
  });

  final String hashAlgorithmOid;
  final Uint8List issuerNameHash;
  final Uint8List issuerKeyHash;
  final BigInt serialNumber;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OcspCertId &&
          runtimeType == other.runtimeType &&
          hashAlgorithmOid == other.hashAlgorithmOid &&
          _bytesEqual(issuerNameHash, other.issuerNameHash) &&
          _bytesEqual(issuerKeyHash, other.issuerKeyHash) &&
          serialNumber == other.serialNumber;

  @override
  int get hashCode =>
      hashAlgorithmOid.hashCode ^
      issuerNameHash.hashCode ^
      issuerKeyHash.hashCode ^
      serialNumber.hashCode;

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Single response from an OCSP response.
class OcspSingleResponse {
  const OcspSingleResponse({
    required this.certId,
    required this.status,
    required this.thisUpdate,
    this.nextUpdate,
    this.revocationTime,
    this.revocationReason,
  });

  final OcspCertId certId;
  final OcspCertStatus status;
  final DateTime thisUpdate;
  final DateTime? nextUpdate;
  final DateTime? revocationTime; // present iff status==revoked
  final int? revocationReason; // CRLReason, optional
}

/// OCSP response from a responder.
class OcspResponse {
  const OcspResponse({
    required this.status,
    this.rawResponse,
    this.responses = const [],
    this.respNonce,
    this.producedAt,
    this.embeddedCerts = const [],
  });

  final OcspResponseStatus status;
  final Uint8List? rawResponse; // the full DER (for embedding in PAdES DSS / CAdES)
  final List<OcspSingleResponse> responses;
  final Uint8List? respNonce; // OCSP nonce extension if echoed
  final DateTime? producedAt;
  final List<Uint8List> embeddedCerts; // BasicOCSPResponse.certs (DER each)

  bool get isSuccessful => status == OcspResponseStatus.successful;
}
