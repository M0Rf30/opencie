// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/services/ltv/asn1/der.dart';
import 'package:opencie/services/ltv/asn1/oids.dart';
import 'package:opencie/services/ltv/cades/cades_lta.dart';
import 'package:opencie/services/ltv/cades/cades_models.dart';
import 'package:opencie/services/ltv/cades/cades_parser.dart';
import 'package:opencie/services/ltv/crl/crl_models.dart';
import 'package:opencie/services/ltv/ocsp/ocsp_models.dart';
import 'package:opencie/services/ltv/tsp/tsp_client.dart';
import 'package:pointycastle/asn1.dart';

import '../../services/sign/upgrade_test_support.dart';
import 'ats_v3_reference.dart';
import 'synthetic_cades.dart';

// ETSI EN 319 122-1 §5.5.2 / §5.5.3: every expectation below is derived from
// ats_v3_reference.dart, which re-reads the standard on raw bytes and shares
// no code with the production implementation.

final _tsaUrl = Uri.parse('https://tsa.test/tsr');

Uint8List _cert(int n) => Uint8List.fromList([0x30, 0x03, 0x02, 0x01, n]);

CadesLtaUpgrader _upgrader({
  List<Uint8List>? imprints,
  List<String>? hashOids,
  List<Uint8List>? tsaCertificates,
  String hashAlgorithmOid = Oid.sha256,
  PreviousTimestampValidation? previous,
  List<Uri>? requests,
}) {
  return CadesLtaUpgrader(
    tspClient: TspClient(
      httpClient: fakeTsaClient(
        imprints: imprints,
        hashOids: hashOids,
        tsaCertificates: tsaCertificates,
        requests: requests,
      ),
    ),
    tspUrl: _tsaUrl,
    hashAlgorithmOid: hashAlgorithmOid,
    previousTimestampValidation: previous,
  );
}

/// The ats-hash-index-v3 attribute value (SET OF) inside the newest archive
/// time-stamp token of [p7].
Uint8List _hashIndexAttrOfNewestToken(Uint8List p7) {
  final tokens = CadesSignedData.parse(p7).archiveTimeStampTokens;
  final token = CadesSignedData.parse(tokens.last);
  return token.getUnsignedAttribute(Oid.atsHashIndexV3)!;
}

/// DER `SET { hashIndex }`, the way the attribute value must look.
Uint8List _expectedHashIndexAttr(Uint8List input, {String? alg}) => refTlv(
  0x31,
  referenceAtsHashIndex(input, hashAlgorithmOid: alg ?? Oid.sha256),
);

/// A signature with a few pre-existing unsigned attributes, one of them with
/// several values in non-DER order.
Uint8List _signatureWithUnsignedAttrs() => buildSyntheticCadesBes(
  rawUnsignedAttrs: [
    buildSyntheticAttribute('1.2.3.4.5', [3, 1, 2]),
    buildSyntheticAttribute(Oid.certificateValues, [7]),
  ],
);

void main() {
  group('archive-time-stamp-v3 message imprint (EN 319 122-1 §5.5.3)', () {
    test('detached signature: matches the independent reference', () async {
      final bes = _signatureWithUnsignedAttrs();
      final imprints = <Uint8List>[];

      await _upgrader(imprints: imprints).upgrade(bes);

      expect(
        imprints.single,
        refDigest(Oid.sha256, referenceArchiveImprintInput(bes)),
      );
    });

    test('attached content: hashes the eContent octets, not the signed '
        'attribute', () async {
      final content = Uint8List.fromList(utf8.encode('the signed document'));
      final bes = buildSyntheticCadesBes(eContent: content);
      final imprints = <Uint8List>[];

      await _upgrader(imprints: imprints).upgrade(bes);

      final input = referenceArchiveImprintInput(bes);
      expect(imprints.single, refDigest(Oid.sha256, input));
      // Sanity: the data hash really sits right after the eContentType TLV.
      final eContentType = RefSignature(bes).encap.children.first.raw;
      expect(
        input.sublist(eContentType.length, eContentType.length + 32),
        refDigest(Oid.sha256, content),
      );
    });

    test(
      'the imprint covers the SignerInfo fields as encoded, including '
      'the [0] tag of signedAttrs, and not the unsigned attributes',
      () async {
        final bes = _signatureWithUnsignedAttrs();
        final sd = CadesSignedData.parse(bes);
        final ref = RefSignature(bes);
        final expectedFields = Uint8List.fromList([
          for (final f in ref.signerFields) ...f.raw,
        ]);

        expect(sd.signerInfoFieldsForAtsV3, expectedFields);
        expect(
          ref.signerFields.map((f) => f.tag).toList(),
          [0x02, 0x30, 0x30, 0xA0, 0x30, 0x04],
          reason:
              'version, sid, digestAlgorithm, [0] signedAttrs, '
              'signatureAlgorithm, signature',
        );
      },
    );

    test('a detached signature using another digest algorithm than the '
        'stamp cannot be archive-stamped (no request is made)', () async {
      final bes = buildSyntheticCadesBes(); // SHA-256 signer
      final requests = <Uri>[];

      await expectLater(
        _upgrader(
          hashAlgorithmOid: Oid.sha384,
          requests: requests,
        ).upgrade(bes),
        throwsA(isA<CadesException>()),
      );
      expect(requests, isEmpty);
    });
  });

  group('ats-hash-index-v3 (EN 319 122-1 §5.5.2)', () {
    test('unsignedAttrValuesHashIndex hashes attrType || AttributeValue for '
        'every value of every unsigned attribute', () async {
      final bes = _signatureWithUnsignedAttrs();

      final out = await _upgrader().upgrade(bes);

      expect(_hashIndexAttrOfNewestToken(out), _expectedHashIndexAttr(bes));

      // Spell out the first entry: type TLV followed by value TLV.
      final parts = CadesSignedData.parse(bes).unsignedAttributeParts;
      expect(parts, hasLength(2));
      expect(parts.first.valueTlvs, hasLength(3));
      final typeTlv = refOid('1.2.3.4.5');
      expect(parts.first.typeTlv, typeTlv);
      final entry = Uint8List.fromList([
        ...typeTlv,
        ...parts.first.valueTlvs.first,
      ]);
      final hashIndex = referenceAtsHashIndex(bes);
      final attrHashes = refParse(hashIndex).single.children[3].children;
      expect(attrHashes, hasLength(4)); // 3 values + 1 value
      expect(
        attrHashes.any((h) => _same(h.value, refDigest(Oid.sha256, entry))),
        isTrue,
      );
    });

    test('certificatesHashIndex / crlsHashIndex cover SignedData.certificates '
        'and SignedData.crls, not the revocation-values attribute', () async {
      final content = Uint8List.fromList(utf8.encode('doc'));
      final sd = CadesSignedData.parse(
        buildSyntheticCadesBes(
          eContent: content,
          rawUnsignedAttrs: [
            buildSyntheticAttribute(Oid.revocationValues, [1]),
          ],
        ),
      );
      sd
        ..addSignedDataCertificate(_cert(1))
        ..addSignedDataCertificate(_cert(2))
        ..addSignedDataCrl(buildSyntheticCrl())
        ..addSignedDataOcspResponse(buildSyntheticOcspResponse());
      final prepared = sd.encode();

      final reparsed = CadesSignedData.parse(prepared);
      expect(reparsed.signedDataCertificateTlvs, [_cert(1), _cert(2)]);
      expect(reparsed.signedDataCrlTlvs, hasLength(2));
      expect(reparsed.signedDataCrlTlvs.first, buildSyntheticCrl());
      // OCSP travels as [1] OtherRevocationInfoFormat { id-ri-ocsp-response }.
      expect(reparsed.signedDataCrlTlvs.last[0], 0xA1);

      final out = await _upgrader().upgrade(prepared);

      expect(
        _hashIndexAttrOfNewestToken(out),
        _expectedHashIndexAttr(prepared),
      );
      final idx = refParse(referenceAtsHashIndex(prepared)).single.children;
      expect(idx[1].children, hasLength(2), reason: 'two certificates');
      expect(idx[2].children, hasLength(2), reason: 'CRL + OCSP');
      expect(idx[3].children, hasLength(1), reason: 'one attribute value');
    });

    test('with nothing to index, the three lists are empty SEQUENCEs '
        '(NOTE 3)', () async {
      final out = await _upgrader().upgrade(buildSyntheticCadesBes());

      final attr = _hashIndexAttrOfNewestToken(out);
      final idx = refParse(attr).single.children.single.children;
      expect(idx[1].raw, [0x30, 0x00]);
      expect(idx[2].raw, [0x30, 0x00]);
      expect(idx[3].raw, [0x30, 0x00]);
    });

    test('hashIndAlgorithm equals the message imprint algorithm of the '
        'stamp (SHA-384)', () async {
      final content = Uint8List.fromList(utf8.encode('doc'));
      final bes = buildSyntheticCadesBes(
        eContent: content,
        digestAlgorithmOid: Oid.sha384,
      );
      final imprints = <Uint8List>[];
      final hashOids = <String>[];

      final out = await _upgrader(
        imprints: imprints,
        hashOids: hashOids,
        hashAlgorithmOid: Oid.sha384,
      ).upgrade(bes);

      expect(hashOids, [Oid.sha384]);
      expect(imprints.single, hasLength(48));
      expect(
        imprints.single,
        refDigest(
          Oid.sha384,
          referenceArchiveImprintInput(bes, hashAlgorithmOid: Oid.sha384),
        ),
      );
      final attr = _hashIndexAttrOfNewestToken(out);
      expect(attr, _expectedHashIndexAttr(bes, alg: Oid.sha384));
      final index = derDecode(attr) as ASN1Set;
      final alg =
          (index.elements!.single as ASN1Sequence).elements!.first
              as ASN1Sequence;
      expect(
        (alg.elements!.first as ASN1ObjectIdentifier).objectIdentifierAsString,
        Oid.sha384,
      );
    });

    test('the hash index travels in the token and is DER', () async {
      final bes = _signatureWithUnsignedAttrs();

      final out = await _upgrader().upgrade(bes);

      final attr = _hashIndexAttrOfNewestToken(out);
      expect(attr[0], 0x31);
      expect(derEncode(derDecode(attr)), attr);
    });
  });

  group('renewal: archive time-stamps are appended, never replaced', () {
    test(
      'the second stamp covers the first and leaves it byte-identical',
      () async {
        final bes = _signatureWithUnsignedAttrs();
        final imprints1 = <Uint8List>[];
        final imprints2 = <Uint8List>[];

        final lta1 = await _upgrader(imprints: imprints1).upgrade(bes);
        final lta2 = await _upgrader(imprints: imprints2).upgrade(lta1);

        final tokens1 = CadesSignedData.parse(lta1).archiveTimeStampTokens;
        final tokens2 = CadesSignedData.parse(lta2).archiveTimeStampTokens;
        expect(tokens1, hasLength(1));
        expect(tokens2, hasLength(2));
        expect(tokens2.first, tokens1.single);

        // Every attribute of lta1 is still there, unchanged and in order, with
        // the new archive-time-stamp-v3 as the last one.
        final parts1 = CadesSignedData.parse(lta1).unsignedAttributeParts;
        final parts2 = CadesSignedData.parse(lta2).unsignedAttributeParts;
        expect(parts2, hasLength(parts1.length + 1));
        for (var i = 0; i < parts1.length; i++) {
          expect(parts2[i].typeTlv, parts1[i].typeTlv);
          expect(parts2[i].valueTlvs, parts1[i].valueTlvs);
        }
        expect(parts2.last.oid, Oid.archiveTimeStampV3);
        expect(
          parts2.where((p) => p.oid == Oid.archiveTimeStampV3),
          hasLength(2),
        );

        // The first stamp's imprint and the second one's differ, and the
        // second one is exactly the reference over lta1, whose unsigned
        // attributes now include the first archive-time-stamp-v3.
        expect(imprints2.single, isNot(imprints1.single));
        expect(
          imprints2.single,
          refDigest(Oid.sha256, referenceArchiveImprintInput(lta1)),
        );
        expect(_hashIndexAttrOfNewestToken(lta2), _expectedHashIndexAttr(lta1));
        // 3 + 1 original values plus the first stamp.
        final idx = refParse(referenceAtsHashIndex(lta1)).single.children;
        expect(idx[3].children, hasLength(5));
      },
    );

    test('validation data for the previous stamps TSA is added to '
        'SignedData before the new stamp, and is covered by it', () async {
      final bes = _signatureWithUnsignedAttrs();
      final tsa1 = _cert(0x11);
      final extra = _cert(0x22);
      final lta1 = await _upgrader(tsaCertificates: [tsa1]).upgrade(bes);

      final seen = <List<Uint8List>>[];
      final imprints2 = <Uint8List>[];
      final crl = CrlData(
        rawCrl: buildSyntheticCrl(),
        issuerDn: Uint8List(0),
        thisUpdate: DateTime.utc(2026),
      );
      final ocsp = OcspResponse(
        status: OcspResponseStatus.successful,
        rawResponse: buildSyntheticOcspResponse(marker: 9),
      );
      final lta2 = await _upgrader(
        imprints: imprints2,
        tsaCertificates: [_cert(0x33)],
        previous: (certs) async {
          seen.add(certs);
          return ValidationMaterial(
            certificates: [extra],
            crls: [crl],
            ocspResponses: [ocsp],
          );
        },
      ).upgrade(lta1);

      // The provider got the previous TSA's certificate.
      expect(seen, [
        [tsa1],
      ]);

      final out = CadesSignedData.parse(lta2);
      expect(out.signedDataCertificateTlvs, [extra]);
      expect(out.signedDataCrlTlvs, hasLength(2));
      expect(out.signedDataCrlTlvs.first, crl.rawCrl);
      expect(out.signedDataCrlTlvs.last[0], 0xA1);

      // The first stamp is untouched.
      expect(
        out.archiveTimeStampTokens.first,
        CadesSignedData.parse(lta1).archiveTimeStampTokens.single,
      );

      // The new imprint covers the extended SignedData: rebuild it the same
      // way and compare with the reference computed on those bytes.
      final prepared = CadesSignedData.parse(lta1)
        ..addSignedDataCertificate(extra)
        ..addSignedDataCrl(crl.rawCrl)
        ..addSignedDataOcspResponse(ocsp.rawResponse!);
      final preparedBytes = prepared.encode();
      expect(
        imprints2.single,
        refDigest(Oid.sha256, referenceArchiveImprintInput(preparedBytes)),
      );
      expect(
        _hashIndexAttrOfNewestToken(lta2),
        _expectedHashIndexAttr(preparedBytes),
      );
    });

    test('the provider is not consulted for a first stamp', () async {
      var calls = 0;
      await _upgrader(
        previous: (_) async {
          calls++;
          return null;
        },
      ).upgrade(buildSyntheticCadesBes());
      expect(calls, 0);
    });

    test('a failing provider does not prevent the renewal', () async {
      final lta1 = await _upgrader().upgrade(buildSyntheticCadesBes());

      final lta2 = await _upgrader(
        previous: (_) async => throw StateError('no network'),
      ).upgrade(lta1);

      expect(CadesSignedData.parse(lta2).archiveTimeStampTokens, hasLength(2));
    });
  });
}

bool _same(Uint8List a, Uint8List b) => bytesEqual(a, b);
