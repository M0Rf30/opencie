// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opencie/models/proxy_config.dart';
import 'package:opencie/models/tsa_config.dart';
import 'package:opencie/providers/settings_provider.dart' show ValidationType;
import 'package:opencie/services/ltv/asn1/der.dart';
import 'package:opencie/services/ltv/asn1/oids.dart';
import 'package:opencie/services/ltv/crl/crl_models.dart';
import 'package:opencie/services/ltv/ocsp/ocsp_models.dart';
import 'package:opencie/services/sign/signature_upgrader.dart';
import 'package:opencie/services/sign/validation_material_collector.dart';
import 'package:pointycastle/asn1.dart';

/// Settings used by the upgrader tests: primary + fallback TSA on
/// distinguishable hosts.
SignatureUpgradeSettings testUpgradeSettings({
  ValidationType validationType = ValidationType.ocspFirst,
  String fallbackUrl = 'https://fallback.tsa.test/tsr',
  String username = '',
  String password = '',
  String policyOid = '',
}) {
  return SignatureUpgradeSettings(
    tsa: TsaConfig(
      serverUrl: 'https://primary.tsa.test/tsr',
      fallbackUrl: fallbackUrl,
      username: username,
      password: password,
      policyOid: policyOid,
    ),
    proxy: const ProxyConfig(),
    validationType: validationType,
  );
}

/// Distinguishable stand-in for a TSA signing certificate: structurally
/// valid DER (SEQUENCE { INTEGER 0x7A }), not a real X.509.
final Uint8List fakeTsaCertificate = Uint8List.fromList([
  0x30,
  0x03,
  0x02,
  0x01,
  0x7A,
]);

/// A [MockClient] that behaves like an RFC 3161 TSA. [failHosts] answer 500,
/// as does every request after the first [failAfter] successful ones.
/// Requested URLs are appended to [requests], message-imprint hashes to
/// [imprints], and the `reqPolicy` OID of each request (null when the
/// TimeStampReq has none) to [policies]. Tokens embed [tsaCertificates] in
/// SignedData.certificates (pass an empty list for a certificate-less TSA).
MockClient fakeTsaClient({
  List<Uri>? requests,
  Set<String> failHosts = const {},
  List<Map<String, String>>? requestHeaders,
  List<Uint8List>? imprints,
  List<String?>? policies,
  List<Uint8List>? tsaCertificates,
  int? failAfter,
}) {
  var served = 0;
  return MockClient((http.Request request) async {
    requests?.add(request.url);
    requestHeaders?.add(request.headers);
    if (failHosts.contains(request.url.host) ||
        (failAfter != null && served >= failAfter)) {
      return http.Response('boom', 500);
    }
    served++;
    final reqSeq = ASN1Parser(request.bodyBytes).nextObject() as ASN1Sequence;
    final msgImprint = reqSeq.elements![1] as ASN1Sequence;
    final hash = (msgImprint.elements![1] as ASN1OctetString).octets!;
    imprints?.add(hash);
    if (policies != null) {
      final third = reqSeq.elements!.length > 2 ? reqSeq.elements![2] : null;
      policies.add(
        third is ASN1ObjectIdentifier ? third.objectIdentifierAsString : null,
      );
    }
    Uint8List? nonce;
    for (var i = 2; i < reqSeq.elements!.length; i++) {
      final el = reqSeq.elements![i];
      if (el is ASN1Integer && el.integer != null) {
        var v = el.integer!;
        final out = <int>[];
        while (v > BigInt.zero) {
          out.insert(0, (v & BigInt.from(0xFF)).toInt());
          v = v >> 8;
        }
        nonce = Uint8List.fromList(out);
        break;
      }
    }
    final token = _buildTimeStampToken(
      hash,
      nonce,
      tsaCertificates ?? [fakeTsaCertificate],
    );
    final status = ASN1Sequence()..add(ASN1Integer(BigInt.zero));
    final resp = ASN1Sequence()
      ..add(status)
      ..add(ASN1Parser(token).nextObject());
    return http.Response.bytes(
      resp.encode(),
      200,
      headers: {'content-type': 'application/timestamp-reply'},
    );
  });
}

Uint8List _buildTimeStampToken(
  Uint8List hash,
  Uint8List? nonce,
  List<Uint8List> certificates,
) {
  final tstInfo = ASN1Sequence()
    ..add(ASN1Integer(BigInt.one))
    ..add(ASN1ObjectIdentifier.fromIdentifierString('1.3.6.1.4.1.601.10.3.1'));
  final imprint = ASN1Sequence()
    ..add(algorithmIdentifier(Oid.sha256))
    ..add(ASN1OctetString(octets: hash));
  tstInfo
    ..add(imprint)
    ..add(ASN1Integer(BigInt.one))
    ..add(_generalizedTime(DateTime.utc(2026, 5, 4, 12)));
  if (nonce != null) {
    var value = BigInt.zero;
    for (final b in nonce) {
      value = (value << 8) | BigInt.from(b & 0xFF);
    }
    tstInfo.add(ASN1Integer(value));
  }

  final encap = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromIdentifierString(Oid.timeStampToken))
    ..add(_explicit(0, ASN1OctetString(octets: tstInfo.encode()).encode()));

  final signerInfos = ASN1Set()
    ..add(ASN1Sequence()..add(ASN1Integer(BigInt.one)));
  final signedData = ASN1Sequence()
    ..add(ASN1Integer(BigInt.from(3)))
    ..add(ASN1Set())
    ..add(encap);
  if (certificates.isNotEmpty) {
    // certificates [0] IMPLICIT: the certificate TLVs follow the tag directly.
    final all = BytesBuilder();
    for (final c in certificates) {
      all.add(c);
    }
    signedData.add(_explicit(0, all.toBytes()));
  }
  signedData.add(signerInfos);
  final contentInfo = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromIdentifierString(Oid.pkcs7SignedData))
    ..add(_explicit(0, signedData.encode()));
  return contentInfo.encode();
}

ASN1Object _explicit(int tag, Uint8List content) {
  final b = BytesBuilder()..addByte(0xA0 | tag);
  if (content.length < 128) {
    b.addByte(content.length);
  } else {
    final len = <int>[];
    var l = content.length;
    while (l > 0) {
      len.insert(0, l & 0xFF);
      l >>= 8;
    }
    b
      ..addByte(0x80 | len.length)
      ..add(len);
  }
  b.add(content);
  return ASN1Parser(b.toBytes()).nextObject();
}

ASN1Object _generalizedTime(DateTime dt) {
  String pad(int v, int w) => v.toString().padLeft(w, '0');
  final s =
      '${pad(dt.year, 4)}${pad(dt.month, 2)}${pad(dt.day, 2)}'
      '${pad(dt.hour, 2)}${pad(dt.minute, 2)}${pad(dt.second, 2)}Z';
  final b = BytesBuilder()
    ..addByte(0x18)
    ..addByte(s.length)
    ..add(s.codeUnits);
  return ASN1Parser(b.toBytes()).nextObject();
}

/// Collector stub returning fixed material, ignoring the signature's certs.
/// Every call's input certificates are appended to [calls]; [resolver], when
/// given, overrides the fixed material per call.
class StubCollector extends ValidationMaterialCollector {
  StubCollector(this.material, {this.resolver})
    : super(revocation: NoRevocation());

  final CollectedValidationMaterial material;
  final CollectedValidationMaterial Function(List<Uint8List> embeddedCerts)?
  resolver;
  final List<List<Uint8List>> calls = [];
  ValidationType? lastType;

  @override
  Future<CollectedValidationMaterial> collect(
    List<Uint8List> embeddedCerts,
    ValidationType type,
  ) async {
    lastType = type;
    calls.add(embeddedCerts);
    return resolver?.call(embeddedCerts) ?? material;
  }
}

/// Collector stub that always fails.
class ThrowingCollector extends ValidationMaterialCollector {
  ThrowingCollector() : super(revocation: NoRevocation());

  @override
  Future<CollectedValidationMaterial> collect(
    List<Uint8List> embeddedCerts,
    ValidationType type,
  ) async => throw StateError('revocation backend exploded');
}

/// [RevocationSource] with no evidence at all.
class NoRevocation implements RevocationSource {
  @override
  Future<OcspResponse?> ocsp(Uint8List certDer, Uint8List issuerDer) async =>
      null;

  @override
  Future<CrlData?> crl(Uint8List certDer) async => null;
}
