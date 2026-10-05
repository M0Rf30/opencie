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

Uint8List _intSet(int v) =>
    derEncode(ASN1Set()..add(ASN1Integer(BigInt.from(v))));

bool _lexLess(Uint8List a, Uint8List b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return a[i] < b[i];
  }
  return a.length < b.length;
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

    test('keeps other unsigned attributes and DER-orders the SET', () async {
      // Deliberately inserted in descending OID order.
      final bes = buildSyntheticCadesBes(
        unsignedAttrs: {
          Oid.revocationValues: _intSet(2),
          Oid.certificateValues: _intSet(1),
        },
      );
      final upgrader = CadesTUpgrader(
        tspClient: TspClient(httpClient: fakeTsaClient()),
        tspUrl: _tsaUrl,
      );

      final upgraded = CadesSignedData.parse(await upgrader.upgrade(bes));

      expect(upgraded.getUnsignedAttribute(Oid.certificateValues), _intSet(1));
      expect(upgraded.getUnsignedAttribute(Oid.revocationValues), _intSet(2));
      expect(
        upgraded.getUnsignedAttribute(Oid.signatureTimeStampToken),
        isNotNull,
      );

      // File order of the attributes is DER canonical (ascending encoding).
      final inFileOrder = upgraded.unsignedAttributesForArchiveTimestamp
          .map((e) => e.value)
          .toList();
      expect(inFileOrder, hasLength(3));
      for (var i = 1; i < inFileOrder.length; i++) {
        expect(
          _lexLess(inFileOrder[i - 1], inFileOrder[i]),
          isTrue,
          reason: 'attribute $i is out of DER order',
        );
      }
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
