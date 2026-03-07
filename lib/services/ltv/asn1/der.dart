// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/digests/sha1.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/digests/sha384.dart';
import 'package:pointycastle/digests/sha512.dart';

import 'oids.dart';

/// Encode an ASN.1 object to DER bytes. Thin wrapper over `obj.encode()`.
Uint8List derEncode(ASN1Object obj) => obj.encode();

/// Parse DER bytes into a single top-level ASN.1 object. Throws on malformed input.
ASN1Object derDecode(Uint8List der) {
  final p = ASN1Parser(der);
  return p.nextObject();
}

/// Wrap an ASN.1 object with an explicit context-specific constructed tag [n].
/// Used for CMS [0] EXPLICIT, [1] EXPLICIT etc.
ASN1Object explicit(int tagNumber, ASN1Object inner) {
  final encoded = inner.encode();
  // Context-specific constructed: 0xA0 | tagNumber
  final tag = 0xA0 | tagNumber;
  final length = encoded.length;
  final result = BytesBuilder();
  result.addByte(tag);
  _encodeLength(result, length);
  result.add(encoded);
  return ASN1Parser(result.toBytes()).nextObject();
}

/// Wrap raw DER bytes with an implicit context-specific tag [n] of class context (0x80).
/// Used for SubjectAlternativeName etc.
Uint8List implicitWrap(int tagNumber, Uint8List innerContent) {
  // Context-specific primitive: 0x80 | tagNumber
  final tag = 0x80 | tagNumber;
  final result = BytesBuilder();
  result.addByte(tag);
  _encodeLength(result, innerContent.length);
  result.add(innerContent);
  return result.toBytes();
}

/// Build an AlgorithmIdentifier:
///   AlgorithmIdentifier ::= SEQUENCE { algorithm OID, parameters ANY DEFINED BY algorithm OPTIONAL }
ASN1Sequence algorithmIdentifier(String oid, {ASN1Object? parameters}) {
  final seq = ASN1Sequence();
  seq.add(ASN1ObjectIdentifier.fromIdentifierString(oid));
  if (parameters != null) {
    seq.add(parameters);
  }
  return seq;
}

/// Build a SET sorted in DER canonical order (required for CMS SignedAttributes).
ASN1Set derSortedSet(List<ASN1Object> items) {
  final encoded = items.map((o) => o.encode()).toList();
  encoded.sort((a, b) => _lexCompare(a, b));
  // Re-decode to ASN1Object list
  final sorted = encoded.map((b) => derDecode(b)).toList();
  final s = ASN1Set();
  for (final o in sorted) {
    s.add(o);
  }
  return s;
}

/// Lexicographic comparison of byte arrays (unsigned).
int _lexCompare(Uint8List a, Uint8List b) {
  final minLen = a.length < b.length ? a.length : b.length;
  for (int i = 0; i < minLen; i++) {
    final cmp = (a[i] & 0xFF).compareTo(b[i] & 0xFF);
    if (cmp != 0) return cmp;
  }
  return a.length.compareTo(b.length);
}

/// Encode DER length field.
void _encodeLength(BytesBuilder builder, int length) {
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

/// Compute SHA-1 of arbitrary bytes (legacy, used by OCSP).
Uint8List sha1Of(Uint8List data) {
  final digest = SHA1Digest();
  return digest.process(data);
}

/// Compute SHA-256 of arbitrary bytes.
Uint8List sha256Of(Uint8List data) {
  final digest = SHA256Digest();
  return digest.process(data);
}

/// Compute SHA-384 of arbitrary bytes.
Uint8List sha384Of(Uint8List data) {
  final digest = SHA384Digest();
  return digest.process(data);
}

/// Compute SHA-512 of arbitrary bytes.
Uint8List sha512Of(Uint8List data) {
  final digest = SHA512Digest();
  return digest.process(data);
}

/// Compute hash of arbitrary bytes by OID. Throws on unknown OID.
Uint8List hashOf(Uint8List data, String hashOid) {
  switch (hashOid) {
    case Oid.sha1:
      return sha1Of(data);
    case Oid.sha256:
      return sha256Of(data);
    case Oid.sha384:
      return sha384Of(data);
    case Oid.sha512:
      return sha512Of(data);
    default:
      throw ArgumentError('Unknown hash OID: $hashOid');
  }
}

/// Constant-time bytes equality.
bool bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  int result = 0;
  for (int i = 0; i < a.length; i++) {
    result |= a[i] ^ b[i];
  }
  return result == 0;
}
