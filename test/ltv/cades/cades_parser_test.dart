// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import 'package:pointycastle/asn1.dart';
import 'package:test/test.dart';

import 'package:opencie/services/ltv/asn1/der.dart';
import 'package:opencie/services/ltv/asn1/oids.dart';
import 'package:opencie/services/ltv/cades/cades_models.dart';
import 'package:opencie/services/ltv/cades/cades_parser.dart';

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
/// Structure: ContentInfo { contentType=signed-data, content=[0] SignedData }
/// SignedData { version=3, digestAlgorithms, encapContentInfo, certificates=[0], signerInfos }
/// SignerInfo { version=3, sid, digestAlgorithm, signedAttrs=[0], signatureAlgorithm, signature, unsignedAttrs=[1] (optional) }
Uint8List buildSyntheticCadesBes({
  List<Uint8List> embeddedCerts = const [],
  Map<String, Uint8List> unsignedAttrs = const {},
}) {
  // Build SignerInfo
  final signerInfo = ASN1Sequence();
  signerInfo.add(ASN1Integer(BigInt.from(3))); // version

  // sid: IssuerAndSerialNumber (SEQUENCE { issuer Name, serialNumber INTEGER })
  final issuerName = ASN1Sequence(); // Empty Name for simplicity
  final sid = ASN1Sequence();
  sid.add(issuerName);
  sid.add(ASN1Integer(BigInt.from(12345))); // serialNumber
  signerInfo.add(sid);

  // digestAlgorithm: AlgorithmIdentifier
  signerInfo.add(algorithmIdentifier(Oid.sha256));

  // signedAttrs [0] IMPLICIT: minimal SignedAttributes
  final signedAttrs = ASN1Set();
  // Add contentType attribute
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

  // Add messageDigest attribute
  final messageDigestAttr = ASN1Sequence();
  messageDigestAttr.add(
    ASN1ObjectIdentifier.fromIdentifierString(Oid.messageDigest),
  );
  final messageDigestAttrValues = ASN1Set();
  messageDigestAttrValues.add(
    ASN1OctetString(octets: Uint8List(32)),
  ); // Dummy SHA-256 hash
  messageDigestAttr.add(messageDigestAttrValues);
  signedAttrs.add(messageDigestAttr);

  signerInfo.add(wrapImplicit(0, signedAttrs));

  // signatureAlgorithm: AlgorithmIdentifier
  signerInfo.add(algorithmIdentifier(Oid.sha256WithRSA));

  // signature: OCTET STRING (dummy)
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

  // encapContentInfo: ContentInfo { contentType=data, content=[0] EXPLICIT OCTET STRING (optional) }
  final encapContentInfo = ASN1Sequence();
  encapContentInfo.add(
    ASN1ObjectIdentifier.fromIdentifierString(Oid.pkcs7Data),
  );
  // Omit content for simplicity
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

void main() {
  group('CadesParser', () {
    test('parse + encode round-trip is byte-identical when no mutations', () {
      final originalDer = buildSyntheticCadesBes();
      final sd = CadesSignedData.parse(originalDer);
      final encodedDer = sd.encode();

      expect(encodedDer, equals(originalDer));
    });

    test('setUnsignedAttribute on signer with NO existing unsignedAttrs', () {
      final originalDer = buildSyntheticCadesBes();
      final sd = CadesSignedData.parse(originalDer);

      // Add a dummy unsigned attribute
      final dummyAttrValueSet = ASN1Set();
      dummyAttrValueSet.add(
        ASN1OctetString(octets: Uint8List.fromList([1, 2, 3])),
      );
      final dummyAttrValueSetDer = derEncode(dummyAttrValueSet);

      sd.setUnsignedAttribute(
        Oid.signatureTimeStampToken,
        dummyAttrValueSetDer,
      );
      final encodedDer = sd.encode();

      // Re-parse and verify the attribute is present
      final sd2 = CadesSignedData.parse(encodedDer);
      final retrievedAttr = sd2.getUnsignedAttribute(
        Oid.signatureTimeStampToken,
      );
      expect(retrievedAttr, isNotNull);
      expect(retrievedAttr, equals(dummyAttrValueSetDer));
    });

    test('setUnsignedAttribute on signer WITH existing unsignedAttrs', () {
      // Build with an existing unsigned attribute
      final dummyAttrValueSet1 = ASN1Set();
      dummyAttrValueSet1.add(
        ASN1OctetString(octets: Uint8List.fromList([1, 2, 3])),
      );
      final dummyAttrValueSetDer1 = derEncode(dummyAttrValueSet1);

      final unsignedAttrs = {
        Oid.signatureTimeStampToken: dummyAttrValueSetDer1,
      };

      final originalDer = buildSyntheticCadesBes(unsignedAttrs: unsignedAttrs);
      final sd = CadesSignedData.parse(originalDer);

      // Add a new unsigned attribute
      final dummyAttrValueSet2 = ASN1Set();
      dummyAttrValueSet2.add(
        ASN1OctetString(octets: Uint8List.fromList([4, 5, 6])),
      );
      final dummyAttrValueSetDer2 = derEncode(dummyAttrValueSet2);

      sd.setUnsignedAttribute(Oid.certificateValues, dummyAttrValueSetDer2);
      final encodedDer = sd.encode();

      // Re-parse and verify both attributes are present
      final sd2 = CadesSignedData.parse(encodedDer);
      final retrievedAttr1 = sd2.getUnsignedAttribute(
        Oid.signatureTimeStampToken,
      );
      final retrievedAttr2 = sd2.getUnsignedAttribute(Oid.certificateValues);

      expect(retrievedAttr1, isNotNull);
      expect(retrievedAttr1, equals(dummyAttrValueSetDer1));
      expect(retrievedAttr2, isNotNull);
      expect(retrievedAttr2, equals(dummyAttrValueSetDer2));
    });

    test('setUnsignedAttribute REPLACES existing attr with same OID', () {
      // Build with an existing unsigned attribute
      final dummyAttrValueSet1 = ASN1Set();
      dummyAttrValueSet1.add(
        ASN1OctetString(octets: Uint8List.fromList([1, 2, 3])),
      );
      final dummyAttrValueSetDer1 = derEncode(dummyAttrValueSet1);

      final unsignedAttrs = {
        Oid.signatureTimeStampToken: dummyAttrValueSetDer1,
      };

      final originalDer = buildSyntheticCadesBes(unsignedAttrs: unsignedAttrs);
      final sd = CadesSignedData.parse(originalDer);

      // Replace the existing attribute
      final dummyAttrValueSet2 = ASN1Set();
      dummyAttrValueSet2.add(
        ASN1OctetString(octets: Uint8List.fromList([7, 8, 9])),
      );
      final dummyAttrValueSetDer2 = derEncode(dummyAttrValueSet2);

      sd.setUnsignedAttribute(
        Oid.signatureTimeStampToken,
        dummyAttrValueSetDer2,
      );
      final encodedDer = sd.encode();

      // Re-parse and verify the attribute is replaced
      final sd2 = CadesSignedData.parse(encodedDer);
      final retrievedAttr = sd2.getUnsignedAttribute(
        Oid.signatureTimeStampToken,
      );

      expect(retrievedAttr, isNotNull);
      expect(retrievedAttr, equals(dummyAttrValueSetDer2));
      expect(retrievedAttr, isNot(equals(dummyAttrValueSetDer1)));
    });

    test('getUnsignedAttribute returns the right bytes; null when absent', () {
      final dummyAttrValueSet = ASN1Set();
      dummyAttrValueSet.add(
        ASN1OctetString(octets: Uint8List.fromList([1, 2, 3])),
      );
      final dummyAttrValueSetDer = derEncode(dummyAttrValueSet);

      final unsignedAttrs = {Oid.signatureTimeStampToken: dummyAttrValueSetDer};

      final originalDer = buildSyntheticCadesBes(unsignedAttrs: unsignedAttrs);
      final sd = CadesSignedData.parse(originalDer);

      final retrievedAttr = sd.getUnsignedAttribute(
        Oid.signatureTimeStampToken,
      );
      expect(retrievedAttr, isNotNull);
      expect(retrievedAttr, equals(dummyAttrValueSetDer));

      final absentAttr = sd.getUnsignedAttribute(Oid.certificateValues);
      expect(absentAttr, isNull);
    });

    test('embeddedCertificates lists the right count', () {
      // Build a dummy certificate (just a valid SEQUENCE)
      final dummyCert = ASN1Sequence();
      dummyCert.add(ASN1Integer(BigInt.from(1))); // dummy content
      final dummyCertDer = derEncode(dummyCert);

      final originalDer = buildSyntheticCadesBes(
        embeddedCerts: [dummyCertDer, dummyCertDer],
      );
      final sd = CadesSignedData.parse(originalDer);

      expect(sd.embeddedCertificates.length, equals(2));
      expect(sd.embeddedCertificates[0], equals(dummyCertDer));
      expect(sd.embeddedCertificates[1], equals(dummyCertDer));
    });

    test('parse TRUE IMPLICIT signedAttrs (no inner SET wrapper)', () {
      // Build a CMS with TRUE IMPLICIT signedAttrs (raw TLVs, no inner 0x31 SET tag)
      // This tests the _parseImplicitSetOf compatibility shim.

      // Build SignerInfo with TRUE IMPLICIT signedAttrs
      final signerInfo = ASN1Sequence();
      signerInfo.add(ASN1Integer(BigInt.from(3))); // version

      // sid
      final issuerName = ASN1Sequence();
      final sid = ASN1Sequence();
      sid.add(issuerName);
      sid.add(ASN1Integer(BigInt.from(12345)));
      signerInfo.add(sid);

      // digestAlgorithm
      signerInfo.add(algorithmIdentifier(Oid.sha256));

      // signedAttrs [0] IMPLICIT: build as raw TLVs (no inner SET wrapper)
      // Create two Attribute SEQUENCEs
      final attr1 = ASN1Sequence();
      attr1.add(ASN1ObjectIdentifier.fromIdentifierString(Oid.contentType));
      final attr1Values = ASN1Set();
      attr1Values.add(ASN1ObjectIdentifier.fromIdentifierString(Oid.pkcs7Data));
      attr1.add(attr1Values);

      final attr2 = ASN1Sequence();
      attr2.add(ASN1ObjectIdentifier.fromIdentifierString(Oid.messageDigest));
      final attr2Values = ASN1Set();
      attr2Values.add(ASN1OctetString(octets: Uint8List(32)));
      attr2.add(attr2Values);

      // Encode both attributes and concatenate their bytes (TRUE IMPLICIT)
      final attr1Bytes = derEncode(attr1);
      final attr2Bytes = derEncode(attr2);
      final implicitAttrsBytes = Uint8List.fromList([
        ...attr1Bytes,
        ...attr2Bytes,
      ]);

      // Wrap as [0] IMPLICIT with the concatenated bytes
      final tag = 0xA0;
      final result = BytesBuilder();
      result.addByte(tag);
      encodeLength(result, implicitAttrsBytes.length);
      result.add(implicitAttrsBytes);
      final signedAttrsElem = ASN1Parser(result.toBytes()).nextObject();
      signerInfo.add(signedAttrsElem);

      // signatureAlgorithm
      signerInfo.add(algorithmIdentifier(Oid.sha256WithRSA));

      // signature
      signerInfo.add(ASN1OctetString(octets: Uint8List(256)));

      // Build rest of CMS
      final signerInfos = ASN1Set();
      signerInfos.add(signerInfo);

      final signedData = ASN1Sequence();
      signedData.add(ASN1Integer(BigInt.from(3))); // version

      final digestAlgorithms = ASN1Set();
      digestAlgorithms.add(algorithmIdentifier(Oid.sha256));
      signedData.add(digestAlgorithms);

      final encapContentInfo = ASN1Sequence();
      encapContentInfo.add(
        ASN1ObjectIdentifier.fromIdentifierString(Oid.pkcs7Data),
      );
      signedData.add(encapContentInfo);

      signedData.add(signerInfos);

      final contentInfo = ASN1Sequence();
      contentInfo.add(
        ASN1ObjectIdentifier.fromIdentifierString(Oid.pkcs7SignedData),
      );
      contentInfo.add(explicit(0, signedData));

      final cmsBytes = derEncode(contentInfo);

      // Parse and verify signedAttrsDer works
      final sd = CadesSignedData.parse(cmsBytes);
      final signedAttrsDer = sd.signedAttrsDer;

      // Should be a valid SET OF with 2 elements
      final decodedSet = derDecode(signedAttrsDer) as ASN1Set;
      expect(decodedSet.elements, isNotNull);
      expect(decodedSet.elements!.length, equals(2));
    });

    test(
      'encapContentInfoForAtsV3 returns only OID TLV for detached content',
      () {
        // Build CMS with detached eContent (just eContentType, no [0] wrapper)
        final originalDer = buildSyntheticCadesBes();
        final sd = CadesSignedData.parse(originalDer);

        final atsV3Input = sd.encapContentInfoForAtsV3;

        // Should be just the OID TLV (id-data = 1.2.840.113549.1.7.1)
        // OID encoding: 06 09 2A 86 48 86 F7 0D 01 07 01
        // Total: 11 bytes (2 header + 9 content)
        expect(atsV3Input.length, equals(11));
        expect(atsV3Input[0], equals(0x06)); // OID tag
        expect(atsV3Input[1], equals(0x09)); // length
      },
    );

    test('encapContentInfoForAtsV3 includes [0] eContent when present', () {
      // Build CMS with attached eContent
      final signerInfo = ASN1Sequence();
      signerInfo.add(ASN1Integer(BigInt.from(3)));

      final issuerName = ASN1Sequence();
      final sid = ASN1Sequence();
      sid.add(issuerName);
      sid.add(ASN1Integer(BigInt.from(12345)));
      signerInfo.add(sid);

      signerInfo.add(algorithmIdentifier(Oid.sha256));

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
      signerInfo.add(algorithmIdentifier(Oid.sha256WithRSA));
      signerInfo.add(ASN1OctetString(octets: Uint8List(256)));

      final signerInfos = ASN1Set();
      signerInfos.add(signerInfo);

      final signedData = ASN1Sequence();
      signedData.add(ASN1Integer(BigInt.from(3)));

      final digestAlgorithms = ASN1Set();
      digestAlgorithms.add(algorithmIdentifier(Oid.sha256));
      signedData.add(digestAlgorithms);

      // encapContentInfo WITH [0] EXPLICIT eContent
      final encapContentInfo = ASN1Sequence();
      encapContentInfo.add(
        ASN1ObjectIdentifier.fromIdentifierString(Oid.pkcs7Data),
      );
      // Add [0] EXPLICIT eContent (a small OCTET STRING)
      final eContentData = Uint8List.fromList([1, 2, 3, 4, 5]);
      final eContent = explicit(0, ASN1OctetString(octets: eContentData));
      encapContentInfo.add(eContent);
      signedData.add(encapContentInfo);

      signedData.add(signerInfos);

      final contentInfo = ASN1Sequence();
      contentInfo.add(
        ASN1ObjectIdentifier.fromIdentifierString(Oid.pkcs7SignedData),
      );
      contentInfo.add(explicit(0, signedData));

      final cmsBytes = derEncode(contentInfo);
      final sd = CadesSignedData.parse(cmsBytes);

      final atsV3Input = sd.encapContentInfoForAtsV3;

      // Should contain OID TLV + [0] eContent TLV
      // OID: 11 bytes
      // [0] eContent: tag (1) + length (1) + OCTET STRING TLV (2 + 5) = 9 bytes
      // Total: 11 + 9 = 20 bytes
      expect(atsV3Input.length, equals(20));
      expect(atsV3Input[0], equals(0x06)); // OID tag
      expect(atsV3Input[11], equals(0xA0)); // [0] tag
    });

    test('multi-signer CMS is rejected', () {
      // Build a CMS with two SignerInfos
      final signerInfo1 = ASN1Sequence();
      signerInfo1.add(ASN1Integer(BigInt.from(3)));
      final issuerName1 = ASN1Sequence();
      final sid1 = ASN1Sequence();
      sid1.add(issuerName1);
      sid1.add(ASN1Integer(BigInt.from(12345)));
      signerInfo1.add(sid1);
      signerInfo1.add(algorithmIdentifier(Oid.sha256));

      final signedAttrs1 = ASN1Set();
      final contentTypeAttr1 = ASN1Sequence();
      contentTypeAttr1.add(
        ASN1ObjectIdentifier.fromIdentifierString(Oid.contentType),
      );
      final contentTypeAttrValues1 = ASN1Set();
      contentTypeAttrValues1.add(
        ASN1ObjectIdentifier.fromIdentifierString(Oid.pkcs7Data),
      );
      contentTypeAttr1.add(contentTypeAttrValues1);
      signedAttrs1.add(contentTypeAttr1);

      final messageDigestAttr1 = ASN1Sequence();
      messageDigestAttr1.add(
        ASN1ObjectIdentifier.fromIdentifierString(Oid.messageDigest),
      );
      final messageDigestAttrValues1 = ASN1Set();
      messageDigestAttrValues1.add(ASN1OctetString(octets: Uint8List(32)));
      messageDigestAttr1.add(messageDigestAttrValues1);
      signedAttrs1.add(messageDigestAttr1);

      signerInfo1.add(wrapImplicit(0, signedAttrs1));
      signerInfo1.add(algorithmIdentifier(Oid.sha256WithRSA));
      signerInfo1.add(ASN1OctetString(octets: Uint8List(256)));

      // Create a second signer (identical for simplicity)
      final signerInfo2 = ASN1Sequence();
      signerInfo2.add(ASN1Integer(BigInt.from(3)));
      final issuerName2 = ASN1Sequence();
      final sid2 = ASN1Sequence();
      sid2.add(issuerName2);
      sid2.add(ASN1Integer(BigInt.from(54321)));
      signerInfo2.add(sid2);
      signerInfo2.add(algorithmIdentifier(Oid.sha256));

      final signedAttrs2 = ASN1Set();
      final contentTypeAttr2 = ASN1Sequence();
      contentTypeAttr2.add(
        ASN1ObjectIdentifier.fromIdentifierString(Oid.contentType),
      );
      final contentTypeAttrValues2 = ASN1Set();
      contentTypeAttrValues2.add(
        ASN1ObjectIdentifier.fromIdentifierString(Oid.pkcs7Data),
      );
      contentTypeAttr2.add(contentTypeAttrValues2);
      signedAttrs2.add(contentTypeAttr2);

      final messageDigestAttr2 = ASN1Sequence();
      messageDigestAttr2.add(
        ASN1ObjectIdentifier.fromIdentifierString(Oid.messageDigest),
      );
      final messageDigestAttrValues2 = ASN1Set();
      messageDigestAttrValues2.add(ASN1OctetString(octets: Uint8List(32)));
      messageDigestAttr2.add(messageDigestAttrValues2);
      signedAttrs2.add(messageDigestAttr2);

      signerInfo2.add(wrapImplicit(0, signedAttrs2));
      signerInfo2.add(algorithmIdentifier(Oid.sha256WithRSA));
      signerInfo2.add(ASN1OctetString(octets: Uint8List(256)));

      final signerInfos = ASN1Set();
      signerInfos.add(signerInfo1);
      signerInfos.add(signerInfo2);

      final signedData = ASN1Sequence();
      signedData.add(ASN1Integer(BigInt.from(3)));

      final digestAlgorithms = ASN1Set();
      digestAlgorithms.add(algorithmIdentifier(Oid.sha256));
      signedData.add(digestAlgorithms);

      final encapContentInfo = ASN1Sequence();
      encapContentInfo.add(
        ASN1ObjectIdentifier.fromIdentifierString(Oid.pkcs7Data),
      );
      signedData.add(encapContentInfo);

      signedData.add(signerInfos);

      final contentInfo = ASN1Sequence();
      contentInfo.add(
        ASN1ObjectIdentifier.fromIdentifierString(Oid.pkcs7SignedData),
      );
      contentInfo.add(explicit(0, signedData));

      final cmsBytes = derEncode(contentInfo);

      // Parsing should throw CadesException
      expect(
        () => CadesSignedData.parse(cmsBytes),
        throwsA(
          predicate<dynamic>(
            (e) =>
                e is CadesException &&
                e.toString().contains('Multi-signer CMS not supported'),
          ),
        ),
      );
    });
  });
}
