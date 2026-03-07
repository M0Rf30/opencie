# LTV Implementation — Technical Reference & Code Patterns

## Quick Reference: OIDs & Constants

```dart
// CAdES Unsigned Attributes
const String OID_SIGNATURE_TIME_STAMP = '1.2.840.113549.1.9.16.2.14';
const String OID_CERTIFICATE_VALUES = '1.2.840.113549.1.9.16.2.23';
const String OID_REVOCATION_VALUES = '1.2.840.113549.1.9.16.2.24';
const String OID_ARCHIVE_TIME_STAMP_V3 = '1.2.840.113549.1.9.16.2.48';

// Hash Algorithms
const String OID_SHA256 = '2.16.840.1.101.3.4.2.1';
const String OID_SHA512 = '2.16.840.1.101.3.4.2.3';
const String OID_SHA1 = '1.3.14.3.2.26';

// OCSP
const String OID_OCSP_NONCE = '1.3.6.1.5.5.7.48.1.2';

// X.509 Extensions
const String OID_AUTHORITY_INFO_ACCESS = '1.3.6.1.4.1.1733.101.1.6.6';  // AIA
const String OID_CRL_DISTRIBUTION_POINTS = '2.5.29.31';  // CDP

// PDF Signature Fields
const String PDF_FILTER = '/Adobe.PPKLite';
const String PDF_SUBFILTER_CADES = '/ETSI.CAdES.detached';
const String PDF_SUBFILTER_RFC3161 = '/ETSI.RFC3161';
```

---

## ASN.1 Encoding Patterns

### Pattern 1: Build TimeStampReq

```dart
import 'package:asn1lib/asn1lib.dart';

Uint8List buildTimeStampReq({
  required String hashAlgorithmOid,
  required List<int> hashedMessage,
  String? nonce,
  bool certReq = true,
}) {
  final seq = ASN1Sequence();
  
  // version INTEGER { v1(1) }
  seq.add(ASN1Integer(1));
  
  // messageImprint MessageImprint
  final msgImprint = ASN1Sequence();
  msgImprint.add(ASN1ObjectIdentifier(hashAlgorithmOid));
  msgImprint.add(ASN1OctetString(hashedMessage));
  seq.add(msgImprint);
  
  // nonce INTEGER OPTIONAL
  if (nonce != null) {
    seq.add(ASN1Integer(BigInt.parse(nonce)));
  }
  
  // certReq BOOLEAN DEFAULT FALSE
  if (certReq) {
    seq.add(ASN1Boolean(true));
  }
  
  return seq.encodedBytes;
}
```

### Pattern 2: Parse TimeStampResp

```dart
class TimeStampResp {
  final int status;  // 0=granted, 1=grantedWithMods, 2=rejection, etc.
  final String? statusString;
  final Uint8List? timeStampToken;
  
  TimeStampResp({
    required this.status,
    this.statusString,
    this.timeStampToken,
  });
}

TimeStampResp parseTimeStampResp(Uint8List bytes) {
  final parser = ASN1Parser(bytes);
  final seq = parser.nextObject() as ASN1Sequence;
  
  // status PKIStatusInfo
  final statusSeq = seq.elements[0] as ASN1Sequence;
  final statusInt = statusSeq.elements[0] as ASN1Integer;
  final status = statusInt.intValue;
  
  // timeStampToken TimeStampToken OPTIONAL
  Uint8List? timeStampToken;
  if (seq.elements.length > 1) {
    final tokenObj = seq.elements[1];
    if (tokenObj is ASN1Sequence) {
      timeStampToken = tokenObj.encodedBytes;
    }
  }
  
  return TimeStampResp(
    status: status,
    timeStampToken: timeStampToken,
  );
}
```

### Pattern 3: Build OCSPRequest

```dart
Uint8List buildOcspRequest({
  required String issuerNameHash,  // hex string
  required String issuerKeyHash,   // hex string
  required String serialNumber,    // hex string
  String? nonce,
}) {
  final seq = ASN1Sequence();
  
  // tbsRequest TBSRequest
  final tbsReq = ASN1Sequence();
  
  // requestList SEQUENCE OF Request
  final reqList = ASN1Sequence();
  
  // Request
  final req = ASN1Sequence();
  
  // reqCert CertID
  final certId = ASN1Sequence();
  
  // hashAlgorithm AlgorithmIdentifier (SHA-256)
  final hashAlgo = ASN1Sequence();
  hashAlgo.add(ASN1ObjectIdentifier('2.16.840.1.101.3.4.2.1'));  // SHA-256
  hashAlgo.add(ASN1Null());
  certId.add(hashAlgo);
  
  // issuerNameHash OCTET STRING
  certId.add(ASN1OctetString(hex.decode(issuerNameHash)));
  
  // issuerKeyHash OCTET STRING
  certId.add(ASN1OctetString(hex.decode(issuerKeyHash)));
  
  // serialNumber CertificateSerialNumber
  certId.add(ASN1Integer(BigInt.parse(serialNumber, radix: 16)));
  
  req.add(certId);
  reqList.add(req);
  tbsReq.add(reqList);
  
  // requestExtensions [2] EXPLICIT Extensions OPTIONAL
  if (nonce != null) {
    final exts = ASN1Sequence();
    
    // Nonce extension
    final nonceExt = ASN1Sequence();
    nonceExt.add(ASN1ObjectIdentifier('1.3.6.1.5.5.7.48.1.2'));  // id-pkix-ocsp-nonce
    nonceExt.add(ASN1OctetString(hex.decode(nonce)));
    exts.add(nonceExt);
    
    // [2] EXPLICIT Extensions
    final extsCtx = ASN1ContextSpecific(tag: 2, elements: [exts]);
    tbsReq.add(extsCtx);
  }
  
  seq.add(tbsReq);
  return seq.encodedBytes;
}
```

### Pattern 4: DER Normalization for Archive-Time-Stamp

```dart
/// Builds the exact input for archive-time-stamp-v3 hash
/// Per RFC 5126 §6.4.1
Uint8List buildArchiveTimestampInput({
  required Uint8List encapContentInfo,  // DER-encoded
  required Uint8List signedAttrs,       // DER-encoded (from CMS)
  required Uint8List unsignedAttrs,     // DER-encoded (all attrs before archive-ts)
}) {
  // Concatenate in order:
  // 1. encapContentInfo (already DER)
  // 2. signedAttrs (already DER)
  // 3. unsignedAttrs (already DER)
  
  final result = BytesBuilder();
  result.add(encapContentInfo);
  result.add(signedAttrs);
  result.add(unsignedAttrs);
  
  return result.toBytes();
}

/// Extract DER-encoded signedAttrs from CMS SignerInfo
/// Note: CMS spec requires signedAttrs to be DER-encoded even if rest is BER
Uint8List extractSignedAttrsFromCms(Uint8List cmsBytes) {
  final parser = ASN1Parser(cmsBytes);
  final signedData = parser.nextObject() as ASN1Sequence;
  
  // SignedData.signerInfos[0].signedAttrs
  final signerInfos = signedData.elements[4] as ASN1Set;
  final signerInfo = signerInfos.elements[0] as ASN1Sequence;
  
  // signedAttrs [0] IMPLICIT Attributes
  final signedAttrs = signerInfo.elements[3];
  
  // Return the DER-encoded bytes
  return signedAttrs.encodedBytes;
}
```

---

## PDF Manipulation Patterns

### Pattern 5: Extract Signature Info from PDF

```dart
class PdfSignatureInfo {
  final String fieldName;
  final Uint8List signatureContents;  // raw CMS bytes
  final List<int> byteRange;          // [0, offset1, offset2, offset3]
  final int signatureObjNum;
  final int signatureObjOffset;
}

PdfSignatureInfo extractSignatureInfo(Uint8List pdfBytes) {
  final pdfStr = utf8.decode(pdfBytes);
  
  // Find /Sig dictionary
  final sigMatch = RegExp(r'/Type\s*/Sig.*?/Contents\s*<([0-9A-Fa-f]+)>').firstMatch(pdfStr);
  if (sigMatch == null) throw Exception('No signature found');
  
  final contentsHex = sigMatch.group(1)!;
  final signatureContents = hex.decode(contentsHex);
  
  // Find /ByteRange
  final byteRangeMatch = RegExp(r'/ByteRange\s*\[\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*\]').firstMatch(pdfStr);
  if (byteRangeMatch == null) throw Exception('No ByteRange found');
  
  final byteRange = [
    int.parse(byteRangeMatch.group(1)!),
    int.parse(byteRangeMatch.group(2)!),
    int.parse(byteRangeMatch.group(3)!),
    int.parse(byteRangeMatch.group(4)!),
  ];
  
  return PdfSignatureInfo(
    fieldName: 'Signature1',  // TODO: extract actual field name
    signatureContents: signatureContents,
    byteRange: byteRange,
    signatureObjNum: 0,  // TODO: extract
    signatureObjOffset: 0,  // TODO: extract
  );
}
```

### Pattern 6: Calculate PDF ByteRange for DocTimeStamp

```dart
/// Calculate /ByteRange for DocTimeStamp
/// Covers entire file except the /Contents placeholder
List<int> calculateDocTimeStampByteRange({
  required int contentsPlaceholderStart,  // byte offset of '<'
  required int contentsPlaceholderEnd,    // byte offset after '>'
  required int totalFileSize,
}) {
  return [
    0,
    contentsPlaceholderStart,
    contentsPlaceholderEnd,
    totalFileSize - contentsPlaceholderEnd,
  ];
}

/// Extract bytes to hash for DocTimeStamp
Uint8List extractDocTimeStampHashInput(
  Uint8List pdfBytes,
  List<int> byteRange,
) {
  final result = BytesBuilder();
  
  // [0...offset1)
  result.add(pdfBytes.sublist(byteRange[0], byteRange[1]));
  
  // [offset2...EOF)
  result.add(pdfBytes.sublist(byteRange[2]));
  
  return result.toBytes();
}
```

### Pattern 7: Build PDF Incremental Update (DSS)

```dart
String buildPdfIncrementalUpdateForDss({
  required int nextObjNum,
  required int prevXrefOffset,
  required Map<int, String> newObjects,  // objNum -> object string
}) {
  final buf = StringBuffer();
  
  // Xref section
  buf.write('xref\n');
  buf.write('0 1\n');
  buf.write('0000000000 65535 f\n');
  
  // Objects in xref
  final objOffsets = <int, int>{};
  int currentOffset = 0;
  
  for (final entry in newObjects.entries) {
    objOffsets[entry.key] = currentOffset;
    currentOffset += entry.value.length;
  }
  
  // Xref entries for new objects
  for (final entry in newObjects.entries) {
    buf.write('${entry.key} 1\n');
    buf.write('${objOffsets[entry.key]!.toString().padLeft(10, '0')} 00000 n\n');
  }
  
  // Trailer
  buf.write('trailer\n');
  buf.write('<<\n');
  buf.write('/Size ${nextObjNum + 1}\n');
  buf.write('/Root 1 0 R\n');
  buf.write('/Prev $prevXrefOffset\n');
  buf.write('>>\n');
  buf.write('startxref\n');
  buf.write('$currentOffset\n');
  buf.write('%%EOF\n');
  
  return buf.toString();
}
```

### Pattern 8: Build DocTimeStamp Dictionary

```dart
String buildDocTimeStampDictionary({
  required List<int> byteRange,
  required int contentsLength,  // length of hex-encoded signature
}) {
  final buf = StringBuffer();
  
  buf.write('<<\n');
  buf.write('/Type /DocTimeStamp\n');
  buf.write('/Filter /Adobe.PPKLite\n');
  buf.write('/SubFilter /ETSI.RFC3161\n');
  buf.write('/ByteRange [${byteRange.join(' ')}]\n');
  
  // Placeholder for /Contents (will be filled with timestamp)
  buf.write('/Contents <');
  buf.write('0' * contentsLength);  // placeholder
  buf.write('>\n');
  
  buf.write('>>\n');
  
  return buf.toString();
}
```

---

## HTTP Patterns

### Pattern 9: POST to TSA

```dart
import 'package:http/http.dart' as http;

Future<Uint8List> postToTsa({
  required String tsaUrl,
  required Uint8List timeStampReq,
  Duration timeout = const Duration(seconds: 30),
}) async {
  try {
    final response = await http.post(
      Uri.parse(tsaUrl),
      headers: {
        'Content-Type': 'application/timestamp-query',
        'User-Agent': 'OpenCIE/1.0',
      },
      body: timeStampReq,
    ).timeout(timeout);
    
    if (response.statusCode != 200) {
      throw TspException('TSA returned HTTP ${response.statusCode}');
    }
    
    if (response.headers['content-type'] != 'application/timestamp-reply') {
      throw TspException('Invalid Content-Type: ${response.headers['content-type']}');
    }
    
    return response.bodyBytes;
  } on TimeoutException {
    throw TspException('TSA request timed out');
  }
}
```

### Pattern 10: POST to OCSP Responder

```dart
Future<Uint8List> postToOcsp({
  required String responderUrl,
  required Uint8List ocspRequest,
  Duration timeout = const Duration(seconds: 30),
}) async {
  try {
    final response = await http.post(
      Uri.parse(responderUrl),
      headers: {
        'Content-Type': 'application/ocsp-request',
        'User-Agent': 'OpenCIE/1.0',
      },
      body: ocspRequest,
    ).timeout(timeout);
    
    if (response.statusCode != 200) {
      throw OcspException('Responder returned HTTP ${response.statusCode}');
    }
    
    return response.bodyBytes;
  } on TimeoutException {
    throw OcspException('OCSP request timed out');
  }
}
```

---

## Certificate Extraction Patterns

### Pattern 11: Extract AIA Extension (OCSP Responder URL)

```dart
String? extractOcspResponderUrl(X509Certificate cert) {
  // AIA extension OID: 1.3.6.1.4.1.1733.101.1.6.6
  // Contains: id-ad-ocsp (1.3.6.1.5.5.7.48.1)
  
  // Using pkcs7 package:
  // cert.extensions contains parsed extensions
  
  // Manual parsing with asn1lib:
  final parser = ASN1Parser(cert.derBytes);
  final certSeq = parser.nextObject() as ASN1Sequence;
  
  // TBSCertificate
  final tbsCert = certSeq.elements[0] as ASN1Sequence;
  
  // extensions [3] EXPLICIT Extensions
  for (final elem in tbsCert.elements) {
    if (elem is ASN1ContextSpecific && elem.tag == 3) {
      final exts = elem.elements[0] as ASN1Sequence;
      
      for (final ext in exts.elements) {
        final extSeq = ext as ASN1Sequence;
        final oid = (extSeq.elements[0] as ASN1ObjectIdentifier).identifier;
        
        if (oid == '1.3.6.1.4.1.1733.101.1.6.6') {  // AIA
          // Parse AIA structure
          // ...
          return 'https://ocsp.example.com';
        }
      }
    }
  }
  
  return null;
}
```

### Pattern 12: Extract CDP Extension (CRL URL)

```dart
List<String> extractCrlDistributionPoints(X509Certificate cert) {
  // CDP extension OID: 2.5.29.31
  
  final urls = <String>[];
  
  // Manual parsing with asn1lib:
  final parser = ASN1Parser(cert.derBytes);
  final certSeq = parser.nextObject() as ASN1Sequence;
  
  // TBSCertificate
  final tbsCert = certSeq.elements[0] as ASN1Sequence;
  
  // extensions [3] EXPLICIT Extensions
  for (final elem in tbsCert.elements) {
    if (elem is ASN1ContextSpecific && elem.tag == 3) {
      final exts = elem.elements[0] as ASN1Sequence;
      
      for (final ext in exts.elements) {
        final extSeq = ext as ASN1Sequence;
        final oid = (extSeq.elements[0] as ASN1ObjectIdentifier).identifier;
        
        if (oid == '2.5.29.31') {  // CDP
          // Parse CDP structure
          // ...
          urls.add('https://crl.example.com/ca.crl');
        }
      }
    }
  }
  
  return urls;
}
```

---

## Error Handling Patterns

### Pattern 13: Retry with Exponential Backoff

```dart
Future<T> retryWithBackoff<T>({
  required Future<T> Function() fn,
  int maxAttempts = 3,
  Duration initialDelay = const Duration(seconds: 1),
}) async {
  Duration delay = initialDelay;
  
  for (int attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await fn();
    } catch (e) {
      if (attempt == maxAttempts) rethrow;
      
      print('Attempt $attempt failed: $e. Retrying in ${delay.inSeconds}s...');
      await Future.delayed(delay);
      delay *= 2;  // exponential backoff
    }
  }
  
  throw Exception('Max attempts exceeded');
}

// Usage:
final timestamp = await retryWithBackoff(
  fn: () => tspClient.timestamp(data: hashBytes),
  maxAttempts: 3,
);
```

### Pattern 14: Fallback TSAs

```dart
final List<String> fallbackTsas = [
  'https://freetsa.org/tsp',
  'https://tsa.register.it/tsp',
  'https://tsa.aruba.it',
];

Future<Uint8List> getTimestampWithFallback(Uint8List data) async {
  for (final tsaUrl in fallbackTsas) {
    try {
      return await TspClient(tsaUrl).timestamp(data: data);
    } catch (e) {
      print('TSA $tsaUrl failed: $e');
      continue;
    }
  }
  
  throw Exception('All TSAs failed');
}
```

---

## Validation Patterns

### Pattern 15: Verify ByteRange Integrity

```dart
bool verifyByteRange(Uint8List pdfBytes, List<int> byteRange) {
  if (byteRange.length != 4) return false;
  
  final [start1, end1, start2, end2] = byteRange;
  
  // Check bounds
  if (start1 < 0 || end1 > pdfBytes.length) return false;
  if (start2 < 0 || end2 > pdfBytes.length) return false;
  
  // Check continuity: end1 + end2 should equal total file size
  if (end1 + end2 != pdfBytes.length) return false;
  
  // Check no overlap
  if (end1 > start2) return false;
  
  return true;
}
```

### Pattern 16: Verify Xref Integrity

```dart
bool verifyXrefIntegrity(String xrefSection) {
  // Each xref entry must be exactly 20 bytes:
  // nnnnnnnnnn ggggg n\n (or f\n)
  
  final lines = xrefSection.split('\n');
  
  for (final line in lines) {
    if (line.isEmpty) continue;
    
    // Skip 'xref' header and subsection headers
    if (line == 'xref' || RegExp(r'^\d+ \d+$').hasMatch(line)) continue;
    
    // Check entry format
    if (!RegExp(r'^\d{10} \d{5} [nf]$').hasMatch(line)) {
      print('Invalid xref entry: "$line"');
      return false;
    }
  }
  
  return true;
}
```

---

## Testing Patterns

### Pattern 17: Test Vector for PAdES-LTA

```dart
void testPadesLtaUpgrade() {
  // Load test PDF (PAdES-B-B)
  final inputPdf = File('test/fixtures/signed_bb.pdf').readAsBytesSync();
  
  // Upgrade to LTA
  final upgrader = PadesLtaUpgrader(
    tsaUrl: 'https://freetsa.org/tsp',
    ocspFetcher: mockOcspFetcher,
    crlFetcher: mockCrlFetcher,
  );
  
  final ltaPdf = await upgrader.upgrade(inputPdf);
  
  // Verify structure
  expect(ltaPdf.contains('/DSS'), true);
  expect(ltaPdf.contains('/DocTimeStamp'), true);
  expect(ltaPdf.contains('/ETSI.RFC3161'), true);
  
  // Verify with external tool
  // openssl ts -verify -in signed_lta.pdf -CAfile cacert.pem
}
```

---

## Performance Optimization Patterns

### Pattern 18: Parallel Revocation Fetching

```dart
Future<RevocationData> fetchRevocationDataParallel(
  List<X509Certificate> certChain,
) async {
  final futures = <Future>[];
  
  // Fetch OCSP for each cert
  for (final cert in certChain) {
    futures.add(
      OcspClient(cert.ocspResponderUrl).fetchStatus(cert: cert)
        .then((resp) => ('ocsp', resp))
        .catchError((e) => ('ocsp_error', e)),
    );
  }
  
  // Fetch CRL for each cert
  for (final cert in certChain) {
    futures.add(
      CrlFetcher(cert.crlUrl).fetch()
        .then((crl) => ('crl', crl))
        .catchError((e) => ('crl_error', e)),
    );
  }
  
  final results = await Future.wait(futures);
  
  final ocspResponses = <Uint8List>[];
  final crls = <Uint8List>[];
  
  for (final result in results) {
    if (result is Tuple2) {
      if (result.item1 == 'ocsp') ocspResponses.add(result.item2);
      if (result.item1 == 'crl') crls.add(result.item2);
    }
  }
  
  return RevocationData(ocspResponses: ocspResponses, crls: crls);
}
```

### Pattern 19: Caching OCSP Responses

```dart
class OcspCache {
  final Map<String, CachedOcspResponse> _cache = {};
  final Duration ttl;
  
  OcspCache({this.ttl = const Duration(hours: 24)});
  
  String _cacheKey(X509Certificate cert, X509Certificate issuer) {
    return '${cert.serialNumber}_${issuer.serialNumber}';
  }
  
  Uint8List? get(X509Certificate cert, X509Certificate issuer) {
    final key = _cacheKey(cert, issuer);
    final cached = _cache[key];
    
    if (cached != null && DateTime.now().isBefore(cached.expiresAt)) {
      return cached.response;
    }
    
    _cache.remove(key);
    return null;
  }
  
  void put(X509Certificate cert, X509Certificate issuer, Uint8List response) {
    final key = _cacheKey(cert, issuer);
    _cache[key] = CachedOcspResponse(
      response: response,
      expiresAt: DateTime.now().add(ttl),
    );
  }
}

class CachedOcspResponse {
  final Uint8List response;
  final DateTime expiresAt;
  
  CachedOcspResponse({required this.response, required this.expiresAt});
}
```

---

## Debugging Patterns

### Pattern 20: Hex Dump for Byte Range Verification

```dart
void debugByteRange(Uint8List pdfBytes, List<int> byteRange) {
  final [start1, end1, start2, end2] = byteRange;
  
  print('ByteRange: [$start1 $end1 $start2 $end2]');
  print('Total file size: ${pdfBytes.length}');
  print('Expected: $end1 + $end2 = ${end1 + end2}');
  
  // Hex dump around boundaries
  print('\nBytes at end1 (${end1 - 10}..${end1 + 10}):');
  final chunk1 = pdfBytes.sublist(max(0, end1 - 10), min(pdfBytes.length, end1 + 10));
  print(hex.encode(chunk1));
  
  print('\nBytes at start2 (${start2 - 10}..${start2 + 10}):');
  final chunk2 = pdfBytes.sublist(max(0, start2 - 10), min(pdfBytes.length, start2 + 10));
  print(hex.encode(chunk2));
  
  // Verify continuity
  if (end1 + end2 == pdfBytes.length) {
    print('✓ ByteRange is valid');
  } else {
    print('✗ ByteRange is INVALID: $end1 + $end2 ≠ ${pdfBytes.length}');
  }
}
```

---

## Summary

These patterns cover the core operations needed for LTV implementation:
- **ASN.1 encoding/decoding** (TimeStampReq, OCSPRequest, etc.)
- **PDF manipulation** (ByteRange, incremental updates, DSS)
- **Network operations** (TSA, OCSP, CRL)
- **Certificate handling** (AIA, CDP extraction)
- **Error handling** (retry, fallback)
- **Performance** (parallel fetching, caching)
- **Debugging** (hex dumps, validation)

Adapt these patterns to your specific use case and always test with real ETSI test vectors.

