// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/services/ltv/asn1/der.dart';
import 'package:opencie/services/ltv/asn1/oids.dart';
import 'package:opencie/services/ltv/cades/cades_models.dart';
import 'package:opencie/services/ltv/cades/cades_parser.dart';
import 'package:opencie/services/ltv/cades/cades_t.dart';
import 'package:opencie/services/ltv/tsp/tsp_client.dart';
import 'package:pointycastle/asn1.dart';

import '../../services/sign/upgrade_test_support.dart';
import 'synthetic_cades.dart';

final _tsaUrl = Uri.parse('https://tsa.test/tsr');

Uint8List _rawAttr(String oid, List<int> ints) =>
    buildSyntheticAttribute(oid, ints);

int _indexOf(Uint8List haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

/// Whether [at] is immediately preceded by a `[1]` (0xA1) tag + length header,
/// i.e. the bytes sit directly under a true IMPLICIT tag.
bool _directlyUnderA1(Uint8List out, int at) {
  for (final hdr in [2, 3, 4]) {
    if (at - hdr < 0 || out[at - hdr] != 0xA1) continue;
    final l = out[at - hdr + 1];
    final expectHdr = l < 0x80 ? 2 : 2 + (l & 0x7F);
    if (expectHdr == hdr) return true;
  }
  return false;
}

void main() {
  group('CadesTUpgrader', () {
    test('adds a signature-time-stamp over the signature value', () async {
      final bes = buildSyntheticCadesBes();
      final before = CadesSignedData.parse(bes);
      final imprints = <Uint8List>[];
      final upgrader = CadesTUpgrader(
        tspClient: TspClient(httpClient: fakeTsaClient(imprints: imprints)),
        tspUrl: _tsaUrl,
      );

      final upgraded = await upgrader.upgrade(bes);

      final after = CadesSignedData.parse(upgraded);
      final attr = after.getUnsignedAttribute(Oid.signatureTimeStampToken);
      expect(attr, isNotNull);

      // SET OF TimeStampToken: one ContentInfo (id-signedData).
      final values = derDecode(attr!) as ASN1Set;
      expect(values.elements, hasLength(1));
      final token = values.elements!.single as ASN1Sequence;
      expect(
        (token.elements!.first as ASN1ObjectIdentifier)
            .objectIdentifierAsString,
        Oid.pkcs7SignedData,
      );

      // The imprint is SHA-256 over the content octets of the signature
      // OCTET STRING — not over its TLV, not over the document.
      expect(imprints, hasLength(1));
      expect(imprints.single, sha256Of(before.signatureValueBytes));
      expect(imprints.single, isNot(sha256Of(before.signatureValueDer)));

      // The signature itself is untouched.
      expect(after.signatureValueBytes, before.signatureValueBytes);
      expect(after.signedAttrsDer, before.signedAttrsDer);
      expect(after.encapContentInfoDer, before.encapContentInfoDer);
    });

    test('is idempotent: an existing signature-time-stamp is kept and the '
        'TSA is not contacted', () async {
      final requests = <Uri>[];
      final upgrader = CadesTUpgrader(
        tspClient: TspClient(httpClient: fakeTsaClient(requests: requests)),
        tspUrl: _tsaUrl,
      );

      final once = await upgrader.upgrade(buildSyntheticCadesBes());
      expect(requests, hasLength(1));

      final twice = await upgrader.upgrade(once);

      expect(requests, hasLength(1));
      expect(twice, once);
    });

    test('keeps existing unsigned attributes byte-for-byte, in their '
        'original order, and appends the timestamp', () async {
      // ETSI EN 319 122-1 clause 5.5.3: augmentation preserves the binary
      // encoding of already present unsigned attributes; RFC 5652 §5.3 does
      // not require DER ordering for unsignedAttrs. Both attributes are in
      // descending encoding order and the first has a non-DER SET OF.
      final rev = _rawAttr(Oid.revocationValues, [2, 1]);
      final cert = _rawAttr(Oid.certificateValues, [4, 3]);
      final bes = buildSyntheticCadesBes(rawUnsignedAttrs: [rev, cert]);
      final upgrader = CadesTUpgrader(
        tspClient: TspClient(httpClient: fakeTsaClient()),
        tspUrl: _tsaUrl,
      );

      final out = await upgrader.upgrade(bes);
      final upgraded = CadesSignedData.parse(out);

      final attrs = upgraded.unsignedAttributesForArchiveTimestamp;
      expect(attrs.map((e) => e.key).toList(), [
        Oid.revocationValues,
        Oid.certificateValues,
        Oid.signatureTimeStampToken, // appended last
      ]);
      expect(attrs[0].value, rev);
      expect(attrs[1].value, cert);

      // The original bytes sit contiguously in the output, directly under a
      // true [1] IMPLICIT header: no inner SET header, no re-sorting, no
      // re-encoding.
      final at = _indexOf(out, [...rev, ...cert]);
      expect(at, greaterThan(1));
      expect(_directlyUnderA1(out, at), isTrue);

      // And the rest of the signature is untouched.
      final before = CadesSignedData.parse(bes);
      expect(upgraded.signedAttrsDer, before.signedAttrsDer);
      expect(upgraded.signatureValueDer, before.signatureValueDer);
    });

    test('unsigned attributes written in the legacy [1] { SET } shape are '
        'read and re-emitted as a true [1] IMPLICIT', () async {
      final bes = buildSyntheticCadesBes(
        unsignedAttrs: {
          Oid.revocationValues: derEncode(
            ASN1Set()..add(ASN1Integer(BigInt.two)),
          ),
        },
      );
      final upgrader = CadesTUpgrader(
        tspClient: TspClient(httpClient: fakeTsaClient()),
        tspUrl: _tsaUrl,
      );

      final out = await upgrader.upgrade(bes);

      final attrs = CadesSignedData.parse(
        out,
      ).unsignedAttributesForArchiveTimestamp;
      expect(attrs.map((e) => e.key).toList(), [
        Oid.revocationValues,
        Oid.signatureTimeStampToken,
      ]);
      // First Attribute starts right after the A1 header (30, not 31).
      final at = _indexOf(out, attrs.first.value);
      expect(_directlyUnderA1(out, at), isTrue);
    });

    test('a TSA transport failure throws CadesException', () async {
      final upgrader = CadesTUpgrader(
        tspClient: TspClient(
          httpClient: fakeTsaClient(failHosts: {_tsaUrl.host}),
        ),
        tspUrl: _tsaUrl,
      );

      expect(
        () => upgrader.upgrade(buildSyntheticCadesBes()),
        throwsA(isA<CadesException>()),
      );
    });

    test('unparsable input throws CadesException', () async {
      final upgrader = CadesTUpgrader(
        tspClient: TspClient(httpClient: fakeTsaClient()),
        tspUrl: _tsaUrl,
      );

      expect(
        () => upgrader.upgrade(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<CadesException>()),
      );
    });
  });
}
