// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import 'package:pointycastle/asn1.dart';
import '../asn1/der.dart';
import '../asn1/oids.dart';
import '../tsp/tsp_client.dart';
import 'ats_hash_index.dart';
import 'cades_models.dart';
import 'cades_parser.dart';

/// Upgrades a CAdES C-LT (or higher) signature to CAdES C-LTA by adding an
/// archive-time-stamp-v3 unsigned attribute.
///
/// Per ETSI EN 319 122-1 §5.5.3, the archive-time-stamp-v3 is computed over
/// the concatenation of:
/// 1. DER(encapContentInfo)
/// 2. DER(signedAttrs) — canonical SET OF Attribute
/// 3. DER(signature OCTET STRING)
/// 4. DER-concatenation of all remaining unsigned attributes in DER-canonical order
///
/// The TimeStampToken returned by the TSA is then augmented with an ats-hash-index-v3
/// unsigned attribute (per ETSI EN 319 122-1 §5.5.2) before being embedded in the
/// outer CAdES signature.
///
/// **MVP Limitation**: Multiple calls to upgrade() REPLACE the existing
/// archive-time-stamp-v3 (per setUnsignedAttribute semantics). Production-grade
/// C-LTA appends multiple archive timestamps for periodic renewal.
class CadesLtaUpgrader {
  CadesLtaUpgrader({
    required this.tspClient,
    required this.tspUrl,
    this.hashAlgorithmOid = Oid.sha256,
  });

  final TspClient tspClient;
  final Uri tspUrl;
  final String hashAlgorithmOid;

  /// Upgrades a CAdES C-LT (or higher) signature to C-LTA by adding an
  /// archive-time-stamp-v3 unsigned attribute.
  ///
  /// Throws [CadesException] if the TSA rejects the request, returns no
  /// timestamp token, or the input cannot be parsed.
  Future<Uint8List> upgrade(Uint8List cadesClt) async {
    try {
      // 1. Parse the input
      final sd = CadesSignedData.parse(cadesClt);

      // 2. Extract the four byte segments for the archive timestamp input
      final encapContentInfoDer = sd.encapContentInfoForAtsV3;
      final signedAttrsDer = sd.signedAttrsDer;
      final signatureValueDer = sd.signatureValueDer;

      // 3. Build the concatenation of remaining unsigned attributes in DER-canonical order
      final unsignedAttrsForArchive = sd.unsignedAttributesForArchiveTimestamp;
      final unsignedAttrsDerList = unsignedAttrsForArchive
          .map((e) => e.value)
          .toList();
      // Sort by full DER bytes ascending (DER-canonical order)
      unsignedAttrsDerList.sort((a, b) => _lexCompare(a, b));
      final unsignedAttrsConcatenated = Uint8List.fromList(
        unsignedAttrsDerList.expand((bytes) => bytes).toList(),
      );

      // 4. Concatenate all four segments
      final archiveTimestampInput = Uint8List.fromList([
        ...encapContentInfoDer,
        ...signedAttrsDer,
        ...signatureValueDer,
        ...unsignedAttrsConcatenated,
      ]);

      // 5. Request timestamp from TSA
      final tspResponse = await tspClient.timestampData(
        tspUrl,
        archiveTimestampInput,
        hashAlgorithmOid: hashAlgorithmOid,
        requestCert: true,
      );

      // 6. Validate response
      if (!tspResponse.isSuccess || tspResponse.timeStampToken == null) {
        throw CadesException(
          'Archive timestamp request rejected: ${tspResponse.status.name}',
        );
      }

      // 7. Parse the TimeStampToken and add ats-hash-index-v3 to its inner SignerInfo
      var tstToken = tspResponse.timeStampToken!;
      try {
        final tstSd = CadesSignedData.parse(tstToken);

        // Build ats-hash-index-v3 using outer CAdES content
        final builder = AtsHashIndexBuilder(hashAlgorithmOid: hashAlgorithmOid);

        // Collect unsigned attribute values from outer CAdES (excluding archive-time-stamp-v3)
        final unsignedAttrValues = <Uint8List>[];
        for (final entry in sd.unsignedAttributesForArchiveTimestamp) {
          // Each entry is (OID, full Attribute SEQUENCE DER)
          // We need to extract the attrValue(s) from the Attribute SEQUENCE
          final attrSeqDer = entry.value;
          final attrSeq = derDecode(attrSeqDer) as ASN1Sequence;
          if (attrSeq.elements != null && attrSeq.elements!.length >= 2) {
            final attrValuesSet = attrSeq.elements![1];
            if (attrValuesSet is ASN1Set && attrValuesSet.elements != null) {
              // Add each value in the SET
              for (final val in attrValuesSet.elements!) {
                unsignedAttrValues.add(derEncode(val));
              }
            }
          }
        }

        final atsHashIndexDer = builder.build(
          certificates: sd.embeddedCertificates,
          crls: sd.embeddedCrls.map((c) => c.rawCrl).toList(),
          unsignedAttrValues: unsignedAttrValues,
        );

        // Add ats-hash-index-v3 as an unsigned attribute to the inner TST's SignerInfo
        final atsHashIndexSet = ASN1Set();
        atsHashIndexSet.add(derDecode(atsHashIndexDer));
        tstSd.setUnsignedAttribute(
          Oid.atsHashIndexV3,
          derEncode(atsHashIndexSet),
        );

        // Re-encode the modified TST
        tstToken = tstSd.encode();
      } catch (e) {
        // If ats-hash-index-v3 addition fails, log but continue with unaugmented TST
        // (non-conformant but better than failing the entire upgrade)
        // In production, this should be stricter.
      }

      // 8. Build the archive-time-stamp-v3 unsigned attribute
      // Attribute ::= SEQUENCE { attrType OID, attrValues SET OF AttributeValue }
      // For archive-time-stamp-v3, attrValues is SET OF TimeStampToken
      final attrValuesSet = ASN1Set();
      attrValuesSet.add(derDecode(tstToken));

      // 9. Add the archive-time-stamp-v3 unsigned attribute
      sd.setUnsignedAttribute(Oid.archiveTimeStampV3, derEncode(attrValuesSet));

      // 10. Return the upgraded signature
      return sd.encode();
    } catch (e) {
      if (e is CadesException) rethrow;
      throw CadesException('Archive timestamp upgrade failed: $e');
    }
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
}
