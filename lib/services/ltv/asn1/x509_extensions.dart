// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';

import 'oids.dart';

class X509Extension {
  final String oid;
  final bool critical;
  final Uint8List value; // raw OCTET STRING contents

  const X509Extension({
    required this.oid,
    required this.critical,
    required this.value,
  });
}

class X509Extensions {
  /// Returns the DER-encoded TBSCertificate extensions, parsed.
  /// Input: full X.509 cert as DER bytes (a `Certificate` SEQUENCE).
  static List<X509Extension> parseFromCertificate(Uint8List certDer) {
    try {
      final cert = ASN1Parser(certDer).nextObject();
      if (cert is! ASN1Sequence ||
          cert.elements == null ||
          cert.elements!.isEmpty) {
        return [];
      }

      // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
      final tbsCert = cert.elements![0];
      if (tbsCert is! ASN1Sequence || tbsCert.elements == null) {
        return [];
      }

      // TBSCertificate ::= SEQUENCE {
      //   version [0] EXPLICIT Version DEFAULT v1,
      //   serialNumber INTEGER,
      //   signature AlgorithmIdentifier,
      //   issuer Name,
      //   validity Validity,
      //   subject Name,
      //   subjectPublicKeyInfo SubjectPublicKeyInfo,
      //   issuerUniqueID [1] IMPLICIT BIT STRING OPTIONAL,
      //   subjectUniqueID [2] IMPLICIT BIT STRING OPTIONAL,
      //   extensions [3] EXPLICIT Extensions OPTIONAL
      // }

      // Find [3] EXPLICIT Extensions
      ASN1Sequence? extensionsSeq;
      for (final elem in tbsCert.elements!) {
        if (elem.tag == 0xA3) {
          // [3] EXPLICIT
          // The value bytes contain the DER-encoded SEQUENCE OF Extension
          final parser = ASN1Parser(elem.valueBytes);
          final obj = parser.nextObject();
          if (obj is ASN1Sequence) {
            extensionsSeq = obj;
          }
          break;
        }
      }

      if (extensionsSeq == null || extensionsSeq.elements == null) {
        return [];
      }

      final extensions = <X509Extension>[];
      for (final extElem in extensionsSeq.elements!) {
        if (extElem is! ASN1Sequence ||
            extElem.elements == null ||
            extElem.elements!.isEmpty) {
          continue;
        }

        // Extension ::= SEQUENCE {
        //   extnID OBJECT IDENTIFIER,
        //   critical BOOLEAN DEFAULT FALSE,
        //   extnValue OCTET STRING
        // }

        final oidObj = extElem.elements![0];
        if (oidObj is! ASN1ObjectIdentifier) {
          continue;
        }

        final oid = oidObj.objectIdentifierAsString ?? '';
        bool critical = false;
        Uint8List value = Uint8List(0);

        if (extElem.elements!.length >= 2) {
          final secondElem = extElem.elements![1];
          if (secondElem is ASN1Boolean) {
            critical = secondElem.boolValue ?? false;
            if (extElem.elements!.length >= 3) {
              final valueElem = extElem.elements![2];
              if (valueElem is ASN1OctetString) {
                value = valueElem.octets ?? Uint8List(0);
              }
            }
          } else if (secondElem is ASN1OctetString) {
            value = secondElem.octets ?? Uint8List(0);
          }
        }

        extensions.add(
          X509Extension(oid: oid, critical: critical, value: value),
        );
      }

      return extensions;
    } catch (e) {
      return [];
    }
  }

  /// Convenience: extract OCSP responder URLs from cert's AIA extension.
  /// Returns empty list if no AIA or no OCSP entries.
  static List<String> ocspUrls(Uint8List certDer) {
    final extensions = parseFromCertificate(certDer);
    for (final ext in extensions) {
      if (ext.oid == Oid.authorityInfoAccess) {
        return _parseAiaUrls(ext.value, Oid.aiaOcsp);
      }
    }
    return [];
  }

  /// Convenience: extract CA Issuers URLs (for fetching intermediate certs).
  static List<String> caIssuersUrls(Uint8List certDer) {
    final extensions = parseFromCertificate(certDer);
    for (final ext in extensions) {
      if (ext.oid == Oid.authorityInfoAccess) {
        return _parseAiaUrls(ext.value, Oid.aiaCaIssuers);
      }
    }
    return [];
  }

  /// Convenience: extract CRL distribution point URLs (HTTP/HTTPS only).
  /// Returns empty list if no CDP.
  static List<String> crlUrls(Uint8List certDer) {
    final extensions = parseFromCertificate(certDer);
    for (final ext in extensions) {
      if (ext.oid == Oid.crlDistributionPoints) {
        return _parseCdpUrls(ext.value);
      }
    }
    return [];
  }

  /// Subject Key Identifier (SKI) bytes if present.
  static Uint8List? subjectKeyIdentifier(Uint8List certDer) {
    final extensions = parseFromCertificate(certDer);
    for (final ext in extensions) {
      if (ext.oid == Oid.subjectKeyIdentifier) {
        try {
          final obj = ASN1Parser(ext.value).nextObject();
          if (obj is ASN1OctetString) {
            return obj.octets;
          }
        } catch (e) {
          // ignore
        }
      }
    }
    return null;
  }

  /// Authority Key Identifier (AKI) keyIdentifier bytes if present.
  static Uint8List? authorityKeyIdentifier(Uint8List certDer) {
    final extensions = parseFromCertificate(certDer);
    for (final ext in extensions) {
      if (ext.oid == Oid.authorityKeyIdentifier) {
        try {
          final obj = ASN1Parser(ext.value).nextObject();
          if (obj is ASN1Sequence &&
              obj.elements != null &&
              obj.elements!.isNotEmpty) {
            // AuthorityKeyIdentifier ::= SEQUENCE {
            //   keyIdentifier [0] IMPLICIT OCTET STRING OPTIONAL,
            //   authorityCertIssuer [1] IMPLICIT GeneralNames OPTIONAL,
            //   authorityCertSerialNumber [2] IMPLICIT INTEGER OPTIONAL
            // }
            final firstElem = obj.elements![0];
            if (firstElem.tag == 0x80) {
              // [0] IMPLICIT OCTET STRING
              return firstElem.valueBytes;
            }
          }
        } catch (e) {
          // ignore
        }
      }
    }
    return null;
  }

  /// Parse AIA extension value for URLs of a specific access method.
  static List<String> _parseAiaUrls(
    Uint8List aiaValue,
    String accessMethodOid,
  ) {
    final urls = <String>[];
    try {
      final obj = ASN1Parser(aiaValue).nextObject();
      if (obj is! ASN1Sequence || obj.elements == null) {
        return urls;
      }

      // AuthorityInfoAccessSyntax ::= SEQUENCE OF AccessDescription
      for (final descElem in obj.elements!) {
        if (descElem is! ASN1Sequence ||
            descElem.elements == null ||
            descElem.elements!.length < 2) {
          continue;
        }

        // AccessDescription ::= SEQUENCE {
        //   accessMethod OBJECT IDENTIFIER,
        //   accessLocation GeneralName
        // }

        final methodObj = descElem.elements![0];
        if (methodObj is! ASN1ObjectIdentifier) {
          continue;
        }

        if (methodObj.objectIdentifierAsString != accessMethodOid) {
          continue;
        }

        final locationObj = descElem.elements![1];
        if (locationObj.tag == 0x86) {
          // [6] IMPLICIT IA5String (uniformResourceIdentifier)
          final url = String.fromCharCodes(
            locationObj.valueBytes ?? Uint8List(0),
          );
          if (_isHttpUrl(url)) {
            urls.add(url);
          }
        }
      }
    } catch (e) {
      // ignore
    }
    return urls;
  }

  /// Parse CDP extension value for CRL URLs.
  static List<String> _parseCdpUrls(Uint8List cdpValue) {
    final urls = <String>[];
    try {
      final obj = ASN1Parser(cdpValue).nextObject();
      if (obj is! ASN1Sequence || obj.elements == null) {
        return urls;
      }

      // CRLDistributionPoints ::= SEQUENCE OF DistributionPoint
      for (final dpElem in obj.elements!) {
        if (dpElem is! ASN1Sequence || dpElem.elements == null) {
          continue;
        }

        // DistributionPoint ::= SEQUENCE {
        //   distributionPoint [0] EXPLICIT DistributionPointName OPTIONAL,
        //   reasons [1] IMPLICIT BIT STRING OPTIONAL,
        //   cRLIssuer [2] IMPLICIT GeneralNames OPTIONAL
        // }

        for (final elem in dpElem.elements!) {
          if (elem.tag == 0xA0) {
            // [0] EXPLICIT DistributionPointName
            // DistributionPointName ::= CHOICE {
            //   fullName [0] IMPLICIT GeneralNames,
            //   nameRelativeToCRLIssuer [1] IMPLICIT RelativeDistinguishedName
            // }
            final parser = ASN1Parser(elem.valueBytes);
            final dpnObj = parser.nextObject();
            if (dpnObj.tag == 0xA0) {
              // [0] IMPLICIT GeneralNames (SEQUENCE OF GeneralName)
              final gnParser = ASN1Parser(dpnObj.valueBytes);
              while (gnParser.hasNext()) {
                final gnObj = gnParser.nextObject();
                if (gnObj.tag == 0x86) {
                  // [6] IMPLICIT IA5String (uniformResourceIdentifier)
                  final url = String.fromCharCodes(
                    gnObj.valueBytes ?? Uint8List(0),
                  );
                  if (_isHttpUrl(url)) {
                    urls.add(url);
                  }
                }
              }
            }
          }
        }
      }
    } catch (e) {
      // ignore
    }
    return urls;
  }

  /// Check if a string is an HTTP or HTTPS URL.
  static bool _isHttpUrl(String url) {
    return url.startsWith('http://') || url.startsWith('https://');
  }
}
