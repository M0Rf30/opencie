// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import 'package:pointycastle/asn1.dart';
import '../asn1/der.dart';
import '../asn1/oids.dart';
import '../crl/crl_models.dart';
import '../ocsp/ocsp_codec.dart';
import '../ocsp/ocsp_models.dart';
import 'cades_models.dart';
import 'cades_parser.dart';

/// Upgrades a CAdES-BES signature to CAdES-C-LT by adding certificate-values
/// and revocation-values unsigned attributes.
class CadesLtUpgrader {
  CadesLtUpgrader();

  /// Upgrades a CAdES-BES (or BES + signature-time-stamp) signature to CAdES-C-LT
  /// by adding certificate-values and revocation-values unsigned attributes.
  ///
  /// The [material] should contain the full chain (excluding the root, which
  /// MAY be omitted per ETSI) and matching CRL/OCSP responses.
  ///
  /// Cert de-duplication: any cert in `material.certificates` that is already
  /// present in SignedData.certificates is omitted from certificate-values
  /// (per ETSI recommendation — avoid duplication).
  Uint8List upgrade(Uint8List cadesBes, ValidationMaterial material) {
    final sd = CadesSignedData.parse(cadesBes);

    // De-duplicate certs: filter material.certificates to those NOT in sd.embeddedCertificates
    final dedupedCerts = <Uint8List>[];
    for (final cert in material.certificates) {
      bool found = false;
      for (final embedded in sd.embeddedCertificates) {
        if (bytesEqual(cert, embedded)) {
          found = true;
          break;
        }
      }
      if (!found) {
        dedupedCerts.add(cert);
      }
    }

    // Check if we have any validation material after dedup
    if (dedupedCerts.isEmpty &&
        material.crls.isEmpty &&
        material.ocspResponses.isEmpty) {
      throw CadesException('no validation material to embed');
    }

    // Build certificate-values attribute if we have certs
    if (dedupedCerts.isNotEmpty) {
      final certValuesAttrValueSetDer = _buildCertificateValuesAttribute(
        dedupedCerts,
      );
      sd.setUnsignedAttribute(Oid.certificateValues, certValuesAttrValueSetDer);
    }

    // Build revocation-values attribute if we have CRLs or OCSP responses
    if (material.crls.isNotEmpty || material.ocspResponses.isNotEmpty) {
      final revocationValuesAttrValueSetDer = _buildRevocationValuesAttribute(
        material.crls,
        material.ocspResponses,
      );
      sd.setUnsignedAttribute(
        Oid.revocationValues,
        revocationValuesAttrValueSetDer,
      );
    }

    return sd.encode();
  }

  /// Builds the certificate-values attribute value (SET OF containing a SEQUENCE OF Certificate).
  /// Per ETSI EN 319 122-1, the AttributeValue is a SET OF, where each element is
  /// a SEQUENCE OF Certificate.
  Uint8List _buildCertificateValuesAttribute(List<Uint8List> certs) {
    // Build SEQUENCE OF Certificate
    final certSequence = ASN1Sequence();
    for (final certDer in certs) {
      final cert = derDecode(certDer);
      certSequence.add(cert);
    }

    // Wrap in SET OF (AttributeValue is a SET OF)
    final attrValueSet = ASN1Set();
    attrValueSet.add(certSequence);

    return derEncode(attrValueSet);
  }

  /// Builds the revocation-values attribute value.
  /// RevocationValues ::= SEQUENCE {
  ///   crlVals     [0] SEQUENCE OF CertificateList OPTIONAL,
  ///   ocspVals    [1] SEQUENCE OF BasicOCSPResponse OPTIONAL,
  ///   otherRevVals[2] OtherRevVals OPTIONAL
  /// }
  /// The AttributeValue is a SET OF containing this SEQUENCE.
  Uint8List _buildRevocationValuesAttribute(
    List<CrlData> crls,
    List<OcspResponse> ocspResponses,
  ) {
    final revocationValuesSeq = ASN1Sequence();

    // Build crlVals [0] SEQUENCE OF CertificateList if we have CRLs
    if (crls.isNotEmpty) {
      final crlValsSeq = ASN1Sequence();
      for (final crl in crls) {
        final crlObj = derDecode(crl.rawCrl);
        crlValsSeq.add(crlObj);
      }
      // Wrap as [0] EXPLICIT
      revocationValuesSeq.add(explicit(0, crlValsSeq));
    }

    // Build ocspVals [1] SEQUENCE OF BasicOCSPResponse if we have OCSP responses
    if (ocspResponses.isNotEmpty) {
      final ocspValsSeq = ASN1Sequence();
      for (final ocspResp in ocspResponses) {
        if (ocspResp.rawResponse != null) {
          final basicOcspResponseDer = extractBasicOcspResponse(
            ocspResp.rawResponse!,
          );
          if (basicOcspResponseDer != null) {
            final basicOcspObj = derDecode(basicOcspResponseDer);
            ocspValsSeq.add(basicOcspObj);
          }
        }
      }
      // Only add if we successfully extracted at least one BasicOCSPResponse
      if (ocspValsSeq.elements != null && ocspValsSeq.elements!.isNotEmpty) {
        // Wrap as [1] EXPLICIT
        revocationValuesSeq.add(explicit(1, ocspValsSeq));
      }
    }

    // Wrap in SET OF (AttributeValue is a SET OF)
    final attrValueSet = ASN1Set();
    attrValueSet.add(revocationValuesSeq);

    return derEncode(attrValueSet);
  }
}
