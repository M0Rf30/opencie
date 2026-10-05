// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import 'package:pointycastle/asn1.dart';
import '../asn1/der.dart';
import '../asn1/oids.dart';

/// Builds an ats-hash-index-v3 attribute value per ETSI EN 319 122-1 §5.5.2.
/// Returns the DER-encoded SEQUENCE.
///
/// ```
/// ATSHashIndexV3 ::= SEQUENCE {
///   hashIndAlgorithm            AlgorithmIdentifier,
///   certificatesHashIndex       SEQUENCE OF OCTET STRING,
///   crlsHashIndex               SEQUENCE OF OCTET STRING,
///   unsignedAttrValuesHashIndex SEQUENCE OF OCTET STRING }
/// ```
///
/// `hashIndAlgorithm` is always written explicitly: the ASN.1 of EN 319
/// 122-1 (V1.1.1 and V1.3.1, Annex D) has no DEFAULT for it. It MUST be the
/// algorithm of the archive time-stamp's message imprint, so the caller
/// passes the same [hashAlgorithmOid] to both.
class AtsHashIndexBuilder {
  AtsHashIndexBuilder({this.hashAlgorithmOid = Oid.sha256});
  final String hashAlgorithmOid;

  /// [certificates]: one entry per `CertificateChoices` of
  /// `SignedData.certificates`, as the complete TLV.
  ///
  /// [crls]: one entry per `RevocationInfoChoice` of `SignedData.crls`
  /// (CertificateList or `[1]` OtherRevocationInfoFormat), complete TLVs.
  /// Revocation values living in a `revocation-values` unsigned attribute
  /// are NOT part of this list; they are covered through
  /// [unsignedAttrValues].
  ///
  /// [unsignedAttrValues]: one entry per `AttributeValue` of every
  /// Attribute in `SignerInfo.unsignedAttrs`: the `attrType` TLV
  /// concatenated with that value's TLV (§5.5.2, unsignedAttrValuesHashIndex).
  ///
  /// Each list is emitted in ascending hash order. The standard does not
  /// prescribe an order (SEQUENCE OF), sorting just makes the output
  /// deterministic.
  Uint8List build({
    required List<Uint8List> certificates,
    required List<Uint8List> crls,
    required List<Uint8List> unsignedAttrValues,
  }) {
    List<Uint8List> hashes(List<Uint8List> items) =>
        items.map((c) => hashOf(c, hashAlgorithmOid)).toList()
          ..sort(_lexCompare);

    final outer = ASN1Sequence()
      ..add(algorithmIdentifier(hashAlgorithmOid))
      ..add(_seqOfOctetStrings(hashes(certificates)))
      ..add(_seqOfOctetStrings(hashes(crls)))
      ..add(_seqOfOctetStrings(hashes(unsignedAttrValues)));
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
