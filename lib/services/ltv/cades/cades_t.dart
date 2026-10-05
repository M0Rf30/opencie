// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';

import '../asn1/der.dart';
import '../asn1/oids.dart';
import '../tsp/tsp_client.dart';
import 'cades_models.dart';
import 'cades_parser.dart';

/// Upgrades a CAdES-B-B signature to CAdES-B-T by adding a
/// `signature-time-stamp` (id-aa-signatureTimeStampToken) unsigned attribute.
///
/// Per ETSI EN 319 122-1 §5.3 / RFC 5126 §6.1.1 the time-stamp's message
/// imprint is the hash of the *value* of the SignerInfo `signature` field
/// (the content octets of its OCTET STRING). B-LT and B-LTA presuppose B-T,
/// so run this before `CadesLtUpgrader` / `CadesLtaUpgrader`.
///
/// Idempotent: a signature that already carries a signature-time-stamp is
/// returned unchanged (no TSA request).
class CadesTUpgrader {
  CadesTUpgrader({
    required this.tspClient,
    required this.tspUrl,
    this.hashAlgorithmOid = Oid.sha256,
  });

  final TspClient tspClient;
  final Uri tspUrl;
  final String hashAlgorithmOid;

  /// Throws [CadesException] if the input cannot be parsed or the TSA
  /// rejects the request / returns no token.
  Future<Uint8List> upgrade(Uint8List cadesBes) async {
    try {
      final sd = CadesSignedData.parse(cadesBes);
      if (sd.getUnsignedAttribute(Oid.signatureTimeStampToken) != null) {
        return cadesBes;
      }

      final response = await tspClient.timestampData(
        tspUrl,
        sd.signatureValueBytes,
        hashAlgorithmOid: hashAlgorithmOid,
        requestCert: true,
      );
      final token = response.timeStampToken;
      if (!response.isSuccess || token == null || token.isEmpty) {
        throw CadesException(
          'Signature timestamp request rejected: ${response.status.name}',
        );
      }

      // Attribute ::= SEQUENCE { attrType, attrValues SET OF TimeStampToken }
      final values = ASN1Set()..add(derDecode(token));
      sd.setUnsignedAttribute(Oid.signatureTimeStampToken, derEncode(values));
      return sd.encode();
    } catch (e) {
      if (e is CadesException) rethrow;
      throw CadesException('Signature timestamp upgrade failed: $e');
    }
  }
}
