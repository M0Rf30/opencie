// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import 'package:pointycastle/asn1.dart';
import '../asn1/der.dart';
import '../asn1/oids.dart';
import '../tsp/tsp_client.dart';
import 'ats_hash_index.dart';
import 'cades_models.dart';
import 'cades_parser.dart';

/// Supplies certificates and revocation evidence for the TSAs that signed the
/// archive time-stamps already present in a signature. Receives every
/// certificate found in those tokens; may return null when nothing could be
/// obtained.
typedef PreviousTimestampValidation =
    Future<ValidationMaterial?> Function(List<Uint8List> previousTsaCerts);

/// Upgrades a CAdES C-LT (or higher) signature to CAdES C-LTA by adding an
/// archive-time-stamp-v3 unsigned attribute (ETSI EN 319 122-1 §5.5.3).
///
/// The message imprint of the time-stamp is the hash of the concatenation of:
/// 1. `SignedData.encapContentInfo.eContentType`, as encoded (TLV);
/// 2. the hash of the signed data (content octets of `eContent`; for a
///    detached signature the `message-digest` signed attribute, provided it
///    uses the same algorithm as the time-stamp);
/// 3. `version, sid, digestAlgorithm, signedAttrs, signatureAlgorithm,
///    signature` of the SignerInfo, as encoded (TLVs, signedAttrs keeping its
///    `[0]` tag);
/// 4. the DER `ATSHashIndexV3` that is also placed, as an
///    ats-hash-index-v3 unsigned attribute, in the returned TimeStampToken
///    (§5.5.2).
///
/// `ATSHashIndexV3` hashes (all with the time-stamp's hash algorithm):
/// each `CertificateChoices` of `SignedData.certificates`, each
/// `RevocationInfoChoice` of `SignedData.crls`, and for every
/// `AttributeValue` of every unsigned attribute the `attrType` TLV
/// concatenated with the value TLV. Earlier archive-time-stamp-v3 attributes
/// are unsigned attributes too, so every new stamp covers the previous ones.
///
/// Calling [upgrade] on a signature that already has archive time-stamps
/// APPENDS another attribute (renewal); existing ones are never replaced or
/// altered. Before that, validation material for the TSAs of the previous
/// stamps is added to `SignedData.certificates` / `SignedData.crls` when
/// [previousTimestampValidation] provides it (§5.5.3: the root SignedData is
/// extended before a new archive-time-stamp-v3 as long as no ATSv2 or older
/// archive form is present).
class CadesLtaUpgrader {
  CadesLtaUpgrader({
    required this.tspClient,
    required this.tspUrl,
    this.hashAlgorithmOid = Oid.sha256,
    this.policyOid,
    this.previousTimestampValidation,
  });

  final TspClient tspClient;
  final Uri tspUrl;
  final String hashAlgorithmOid;

  /// Optional TSA policy OID (RFC 3161 `reqPolicy`); blank means none.
  final String? policyOid;

  /// Validation material for the TSAs of already present archive
  /// time-stamps. Only consulted when there are any.
  final PreviousTimestampValidation? previousTimestampValidation;

  /// Throws [CadesException] if the TSA rejects the request, returns no
  /// timestamp token, or the input cannot be parsed.
  Future<Uint8List> upgrade(Uint8List cadesClt) async {
    try {
      final sd = CadesSignedData.parse(cadesClt);

      // 1. Renewal: validation data for the previous stamps' TSAs goes into
      //    the root SignedData before the new stamp is requested.
      final previous = sd.archiveTimeStampTokens;
      if (previous.isNotEmpty) {
        await _addPreviousChainValidation(sd, previous);
      }

      // 2. ATSHashIndexV3 over everything present right now.
      final atsHashIndexDer =
          AtsHashIndexBuilder(hashAlgorithmOid: hashAlgorithmOid).build(
            certificates: sd.signedDataCertificateTlvs,
            crls: sd.signedDataCrlTlvs,
            unsignedAttrValues: [
              for (final p in sd.unsignedAttributeParts)
                for (final v in p.valueTlvs)
                  Uint8List.fromList([...p.typeTlv, ...v]),
            ],
          );

      // 3. Message imprint input (§5.5.3 items 1-4).
      final archiveTimestampInput = Uint8List.fromList([
        ...sd.eContentTypeTlv,
        ..._signedDataHash(sd),
        ...sd.signerInfoFieldsForAtsV3,
        ...atsHashIndexDer,
      ]);

      // 4. Request the time-stamp. TspClient verifies that the token echoes
      //    our hash and hash algorithm, so the token's messageImprint
      //    algorithm equals hashAlgorithmOid, and so does hashIndAlgorithm.
      final tspResponse = await tspClient.timestampData(
        tspUrl,
        archiveTimestampInput,
        hashAlgorithmOid: hashAlgorithmOid,
        requestCert: true,
        policyOid: policyOid,
      );
      if (!tspResponse.isSuccess || tspResponse.timeStampToken == null) {
        throw CadesException(
          'Archive timestamp request rejected: ${tspResponse.status.name}',
        );
      }
      // §5.5.2: hashIndAlgorithm must be the algorithm of the time-stamp's
      // message imprint. TspClient already rejects a mismatching reply; keep
      // the invariant explicit here because the hash index is built before
      // the request.
      if (tspResponse.messageImprintHashOid != hashAlgorithmOid) {
        throw CadesException(
          'Archive timestamp uses ${tspResponse.messageImprintHashOid}, '
          'expected $hashAlgorithmOid',
        );
      }

      // 5. The ats-hash-index-v3 travels as an unsigned attribute of the
      //    token's own SignerInfo.
      Uint8List tstToken;
      try {
        final tstSd = CadesSignedData.parse(tspResponse.timeStampToken!);
        tstSd.setUnsignedAttribute(
          Oid.atsHashIndexV3,
          derEncode(ASN1Set()..add(derDecode(atsHashIndexDer))),
        );
        tstToken = tstSd.encode();
      } catch (e) {
        // An archive timestamp without its hash index protects nothing.
        throw CadesException(
          'Failed to build ats-hash-index-v3 for archive timestamp: $e',
        );
      }

      // 6. Append (never replace) the archive-time-stamp-v3 attribute.
      sd.appendUnsignedAttribute(
        Oid.archiveTimeStampV3,
        derEncode(ASN1Set()..add(derDecode(tstToken))),
      );
      return sd.encode();
    } catch (e) {
      if (e is CadesException) rethrow;
      throw CadesException('Archive timestamp upgrade failed: $e');
    }
  }

  /// §5.5.3 item 2: hash of the signed data with [hashAlgorithmOid].
  Uint8List _signedDataHash(CadesSignedData sd) {
    final content = sd.eContentOctets;
    if (content != null) return hashOf(content, hashAlgorithmOid);

    // Detached: the data is not available, but the signature commits to its
    // hash in the message-digest attribute.
    final md = sd.messageDigestAttributeValue;
    if (md != null && sd.signerDigestAlgorithmOid == hashAlgorithmOid) {
      return md;
    }
    throw CadesException(
      'detached signature: the hash of the signed data is only known with '
      '${sd.signerDigestAlgorithmOid}, not $hashAlgorithmOid',
    );
  }

  Future<void> _addPreviousChainValidation(
    CadesSignedData sd,
    List<Uint8List> previousTokens,
  ) async {
    final provider = previousTimestampValidation;
    if (provider == null) return;

    final certs = <Uint8List>[];
    for (final token in previousTokens) {
      try {
        for (final c in CadesSignedData.parse(token).embeddedCertificates) {
          if (!certs.any((o) => bytesEqual(o, c))) certs.add(c);
        }
      } catch (_) {
        // Intentional: an unreadable previous token just contributes nothing.
      }
    }
    if (certs.isEmpty) return;

    ValidationMaterial? material;
    try {
      material = await provider(certs);
    } catch (_) {
      // Intentional: extra validation data is best effort; the new stamp is
      // still worth adding without it.
      return;
    }
    if (material == null) return;

    for (final c in material.certificates) {
      sd.addSignedDataCertificate(c);
    }
    for (final crl in material.crls) {
      sd.addSignedDataCrl(crl.rawCrl);
    }
    for (final ocsp in material.ocspResponses) {
      final raw = ocsp.rawResponse;
      if (raw != null) sd.addSignedDataOcspResponse(raw);
    }
  }
}
