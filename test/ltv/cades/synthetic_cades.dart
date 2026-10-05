// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

// Synthetic CMS / OCSP / CRL builders shared by CAdES and signing tests.
// Fake data only.

import 'dart:typed_data';

import 'package:opencie/services/ltv/asn1/der.dart';
import 'package:opencie/services/ltv/asn1/oids.dart';
import 'package:pointycastle/asn1.dart';

/// Wraps an ASN1Object with an implicit context-specific tag [n].
ASN1Object wrapImplicit(int tagNumber, ASN1Object inner) {
  final encoded = derEncode(inner);
  final tag = 0xA0 | tagNumber;
  final result = BytesBuilder();
  result.addByte(tag);
  encodeLength(result, encoded.length);
  result.add(encoded);
  return ASN1Parser(result.toBytes()).nextObject();
}

void encodeLength(BytesBuilder builder, int length) {
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

/// Builds a synthetic CAdES-BES SignedData blob for testing.
Uint8List buildSyntheticCadesBes({
  List<Uint8List> embeddedCerts = const [],
  Map<String, Uint8List> unsignedAttrs = const {},
}) {
  // Build SignerInfo
  final signerInfo = ASN1Sequence();
  signerInfo.add(ASN1Integer(BigInt.from(3))); // version

  // sid: IssuerAndSerialNumber
  final issuerName = ASN1Sequence();
  final sid = ASN1Sequence();
  sid.add(issuerName);
  sid.add(ASN1Integer(BigInt.from(12345)));
  signerInfo.add(sid);

  // digestAlgorithm
  signerInfo.add(algorithmIdentifier(Oid.sha256));

  // signedAttrs [0] IMPLICIT
  final signedAttrs = ASN1Set();
  final contentTypeAttr = ASN1Sequence();
  contentTypeAttr.add(
    ASN1ObjectIdentifier.fromIdentifierString(Oid.contentType),
  );
  final contentTypeAttrValues = ASN1Set();
  contentTypeAttrValues.add(
    ASN1ObjectIdentifier.fromIdentifierString(Oid.pkcs7Data),
  );
  contentTypeAttr.add(contentTypeAttrValues);
  signedAttrs.add(contentTypeAttr);

  final messageDigestAttr = ASN1Sequence();
  messageDigestAttr.add(
    ASN1ObjectIdentifier.fromIdentifierString(Oid.messageDigest),
  );
  final messageDigestAttrValues = ASN1Set();
  messageDigestAttrValues.add(ASN1OctetString(octets: Uint8List(32)));
  messageDigestAttr.add(messageDigestAttrValues);
  signedAttrs.add(messageDigestAttr);

  signerInfo.add(wrapImplicit(0, signedAttrs));

  // signatureAlgorithm
  signerInfo.add(algorithmIdentifier(Oid.sha256WithRSA));

  // signature
  signerInfo.add(ASN1OctetString(octets: Uint8List(256)));

  // unsignedAttrs [1] IMPLICIT (optional)
  if (unsignedAttrs.isNotEmpty) {
    final unsignedAttrsSet = ASN1Set();
    for (final oid in unsignedAttrs.keys) {
      final attrValueSetDer = unsignedAttrs[oid]!;
      final attr = ASN1Sequence();
      attr.add(ASN1ObjectIdentifier.fromIdentifierString(oid));
      final attrValuesSet = derDecode(attrValueSetDer);
      attr.add(attrValuesSet);
      unsignedAttrsSet.add(attr);
    }
    signerInfo.add(wrapImplicit(1, unsignedAttrsSet));
  }

  // Build SignerInfos SET
  final signerInfos = ASN1Set();
  signerInfos.add(signerInfo);

  // Build SignedData
  final signedData = ASN1Sequence();
  signedData.add(ASN1Integer(BigInt.from(3))); // version

  // digestAlgorithms SET OF
  final digestAlgorithms = ASN1Set();
  digestAlgorithms.add(algorithmIdentifier(Oid.sha256));
  signedData.add(digestAlgorithms);

  // encapContentInfo
  final encapContentInfo = ASN1Sequence();
  encapContentInfo.add(
    ASN1ObjectIdentifier.fromIdentifierString(Oid.pkcs7Data),
  );
  signedData.add(encapContentInfo);

  // certificates [0] IMPLICIT (optional)
  if (embeddedCerts.isNotEmpty) {
    final certsSeq = ASN1Sequence();
    for (final certDer in embeddedCerts) {
      certsSeq.add(derDecode(certDer));
    }
    signedData.add(wrapImplicit(0, certsSeq));
  }

  // signerInfos SET OF
  signedData.add(signerInfos);

  // Build ContentInfo
  final contentInfo = ASN1Sequence();
  contentInfo.add(
    ASN1ObjectIdentifier.fromIdentifierString(Oid.pkcs7SignedData),
  );
  contentInfo.add(explicit(0, signedData));

  return derEncode(contentInfo);
}

/// Builds a synthetic CRL (just a valid SEQUENCE for embedding).
Uint8List buildSyntheticCrl() {
  final crl = ASN1Sequence();
  crl.add(ASN1Sequence()); // TBSCertList (dummy)
  crl.add(algorithmIdentifier(Oid.sha256WithRSA)); // signatureAlgorithm
  crl.add(ASN1BitString(stringValues: List<int>.filled(256, 0))); // signature
  return derEncode(crl);
}

/// Builds a synthetic OCSPResponse wrapping a BasicOCSPResponse.
Uint8List buildSyntheticOcspResponse() {
  // Build a minimal BasicOCSPResponse (just a SEQUENCE with dummy content)
  final basicOcspResponse = ASN1Sequence();
  basicOcspResponse.add(ASN1Integer(BigInt.from(1))); // dummy content

  final basicOcspResponseDer = derEncode(basicOcspResponse);

  // Wrap in OCSPResponse
  final ocspResponse = ASN1Sequence();
  ocspResponse.add(ASN1Enumerated(0)); // responseStatus = successful

  // responseBytes [0] EXPLICIT
  final responseBytes = ASN1Sequence();
  responseBytes.add(ASN1ObjectIdentifier.fromIdentifierString(Oid.ocspBasic));
  responseBytes.add(ASN1OctetString(octets: basicOcspResponseDer));

  ocspResponse.add(explicit(0, responseBytes));

  return derEncode(ocspResponse);
}
