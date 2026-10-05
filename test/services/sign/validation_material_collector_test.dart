// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/providers/settings_provider.dart' show ValidationType;
import 'package:opencie/services/ltv/asn1/der.dart';
import 'package:opencie/services/ltv/asn1/oids.dart';
import 'package:opencie/services/ltv/crl/crl_models.dart';
import 'package:opencie/services/ltv/ocsp/ocsp_models.dart';
import 'package:opencie/services/sign/validation_material_collector.dart';
import 'package:pointycastle/asn1.dart';

/// Minimal structurally valid X.509 certificate: only subject and issuer
/// matter to the chain builder (no key identifiers, no AIA).
Uint8List _cert({required String subject, required String issuer}) {
  ASN1Sequence name(String cn) {
    final atv = ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromIdentifierString('2.5.4.3'))
      ..add(ASN1UTF8String(utf8StringValue: cn));
    return ASN1Sequence()..add(ASN1Set()..add(atv));
  }

  ASN1Object utcTime(String s) {
    final b = BytesBuilder()
      ..addByte(0x17)
      ..addByte(s.length)
      ..add(s.codeUnits);
    return ASN1Parser(b.toBytes()).nextObject();
  }

  final validity = ASN1Sequence()
    ..add(utcTime('260101000000Z'))
    ..add(utcTime('360101000000Z'));
  final spki = ASN1Sequence()
    ..add(algorithmIdentifier(Oid.rsaEncryption, parameters: ASN1Null()))
    ..add(ASN1BitString(stringValues: [0]));
  final tbs = ASN1Sequence()
    ..add(ASN1Integer(BigInt.from(subject.hashCode & 0xFFFF)))
    ..add(algorithmIdentifier(Oid.sha256WithRSA))
    ..add(name(issuer))
    ..add(validity)
    ..add(name(subject))
    ..add(spki);
  final cert = ASN1Sequence()
    ..add(tbs)
    ..add(algorithmIdentifier(Oid.sha256WithRSA))
    ..add(ASN1BitString(stringValues: [0]));
  return cert.encode();
}

/// Records every OCSP/CRL lookup; answers from the configured sets.
class _FakeRevocation implements RevocationSource {
  _FakeRevocation({
    required this.names,
    this.ocspFor = const {},
    this.crlFor = const {},
  });

  final Map<Uint8List, String> names;
  final Set<String> ocspFor;
  final Set<String> crlFor;
  final calls = <String>[];

  String _label(Uint8List der) =>
      names.entries.firstWhere((e) => bytesEqual(e.key, der)).value;

  @override
  Future<OcspResponse?> ocsp(Uint8List certDer, Uint8List issuerDer) async {
    final who = _label(certDer);
    calls.add('ocsp:$who');
    if (!ocspFor.contains(who)) return null;
    return OcspResponse(
      status: OcspResponseStatus.successful,
      rawResponse: Uint8List.fromList([who.codeUnitAt(0)]),
    );
  }

  @override
  Future<CrlData?> crl(Uint8List certDer) async {
    final who = _label(certDer);
    calls.add('crl:$who');
    if (!crlFor.contains(who)) return null;
    return CrlData(
      rawCrl: Uint8List.fromList([who.codeUnitAt(0)]),
      issuerDn: Uint8List(0),
      thisUpdate: DateTime.utc(2026),
    );
  }
}

void main() {
  late Uint8List leaf;
  late Uint8List sub;
  late Uint8List root;

  setUp(() {
    leaf = _cert(subject: 'Leaf', issuer: 'Sub');
    sub = _cert(subject: 'Sub', issuer: 'Root');
    root = _cert(subject: 'Root', issuer: 'Root');
  });

  ValidationMaterialCollector collectorWith(_FakeRevocation r) =>
      ValidationMaterialCollector(revocation: r);

  _FakeRevocation fake({
    Set<String> ocsp = const {},
    Set<String> crl = const {},
  }) => _FakeRevocation(
    names: {leaf: 'leaf', sub: 'sub', root: 'root'},
    ocspFor: ocsp,
    crlFor: crl,
  );

  group('ValidationMaterialCollector.buildChain', () {
    test('orders signer → issuer → root regardless of input order', () async {
      final chain = await collectorWith(fake()).buildChain([root, leaf, sub]);

      expect(chain, hasLength(3));
      expect(bytesEqual(chain[0], leaf), isTrue);
      expect(bytesEqual(chain[1], sub), isTrue);
      expect(bytesEqual(chain[2], root), isTrue);
    });

    test('stops when the issuer is unknown', () async {
      final chain = await collectorWith(fake()).buildChain([leaf]);

      expect(chain, hasLength(1));
      expect(bytesEqual(chain.single, leaf), isTrue);
    });

    test('no certificates → empty material', () async {
      final material = await collectorWith(
        fake(),
      ).collect(const [], ValidationType.ocspFirst);

      expect(material.certificates, isEmpty);
      expect(material.hasRevocationData, isFalse);
    });
  });

  group('ValidationMaterialCollector.collect routing', () {
    test('ocspOnly never touches CRLs, even when OCSP has nothing', () async {
      final r = fake(crl: {'leaf', 'sub'});
      final m = await collectorWith(
        r,
      ).collect([leaf, sub, root], ValidationType.ocspOnly);

      expect(r.calls, ['ocsp:leaf', 'ocsp:sub']);
      expect(m.crls, isEmpty);
      expect(m.ocspResponses, isEmpty);
      expect(m.hasRevocationData, isFalse);
      // Certificates are still returned for embedding.
      expect(m.certificates, hasLength(3));
    });

    test('crlOnly never touches OCSP', () async {
      final r = fake(ocsp: {'leaf', 'sub'}, crl: {'leaf'});
      final m = await collectorWith(
        r,
      ).collect([leaf, sub, root], ValidationType.crlOnly);

      expect(r.calls, ['crl:leaf', 'crl:sub']);
      expect(m.crls, hasLength(1));
      expect(m.ocspResponses, isEmpty);
    });

    test('ocspFirst falls back to CRL only where OCSP gave nothing', () async {
      final r = fake(ocsp: {'sub'}, crl: {'leaf'});
      final m = await collectorWith(
        r,
      ).collect([leaf, sub, root], ValidationType.ocspFirst);

      expect(r.calls, ['ocsp:leaf', 'crl:leaf', 'ocsp:sub']);
      expect(m.ocspResponses, hasLength(1));
      expect(m.crls, hasLength(1));
    });

    test(
      'crlFirst falls back to OCSP only where the CRL gave nothing',
      () async {
        final r = fake(ocsp: {'sub'}, crl: {'leaf'});
        final m = await collectorWith(
          r,
        ).collect([leaf, sub, root], ValidationType.crlFirst);

        expect(r.calls, ['crl:leaf', 'crl:sub', 'ocsp:sub']);
        expect(m.crls, hasLength(1));
        expect(m.ocspResponses, hasLength(1));
      },
    );

    test('the self-signed root is never queried', () async {
      final r = fake(ocsp: {'leaf', 'sub', 'root'}, crl: {'root'});
      await collectorWith(
        r,
      ).collect([leaf, sub, root], ValidationType.ocspFirst);

      expect(r.calls.where((c) => c.endsWith(':root')), isEmpty);
    });

    test('a lone leaf without a known issuer can only use CRL', () async {
      final r = fake(ocsp: {'leaf'}, crl: {'leaf'});
      final m = await collectorWith(
        r,
      ).collect([leaf], ValidationType.ocspFirst);

      // OCSP needs the issuer certificate, so it is not even attempted.
      expect(r.calls, ['crl:leaf']);
      expect(m.crls, hasLength(1));
    });
  });
}
