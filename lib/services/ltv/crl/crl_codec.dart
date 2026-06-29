// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';

import '../asn1/der.dart';
import 'crl_models.dart';

/// Parses a CRL from DER bytes. Returns null on any parse failure (defensive).
/// Extracts issuer DN, thisUpdate, and optional nextUpdate.
CrlData? parseCrl(Uint8List rawDer, {String? sourceUrl}) {
  try {
    // Parse outer SEQUENCE (CertificateList)
    final certListObj = derDecode(rawDer);
    if (certListObj is! ASN1Sequence ||
        certListObj.elements == null ||
        certListObj.elements!.isEmpty) {
      return null;
    }

    // First element is TBSCertList
    final tbsCertListObj = certListObj.elements![0];
    if (tbsCertListObj is! ASN1Sequence ||
        tbsCertListObj.elements == null ||
        tbsCertListObj.elements!.isEmpty) {
      return null;
    }

    final tbsElements = tbsCertListObj.elements!;
    int idx = 0;

    // Optional: version INTEGER (only if first element is INTEGER)
    if (idx < tbsElements.length && tbsElements[idx] is ASN1Integer) {
      idx++;
    }

    // signature AlgorithmIdentifier (skip)
    if (idx >= tbsElements.length) {
      return null;
    }
    idx++;

    // issuer Name (SEQUENCE)
    if (idx >= tbsElements.length) {
      return null;
    }
    final issuerObj = tbsElements[idx];
    if (issuerObj is! ASN1Sequence) {
      return null;
    }
    final issuerDn = derEncode(issuerObj);
    idx++;

    // thisUpdate Time (CHOICE: UTCTime or GeneralizedTime)
    if (idx >= tbsElements.length) {
      return null;
    }
    final thisUpdateObj = tbsElements[idx];
    final thisUpdate = _parseTime(thisUpdateObj);
    if (thisUpdate == null) {
      return null;
    }
    idx++;

    // nextUpdate Time OPTIONAL
    DateTime? nextUpdate;
    if (idx < tbsElements.length) {
      final nextUpdateObj = tbsElements[idx];
      // Check if it's a Time (UTCTime or GeneralizedTime), not another structure
      if (nextUpdateObj is ASN1UtcTime ||
          nextUpdateObj is ASN1GeneralizedTime) {
        nextUpdate = _parseTime(nextUpdateObj);
      }
    }

    return CrlData(
      rawCrl: rawDer,
      issuerDn: issuerDn,
      thisUpdate: thisUpdate,
      nextUpdate: nextUpdate,
      sourceUrl: sourceUrl,
    );
  } catch (e) {
    return null;
  }
}

/// Parse a Time CHOICE (UTCTime or GeneralizedTime) to DateTime.
DateTime? _parseTime(ASN1Object obj) {
  try {
    if (obj is ASN1UtcTime) {
      return obj.time;
    } else if (obj is ASN1GeneralizedTime) {
      return obj.dateTimeValue;
    }
  } catch (e) {
    // ignore
  }
  return null;
}

/// Detects PEM-armored CRL and converts to DER. Returns input unchanged if not PEM.
/// Returns null if PEM detection succeeded but base64 decode failed.
Uint8List? pemOrDerToDer(Uint8List input) {
  try {
    final str = String.fromCharCodes(input);

    // Check for PEM armor
    if (str.contains('-----BEGIN X509 CRL-----') ||
        str.contains('-----BEGIN CRL-----')) {
      // Extract base64 body
      final lines = str.split('\n');
      final bodyLines = <String>[];
      bool inBody = false;

      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.contains('-----BEGIN')) {
          inBody = true;
          continue;
        }
        if (trimmed.contains('-----END')) {
          break;
        }
        if (inBody && trimmed.isNotEmpty) {
          bodyLines.add(trimmed);
        }
      }

      if (bodyLines.isEmpty) {
        return null;
      }

      final base64Body = bodyLines.join('');
      try {
        return base64Decode(base64Body);
      } catch (e) {
        return null;
      }
    }

    // Not PEM, return as-is
    return input;
  } catch (e) {
    // If string conversion fails, assume it's binary DER
    return input;
  }
}
