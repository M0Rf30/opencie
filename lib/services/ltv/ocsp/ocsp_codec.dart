// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';

import '../asn1/der.dart';
import '../asn1/oids.dart';
import 'ocsp_models.dart';

/// Encodes an OCSPRequest:
/// OCSPRequest ::= SEQUENCE {
///   tbsRequest         TBSRequest,
///   optionalSignature  [0] EXPLICIT Signature OPTIONAL  -- omitted
/// }
/// TBSRequest ::= SEQUENCE {
///   version           [0] EXPLICIT Version DEFAULT v1,  -- omit (default)
///   requestorName     [1] EXPLICIT GeneralName OPTIONAL,  -- omit
///   requestList        SEQUENCE OF Request,
///   requestExtensions [2] EXPLICIT Extensions OPTIONAL
/// }
/// Request ::= SEQUENCE { reqCert CertID, singleRequestExtensions [0] EXPLICIT Extensions OPTIONAL }
/// Nonce extension: OID = id-pkix-ocsp-nonce, extnValue = OCTET STRING wrapping OCTET STRING(nonce-bytes).
Uint8List encodeOcspRequest({
  required List<OcspCertId> certIds,
  Uint8List? nonce,
}) {
  // Build requestList: SEQUENCE OF Request
  final requestList = ASN1Sequence();
  for (final certId in certIds) {
    final request = ASN1Sequence();
    request.add(_encodeCertId(certId));
    requestList.add(request);
  }

  // Build TBSRequest (omit version since it's default v1)
  final tbsRequest = ASN1Sequence();
  tbsRequest.add(requestList);

  // Add extensions if nonce is provided
  if (nonce != null) {
    final extensions = ASN1Sequence();
    final ext = ASN1Sequence();
    ext.add(ASN1ObjectIdentifier.fromIdentifierString(Oid.ocspNonce));
    // extnValue is OCTET STRING wrapping OCTET STRING(nonce)
    final innerOctetString = ASN1OctetString(octets: nonce);
    final outerOctetString = ASN1OctetString(octets: innerOctetString.encode());
    ext.add(outerOctetString);
    extensions.add(ext);
    // [2] EXPLICIT Extensions
    tbsRequest.add(explicit(2, extensions));
  }

  // Build OCSPRequest (omit optionalSignature)
  final ocspRequest = ASN1Sequence();
  ocspRequest.add(tbsRequest);

  return derEncode(ocspRequest);
}

/// Encodes a CertID:
/// CertID ::= SEQUENCE {
///   hashAlgorithm   AlgorithmIdentifier,
///   issuerNameHash  OCTET STRING,
///   issuerKeyHash   OCTET STRING,
///   serialNumber    INTEGER
/// }
ASN1Sequence _encodeCertId(OcspCertId certId) {
  final seq = ASN1Sequence();
  seq.add(algorithmIdentifier(certId.hashAlgorithmOid));
  seq.add(ASN1OctetString(octets: certId.issuerNameHash));
  seq.add(ASN1OctetString(octets: certId.issuerKeyHash));
  seq.add(_encodeBigInt(certId.serialNumber));
  return seq;
}

/// Encode a BigInt as ASN.1 INTEGER (with proper sign handling).
ASN1Integer _encodeBigInt(BigInt value) {
  return ASN1Integer(value);
}

/// Parses an OCSPResponse, including the BasicOCSPResponse inside.
/// OCSPResponse ::= SEQUENCE { responseStatus OCSPResponseStatus, responseBytes [0] EXPLICIT ResponseBytes OPTIONAL }
/// ResponseBytes ::= SEQUENCE { responseType OID, response OCTET STRING }
/// BasicOCSPResponse ::= SEQUENCE { tbsResponseData ResponseData, signatureAlgorithm AlgorithmIdentifier, signature BIT STRING, certs [0] EXPLICIT SEQUENCE OF Certificate OPTIONAL }
/// ResponseData ::= SEQUENCE { version [0] EXPLICIT Version DEFAULT v1, responderID ResponderID, producedAt GeneralizedTime, responses SEQUENCE OF SingleResponse, responseExtensions [1] EXPLICIT Extensions OPTIONAL }
/// SingleResponse ::= SEQUENCE { certID CertID, certStatus CertStatus, thisUpdate GeneralizedTime, nextUpdate [0] EXPLICIT GeneralizedTime OPTIONAL, singleExtensions [1] EXPLICIT Extensions OPTIONAL }
OcspResponse parseOcspResponse(Uint8List der) {
  try {
    final obj = derDecode(der);
    if (obj is! ASN1Sequence || obj.elements == null || obj.elements!.isEmpty) {
      return OcspResponse(status: OcspResponseStatus.internalError);
    }

    // Parse responseStatus
    final statusObj = obj.elements![0];

    int statusValue = 2; // default to internalError
    if (statusObj is ASN1Enumerated) {
      statusValue = statusObj.integer?.toInt() ?? 2;
    } else if (statusObj is ASN1Integer) {
      // pointycastle may parse ENUMERATED as INTEGER
      statusValue = statusObj.integer?.toInt() ?? 2;
    } else {
      return OcspResponse(status: OcspResponseStatus.internalError);
    }

    final status = OcspResponseStatus.fromValue(statusValue);
    if (status != OcspResponseStatus.successful) {
      return OcspResponse(status: status);
    }

    // Parse responseBytes [0] EXPLICIT
    if (obj.elements!.length < 2) {
      return OcspResponse(status: OcspResponseStatus.internalError);
    }

    final responseBytes = obj.elements![1];
    if (responseBytes.tag != 0xA0) {
      return OcspResponse(status: OcspResponseStatus.internalError);
    }

    ASN1Sequence responseBytesSeq;
    try {
      final responseBytesContent = ASN1Parser(
        responseBytes.valueBytes ?? Uint8List(0),
      ).nextObject();
      if (responseBytesContent is! ASN1Sequence) {
        return OcspResponse(status: OcspResponseStatus.internalError);
      }
      responseBytesSeq = responseBytesContent;
    } catch (e) {
      return OcspResponse(status: OcspResponseStatus.internalError);
    }

    if (responseBytesSeq.elements == null ||
        responseBytesSeq.elements!.isEmpty) {
      return OcspResponse(status: OcspResponseStatus.internalError);
    }

    // Check responseType OID == id-pkix-ocsp-basic
    final responseTypeObj = responseBytesSeq.elements![0];
    if (responseTypeObj is! ASN1ObjectIdentifier) {
      return OcspResponse(status: OcspResponseStatus.internalError);
    }

    final responseTypeOid = responseTypeObj.objectIdentifierAsString ?? '';
    if (responseTypeOid != Oid.ocspBasic) {
      return OcspResponse(status: OcspResponseStatus.internalError);
    }

    // Parse response OCTET STRING
    if (responseBytesSeq.elements!.length < 2) {
      return OcspResponse(status: OcspResponseStatus.internalError);
    }

    final responseOctetObj = responseBytesSeq.elements![1];
    if (responseOctetObj is! ASN1OctetString) {
      return OcspResponse(status: OcspResponseStatus.internalError);
    }

    final basicOcspResponseDer = responseOctetObj.octets ?? Uint8List(0);
    if (basicOcspResponseDer.isEmpty) {
      return OcspResponse(status: OcspResponseStatus.internalError);
    }

    ASN1Sequence basicOcspResponse;
    try {
      final basicOcspResponseObj = derDecode(basicOcspResponseDer);
      if (basicOcspResponseObj is! ASN1Sequence) {
        return OcspResponse(status: OcspResponseStatus.internalError);
      }
      basicOcspResponse = basicOcspResponseObj;
    } catch (e) {
      return OcspResponse(status: OcspResponseStatus.internalError);
    }

    if (basicOcspResponse.elements == null ||
        basicOcspResponse.elements!.isEmpty) {
      return OcspResponse(status: OcspResponseStatus.internalError);
    }

    // Parse ResponseData (first element of BasicOCSPResponse)
    final responseDataObj = basicOcspResponse.elements![0];
    if (responseDataObj is! ASN1Sequence || responseDataObj.elements == null) {
      return OcspResponse(status: OcspResponseStatus.internalError);
    }

    final responseData = responseDataObj;
    DateTime? producedAt;
    List<OcspSingleResponse> singleResponses = [];
    Uint8List? respNonce;

    // Parse ResponseData fields
    // ResponseData ::= SEQUENCE {
    //   version [0] EXPLICIT Version DEFAULT v1,
    //   responderID ResponderID,
    //   producedAt GeneralizedTime,
    //   responses SEQUENCE OF SingleResponse,
    //   responseExtensions [1] EXPLICIT Extensions OPTIONAL
    // }
    int idx = 0;
    for (final elem in responseData.elements!) {
      if (elem.tag == 0xA0) {
        // [0] EXPLICIT version (skip, default v1)
        idx++;
      } else if (idx == 1 &&
          (elem is ASN1Sequence || elem.tag == 0xA1 || elem.tag == 0xA2)) {
        // responderID (ResponderID is a CHOICE, either [1] or [2], or a Name SEQUENCE)
        // For now, skip responderID parsing
        idx++;
      } else if (idx == 2 && elem is ASN1GeneralizedTime) {
        // producedAt
        producedAt = elem.dateTimeValue;
        idx++;
      } else if (idx == 3 && elem is ASN1Sequence) {
        // responses SEQUENCE OF SingleResponse
        singleResponses = _parseSingleResponses(elem);
        idx++;
      } else if (elem.tag == 0xA1) {
        // [1] EXPLICIT responseExtensions
        respNonce = _extractNonceFromExtensions(
          elem.valueBytes ?? Uint8List(0),
        );
        idx++;
      }
    }

    // Parse embedded certs from [0] EXPLICIT SEQUENCE OF Certificate
    final embeddedCerts = <Uint8List>[];
    if (basicOcspResponse.elements!.length > 3) {
      final certsElem = basicOcspResponse.elements![3];
      if (certsElem.tag == 0xA0) {
        // [0] EXPLICIT SEQUENCE OF Certificate
        try {
          final certsSeq = derDecode(certsElem.valueBytes ?? Uint8List(0));
          if (certsSeq is ASN1Sequence && certsSeq.elements != null) {
            for (final certElem in certsSeq.elements!) {
              embeddedCerts.add(derEncode(certElem));
            }
          }
        } catch (e) {
          // ignore cert parsing errors
        }
      }
    }

    return OcspResponse(
      status: OcspResponseStatus.successful,
      rawResponse: der,
      responses: singleResponses,
      respNonce: respNonce,
      producedAt: producedAt,
      embeddedCerts: embeddedCerts,
    );
  } catch (e) {
    return OcspResponse(status: OcspResponseStatus.internalError);
  }
}

/// Parse SEQUENCE OF SingleResponse.
List<OcspSingleResponse> _parseSingleResponses(ASN1Sequence responsesSeq) {
  final result = <OcspSingleResponse>[];
  if (responsesSeq.elements == null) {
    return result;
  }

  for (final elem in responsesSeq.elements!) {
    if (elem is! ASN1Sequence ||
        elem.elements == null ||
        elem.elements!.isEmpty) {
      continue;
    }

    try {
      final singleResp = _parseSingleResponse(elem);
      if (singleResp != null) {
        result.add(singleResp);
      }
    } catch (e) {
      // ignore parse errors
    }
  }

  return result;
}

/// Parse a single SingleResponse.
OcspSingleResponse? _parseSingleResponse(ASN1Sequence singleRespSeq) {
  if (singleRespSeq.elements == null || singleRespSeq.elements!.length < 3) {
    return null;
  }

  // Parse CertID
  final certIdObj = singleRespSeq.elements![0];
  if (certIdObj is! ASN1Sequence) {
    return null;
  }

  final certId = _parseCertId(certIdObj);
  if (certId == null) {
    return null;
  }

  // Parse CertStatus (CHOICE)
  final certStatusObj = singleRespSeq.elements![1];
  final status = _parseCertStatus(certStatusObj);

  // Parse thisUpdate (GeneralizedTime)
  final thisUpdateObj = singleRespSeq.elements![2];
  DateTime? thisUpdate;
  if (thisUpdateObj is ASN1GeneralizedTime) {
    thisUpdate = thisUpdateObj.dateTimeValue;
  }

  if (thisUpdate == null) {
    return null;
  }

  // Parse optional nextUpdate [0] EXPLICIT and revocationTime/reason
  DateTime? nextUpdate;
  DateTime? revocationTime;
  int? revocationReason;

  for (int i = 3; i < singleRespSeq.elements!.length; i++) {
    final elem = singleRespSeq.elements![i];
    if (elem.tag == 0xA0) {
      // [0] EXPLICIT nextUpdate
      try {
        final nextUpdateObj = derDecode(elem.valueBytes ?? Uint8List(0));
        if (nextUpdateObj is ASN1GeneralizedTime) {
          nextUpdate = nextUpdateObj.dateTimeValue;
        }
      } catch (e) {
        // ignore
      }
    } else if (elem.tag == 0xA1) {
      // [1] EXPLICIT singleExtensions
      // For now, skip
    }
  }

  // Extract revocationTime and reason from RevokedInfo if status is revoked
  if (status == OcspCertStatus.revoked && certStatusObj.tag == 0xA1) {
    try {
      final revokedInfoObj = derDecode(
        certStatusObj.valueBytes ?? Uint8List(0),
      );
      if (revokedInfoObj is ASN1Sequence && revokedInfoObj.elements != null) {
        // RevokedInfo ::= SEQUENCE { revocationTime GeneralizedTime, revocationReason [0] EXPLICIT CRLReason OPTIONAL }
        if (revokedInfoObj.elements!.isNotEmpty) {
          final revTimeObj = revokedInfoObj.elements![0];
          if (revTimeObj is ASN1GeneralizedTime) {
            revocationTime = revTimeObj.dateTimeValue;
          }
        }
        if (revokedInfoObj.elements!.length > 1) {
          final reasonElem = revokedInfoObj.elements![1];
          if (reasonElem.tag == 0xA0) {
            try {
              final reasonObj = derDecode(
                reasonElem.valueBytes ?? Uint8List(0),
              );
              if (reasonObj is ASN1Enumerated) {
                revocationReason = reasonObj.integer?.toInt();
              }
            } catch (e) {
              // ignore
            }
          }
        }
      }
    } catch (e) {
      // ignore
    }
  }

  return OcspSingleResponse(
    certId: certId,
    status: status,
    thisUpdate: thisUpdate,
    nextUpdate: nextUpdate,
    revocationTime: revocationTime,
    revocationReason: revocationReason,
  );
}

/// Parse a CertID.
OcspCertId? _parseCertId(ASN1Sequence certIdSeq) {
  if (certIdSeq.elements == null || certIdSeq.elements!.length < 4) {
    return null;
  }

  // Parse hashAlgorithm AlgorithmIdentifier
  final hashAlgObj = certIdSeq.elements![0];
  if (hashAlgObj is! ASN1Sequence ||
      hashAlgObj.elements == null ||
      hashAlgObj.elements!.isEmpty) {
    return null;
  }

  final hashAlgOidObj = hashAlgObj.elements![0];
  if (hashAlgOidObj is! ASN1ObjectIdentifier) {
    return null;
  }

  final hashAlgorithmOid = hashAlgOidObj.objectIdentifierAsString ?? '';

  // Parse issuerNameHash OCTET STRING
  final issuerNameHashObj = certIdSeq.elements![1];
  if (issuerNameHashObj is! ASN1OctetString) {
    return null;
  }

  final issuerNameHash = issuerNameHashObj.octets ?? Uint8List(0);

  // Parse issuerKeyHash OCTET STRING
  final issuerKeyHashObj = certIdSeq.elements![2];
  if (issuerKeyHashObj is! ASN1OctetString) {
    return null;
  }

  final issuerKeyHash = issuerKeyHashObj.octets ?? Uint8List(0);

  // Parse serialNumber INTEGER
  final serialNumberObj = certIdSeq.elements![3];
  if (serialNumberObj is! ASN1Integer) {
    return null;
  }

  final serialNumber = serialNumberObj.integer ?? BigInt.zero;

  return OcspCertId(
    hashAlgorithmOid: hashAlgorithmOid,
    issuerNameHash: issuerNameHash,
    issuerKeyHash: issuerKeyHash,
    serialNumber: serialNumber,
  );
}

/// Parse CertStatus (CHOICE).
OcspCertStatus _parseCertStatus(ASN1Object statusObj) {
  if (statusObj.tag == 0x80) {
    // [0] IMPLICIT NULL (good)
    return OcspCertStatus.good;
  } else if (statusObj.tag == 0xA1) {
    // [1] IMPLICIT RevokedInfo
    return OcspCertStatus.revoked;
  } else if (statusObj.tag == 0x82) {
    // [2] IMPLICIT UnknownInfo
    return OcspCertStatus.unknown;
  }
  return OcspCertStatus.unknown;
}

/// Extract nonce from responseExtensions.
Uint8List? _extractNonceFromExtensions(Uint8List extBytes) {
  try {
    if (extBytes.isEmpty) {
      return null;
    }

    final extSeq = derDecode(extBytes);
    if (extSeq is! ASN1Sequence || extSeq.elements == null) {
      return null;
    }

    for (final elem in extSeq.elements!) {
      if (elem is! ASN1Sequence ||
          elem.elements == null ||
          elem.elements!.isEmpty) {
        continue;
      }

      final oidObj = elem.elements![0];
      if (oidObj is! ASN1ObjectIdentifier) {
        continue;
      }

      if (oidObj.objectIdentifierAsString != Oid.ocspNonce) {
        continue;
      }

      // Found nonce extension, parse extnValue
      Uint8List extnValue = Uint8List(0);
      if (elem.elements!.length >= 2) {
        final secondElem = elem.elements![1];
        if (secondElem is ASN1Boolean) {
          // critical flag present
          if (elem.elements!.length >= 3) {
            final valueElem = elem.elements![2];
            if (valueElem is ASN1OctetString) {
              extnValue = valueElem.octets ?? Uint8List(0);
            }
          }
        } else if (secondElem is ASN1OctetString) {
          extnValue = secondElem.octets ?? Uint8List(0);
        }
      }

      // extnValue is OCTET STRING wrapping OCTET STRING(nonce)
      if (extnValue.isNotEmpty) {
        try {
          final innerObj = derDecode(extnValue);
          if (innerObj is ASN1OctetString) {
            return innerObj.octets;
          }
        } catch (e) {
          // ignore
        }
      }

      return null;
    }
  } catch (e) {
    // ignore
  }

  return null;
}

/// Extracts the DER-encoded BasicOCSPResponse from an OCSPResponse DER blob.
///
/// OCSPResponse ::= SEQUENCE { responseStatus, responseBytes [0] EXPLICIT ResponseBytes OPTIONAL }
/// ResponseBytes ::= SEQUENCE { responseType OID, response OCTET STRING }
/// The response OCTET STRING contains the DER of BasicOCSPResponse.
///
/// Returns the DER bytes of BasicOCSPResponse, or null if extraction fails.
Uint8List? extractBasicOcspResponse(Uint8List ocspResponseDer) {
  try {
    final obj = derDecode(ocspResponseDer);
    if (obj is! ASN1Sequence ||
        obj.elements == null ||
        obj.elements!.length < 2) {
      return null;
    }

    // Skip responseStatus (first element)
    final responseBytes = obj.elements![1];
    if (responseBytes.tag != 0xA0) {
      return null;
    }

    // Parse responseBytes [0] EXPLICIT
    ASN1Sequence responseBytesSeq;
    try {
      final responseBytesContent = ASN1Parser(
        responseBytes.valueBytes ?? Uint8List(0),
      ).nextObject();
      if (responseBytesContent is! ASN1Sequence) {
        return null;
      }
      responseBytesSeq = responseBytesContent;
    } catch (e) {
      return null;
    }

    if (responseBytesSeq.elements == null ||
        responseBytesSeq.elements!.length < 2) {
      return null;
    }

    // Skip responseType OID (first element)
    // Extract response OCTET STRING (second element)
    final responseOctetObj = responseBytesSeq.elements![1];
    if (responseOctetObj is! ASN1OctetString) {
      return null;
    }

    final basicOcspResponseDer = responseOctetObj.octets ?? Uint8List(0);
    if (basicOcspResponseDer.isEmpty) {
      return null;
    }

    return basicOcspResponseDer;
  } catch (e) {
    return null;
  }
}
