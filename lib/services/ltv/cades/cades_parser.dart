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
  
  // Parsed unsigned attributes (OID -> attribute value SET DER)
  late Map<String, Uint8List> _unsignedAttrs;
  
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

      _signedData = derDecode(contentObj.valueBytes ?? Uint8List(0)) as ASN1Sequence;
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
     throw CadesException('Multi-signer CMS not supported (got ${_signerInfos.elements!.length} SignerInfos)');
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
                 if (certElem.elements != null && certElem.elements!.isNotEmpty &&
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
    _unsignedAttrs = {};

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
    for (int i = 0; i < _signerInfo0.elements!.length; i++) {
      final elem = _signerInfo0.elements![i];
      if (elem.tag == 0xA1) {
        // Found unsignedAttrs [1]
        // Parse as SET OF Attribute
        try {
          final unsignedAttrsSet = derDecode(elem.valueBytes ?? Uint8List(0));
          if (unsignedAttrsSet is ASN1Set && unsignedAttrsSet.elements != null) {
            for (final attrElem in unsignedAttrsSet.elements!) {
              if (attrElem is ASN1Sequence && attrElem.elements != null && attrElem.elements!.length >= 2) {
                final oidObj = attrElem.elements![0];
                if (oidObj is ASN1ObjectIdentifier) {
                  final oid = oidObj.objectIdentifierAsString ?? '';
                  // attrValues is a SET OF (second element)
                  final attrValuesObj = attrElem.elements![1];
                  if (attrValuesObj is ASN1Set) {
                    _unsignedAttrs[oid] = derEncode(attrValuesObj);
                  }
                }
              }
            }
          }
        } catch (e) {
          // ignore parsing errors
        }
        break;
      }
    }

  }

  /// Returns the DER bytes of the SignedData ContentInfo.
  Uint8List encode() {
    try {
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

    // Add new unsignedAttrs if not empty
    if (_unsignedAttrs.isNotEmpty) {
      final unsignedAttrsSet = ASN1Set();
      for (final oid in _unsignedAttrs.keys) {
        final attrValueSetDer = _unsignedAttrs[oid]!;
        final attr = ASN1Sequence();
        attr.add(ASN1ObjectIdentifier.fromIdentifierString(oid));
        // attrValues is already a SET, parse and add it
        final attrValuesSet = derDecode(attrValueSetDer);
        attr.add(attrValuesSet);
        unsignedAttrsSet.add(attr);
      }
      // Wrap as [1] IMPLICIT
      newSignerInfo0.add(_wrapImplicit(1, unsignedAttrsSet));
    }

    return derEncode(newSignerInfo0);
  }

  /// Wraps an ASN1Set with an implicit context-specific tag [n].
  /// For [1] IMPLICIT, the tag is 0xA1 (constructed, context-specific).
  ASN1Object _wrapImplicit(int tagNumber, ASN1Set innerSet) {
    final encoded = derEncode(innerSet);
    // Context-specific constructed: 0xA0 | tagNumber
    final tag = 0xA0 | tagNumber;
    final result = BytesBuilder();
    result.addByte(tag);
    _encodeLength(result, encoded.length);
    result.add(encoded);
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

  /// Adds an unsigned attribute to the FIRST signer.
  /// If an attribute with the same OID already exists, REPLACES it.
  void setUnsignedAttribute(String oid, Uint8List attributeValueSetDer) {
    _unsignedAttrs[oid] = attributeValueSetDer;
  }

  /// Returns the DER of an existing unsigned attr value (the SET OF AttributeValue),
  /// or null if not present.
  Uint8List? getUnsignedAttribute(String oid) {
    return _unsignedAttrs[oid];
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
    final attrValueSetDer = _unsignedAttrs[Oid.revocationValues];
    if (attrValueSetDer == null) return const [];

    try {
      // attrValueSetDer is the SET OF AttributeValue DER
      final attrValueSet = derDecode(attrValueSetDer);
      if (attrValueSet is! ASN1Set || attrValueSet.elements == null || attrValueSet.elements!.isEmpty) {
        return const [];
      }
      // First element of the SET is the RevocationValues SEQUENCE
      final revValSeq = attrValueSet.elements![0];
      if (revValSeq is! ASN1Sequence || revValSeq.elements == null) return const [];

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
                      if (idx < tbs.elements!.length && tbs.elements![idx] is ASN1Sequence) {
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
                result.add(CrlData(
                  rawCrl: rawCrl,
                  issuerDn: issuerDn,
                  thisUpdate: thisUpdate,
                ));
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

   /// Returns a list of (OID, full Attribute SEQUENCE DER) pairs for all unsigned attributes
   /// except the archive-time-stamp-v3. Each entry is the complete SEQUENCE TLV,
   /// suitable for sorting and concatenation.
   List<MapEntry<String, Uint8List>> get unsignedAttributesForArchiveTimestamp {
     final result = <MapEntry<String, Uint8List>>[];

     if (_signerInfo0.elements == null) {
       return result;
     }

     // Find unsignedAttrs [1] IMPLICIT
     for (final elem in _signerInfo0.elements!) {
       if (elem.tag == 0xA1) {
         // Found unsignedAttrs [1]
         try {
           final attrs = _parseImplicitSetOf(elem.valueBytes ?? Uint8List(0));
           for (final attrElem in attrs) {
             if (attrElem is ASN1Sequence && attrElem.elements != null && attrElem.elements!.length >= 2) {
               final oidObj = attrElem.elements![0];
               if (oidObj is ASN1ObjectIdentifier) {
                 final oid = oidObj.objectIdentifierAsString ?? '';
                 // Skip archive-time-stamp-v3 itself
                 if (oid == Oid.archiveTimeStampV3) {
                   continue;
                 }
                 // Store the full Attribute SEQUENCE TLV
                 result.add(MapEntry(oid, derEncode(attrElem)));
               }
             }
           }
         } catch (e) {
           // ignore parsing errors
         }
         break;
       }
     }

     return result;
   }
}
