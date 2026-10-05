// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import 'package:pointycastle/asn1.dart';
import '../asn1/der.dart';
import '../asn1/oids.dart';
import '../crl/crl_models.dart';
import 'cades_models.dart';

/// Parses and manipulates a CAdES SignedData blob (CMS ContentInfo).
///
/// Strategy: Use byte-range preservation for robustness.
/// - Parse the top-level structure to locate SignerInfo[0].
/// - For SignerInfo[0], record byte ranges of (a) prefix (before unsignedAttrs)
///   and (b) unsignedAttrs section (or absence).
/// - On encode: emit prefix-bytes ++ new-unsigned-attrs-bytes, re-wrap as SEQUENCE,
///   then re-emit SignerInfos SET, then re-emit SignedData SEQUENCE, then ContentInfo.
/// This avoids full round-trip re-encoding which can shift canonical forms.
class CadesSignedData {
  late ASN1Sequence _contentInfo;
  late ASN1Sequence _signedData;
  late ASN1Set _signerInfos;
  late ASN1Sequence _signerInfo0;

  // Unsigned attributes of SignerInfo[0] in FILE ORDER. Attributes read from
  // the input keep their original encoding (see [_UnsignedAttr.attrDer]).
  late List<_UnsignedAttr> _unsignedAttrs;

  // Set when the input's unsignedAttrs could not be split into Attributes.
  // Reading still works, but [encode] refuses to rewrite such a signature
  // (it would silently drop attributes).
  bool _unsignedAttrsUnreadable = false;

  // Embedded certificates from SignedData.certificates [0]
  late List<Uint8List> _embeddedCerts;

  /// Parses a CAdES `.p7m` (or detached CMS) DER blob.
  /// Throws CadesException on parse failure.
  factory CadesSignedData.parse(Uint8List der) {
    final instance = CadesSignedData._();
    instance._parse(der);
    return instance;
  }

  CadesSignedData._();

  /// Parses valueBytes of an IMPLICIT context-specific tag as a list of TLVs.
  /// Handles both true IMPLICIT (raw TLVs) and EXPLICIT-wrapped (single SET containing TLVs).
  /// This compatibility shim allows both old test fixtures (EXPLICIT shape) and real CIE
  /// input (true IMPLICIT shape) to parse cleanly.
  List<ASN1Object> _parseImplicitSetOf(Uint8List valueBytes) {
    if (valueBytes.isEmpty) return [];
    final p = ASN1Parser(valueBytes);
    final raw = <ASN1Object>[];
    while (p.hasNext()) {
      raw.add(p.nextObject());
    }
    // Compatibility: if value bytes happened to contain a single SET (some encoders
    // emit [0] EXPLICIT { SET OF Attribute } instead of true [0] IMPLICIT SET OF Attribute),
    // unwrap it.
    if (raw.length == 1 && raw[0] is ASN1Set) {
      return (raw[0] as ASN1Set).elements ?? [];
    }
    return raw;
  }

  void _parse(Uint8List der) {
    try {
      // Parse ContentInfo
      _contentInfo = derDecode(der) as ASN1Sequence;
      if (_contentInfo.elements == null || _contentInfo.elements!.length < 2) {
        throw CadesException('Invalid ContentInfo structure');
      }

      // Verify contentType is signed-data
      final contentTypeObj = _contentInfo.elements![0];
      if (contentTypeObj is! ASN1ObjectIdentifier) {
        throw CadesException('ContentInfo.contentType is not an OID');
      }

      // Parse SignedData from [0] EXPLICIT
      final contentObj = _contentInfo.elements![1];
      if (contentObj.tag != 0xA0) {
        throw CadesException('ContentInfo.content is not [0] EXPLICIT');
      }

      _signedData =
          derDecode(contentObj.valueBytes ?? Uint8List(0)) as ASN1Sequence;
      if (_signedData.elements == null || _signedData.elements!.isEmpty) {
        throw CadesException('Invalid SignedData structure');
      }

      // Parse SignerInfos (last element of SignedData)
      final lastElem = _signedData.elements!.last;
      if (lastElem is! ASN1Set) {
        throw CadesException('SignedData.signerInfos is not a SET');
      }

      _signerInfos = lastElem;
      if (_signerInfos.elements == null || _signerInfos.elements!.isEmpty) {
        throw CadesException('SignerInfos is empty');
      }

      // Parse SignerInfo[0]
      if (_signerInfos.elements!.length != 1) {
        throw CadesException(
          'Multi-signer CMS not supported (got ${_signerInfos.elements!.length} SignerInfos)',
        );
      }
      _signerInfo0 = _signerInfos.elements![0] as ASN1Sequence;
      if (_signerInfo0.elements == null || _signerInfo0.elements!.isEmpty) {
        throw CadesException('SignerInfo[0] is empty');
      }

      // Extract embedded certificates from SignedData.certificates [0] if present
      _embeddedCerts = [];
      for (final elem in _signedData.elements!) {
        if (elem.tag == 0xA0) {
          // [0] IMPLICIT CertificateSet
          try {
            final certs = _parseImplicitSetOf(elem.valueBytes ?? Uint8List(0));
            for (final certElem in certs) {
              // Filter for SEQUENCE-tagged elements (X.509 Certificate is 30 LL ...)
              if (certElem is ASN1Sequence) {
                // Check if this SEQUENCE is a container (has multiple elements that are SEQUENCEs)
                // or a single certificate. If it's a container, extract the certificates.
                if (certElem.elements != null &&
                    certElem.elements!.isNotEmpty &&
                    certElem.elements!.every((e) => e is ASN1Sequence)) {
                  // Likely a container SEQUENCE, extract each element
                  for (final innerCert in certElem.elements!) {
                    if (innerCert is ASN1Sequence) {
                      _embeddedCerts.add(derEncode(innerCert));
                    }
                  }
                } else {
                  // Single certificate SEQUENCE
                  _embeddedCerts.add(derEncode(certElem));
                }
              }
            }
          } catch (e) {
            // ignore cert parsing errors
          }
          break;
        }
      }

      // Parse unsigned attributes from SignerInfo[0]
      _parseSignerInfo0UnsignedAttrs();
    } catch (e) {
      if (e is CadesException) rethrow;
      throw CadesException('Parse error: $e');
    }
  }

  void _parseSignerInfo0UnsignedAttrs() {
    _unsignedAttrs = [];
    _unsignedAttrsUnreadable = false;

    // SignerInfo structure:
    // SEQUENCE {
    //   version INTEGER,
    //   sid SignerIdentifier,
    //   digestAlgorithm AlgorithmIdentifier,
    //   signedAttrs [0] IMPLICIT OPTIONAL,
    //   signatureAlgorithm AlgorithmIdentifier,
    //   signature OCTET STRING,
    //   unsignedAttrs [1] IMPLICIT OPTIONAL
    // }

    if (_signerInfo0.elements == null) {
      return;
    }

    // Find unsignedAttrs [1] IMPLICIT
    for (final elem in _signerInfo0.elements!) {
      if (elem.tag != 0xA1) continue;
      try {
        final content = elem.valueBytes ?? Uint8List(0);
        List<Uint8List> attrs;
        try {
          attrs = _splitTlvs(content);
          // Tolerate the legacy EXPLICIT shape [1] { SET OF Attribute } that
          // older fixtures use: a lone SET (0x31) child is unwrapped.
          if (attrs.length == 1 && attrs.first.first == 0x31) {
            attrs = _splitTlvs(derDecode(attrs.first).valueBytes!);
          }
        } on CadesException {
          // Indefinite-length BER: no byte-exact slice is available, fall
          // back to re-encoding each Attribute.
          attrs = _parseImplicitSetOf(content).map(derEncode).toList();
        }
        for (final raw in attrs) {
          final attr = derDecode(raw);
          if (attr is! ASN1Sequence ||
              attr.elements == null ||
              attr.elements!.length < 2) {
            throw CadesException('malformed unsigned attribute');
          }
          final oidObj = attr.elements![0];
          final values = attr.elements![1];
          if (oidObj is! ASN1ObjectIdentifier || values is! ASN1Set) {
            throw CadesException('malformed unsigned attribute');
          }
          _unsignedAttrs.add(
            _UnsignedAttr(
              oidObj.objectIdentifierAsString ?? '',
              derEncode(values),
              raw,
            ),
          );
        }
      } catch (_) {
        // Intentional: leave the signature readable but refuse to rewrite
        // it ([encode]) rather than silently dropping attributes.
        _unsignedAttrs = [];
        _unsignedAttrsUnreadable = true;
      }
      break;
    }
  }

  /// Splits [data] into its top-level TLVs, returning each one's exact bytes.
  /// Throws [CadesException] on truncation or indefinite lengths.
  static List<Uint8List> _splitTlvs(Uint8List data) {
    final out = <Uint8List>[];
    var pos = 0;
    while (pos < data.length) {
      final start = pos;
      if ((data[pos++] & 0x1F) == 0x1F) {
        // High-tag-number form: base-128 digits until the continuation bit
        // clears.
        while (pos < data.length && (data[pos] & 0x80) != 0) {
          pos++;
        }
        pos++;
      }
      if (pos >= data.length) throw CadesException('truncated TLV');
      final first = data[pos++];
      int length;
      if (first < 0x80) {
        length = first;
      } else if (first == 0x80) {
        throw CadesException('indefinite length is not supported here');
      } else {
        final n = first & 0x7F;
        if (n > 4 || pos + n > data.length) {
          throw CadesException('bad TLV length');
        }
        length = 0;
        for (var i = 0; i < n; i++) {
          length = (length << 8) | data[pos++];
        }
      }
      final end = pos + length;
      if (end > data.length) throw CadesException('truncated TLV');
      out.add(Uint8List.fromList(data.sublist(start, end)));
      pos = end;
    }
    return out;
  }

  /// Returns the DER bytes of the SignedData ContentInfo.
  Uint8List encode() {
    try {
      if (_unsignedAttrsUnreadable) {
        throw CadesException(
          'unsignedAttrs could not be parsed; refusing to rewrite',
        );
      }
      // Rebuild SignerInfo[0] with updated unsignedAttrs
      final newSignerInfo0Der = _rebuildSignerInfo0();

      // Rebuild SignerInfos SET with the new SignerInfo[0]
      final newSignerInfosSet = ASN1Set();
      newSignerInfosSet.add(derDecode(newSignerInfo0Der));
      // Add any other signers (if present)
      if (_signerInfos.elements != null && _signerInfos.elements!.length > 1) {
        for (int i = 1; i < _signerInfos.elements!.length; i++) {
          newSignerInfosSet.add(_signerInfos.elements![i]);
        }
      }

      // Rebuild SignedData with the new SignerInfos
      final newSignedDataSeq = ASN1Sequence();
      if (_signedData.elements != null) {
        for (int i = 0; i < _signedData.elements!.length; i++) {
          final elem = _signedData.elements![i];
          if (elem is ASN1Set && i == _signedData.elements!.length - 1) {
            // This is the SignerInfos SET, replace it
            newSignedDataSeq.add(newSignerInfosSet);
          } else {
            // Keep other elements as-is
            newSignedDataSeq.add(elem);
          }
        }
      }

      // Rebuild ContentInfo
      final newContentInfo = ASN1Sequence();
      if (_contentInfo.elements != null && _contentInfo.elements!.isNotEmpty) {
        newContentInfo.add(_contentInfo.elements![0]); // contentType OID
        // Wrap SignedData in [0] EXPLICIT
        newContentInfo.add(explicit(0, newSignedDataSeq));
      }

      return derEncode(newContentInfo);
    } catch (e) {
      throw CadesException('Encode error: $e');
    }
  }

  Uint8List _rebuildSignerInfo0() {
    // Rebuild SignerInfo[0] with updated unsignedAttrs
    final newSignerInfo0 = ASN1Sequence();

    // Add all prefix elements
    if (_signerInfo0.elements != null) {
      for (final elem in _signerInfo0.elements!) {
        if (elem.tag == 0xA1) {
          // Stop before unsignedAttrs
          break;
        }
        newSignerInfo0.add(elem);
      }
    }

    // Unsigned attributes: RFC 5652 §5.3 types them as a plain
    // `SET SIZE (1..MAX) OF Attribute` and, unlike signedAttrs (§5.4, DER
    // because the signature covers them), does not require DER ordering.
    // ETSI EN 319 122-1 clause 5.5.3 (archive-time-stamp-v3) goes further:
    // "The augmentation shall preserve the binary encoding of already
    // present unsigned attributes and any component contributing to the
    // archive time-stamp's message imprint computation input."
    // Re-sorting would move already-present attributes (and, for attributes
    // read from BER input, re-encode them), so existing Attributes are
    // emitted verbatim, in their original order, and new ones are appended.
    // The ats-hash-index-v3 is order independent (its hash lists are sorted,
    // see AtsHashIndexBuilder), so appending cannot invalidate it.
    // [1] IMPLICIT: the Attributes follow the tag/length directly, with no
    // inner SET header.
    if (_unsignedAttrs.isNotEmpty) {
      final content = BytesBuilder();
      for (final a in _unsignedAttrs) {
        content.add(a.attrDer);
      }
      newSignerInfo0.add(_implicitConstructed(1, content.toBytes()));
    }

    return derEncode(newSignerInfo0);
  }

  /// Builds a context-specific constructed object `[n]` around [content]
  /// (already-encoded TLVs) without adding an inner header.
  ASN1Object _implicitConstructed(int tagNumber, Uint8List content) {
    // Context-specific constructed: 0xA0 | tagNumber
    final tag = 0xA0 | tagNumber;
    final result = BytesBuilder();
    result.addByte(tag);
    _encodeLength(result, content.length);
    result.add(content);
    return ASN1Parser(result.toBytes()).nextObject();
  }

  void _encodeLength(BytesBuilder builder, int length) {
    if (length < 128) {
      builder.addByte(length);
    } else {
      final bytes = <int>[];
      var len = length;
      while (len > 0) {
        bytes.insert(0, len & 0xFF);
        len >>= 8;
      }
      builder.addByte(0x80 | bytes.length);
      builder.add(bytes);
    }
  }

  /// Sets an unsigned attribute on the FIRST signer. An existing attribute
  /// with the same OID is REPLACED in place (its position is kept); a new
  /// one is APPENDED after all existing attributes.
  void setUnsignedAttribute(String oid, Uint8List attributeValueSetDer) {
    final attr = ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromIdentifierString(oid))
      ..add(derDecode(attributeValueSetDer));
    final entry = _UnsignedAttr(oid, attributeValueSetDer, derEncode(attr));
    final i = _unsignedAttrs.indexWhere((a) => a.oid == oid);
    if (i >= 0) {
      _unsignedAttrs[i] = entry;
    } else {
      _unsignedAttrs.add(entry);
    }
  }

  /// Returns the DER of an existing unsigned attr value (the SET OF AttributeValue),
  /// or null if not present.
  Uint8List? getUnsignedAttribute(String oid) {
    for (final a in _unsignedAttrs) {
      if (a.oid == oid) return a.valueSetDer;
    }
    return null;
  }

  /// Certificates carried inside the signature-time-stamp token(s) (the
  /// TSA's signing certificate and any chain the TSA included), de-duplicated.
  /// Empty when there is no such attribute or a token cannot be parsed.
  List<Uint8List> get signatureTimeStampCertificates {
    final out = <Uint8List>[];
    final set = getUnsignedAttribute(Oid.signatureTimeStampToken);
    if (set == null) return out;
    try {
      final values = derDecode(set);
      if (values is! ASN1Set) return out;
      for (final token in values.elements ?? const <ASN1Object>[]) {
        final certs = CadesSignedData.parse(
          derEncode(token),
        ).embeddedCertificates;
        for (final c in certs) {
          if (!out.any((o) => bytesEqual(o, c))) out.add(c);
        }
      }
    } catch (_) {
      // Intentional: an unreadable token simply yields no certificates.
    }
    return out;
  }

  /// All certificates currently embedded in SignedData.certificates [0].
  List<Uint8List> get embeddedCertificates => _embeddedCerts;

  /// CRLs extracted from the revocationValues unsigned attribute (id-aa-ets-revocationValues).
  ///
  /// RevocationValues ::= SEQUENCE {
  ///   crlVals   [0] SEQUENCE OF CertificateList OPTIONAL,
  ///   ocspVals  [1] SEQUENCE OF BasicOCSPResponse OPTIONAL,
  ///   ...
  /// }
  ///
  /// Returns an empty list if the attribute is absent or unparseable.
  List<CrlData> get embeddedCrls {
    final attrValueSetDer = getUnsignedAttribute(Oid.revocationValues);
    if (attrValueSetDer == null) return const [];

    try {
      // attrValueSetDer is the SET OF AttributeValue DER
      final attrValueSet = derDecode(attrValueSetDer);
      if (attrValueSet is! ASN1Set ||
          attrValueSet.elements == null ||
          attrValueSet.elements!.isEmpty) {
        return const [];
      }
      // First element of the SET is the RevocationValues SEQUENCE
      final revValSeq = attrValueSet.elements![0];
      if (revValSeq is! ASN1Sequence || revValSeq.elements == null) {
        return const [];
      }

      final result = <CrlData>[];
      for (final elem in revValSeq.elements!) {
        // crlVals is [0] EXPLICIT SEQUENCE OF CertificateList
        if (elem.tag == 0xA0) {
          final crlValsBytes = elem.valueBytes ?? Uint8List(0);
          final p = ASN1Parser(crlValsBytes);
          while (p.hasNext()) {
            try {
              final crlSeq = p.nextObject();
              if (crlSeq is ASN1Sequence) {
                final rawCrl = derEncode(crlSeq);
                // Extract thisUpdate from TBSCertList (index 0 of CertificateList).
                // CertificateList ::= SEQUENCE { tbsCertList TBSCertList, ... }
                // TBSCertList ::= SEQUENCE { version [0] OPTIONAL, signature, issuer, thisUpdate, ... }
                DateTime thisUpdate = DateTime.now();
                Uint8List issuerDn = Uint8List(0);
                try {
                  if (crlSeq.elements != null && crlSeq.elements!.isNotEmpty) {
                    final tbs = crlSeq.elements![0];
                    if (tbs is ASN1Sequence && tbs.elements != null) {
                      // Find issuer and thisUpdate: skip optional version [0]
                      int idx = 0;
                      if (tbs.elements![idx].tag == 0xA0) idx++; // skip version
                      idx++; // skip signature AlgorithmIdentifier
                      // issuer Name
                      if (idx < tbs.elements!.length &&
                          tbs.elements![idx] is ASN1Sequence) {
                        issuerDn = derEncode(tbs.elements![idx]);
                        idx++;
                      }
                      // thisUpdate (UTCTime or GeneralizedTime)
                      if (idx < tbs.elements!.length) {
                        final tu = tbs.elements![idx];
                        if (tu is ASN1UtcTime) {
                          thisUpdate = tu.time ?? DateTime.now();
                        } else if (tu is ASN1GeneralizedTime) {
                          thisUpdate = tu.dateTimeValue ?? DateTime.now();
                        }
                      }
                    }
                  }
                } catch (_) {
                  // metadata extraction failed; use defaults
                }
                result.add(
                  CrlData(
                    rawCrl: rawCrl,
                    issuerDn: issuerDn,
                    thisUpdate: thisUpdate,
                  ),
                );
              }
            } catch (_) {
              // skip unparseable CRL entry
            }
          }
          break; // crlVals is [0], stop after first match
        }
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  /// Returns the DER encoding of the EncapsulatedContentInfo SEQUENCE.
  /// This is the third element of SignedData (after version and digestAlgorithms).
  Uint8List get encapContentInfoDer {
    if (_signedData.elements == null || _signedData.elements!.length < 3) {
      throw CadesException('SignedData missing encapContentInfo');
    }
    // encapContentInfo is typically at index 2
    final encapContentInfo = _signedData.elements![2];
    return derEncode(encapContentInfo);
  }

  /// Builds the encapContentInfo portion of the archive-time-stamp-v3 input
  /// per ETSI EN 319 122-1 §5.5.3: concatenation of eContentType TLV
  /// and (if present) [0] EXPLICIT eContent TLV. Does NOT include the
  /// outer EncapsulatedContentInfo SEQUENCE wrapper.
  Uint8List get encapContentInfoForAtsV3 {
    if (_signedData.elements == null || _signedData.elements!.length < 3) {
      throw CadesException('SignedData missing encapContentInfo');
    }
    final eci = _signedData.elements![2] as ASN1Sequence;
    final out = BytesBuilder();
    // eContentType (always present)
    if (eci.elements != null && eci.elements!.isNotEmpty) {
      out.add(derEncode(eci.elements![0]));
    }
    // [0] EXPLICIT eContent (optional; tag 0xA0)
    if ((eci.elements?.length ?? 0) > 1) {
      final eContent = eci.elements![1];
      if (eContent.tag == 0xA0) {
        out.add(derEncode(eContent));
      }
    }
    return out.toBytes();
  }

  /// Returns the DER encoding of the signedAttrs as a canonical SET OF Attribute (tag 0x31).
  /// SignerInfo stores signedAttrs as [0] IMPLICIT, so we extract the inner elements
  /// and re-encode them as a canonical SET OF with tag 0x31.
  Uint8List get signedAttrsDer {
    if (_signerInfo0.elements == null) {
      throw CadesException('SignerInfo[0] is empty');
    }

    // Find signedAttrs [0] IMPLICIT
    for (final elem in _signerInfo0.elements!) {
      if (elem.tag == 0xA0) {
        // Found signedAttrs [0]
        try {
          final attrs = _parseImplicitSetOf(elem.valueBytes ?? Uint8List(0));
          // Build canonical 0x31 SET in DER order
          return derEncode(derSortedSet(attrs));
        } catch (e) {
          throw CadesException('Failed to parse signedAttrs: $e');
        }
      }
    }

    throw CadesException('SignerInfo[0] missing signedAttrs [0]');
  }

  /// Returns the DER encoding of the signature OCTET STRING (full TLV with tag 0x04).
  /// This is the signature field in SignerInfo[0].
  Uint8List get signatureValueDer {
    if (_signerInfo0.elements == null) {
      throw CadesException('SignerInfo[0] is empty');
    }

    // SignerInfo structure:
    // SEQUENCE {
    //   version INTEGER,
    //   sid SignerIdentifier,
    //   digestAlgorithm AlgorithmIdentifier,
    //   signedAttrs [0] IMPLICIT OPTIONAL,
    //   signatureAlgorithm AlgorithmIdentifier,
    //   signature OCTET STRING,
    //   unsignedAttrs [1] IMPLICIT OPTIONAL
    // }

    // Find the signature OCTET STRING (tag 0x04)
    for (final elem in _signerInfo0.elements!) {
      if (elem is ASN1OctetString) {
        return derEncode(elem);
      }
    }

    throw CadesException('SignerInfo[0] missing signature OCTET STRING');
  }

  /// The content octets of the SignerInfo `signature` OCTET STRING (no tag /
  /// length). This is the value that a CAdES signature-time-stamp
  /// (id-aa-signatureTimeStampToken) imprints (ETSI EN 319 122-1 §5.3).
  Uint8List get signatureValueBytes {
    if (_signerInfo0.elements == null) {
      throw CadesException('SignerInfo[0] is empty');
    }
    for (final elem in _signerInfo0.elements!) {
      if (elem is ASN1OctetString) {
        final v = elem.octets ?? elem.valueBytes;
        if (v == null) break;
        return v;
      }
    }
    throw CadesException('SignerInfo[0] missing signature OCTET STRING');
  }

  /// Returns a list of (OID, full Attribute SEQUENCE DER) pairs for all unsigned attributes
  /// except the archive-time-stamp-v3. Each entry is the complete SEQUENCE TLV,
  /// suitable for sorting and concatenation.
  List<MapEntry<String, Uint8List>> get unsignedAttributesForArchiveTimestamp {
    return [
      for (final a in _unsignedAttrs)
        if (a.oid != Oid.archiveTimeStampV3) MapEntry(a.oid, a.attrDer),
    ];
  }
}

class _UnsignedAttr {
  _UnsignedAttr(this.oid, this.valueSetDer, this.attrDer);

  final String oid;

  /// DER of the `SET OF AttributeValue`.
  final Uint8List valueSetDer;

  /// The complete Attribute TLV: verbatim input bytes for attributes that
  /// were already present, freshly DER-encoded for new ones.
  final Uint8List attrDer;
}
