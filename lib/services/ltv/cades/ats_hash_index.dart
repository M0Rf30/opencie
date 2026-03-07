// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import 'package:pointycastle/asn1.dart';
import '../asn1/der.dart';
import '../asn1/oids.dart';

/// Builds an ats-hash-index-v3 ASN.1 structure per ETSI EN 319 122-1 §5.5.2.2.
/// Returns the DER-encoded SEQUENCE.
///
/// ATSHashIndexV3 ::= SEQUENCE {
///   hashIndAlgorithm     AlgorithmIdentifier DEFAULT { algorithm id-sha256 },
///   certificatesHashIndex SEQUENCE OF OCTET STRING,
///   crlsHashIndex        SEQUENCE OF OCTET STRING,
///   unsignedAttrValuesHashIndex SEQUENCE OF OCTET STRING
/// }
class AtsHashIndexBuilder {
  AtsHashIndexBuilder({this.hashAlgorithmOid = Oid.sha256});
  final String hashAlgorithmOid;

  /// [certificates]: each element is the full Certificate TLV bytes from SignedData.certificates.
  /// [crls]: each element is the full TLV bytes (CertificateList for CRL, BasicOCSPResponse-wrapped for OCSP).
  ///   Per the spec these come from RevocationInfoChoices, so include both kinds.
  /// [unsignedAttrValues]: each element is the full TLV bytes of one attrValue (NOT the whole Attribute SEQ).
  Uint8List build({
    required List<Uint8List> certificates,
    required List<Uint8List> crls,
    required List<Uint8List> unsignedAttrValues,
  }) {
    final certHashes = certificates.map((c) => hashOf(c, hashAlgorithmOid)).toList();
    final crlHashes = crls.map((c) => hashOf(c, hashAlgorithmOid)).toList();
    final attrHashes = unsignedAttrValues.map((a) => hashOf(a, hashAlgorithmOid)).toList();

    // Sort each list by byte order, ascending
    certHashes.sort((a, b) => _lexCompare(a, b));
    crlHashes.sort((a, b) => _lexCompare(a, b));
    attrHashes.sort((a, b) => _lexCompare(a, b));

    // Build SEQUENCE OF OCTET STRING for each list
    final certSeq = _seqOfOctetStrings(certHashes);
    final crlSeq = _seqOfOctetStrings(crlHashes);
    final attrSeq = _seqOfOctetStrings(attrHashes);

    // Build outer SEQUENCE
    final outer = ASN1Sequence();
    // hashIndAlgorithm: include explicitly even if SHA-256 (DEFAULT) for clarity
    // Most implementations emit it.
    outer.add(algorithmIdentifier(hashAlgorithmOid));
    outer.add(certSeq);
    outer.add(crlSeq);
    outer.add(attrSeq);
    return derEncode(outer);
  }

  /// Lexicographic comparison of byte arrays (unsigned).
  static int _lexCompare(Uint8List a, Uint8List b) {
    final minLen = a.length < b.length ? a.length : b.length;
    for (int i = 0; i < minLen; i++) {
      final cmp = (a[i] & 0xFF).compareTo(b[i] & 0xFF);
      if (cmp != 0) return cmp;
    }
    return a.length.compareTo(b.length);
  }

  /// Build a SEQUENCE OF OCTET STRING from a list of byte arrays.
  static ASN1Sequence _seqOfOctetStrings(List<Uint8List> hashes) {
    final seq = ASN1Sequence();
    for (final hash in hashes) {
      seq.add(ASN1OctetString(octets: hash));
    }
    return seq;
  }
}
