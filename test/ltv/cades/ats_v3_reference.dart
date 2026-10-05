// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

// Independent reference computation of the archive-time-stamp-v3 message
// imprint input and of ATSHashIndexV3, written straight from ETSI EN 319
// 122-1 clauses 5.5.2 and 5.5.3 with a tiny TLV walker of its own. It
// deliberately uses no production CMS/CAdES code, only pointycastle's raw
// digests, so that tests compare two separate readings of the standard.

import 'dart:typed_data';

import 'package:pointycastle/export.dart';

const _sha256 = '2.16.840.1.101.3.4.2.1';
const _sha384 = '2.16.840.1.101.3.4.2.2';
const _sha512 = '2.16.840.1.101.3.4.2.3';

class RefTlv {
  RefTlv(this.raw, this.tag, this.value);

  /// Tag + length + value, exactly as in the input.
  final Uint8List raw;
  final int tag;
  final Uint8List value;

  List<RefTlv> get children => refParse(value);
}

/// Splits [data] into consecutive definite-length TLVs.
List<RefTlv> refParse(Uint8List data) {
  final out = <RefTlv>[];
  var p = 0;
  while (p < data.length) {
    final start = p;
    final tag = data[p++];
    var len = data[p++];
    if (len >= 0x80) {
      final n = len & 0x7F;
      len = 0;
      for (var i = 0; i < n; i++) {
        len = (len << 8) | data[p++];
      }
    }
    out.add(
      RefTlv(
        Uint8List.sublistView(data, start, p + len),
        tag,
        Uint8List.sublistView(data, p, p + len),
      ),
    );
    p += len;
  }
  return out;
}

Uint8List refDigest(String oid, List<int> data) {
  final d = switch (oid) {
    _sha256 => SHA256Digest(),
    _sha384 => SHA384Digest(),
    _sha512 => SHA512Digest(),
    _ => throw ArgumentError('unsupported hash $oid'),
  };
  return d.process(Uint8List.fromList(data));
}

Uint8List refTlv(int tag, List<int> content) {
  final out = <int>[tag];
  if (content.length < 0x80) {
    out.add(content.length);
  } else {
    final lenBytes = <int>[];
    var l = content.length;
    while (l > 0) {
      lenBytes.insert(0, l & 0xFF);
      l >>= 8;
    }
    out
      ..add(0x80 | lenBytes.length)
      ..addAll(lenBytes);
  }
  out.addAll(content);
  return Uint8List.fromList(out);
}

Uint8List refOid(String dotted) {
  final arcs = dotted.split('.').map(int.parse).toList();
  final body = <int>[arcs[0] * 40 + arcs[1]];
  for (final a in arcs.skip(2)) {
    final chunk = <int>[a & 0x7F];
    var v = a >> 7;
    while (v > 0) {
      chunk.insert(0, 0x80 | (v & 0x7F));
      v >>= 7;
    }
    body.addAll(chunk);
  }
  return refTlv(0x06, body);
}

int _cmp(Uint8List a, Uint8List b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return a.length.compareTo(b.length);
}

/// The pieces of a CAdES signature that §5.5 needs, read from raw bytes.
class RefSignature {
  RefSignature(Uint8List p7) {
    final contentInfo = refParse(p7).single;
    final signedData = refParse(contentInfo.children[1].value).single;
    final sd = signedData.children;
    encap = sd[2];
    signerInfos = sd.last;
    for (final e in sd.skip(3).take(sd.length - 4)) {
      if (e.tag == 0xA0) certs = e.children;
      if (e.tag == 0xA1) crls = e.children;
    }
    final fields = signerInfos.children.single.children;
    if (fields.last.tag == 0xA1) {
      unsignedAttrs = fields.last.children;
      signerFields = fields.sublist(0, fields.length - 1);
    } else {
      signerFields = fields;
    }
  }

  late final RefTlv encap;
  late final RefTlv signerInfos;
  List<RefTlv> certs = const [];
  List<RefTlv> crls = const [];
  List<RefTlv> unsignedAttrs = const [];
  late final List<RefTlv> signerFields;

  /// The content octets of eContent, or null when detached.
  Uint8List? get content {
    final c = encap.children;
    if (c.length < 2) return null;
    return c[1].children.single.value;
  }

  /// The message-digest signed attribute value (signedAttrs is the only
  /// `[0]` constructed field of the SignerInfo).
  Uint8List get messageDigest {
    final signedAttrs = signerFields.firstWhere((f) => f.tag == 0xA0);
    final mdOid = refOid('1.2.840.113549.1.9.4');
    var attrs = signedAttrs.children;
    // Some fixtures wrap the attributes in one extra SET under the tag.
    if (attrs.length == 1 && attrs.single.tag == 0x31) {
      attrs = attrs.single.children;
    }
    for (final attr in attrs) {
      final parts = attr.children;
      if (parts[0].raw.length == mdOid.length &&
          _cmp(parts[0].raw, mdOid) == 0) {
        return parts[1].children.single.value;
      }
    }
    throw StateError('no message-digest attribute');
  }
}

/// ATSHashIndexV3 (§5.5.2), DER, for [p7] as it is right now.
Uint8List referenceAtsHashIndex(
  Uint8List p7, {
  String hashAlgorithmOid = _sha256,
}) {
  final s = RefSignature(p7);

  List<Uint8List> hashed(Iterable<List<int>> inputs) =>
      inputs.map((i) => refDigest(hashAlgorithmOid, i)).toList()..sort(_cmp);

  // certificatesHashIndex: one hash per CertificateChoices, whole TLV.
  final certHashes = hashed(s.certs.map((c) => c.raw));
  // crlsHashIndex: one hash per RevocationInfoChoice, whole TLV.
  final crlHashes = hashed(s.crls.map((c) => c.raw));
  // unsignedAttrValuesHashIndex: for every AttributeValue of every Attribute,
  // hash(attrType TLV || AttributeValue TLV).
  final attrInputs = <List<int>>[];
  for (final attr in s.unsignedAttrs) {
    final parts = attr.children;
    for (final v in parts[1].children) {
      attrInputs.add([...parts[0].raw, ...v.raw]);
    }
  }
  final attrHashes = hashed(attrInputs);

  Uint8List seqOfOctets(List<Uint8List> hs) =>
      refTlv(0x30, [for (final h in hs) ...refTlv(0x04, h)]);

  return refTlv(0x30, [
    ...refTlv(0x30, refOid(hashAlgorithmOid)), // AlgorithmIdentifier, no params
    ...seqOfOctets(certHashes),
    ...seqOfOctets(crlHashes),
    ...seqOfOctets(attrHashes),
  ]);
}

/// The bytes that the archive-time-stamp-v3 message imprint is the hash of
/// (§5.5.3): eContentType TLV || hash of the signed data || SignerInfo
/// version, sid, digestAlgorithm, signedAttrs, signatureAlgorithm, signature
/// (as encoded) || ATSHashIndexV3.
Uint8List referenceArchiveImprintInput(
  Uint8List p7, {
  String hashAlgorithmOid = _sha256,
}) {
  final s = RefSignature(p7);
  final content = s.content;
  // Detached: the message-digest attribute carries the hash (valid when the
  // signer used the same algorithm, which the tests guarantee).
  final dataHash = content != null
      ? refDigest(hashAlgorithmOid, content)
      : s.messageDigest;
  return Uint8List.fromList([
    ...s.encap.children.first.raw,
    ...dataHash,
    for (final f in s.signerFields) ...f.raw,
    ...referenceAtsHashIndex(p7, hashAlgorithmOid: hashAlgorithmOid),
  ]);
}

/// [p7] without its last unsigned attribute, every enclosing length rebuilt.
/// Used to recover "the signature as it was when the last archive
/// time-stamp was requested" from a finished file.
Uint8List refWithoutLastUnsignedAttribute(Uint8List p7) {
  final contentInfo = refParse(p7).single;
  final ciChildren = contentInfo.children;
  final signedData = refParse(ciChildren[1].value).single;
  final sd = signedData.children;
  final signerInfo = refParse(sd.last.value).single;
  final fields = signerInfo.children;
  final attrs = fields.last.children;
  final newFields = [
    for (final f in fields.take(fields.length - 1)) ...f.raw,
    if (attrs.length > 1)
      ...refTlv(0xA1, [for (final a in attrs.take(attrs.length - 1)) ...a.raw]),
  ];
  final newSignerInfos = refTlv(0x31, refTlv(0x30, newFields));
  final newSignedData = refTlv(0x30, [
    for (final e in sd.take(sd.length - 1)) ...e.raw,
    ...newSignerInfos,
  ]);
  return refTlv(0x30, [...ciChildren[0].raw, ...refTlv(0xA0, newSignedData)]);
}
