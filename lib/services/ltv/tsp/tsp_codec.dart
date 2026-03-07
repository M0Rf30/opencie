// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';

import '../asn1/der.dart';
import '../asn1/oids.dart';
import 'tsp_models.dart';

/// Builds a DER-encoded TimeStampReq:
/// TimeStampReq ::= SEQUENCE {
///   version              INTEGER  { v1(1) },
///   messageImprint       MessageImprint,
///   reqPolicy            TSAPolicyId    OPTIONAL,
///   nonce                INTEGER        OPTIONAL,
///   certReq              BOOLEAN        DEFAULT FALSE,
///   extensions           [0] IMPLICIT Extensions OPTIONAL
/// }
/// MessageImprint ::= SEQUENCE { hashAlgorithm AlgorithmIdentifier, hashedMessage OCTET STRING }
Uint8List encodeTspRequest(TspRequest req) {
  final seq = ASN1Sequence();

  // version INTEGER { v1(1) }
  seq.add(ASN1Integer(BigInt.one));

  // messageImprint MessageImprint
  final msgImprint = ASN1Sequence();
  msgImprint.add(algorithmIdentifier(req.hashAlgorithmOid));
  msgImprint.add(ASN1OctetString(octets: req.messageImprintHash));
  seq.add(msgImprint);

  // reqPolicy TSAPolicyId OPTIONAL
  if (req.policyOid != null) {
    seq.add(ASN1ObjectIdentifier.fromIdentifierString(req.policyOid!));
  }

  // nonce INTEGER OPTIONAL
  if (req.nonce != null) {
    seq.add(_encodeNonce(req.nonce!));
  }

  // certReq BOOLEAN DEFAULT FALSE
  if (req.reqCertReq) {
    seq.add(ASN1Boolean(true));
  }

  // extensions [0] IMPLICIT Extensions OPTIONAL — omitted (not needed)

  return seq.encode();
}

/// Parses TimeStampResp:
/// TimeStampResp ::= SEQUENCE { status PKIStatusInfo, timeStampToken TimeStampToken OPTIONAL }
/// PKIStatusInfo ::= SEQUENCE { status PKIStatus, statusString PKIFreeText OPTIONAL, failInfo PKIFailureInfo OPTIONAL }
/// TimeStampToken ::= ContentInfo  -- with eContentType id-ct-TSTInfo and eContent OCTET STRING wrapping TSTInfo
TspResponse parseTspResponse(Uint8List der) {
  try {
    final parser = ASN1Parser(der);
    final respSeq = parser.nextObject() as ASN1Sequence;

    // Parse PKIStatusInfo (first element)
    final statusSeq = respSeq.elements![0] as ASN1Sequence;
    final statusInt = statusSeq.elements![0] as ASN1Integer;
    final statusValue = statusInt.integer?.toInt() ?? 2;
    final status = TspStatus.fromValue(statusValue);

    // Parse statusString (optional)
    final statusStrings = <String>[];
    if (statusSeq.elements!.length > 1) {
      final elem = statusSeq.elements![1];
      if (elem is ASN1Sequence) {
        // PKIFreeText is SEQUENCE OF UTF8String
        for (final item in elem.elements ?? []) {
          if (item is ASN1UTF8String) {
            statusStrings.add(item.utf8StringValue ?? '');
          }
        }
      }
    }

    // Parse failInfo (optional)
    int? failInfo;
    if (statusSeq.elements!.length > 2) {
      final elem = statusSeq.elements![2];
      if (elem is ASN1BitString) {
        // Convert bit string to integer
        final bytes = elem.stringValues;
        if (bytes != null && bytes.isNotEmpty) {
          failInfo = bytes[0] & 0xFF;
        }
      }
    }

    // Parse timeStampToken (optional, second element of TimeStampResp)
    Uint8List? timeStampToken;
    DateTime? genTime;
    String? messageImprintHashOid;
    Uint8List? messageImprintHash;
    Uint8List? respNonce;

    if (respSeq.elements!.length > 1) {
      final tokenObj = respSeq.elements![1];
      if (tokenObj is ASN1Sequence) {
        timeStampToken = tokenObj.encode();

        // Parse TSTInfo from inside the token
        try {
          final tstInfo = _parseTstInfo(timeStampToken);
          genTime = tstInfo.genTime;
          messageImprintHashOid = tstInfo.hashOid;
          messageImprintHash = tstInfo.hash;
          respNonce = tstInfo.nonce;
        } catch (e) {
          // Silently ignore TSTInfo parsing errors; token is still valid
        }
      }
    }

    return TspResponse(
      status: status,
      statusStrings: statusStrings,
      failInfo: failInfo,
      timeStampToken: timeStampToken,
      genTime: genTime,
      messageImprintHashOid: messageImprintHashOid,
      messageImprintHash: messageImprintHash,
      respNonce: respNonce,
    );
  } catch (e) {
    // Defensive: return rejection on parse error
    return TspResponse(
      status: TspStatus.rejection,
      statusStrings: ['parse error: $e'],
    );
  }
}

/// Parses an embedded TSTInfo to extract genTime, messageImprint, nonce.
/// Used internally by parseTspResponse and exposed for verifying tokens.
/// TSTInfo ::= SEQUENCE {
///   version INTEGER { v1(1) },
///   policy TSAPolicyId,
///   messageImprint MessageImprint,
///   serialNumber INTEGER,
///   genTime GeneralizedTime,
///   accuracy Accuracy OPTIONAL,
///   ordering BOOLEAN DEFAULT FALSE,
///   nonce INTEGER OPTIONAL,
///   tsa [0] GeneralName OPTIONAL,
///   extensions [1] IMPLICIT Extensions OPTIONAL
/// }
({DateTime? genTime, String? hashOid, Uint8List? hash, Uint8List? nonce}) _parseTstInfo(
    Uint8List timeStampTokenDer) {
  final parser = ASN1Parser(timeStampTokenDer);
  final contentInfo = parser.nextObject() as ASN1Sequence;

  // ContentInfo ::= SEQUENCE { contentType OID, [0] EXPLICIT content }
  // contentType should be id-signedData (1.2.840.113549.1.7.2)
  final contentType = contentInfo.elements![0] as ASN1ObjectIdentifier;
  if (contentType.objectIdentifierAsString != Oid.pkcs7SignedData) {
    throw Exception('Expected SignedData, got ${contentType.objectIdentifierAsString}');
  }

  // Extract [0] EXPLICIT content (SignedData)
  // In pointycastle 4.0, context-specific tags are just ASN1Objects with tag 0xA0 (constructed context 0)
  ASN1Sequence signedData;
  if (contentInfo.elements!.length > 1) {
    final ctx = contentInfo.elements![1];
    // Check if it's a context-specific tag (0xA0 = constructed context 0)
    if (ctx.tag == 0xA0) {
      // Parse the content inside the context tag
      final ctxContent = ASN1Parser(ctx.valueBytes!).nextObject();
      signedData = ctxContent as ASN1Sequence;
    } else {
      throw Exception('Expected [0] EXPLICIT tag, got tag ${ctx.tag}');
    }
  } else {
    throw Exception('No SignedData found in ContentInfo');
  }

  // SignedData ::= SEQUENCE {
  //   version CMSVersion,
  //   digestAlgorithms SET OF DigestAlgorithmIdentifier,
  //   encapContentInfo EncapsulatedContentInfo,
  //   certificates [0] IMPLICIT CertificateSet OPTIONAL,
  //   signerInfos SignerInfos
  // }
  // We need encapContentInfo (element 2)
  final encapContentInfo = signedData.elements![2] as ASN1Sequence;

  // EncapsulatedContentInfo ::= SEQUENCE {
  //   eContentType OBJECT IDENTIFIER,
  //   eContent [0] EXPLICIT OCTET STRING OPTIONAL
  // }
  final eContentType = encapContentInfo.elements![0] as ASN1ObjectIdentifier;
  if (eContentType.objectIdentifierAsString != Oid.timeStampToken) {
    throw Exception('Expected TSTInfo, got ${eContentType.objectIdentifierAsString}');
  }

  // Extract eContent [0] EXPLICIT OCTET STRING
  Uint8List tstInfoDer;
  if (encapContentInfo.elements!.length > 1) {
    final ctx = encapContentInfo.elements![1];
    if (ctx.tag == 0xA0) {
      // Parse the OCTET STRING inside the context tag
      final octetString = ASN1Parser(ctx.valueBytes!).nextObject() as ASN1OctetString;
      tstInfoDer = octetString.octets!;
    } else {
      throw Exception('Expected [0] EXPLICIT tag, got tag ${ctx.tag}');
    }
  } else {
    throw Exception('No eContent found in EncapsulatedContentInfo');
  }

  // Parse TSTInfo SEQUENCE
  final tstInfoParser = ASN1Parser(tstInfoDer);
  final tstInfo = tstInfoParser.nextObject() as ASN1Sequence;

  // TSTInfo elements:
  // 0: version
  // 1: policy
  // 2: messageImprint
  // 3: serialNumber
  // 4: genTime
  // 5+: optional fields

  DateTime? genTime;
  String? hashOid;
  Uint8List? hash;
  Uint8List? nonce;

  // Parse genTime (element 4)
  if (tstInfo.elements!.length > 4) {
    final genTimeObj = tstInfo.elements![4];
    if (genTimeObj is ASN1GeneralizedTime) {
      genTime = genTimeObj.dateTimeValue;
    }
  }

  // Parse messageImprint (element 2)
  if (tstInfo.elements!.length > 2) {
    final msgImprint = tstInfo.elements![2] as ASN1Sequence;
    // MessageImprint ::= SEQUENCE { hashAlgorithm AlgorithmIdentifier, hashedMessage OCTET STRING }
    final hashAlgoSeq = msgImprint.elements![0] as ASN1Sequence;
    final hashAlgoOid = hashAlgoSeq.elements![0] as ASN1ObjectIdentifier;
    hashOid = hashAlgoOid.objectIdentifierAsString;

    final hashedMessage = msgImprint.elements![1] as ASN1OctetString;
    hash = hashedMessage.octets;
  }

  // Parse nonce (optional, look for INTEGER after genTime)
  for (int i = 5; i < tstInfo.elements!.length; i++) {
    final elem = tstInfo.elements![i];
    if (elem is ASN1Integer) {
      // This is likely the nonce
      nonce = _decodeNonce(elem);
      break;
    }
  }

  return (genTime: genTime, hashOid: hashOid, hash: hash, nonce: nonce);
}

/// Encode a nonce (Uint8List) as an ASN.1 INTEGER.
/// Left-pads with 0x00 if high bit is set to keep it positive.
ASN1Integer _encodeNonce(Uint8List nonceBytes) {
  // Convert bytes to BigInt
  var value = BigInt.zero;
  for (final byte in nonceBytes) {
    value = (value << 8) | BigInt.from(byte & 0xFF);
  }
  return ASN1Integer(value);
}

/// Decode an ASN.1 INTEGER nonce back to bytes.
/// Strips leading zero padding if present.
Uint8List _decodeNonce(ASN1Integer nonceInt) {
  final value = nonceInt.integer;
  if (value == null || value == BigInt.zero) {
    return Uint8List(0);
  }

  // Convert BigInt to bytes
  final bytes = <int>[];
  var v = value;
  while (v > BigInt.zero) {
    bytes.insert(0, (v & BigInt.from(0xFF)).toInt());
    v = v >> 8;
  }

  // Strip leading zero if present (was added for sign bit)
  if (bytes.isNotEmpty && bytes[0] == 0x00 && bytes.length > 1) {
    bytes.removeAt(0);
  }

  return Uint8List.fromList(bytes);
}


