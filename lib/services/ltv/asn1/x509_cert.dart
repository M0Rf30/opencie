// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'oids.dart';

/// Parsed fields from a DER-encoded X.509 v3 certificate.
///
/// Only the fields needed for the CIE management UI are extracted.
/// Parsing is best-effort: fields that cannot be decoded are left null.
class X509CertInfo {
  const X509CertInfo({
    this.subject,
    this.issuer,
    this.serial,
    this.notBefore,
    this.notAfter,
    this.keyAlgorithm,
  });

  /// Subject distinguished name as a human-readable string (e.g. "CN=Mario Rossi, C=IT").
  final String? subject;

  /// Issuer distinguished name.
  final String? issuer;

  /// Serial number as an uppercase hex string.
  final String? serial;

  /// Certificate validity start.
  final DateTime? notBefore;

  /// Certificate validity end (expiry date).
  final DateTime? notAfter;

  /// Key algorithm OID resolved to a short name (e.g. "RSA", "EC").
  final String? keyAlgorithm;

  /// Parse a DER-encoded X.509 certificate.
  ///
  /// Returns null if the top-level structure is unrecognisable.
  static X509CertInfo? fromDer(Uint8List der) {
    try {
      return _parse(der);
    } catch (e, _) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Minimal hand-rolled BER/DER TLV walker — tolerates unknown tags.
  // ---------------------------------------------------------------------------

  /// Returns (tag, valueOffset, valueLength) for the TLV at [pos] in [data].
  static (int tag, int valOff, int valLen) _tlv(Uint8List data, int pos) {
    final tag = data[pos];
    int p = pos + 1;
    int len = data[p++];
    if (len == 0x80) {
      // indefinite — not expected in DER but handle gracefully
      throw FormatException('indefinite length not supported');
    }
    if (len > 0x80) {
      final nBytes = len & 0x7F;
      len = 0;
      for (int i = 0; i < nBytes; i++) {
        len = (len << 8) | data[p++];
      }
    }
    return (tag, p, len);
  }

  /// Returns the value bytes of the TLV at [pos].
  static Uint8List _val(Uint8List data, int pos) {
    final (_, valOff, valLen) = _tlv(data, pos);
    return Uint8List.sublistView(data, valOff, valOff + valLen);
  }

  /// Returns the total encoded byte length of the TLV at [pos].
  static int _totalLen(Uint8List data, int pos) {
    final (_, valOff, valLen) = _tlv(data, pos);
    return (valOff - pos) + valLen;
  }

  /// Iterates over the children of a SEQUENCE/SET/context TLV at [pos],
  /// returning (childPos, childTag) pairs.
  static Iterable<(int pos, int tag)> _children(
      Uint8List data, int seqPos) sync* {
    final (_, valOff, valLen) = _tlv(data, seqPos);
    int p = valOff;
    final end = valOff + valLen;
    while (p < end) {
      yield (p, data[p]);
      p += _totalLen(data, p);
    }
  }

  static X509CertInfo _parse(Uint8List der) {
    // Certificate  ::=  SEQUENCE { tbsCertificate, signatureAlgorithm, signature }
    // We only need tbsCertificate (first child of the outer SEQUENCE).
    final outerChildren = _children(der, 0).toList();
    final tbsPos = outerChildren[0].$1; // TBSCertificate SEQUENCE

    // TBSCertificate children in order:
    //   [0] version (optional, EXPLICIT)
    //   serialNumber INTEGER
    //   signature AlgorithmIdentifier
    //   issuer Name
    //   validity Validity
    //   subject Name
    //   subjectPublicKeyInfo SubjectPublicKeyInfo
    //   [1] issuerUniqueID (optional)
    //   [2] subjectUniqueID (optional)
    //   [3] extensions (optional)
    final tbsChildren = _children(der, tbsPos).toList();

    int idx = 0;

    // Skip optional [0] EXPLICIT version (tag 0xA0)
    if (tbsChildren[idx].$2 == 0xA0) idx++;

    // serialNumber INTEGER (tag 0x02)
    final serialPos = tbsChildren[idx++].$1;
    final serialBytes = _val(der, serialPos);
    final serialHex = serialBytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();

    // signature AlgorithmIdentifier (skip)
    idx++;

    // issuer Name (SEQUENCE, tag 0x30)
    final issuerPos = tbsChildren[idx++].$1;
    final issuerStr = _parseName(der, issuerPos);

    // validity Validity (SEQUENCE, tag 0x30)
    final validityPos = tbsChildren[idx++].$1;
    final validityChildren = _children(der, validityPos).toList();
    final notBefore = _parseTime(der, validityChildren[0].$1);
    final notAfter = _parseTime(der, validityChildren[1].$1);

    // subject Name (SEQUENCE, tag 0x30)
    final subjectPos = tbsChildren[idx++].$1;
    final subjectStr = _parseName(der, subjectPos);

    // subjectPublicKeyInfo (SEQUENCE, tag 0x30)
    final spkiPos = tbsChildren[idx].$1;
    final spkiChildren = _children(der, spkiPos).toList();
    final algSeqPos = spkiChildren[0].$1;
    final algChildren = _children(der, algSeqPos).toList();
    final algOidBytes = _val(der, algChildren[0].$1);
    final algOid = _decodeOid(algOidBytes);
    final keyAlg = _resolveKeyAlg(algOid);

    return X509CertInfo(
      subject: subjectStr,
      issuer: issuerStr,
      serial: serialHex,
      notBefore: notBefore,
      notAfter: notAfter,
      keyAlgorithm: keyAlg,
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static String _parseName(Uint8List data, int namePos) {
    final parts = <String>[];
    for (final (rdnPos, _) in _children(data, namePos)) {
      // RDN is a SET; each element is a SEQUENCE { OID, value }
      for (final (atvPos, _) in _children(data, rdnPos)) {
        final atvChildren = _children(data, atvPos).toList();
        if (atvChildren.length < 2) continue;
        final oidBytes = _val(data, atvChildren[0].$1);
        final oid = _decodeOid(oidBytes);
        final label = _resolveAttrType(oid);
        final value = _stringValue(data, atvChildren[1].$1);
        parts.add('$label=$value');
      }
    }
    return parts.join(', ');
  }

  static String _stringValue(Uint8List data, int pos) {
    final bytes = _val(data, pos);
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }

  static DateTime? _parseTime(Uint8List data, int pos) {
    try {
      final tag = data[pos];
      final bytes = _val(data, pos);
      final s = ascii.decode(bytes);
      if (tag == 0x17) {
        // UTCTime: YYMMDDHHMMSS[Z]
        final y2 = int.parse(s.substring(0, 2));
        final century = y2 > 75 ? '19' : '20';
        final full = '$century${s.substring(0, 6)}T${s.substring(6)}';
        // Remove trailing Z for DateTime.parse, add back as UTC
        final clean = full.endsWith('Z') ? full : '${full}Z';
        return DateTime.tryParse(clean);
      } else if (tag == 0x18) {
        // GeneralizedTime: YYYYMMDDHHMMSS[Z]
        final clean = '${s.substring(0, 8)}T${s.substring(8)}';
        final withZ = clean.endsWith('Z') ? clean : '${clean}Z';
        return DateTime.tryParse(withZ);
      }
    } catch (_) {}
    return null;
  }

  /// Decode a DER OID value bytes to dotted string.
  static String _decodeOid(Uint8List bytes) {
    if (bytes.isEmpty) return '';
    final parts = <int>[];
    parts.add(bytes[0] ~/ 40);
    parts.add(bytes[0] % 40);
    int val = 0;
    for (int i = 1; i < bytes.length; i++) {
      val = (val << 7) | (bytes[i] & 0x7F);
      if ((bytes[i] & 0x80) == 0) {
        parts.add(val);
        val = 0;
      }
    }
    return parts.join('.');
  }

  static String _resolveKeyAlg(String oid) {
    switch (oid) {
      case Oid.rsaEncryption:
        return 'RSA';
      case Oid.ecPublicKey:
        return 'EC';
      case '1.2.840.10040.4.1': // id-dsa
        return 'DSA';
      default:
        return oid;
    }
  }

  static String _resolveAttrType(String oid) {
    switch (oid) {
      case '2.5.4.3':
        return 'CN';
      case '2.5.4.6':
        return 'C';
      case '2.5.4.7':
        return 'L';
      case '2.5.4.8':
        return 'ST';
      case '2.5.4.10':
        return 'O';
      case '2.5.4.11':
        return 'OU';
      case '1.2.840.113549.1.9.1':
        return 'emailAddress';
      case '2.5.4.5':
        return 'serialNumber';
      default:
        return oid;
    }
  }
}
