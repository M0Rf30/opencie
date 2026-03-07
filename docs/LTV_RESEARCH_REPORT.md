# Long-Term Validation (LTV) for PAdES-LTA & CAdES-LTA in Dart/Flutter
## Authoritative Research Report (2025/2026)

**Date**: May 2026  
**Scope**: PAdES-B-LT/B-LTA and CAdES-C-LT/C-LTA implementation in pure Dart  
**Target**: OpenCIE PKCS#11 (Italian CIE smart card) integration

---

## 1. SPECIFICATIONS & PROFILE REQUIREMENTS

### 1.1 Authoritative Standards

| Standard | Version | Status | Scope |
|----------|---------|--------|-------|
| **ETSI EN 319 142-1** | v1.1.1 (2016-04) | Current | PAdES baseline profiles (B-B, B-T, B-LT, B-LTA) |
| **ETSI EN 319 122-1** | v1.3.1 (2023-06) | Current | CAdES baseline profiles (C-B, C-T, C-LT, C-LTA) |
| **ETSI EN 319 102-1** | (referenced) | Current | Signature validation procedures |
| **RFC 3161** | (2001-08) | Current | Time-Stamp Protocol (TSP) |
| **RFC 5652** | (CMS) | Current | Cryptographic Message Syntax |
| **RFC 5280** | (X.509) | Current | Certificate & CRL profiles |
| **RFC 6960** | (OCSP) | Current | Online Certificate Status Protocol |
| **RFC 5126** | (CAdES) | Current | CMS Advanced Electronic Signatures |
| **ISO 32000-1** | (PDF 1.7) | Current | PDF specification |

**AGID Italian Profile**: No deviations from baseline ETSI for PAdES-LTA/CAdES-LTA. AGID references ETSI EN 319 122-1, EN 319 142-1, EN 319 102-1 directly. Italian REM baseline (EN 319 532-4) requires CAdES/XAdES/PAdES baseline signatures with B-T minimum for evidence.

---

### 1.2 Profile Comparison Checklist

#### **PAdES-B-B (Basic)**
- ✅ Signature Dictionary with `/Type /Sig`, `/Filter /Adobe.PPKLite`, `/SubFilter /ETSI.CAdES.detached`
- ✅ CMS SignedData (PKCS#7) with signing certificate
- ✅ `/ByteRange` covering document (excluding `/Contents`)
- ✅ `/M` (signing time, optional but recommended)
- ❌ No timestamp
- ❌ No revocation data
- ❌ No DSS

#### **PAdES-B-T (Timestamped)**
- ✅ All B-B requirements
- ✅ RFC 3161 TimeStampToken embedded in CMS unsigned attributes (`signature-time-stamp`, OID 1.2.840.113549.1.9.16.2.14)
- ✅ TSA certificate chain embedded
- ❌ No revocation data
- ❌ No DSS

#### **PAdES-B-LT (Long-Term)**
- ✅ All B-T requirements
- ✅ **DSS (Document Security Store)** dictionary at `/Catalog /DSS`
  - `/Certs`: array of all certificates (signing cert, intermediates, TSA cert, OCSP responder certs)
  - `/OCSPs`: array of OCSP responses for cert chain validation
  - `/CRLs`: array of CRLs (optional, OCSP preferred)
  - `/VRI`: (optional) per-signature validation info keyed by SHA1(signature)
- ✅ Incremental update (new xref section) after original signature
- ❌ No document timestamp
- ❌ No archive timestamp

#### **PAdES-B-LTA (Long-Term Archive)**
- ✅ All B-LT requirements
- ✅ **Document Time-Stamp** (second incremental update)
  - `/Type /DocTimeStamp`
  - `/SubFilter /ETSI.RFC3161`
  - `/ByteRange` covering entire file up to (but excluding) `/Contents` placeholder
  - RFC 3161 TimeStampToken over DSS + VRI + original signature
- ✅ TSA cert chain for document timestamp embedded in DSS
- ✅ OCSP/CRL for TSA cert in DSS

---

#### **CAdES-C-B (Basic)**
- ✅ CMS SignedData with signing certificate
- ✅ Signed attributes: `content-type`, `message-digest`, `signing-time`, `signing-certificate` (or `signing-certificate-v2`)
- ❌ No revocation data
- ❌ No timestamp

#### **CAdES-C-T (Timestamped)**
- ✅ All C-B requirements
- ✅ Unsigned attribute: `signature-time-stamp` (OID 1.2.840.113549.1.9.16.2.14)
  - Contains RFC 3161 TimeStampToken
- ❌ No revocation data

#### **CAdES-C-LT (Long-Term)**
- ✅ All C-T requirements
- ✅ Unsigned attributes (in order):
  1. **`certificate-values`** (OID 1.2.840.113549.1.9.16.2.23)
     - Sequence of DER-encoded X.509 certificates
     - All certs from signing cert to root (or intermediate)
  2. **`revocation-values`** (OID 1.2.840.113549.1.9.16.2.24)
     - `crlVals`: sequence of DER-encoded CRLs
     - `ocspVals`: sequence of OCSP responses
- ✅ No timestamp over revocation data

#### **CAdES-C-LTA (Long-Term Archive)**
- ✅ All C-LT requirements
- ✅ Unsigned attribute: **`archive-time-stamp-v3`** (OID 1.2.840.113549.1.9.16.2.48)
  - RFC 3161 TimeStampToken
  - **Critical**: Input to hash is **DER-encoded concatenation** of:
    - `encapContentInfo` from original SignedData
    - `signedAttrs` (DER-encoded, as per CMS spec)
    - `unsignedAttrs` up to (but excluding) this archive-time-stamp attribute
  - See RFC 5126 §6.4.1 for exact construction
- ✅ Can have multiple archive-time-stamps (for periodic renewal)

---

## 2. CONCRETE DATA STRUCTURES

### 2.1 PAdES DSS Dictionary Structure

**Location**: `/Catalog /DSS` (root catalog object)

```
/DSS <<
  /Type /DSS
  /Certs [
    <stream 1: DER X.509 cert>
    <stream 2: DER X.509 cert>
    ...
  ]
  /OCSPs [
    <stream 1: DER OCSP response>
    <stream 2: DER OCSP response>
    ...
  ]
  /CRLs [
    <stream 1: DER CRL>
    ...
  ]
  /VRI <<
    /SHA1HASH1 <<
      /Cert [<ref to stream 1> <ref to stream 2> ...]
      /OCSP [<ref to stream 1> ...]
      /CRL [<ref to stream 1> ...]
      /TS <stream: RFC 3161 token>
    >>
    /SHA1HASH2 << ... >>
  >>
>>
```

**Key Points**:
- All `/Certs`, `/OCSPs`, `/CRLs` entries are **indirect references** (e.g., `5 0 R`) to streams
- Each stream contains **raw DER bytes** (no wrapping)
- `/VRI` keys are **uppercase hex SHA1** of the signature's `/Contents` value (without angle brackets)
- `/VRI` is **optional** if only one signature; required for multiple signatures
- DSS must be in an **incremental update** section (new xref)
- If signature is also in incremental update, DSS update must come **after** signature update

**PDF Dictionary Keys** (exact names):
- `/Type` → `/DSS`
- `/Certs` → array of indirect refs
- `/OCSPs` → array of indirect refs
- `/CRLs` → array of indirect refs
- `/VRI` → dictionary of signature VRI dicts

---

### 2.2 PAdES Document Time-Stamp (DocTimeStamp)

**Location**: New signature dictionary in second incremental update (after DSS)

```
/DocTimeStamp <<
  /Type /DocTimeStamp
  /Filter /Adobe.PPKLite
  /SubFilter /ETSI.RFC3161
  /ByteRange [0 <offset1> <offset2> <offset3>]
  /Contents <PLACEHOLDER_FOR_TSA_SIGNATURE>
>>
```

**ByteRange Calculation**:
- `[0 offset1 offset2 offset3]`
- `offset1` = byte position where `/Contents <` starts
- `offset2` = byte position after `>` (start of xref/trailer)
- `offset3` = length of `/Contents` placeholder (e.g., `<...>` = 2 + 2*len(hex) bytes)
- **Hash input**: bytes `[0...offset1)` + bytes `[offset2...EOF)`
  - Includes entire DSS, VRI, original signature
  - Excludes the `/Contents` placeholder itself

**Critical Differences from Signature Dictionary**:
- `/Type /DocTimeStamp` (not `/Sig`)
- `/SubFilter /ETSI.RFC3161` (RFC 3161 token, not CMS)
- `/ByteRange` covers **entire document** (including DSS), not just original document
- No `/M` (signing time) — timestamp is in `/Contents`
- No `/Reason`, `/Location`, etc.

**Incremental Update Structure**:
```
<original PDF bytes>
%%EOF
<newline>
<xref section for DocTimeStamp object>
<trailer with /Prev pointing to previous xref offset>
startxref
<offset of new xref>
%%EOF
```

---

### 2.3 CAdES Unsigned Attributes (C-LTA)

**Order in SignerInfo.unsignedAttrs**:

1. **`signature-time-stamp`** (OID 1.2.840.113549.1.9.16.2.14)
   - Attribute value: RFC 3161 TimeStampToken (DER-encoded)
   - Covers signed attributes of original signature

2. **`certificate-values`** (OID 1.2.840.113549.1.9.16.2.23)
   ```asn1
   CertificateValues ::= SEQUENCE OF Certificate
   ```
   - Each `Certificate` is DER-encoded X.509
   - Include: signing cert, intermediates, root (or up to trusted anchor)
   - Also include: TSA cert, OCSP responder certs

3. **`revocation-values`** (OID 1.2.840.113549.1.9.16.2.24)
   ```asn1
   RevocationValues ::= SEQUENCE {
     crlVals [0] EXPLICIT SEQUENCE OF CertificateList OPTIONAL,
     ocspVals [1] EXPLICIT SEQUENCE OF OCSPResponse OPTIONAL
   }
   ```
   - `crlVals`: DER-encoded CRLs
   - `ocspVals`: DER-encoded OCSP responses
   - Include revocation data for: signing cert, intermediates, TSA cert, OCSP responder cert

4. **`archive-time-stamp-v3`** (OID 1.2.840.113549.1.9.16.2.48) — **CRITICAL**
   ```asn1
   ArchiveTimeStampV3 ::= TimeStampToken
   ```
   - **Input to TSA hash** (RFC 5126 §6.4.1):
     ```
     hash_input = DER(encapContentInfo) || DER(signedAttrs) || DER(unsignedAttrs_up_to_this_point)
     ```
   - `encapContentInfo`: from original SignedData (DER-encoded)
   - `signedAttrs`: DER-encoded (as per CMS §5.3 — always DER, even if rest is BER)
   - `unsignedAttrs`: DER-encoded sequence of all unsigned attributes **before** this archive-time-stamp
   - **NOT** included: the archive-time-stamp attribute itself, any subsequent attributes

---

### 2.4 ASN.1 OIDs Reference

| Attribute | OID | Type |
|-----------|-----|------|
| signature-time-stamp | 1.2.840.113549.1.9.16.2.14 | Unsigned |
| certificate-values | 1.2.840.113549.1.9.16.2.23 | Unsigned |
| revocation-values | 1.2.840.113549.1.9.16.2.24 | Unsigned |
| archive-time-stamp-v3 | 1.2.840.113549.1.9.16.2.48 | Unsigned |
| signing-certificate-v2 | 1.2.840.113549.1.9.16.2.47 | Signed |
| content-type | 1.2.840.113549.1.9.3 | Signed |
| message-digest | 1.2.840.113549.1.9.4 | Signed |
| signing-time | 1.2.840.113549.1.9.5 | Signed |

---

## 3. NETWORK PROTOCOLS

### 3.1 RFC 3161 Time-Stamp Protocol (TSP)

**Request (TimeStampReq)**:
```asn1
TimeStampReq ::= SEQUENCE {
  version INTEGER { v1(1) },
  messageImprint MessageImprint,
  reqPolicy TSAPolicyId OPTIONAL,
  nonce INTEGER OPTIONAL,
  certReq BOOLEAN DEFAULT FALSE,
  extensions [0] IMPLICIT Extensions OPTIONAL
}

MessageImprint ::= SEQUENCE {
  hashAlgorithm AlgorithmIdentifier,
  hashedMessage OCTET STRING
}
```

**Response (TimeStampResp)**:
```asn1
TimeStampResp ::= SEQUENCE {
  status PKIStatusInfo,
  timeStampToken TimeStampToken OPTIONAL
}

PKIStatusInfo ::= SEQUENCE {
  status PKIStatus,
  statusString PKIFreeText OPTIONAL,
  failInfo PKIFailureInfo OPTIONAL
}

PKIStatus ::= INTEGER { granted(0), grantedWithMods(1), rejection(2), waiting(3), revocationWarning(4), revocationNotification(5) }
```

**HTTP Transport**:
- **Request**: POST to TSA URL
  - `Content-Type: application/timestamp-query`
  - Body: DER-encoded TimeStampReq
- **Response**:
  - `Content-Type: application/timestamp-reply`
  - Body: DER-encoded TimeStampResp

**TimeStampToken Structure**:
- CMS SignedData containing:
  - `eContentType`: `id-ct-TSTInfo` (1.2.840.113549.1.9.16.1.4)
  - `eContent`: TSTInfo (DER-encoded)
  - Signer info with TSA certificate

**TSTInfo** (inside TimeStampToken):
```asn1
TSTInfo ::= SEQUENCE {
  version INTEGER { v1(1) },
  policy TSAPolicyId,
  messageImprint MessageImprint,
  serialNumber INTEGER,
  genTime GeneralizedTime,
  accuracy Accuracy OPTIONAL,
  ordering BOOLEAN DEFAULT FALSE,
  nonce INTEGER OPTIONAL,
  tsa [0] GeneralName OPTIONAL,
  extensions [1] IMPLICIT Extensions OPTIONAL
}
```

---

### 3.2 Free Italian/EU TSAs (2025/2026)

| TSA | URL | Auth | Notes | Status |
|-----|-----|------|-------|--------|
| **FreeTSA.org** | `https://freetsa.org/tsp` | None | RFC 3161 compliant, P-384 ECDSA (since 2026-03), no logs | ✅ Active |
| **Register.it** | `https://tsa.register.it/tsp` | None | Italian QTSP, qualified timestamp | ✅ Active |
| **Aruba** | `https://tsa.aruba.it` | None | Italian QTSP, qualified | ✅ Active |
| **Namirial** | `https://timestamp.namirial.com/tsp` | None | Italian QTSP | ✅ Active |
| **Infocert** | `https://tsa.infocert.it` | None | Italian QTSP | ✅ Active |

**Recommended for Flutter Desktop**:
1. **FreeTSA.org** — no auth, reliable, free, Tor-friendly
2. **Register.it** — Italian, qualified, no auth
3. **Aruba** — Italian, qualified, fallback

**Quirks**:
- FreeTSA: Nonce optional; `certReq=true` returns TSA cert chain
- Register.it: Requires valid `messageImprint` hash algorithm
- All: Expect HTTP 200 with `application/timestamp-reply` on success

---

### 3.3 OCSP (RFC 6960)

**Request (OCSPRequest)**:
```asn1
OCSPRequest ::= SEQUENCE {
  tbsRequest TBSRequest,
  optionalSignature [0] EXPLICIT Signature OPTIONAL
}

TBSRequest ::= SEQUENCE {
  version [0] EXPLICIT Version DEFAULT v1,
  requestorName [1] EXPLICIT GeneralName OPTIONAL,
  requestList SEQUENCE OF Request,
  requestExtensions [2] EXPLICIT Extensions OPTIONAL
}

Request ::= SEQUENCE {
  reqCert CertID,
  singleRequestExtensions [0] EXPLICIT Extensions OPTIONAL
}

CertID ::= SEQUENCE {
  hashAlgorithm AlgorithmIdentifier,
  issuerNameHash OCTET STRING,
  issuerKeyHash OCTET STRING,
  serialNumber CertificateSerialNumber
}
```

**Response (OCSPResponse)**:
```asn1
OCSPResponse ::= SEQUENCE {
  responseStatus OCSPResponseStatus,
  responseBytes [0] EXPLICIT ResponseBytes OPTIONAL
}

OCSPResponseStatus ::= ENUMERATED {
  successful(0), malformedRequest(1), internalError(2), tryLater(3),
  sigRequired(5), unauthorized(6)
}

ResponseBytes ::= SEQUENCE {
  responseType OBJECT IDENTIFIER,
  response OCTET STRING
}
```

**Nonce Extension** (RFC 9654):
- OID: `1.3.6.1.5.5.7.48.1.2` (id-pkix-ocsp-nonce)
- Value: OCTET STRING (1–128 bytes, min 32 recommended)
- **Critical**: If nonce in request, response MUST contain same nonce

**Responder URL**:
- Extract from certificate AIA extension (OID 1.3.6.1.4.1.1733.101.1.6.6)
- Or use issuer's OCSP URL from AIA

**HTTP Transport**:
- **GET**: `<responder_url>/<base64url(DER(OCSPRequest))>`
- **POST**: `Content-Type: application/ocsp-request`, body = DER(OCSPRequest)

---

### 3.4 CRL (RFC 5280)

**Fetch**:
- Extract from certificate CRL Distribution Points extension (OID 2.5.29.31)
- HTTP GET the URL
- Response: DER-encoded X.509 CRL

**Structure**:
```asn1
CertificateList ::= SEQUENCE {
  tbsCertList TBSCertList,
  signatureAlgorithm AlgorithmIdentifier,
  signature BIT STRING
}

TBSCertList ::= SEQUENCE {
  version Version OPTIONAL,
  signature AlgorithmIdentifier,
  issuer Name,
  thisUpdate Time,
  nextUpdate Time OPTIONAL,
  revokedCertificates SEQUENCE OF RevokedCertificate OPTIONAL,
  crlExtensions [0] EXPLICIT Extensions OPTIONAL
}
```

**For LTA**: Embed raw DER bytes in DSS `/CRLs` array (no parsing needed).

---

## 4. DART ECOSYSTEM REALITY CHECK

### 4.1 ASN.1 & Encoding

| Package | Version | Last Update | Maintained | License | Status | Gaps |
|---------|---------|-------------|-----------|---------|--------|------|
| **asn1lib** | 1.6.5 | 10mo ago | ⚠️ Minimal | BSD-2 | ✅ Works | No DER normalization; relaxed parsing only |
| **pointycastle** | 1.1.0 | 2y ago | ⚠️ Minimal | MIT | ✅ Works | ASN.1 support via `asn1` lib; crypto primitives |

**Verdict**: `asn1lib` is functional for basic encode/decode. **Gap**: No automatic DER normalization (needed for archive-time-stamp-v3 input construction).

---

### 4.2 PKCS#7 / CMS

| Package | Version | Last Update | Maintained | License | Status | Gaps |
|---------|---------|-------------|-----------|---------|--------|------|
| **pkcs7** | 1.0.6 | 12mo ago | ⚠️ Minimal | BSD-3 | ✅ Partial | Can parse/build PKCS#7; has TSP support; **no unsigned attributes for C-LTA** |
| **pdf_plus** | (GitHub) | 28 Jan 2026 | ✅ Active | MIT | ✅ Excellent | PAdES signing, validation, incremental updates; **no LTA upgrade** |

**Verdict**: `pkcs7` covers basic CMS but lacks C-LTA unsigned attribute construction. `pdf_plus` is the best Dart PDF library but doesn't expose LTA upgrade APIs.

---

### 4.3 PDF Manipulation

| Package | Version | Last Update | Maintained | License | Status | Gaps |
|---------|---------|-------------|-----------|---------|--------|------|
| **pdf** (dart_pdf) | 3.10.0+ | Recent | ✅ Active | Apache 2.0 | ✅ Works | PDF generation; **no signature support** |
| **syncfusion_flutter_pdf** | 25.1.0+ | Recent | ✅ Active | Proprietary | ✅ Good | Signing, validation, **has `createLongTermValidity()` method** | **Method exists but undocumented; may not be production-ready** |
| **pdf_plus** | (GitHub) | 28 Jan 2026 | ✅ Active | MIT | ✅ Excellent | Incremental updates, signature validation, **no LTA upgrade** |
| **pdfrx** | 1.0.0+ | Recent | ✅ Active | MIT | ⚠️ Limited | PDF rendering; **no signing** |

**Verdict**: `syncfusion_flutter_pdf` has a `createLongTermValidity()` method but it's undocumented and may not follow ETSI specs. `pdf_plus` is best for low-level control but requires manual LTA implementation.

---

### 4.4 RFC 3161 / TSP

| Package | Version | Last Update | Maintained | License | Status | Gaps |
|---------|---------|-------------|-----------|---------|--------|------|
| **pkcs7** | 1.0.6 | 12mo ago | ⚠️ Minimal | BSD-3 | ✅ Partial | Has `generateTSQ()` and `addTimestamp()` | **No direct RFC 3161 request/response parsing** |
| (none) | — | — | — | — | ❌ None | **No dedicated RFC 3161 library in Dart** |

**Verdict**: Must implement RFC 3161 TSP client manually (ASN.1 encode/decode + HTTP POST).

---

### 4.5 OCSP

| Package | Version | Last Update | Maintained | License | Status | Gaps |
|---------|---------|-------------|-----------|---------|--------|------|
| (none) | — | — | — | — | ❌ None | **No OCSP library in Dart** |

**Verdict**: Must implement OCSP client manually (ASN.1 encode/decode + HTTP POST/GET).

---

### 4.6 CRL

| Package | Version | Last Update | Maintained | License | Status | Gaps |
|---------|---------|-------------|-----------|---------|--------|------|
| (none) | — | — | — | — | ❌ None | **No CRL parser in Dart** |

**Verdict**: Just fetch raw DER bytes; no parsing needed for embedding.

---

### 4.7 X.509 Certificates

| Package | Version | Last Update | Maintained | License | Status | Gaps |
|---------|---------|-------------|-----------|---------|--------|------|
| **pkcs7** | 1.0.6 | 12mo ago | ⚠️ Minimal | BSD-3 | ✅ Partial | X509 class; can parse certs | **Limited extension parsing** |
| **pointycastle** | 1.1.0 | 2y ago | ⚠️ Minimal | MIT | ✅ Works | X.509 parsing via ASN.1 | **No AIA/CDP extension helpers** |

**Verdict**: Can parse certs with `pkcs7.X509` but must manually extract AIA/CDP extensions.

---

## 5. RECOMMENDED ARCHITECTURE

### 5.1 High-Level Strategy

**Option (B) — Pure Dart LTV Upgrader** (RECOMMENDED)

Rationale:
- OpenCiePkcs11 already produces PAdES-B-B and CAdES-B-B
- Extending native libopencie is out of scope
- Pure Dart allows cross-platform (desktop, server) without FFI
- Dart ecosystem has enough primitives (ASN.1, HTTP, PDF basics)

---

### 5.2 Module Architecture

```
opencie/
├── lib/
│   ├── ltv/
│   │   ├── pades_lta_upgrader.dart       # PAdES-B-B → B-LTA
│   │   ├── cades_lta_upgrader.dart       # CAdES-B-B → C-LTA
│   │   ├── tsp_client.dart               # RFC 3161 TSP
│   │   ├── ocsp_client.dart              # RFC 6960 OCSP
│   │   ├── crl_fetcher.dart              # CRL download
│   │   ├── dss_builder.dart              # DSS dictionary construction
│   │   ├── cms_builder.dart              # CMS unsigned attributes
│   │   ├── pdf_incremental_update.dart   # PDF xref/trailer
│   │   └── asn1_utils.dart               # DER encoding helpers
│   └── ...
```

---

### 5.3 PAdES-B-B → PAdES-B-LTA Workflow

```dart
// 1. Load signed PDF (from OpenCiePkcs11.sign())
final signedPdfBytes = await openCie.sign(document);

// 2. Extract signature info
final sigInfo = PdfSignatureExtractor.extract(signedPdfBytes);
// → sigInfo.certChain, sigInfo.signatureContents, sigInfo.byteRange

// 3. Fetch revocation data (parallel)
final ocspResponses = await OcspClient.fetchForChain(sigInfo.certChain);
final crls = await CrlFetcher.fetchForChain(sigInfo.certChain);

// 4. Build DSS dictionary
final dssDict = DssBuilder()
  .addCertificates(sigInfo.certChain)
  .addOcspResponses(ocspResponses)
  .addCrls(crls)
  .build();

// 5. Add DSS as incremental update
final ltPdfBytes = PdfIncrementalUpdate.addDss(signedPdfBytes, dssDict);

// 6. Timestamp the DSS (get document timestamp)
final docTimestampToken = await TspClient.timestamp(
  data: ltPdfBytes,  // entire file up to DocTimeStamp placeholder
  hashAlgo: 'SHA-256',
);

// 7. Add DocTimeStamp as second incremental update
final ltaPdfBytes = PdfIncrementalUpdate.addDocTimeStamp(
  ltPdfBytes,
  docTimestampToken,
);

// 8. Save
await File('signed_lta.pdf').writeAsBytes(ltaPdfBytes);
```

---

### 5.4 CAdES-B-B → CAdES-C-LTA Workflow

```dart
// 1. Load signed CMS blob (from OpenCiePkcs11.sign())
final cmsBytes = await openCie.sign(document);

// 2. Parse CMS SignedData
final cms = CmsParser.parse(cmsBytes);
// → cms.signerInfo, cms.certificates, cms.signedAttrs

// 3. Fetch revocation data
final ocspResponses = await OcspClient.fetchForChain(cms.certificates);
final crls = await CrlFetcher.fetchForChain(cms.certificates);

// 4. Add signature-time-stamp (if not present)
if (!cms.hasSignatureTimeStamp) {
  final sigTimestamp = await TspClient.timestamp(
    data: cms.signerInfo.signedAttrs,  // DER-encoded
    hashAlgo: 'SHA-256',
  );
  cms.addUnsignedAttribute(
    oid: '1.2.840.113549.1.9.16.2.14',  // signature-time-stamp
    value: sigTimestamp,
  );
}

// 5. Add certificate-values
cms.addUnsignedAttribute(
  oid: '1.2.840.113549.1.9.16.2.23',  // certificate-values
  value: CmsBuilder.encodeCertificateValues(cms.certificates),
);

// 6. Add revocation-values
cms.addUnsignedAttribute(
  oid: '1.2.840.113549.1.9.16.2.24',  // revocation-values
  value: CmsBuilder.encodeRevocationValues(ocspResponses, crls),
);

// 7. Build archive-time-stamp-v3 input
final archiveInput = CmsBuilder.buildArchiveTimestampInput(
  encapContentInfo: cms.encapContentInfo,
  signedAttrs: cms.signerInfo.signedAttrs,  // DER-encoded
  unsignedAttrs: cms.signerInfo.unsignedAttrs,  // DER-encoded, up to this point
);

// 8. Get archive timestamp
final archiveTimestamp = await TspClient.timestamp(
  data: archiveInput,
  hashAlgo: 'SHA-256',
);

// 9. Add archive-time-stamp-v3
cms.addUnsignedAttribute(
  oid: '1.2.840.113549.1.9.16.2.48',  // archive-time-stamp-v3
  value: archiveTimestamp,
);

// 10. Encode and save
final ltaCmsBytes = cms.encode();
await File('signed_lta.cms').writeAsBytes(ltaCmsBytes);
```

---

### 5.5 Key Implementation Details

#### **5.5.1 TSP Client**

```dart
class TspClient {
  final String tsaUrl;
  final String? hashAlgorithm;  // 'SHA-256', 'SHA-512', etc.
  
  Future<Uint8List> timestamp({
    required Uint8List data,
    String hashAlgo = 'SHA-256',
    bool requireCert = true,
    String? nonce,
  }) async {
    // 1. Hash the data
    final hash = sha256.convert(data).bytes;
    
    // 2. Build TimeStampReq (ASN.1)
    final req = _buildTimeStampReq(
      hashAlgo: hashAlgo,
      hashedMessage: hash,
      nonce: nonce,
      certReq: requireCert,
    );
    
    // 3. POST to TSA
    final response = await http.post(
      Uri.parse(tsaUrl),
      headers: {'Content-Type': 'application/timestamp-query'},
      body: req,
    );
    
    if (response.statusCode != 200) {
      throw TspException('TSA returned ${response.statusCode}');
    }
    
    // 4. Parse TimeStampResp
    final resp = _parseTimeStampResp(response.bodyBytes);
    
    if (resp.status != 0) {  // 0 = granted
      throw TspException('TSA status: ${resp.status}');
    }
    
    // 5. Return TimeStampToken (CMS SignedData)
    return resp.timeStampToken;
  }
  
  Uint8List _buildTimeStampReq({
    required String hashAlgo,
    required List<int> hashedMessage,
    String? nonce,
    bool certReq = true,
  }) {
    // Use asn1lib to build:
    // TimeStampReq ::= SEQUENCE {
    //   version INTEGER { v1(1) },
    //   messageImprint MessageImprint,
    //   nonce INTEGER OPTIONAL,
    //   certReq BOOLEAN DEFAULT FALSE,
    //   ...
    // }
    
    final seq = ASN1Sequence();
    seq.add(ASN1Integer(1));  // version
    
    // messageImprint
    final msgImprint = ASN1Sequence();
    msgImprint.add(ASN1ObjectIdentifier(_hashAlgoOid(hashAlgo)));
    msgImprint.add(ASN1OctetString(hashedMessage));
    seq.add(msgImprint);
    
    if (nonce != null) {
      seq.add(ASN1Integer(BigInt.parse(nonce)));
    }
    
    if (certReq) {
      seq.add(ASN1Boolean(true));
    }
    
    return seq.encodedBytes;
  }
  
  TimeStampResp _parseTimeStampResp(Uint8List bytes) {
    // Parse ASN.1 TimeStampResp
    final parser = ASN1Parser(bytes);
    final seq = parser.nextObject() as ASN1Sequence;
    
    // Extract status, timeStampToken
    // ...
    
    return TimeStampResp(...);
  }
  
  String _hashAlgoOid(String algo) {
    return {
      'SHA-256': '2.16.840.1.101.3.4.2.1',
      'SHA-512': '2.16.840.1.101.3.4.2.3',
      'SHA-1': '1.3.14.3.2.26',
    }[algo] ?? '2.16.840.1.101.3.4.2.1';
  }
}
```

#### **5.5.2 OCSP Client**

```dart
class OcspClient {
  final String responderUrl;
  
  Future<Uint8List> fetchStatus({
    required X509Certificate cert,
    required X509Certificate issuer,
    String? nonce,
  }) async {
    // 1. Build OCSPRequest
    final req = _buildOcspRequest(cert, issuer, nonce);
    
    // 2. POST to responder
    final response = await http.post(
      Uri.parse(responderUrl),
      headers: {'Content-Type': 'application/ocsp-request'},
      body: req,
    );
    
    if (response.statusCode != 200) {
      throw OcspException('Responder returned ${response.statusCode}');
    }
    
    // 3. Parse OCSPResponse
    final resp = _parseOcspResponse(response.bodyBytes);
    
    if (resp.responseStatus != 0) {  // 0 = successful
      throw OcspException('OCSP status: ${resp.responseStatus}');
    }
    
    // 4. Verify nonce if present
    if (nonce != null && resp.nonce != nonce) {
      throw OcspException('Nonce mismatch');
    }
    
    // 5. Return raw OCSP response (for embedding in DSS/revocation-values)
    return response.bodyBytes;
  }
  
  Uint8List _buildOcspRequest(
    X509Certificate cert,
    X509Certificate issuer,
    String? nonce,
  ) {
    // Build OCSPRequest ASN.1
    // ...
  }
  
  OcspResponse _parseOcspResponse(Uint8List bytes) {
    // Parse OCSPResponse ASN.1
    // ...
  }
}
```

#### **5.5.3 DSS Builder**

```dart
class DssBuilder {
  final List<Uint8List> _certs = [];
  final List<Uint8List> _ocspResponses = [];
  final List<Uint8List> _crls = [];
  
  DssBuilder addCertificates(List<X509Certificate> certs) {
    for (final cert in certs) {
      _certs.add(cert.derBytes);
    }
    return this;
  }
  
  DssBuilder addOcspResponses(List<Uint8List> responses) {
    _ocspResponses.addAll(responses);
    return this;
  }
  
  DssBuilder addCrls(List<Uint8List> crls) {
    _crls.addAll(crls);
    return this;
  }
  
  String build() {
    // Return PDF dictionary string:
    // /DSS << /Type /DSS /Certs [...] /OCSPs [...] /CRLs [...] >>
    
    final buf = StringBuffer();
    buf.write('<<\n');
    buf.write('/Type /DSS\n');
    
    // Add /Certs array (indirect refs)
    if (_certs.isNotEmpty) {
      buf.write('/Certs [\n');
      for (int i = 0; i < _certs.length; i++) {
        buf.write('${_certObjNum + i} 0 R\n');
      }
      buf.write(']\n');
    }
    
    // Add /OCSPs array
    if (_ocspResponses.isNotEmpty) {
      buf.write('/OCSPs [\n');
      for (int i = 0; i < _ocspResponses.length; i++) {
        buf.write('${_ocspObjNum + i} 0 R\n');
      }
      buf.write(']\n');
    }
    
    // Add /CRLs array
    if (_crls.isNotEmpty) {
      buf.write('/CRLs [\n');
      for (int i = 0; i < _crls.length; i++) {
        buf.write('${_crlObjNum + i} 0 R\n');
      }
      buf.write(']\n');
    }
    
    buf.write('>>\n');
    return buf.toString();
  }
}
```

#### **5.5.4 PDF Incremental Update**

```dart
class PdfIncrementalUpdate {
  static Uint8List addDss(Uint8List pdfBytes, String dssDict) {
    // 1. Find /Catalog object
    final catalogRef = _findCatalogRef(pdfBytes);
    
    // 2. Create new DSS object
    final dssObjNum = _getNextObjNum(pdfBytes);
    final dssObj = '$dssObjNum 0 obj\n$dssDict\nendobj\n';
    
    // 3. Update /Catalog to reference /DSS
    final updatedCatalog = _addDssRefToCatalog(pdfBytes, catalogRef, dssObjNum);
    
    // 4. Build incremental update
    final xrefOffset = pdfBytes.length;
    final xref = _buildXref([
      (catalogRef, updatedCatalog),
      (dssObjNum, dssObj),
      // ... other objects (cert streams, OCSP streams, etc.)
    ]);
    
    final trailer = _buildTrailer(
      size: _getNextObjNum(pdfBytes),
      prev: _findPrevXrefOffset(pdfBytes),
    );
    
    // 5. Concatenate
    final result = BytesBuilder();
    result.add(pdfBytes);
    result.add(utf8.encode('\n'));
    result.add(utf8.encode(dssObj));
    // ... add cert/OCSP/CRL streams
    result.add(utf8.encode(xref));
    result.add(utf8.encode(trailer));
    result.add(utf8.encode('startxref\n$xrefOffset\n%%EOF\n'));
    
    return result.toBytes();
  }
  
  static Uint8List addDocTimeStamp(
    Uint8List pdfBytes,
    Uint8List timeStampToken,
  ) {
    // Similar to addDss, but:
    // 1. Create /DocTimeStamp dictionary
    // 2. Calculate /ByteRange to cover entire file
    // 3. Create placeholder for /Contents
    // 4. Hash the placeholder area
    // 5. Get timestamp from TSA
    // 6. Fill in /Contents with timestamp
    // 7. Add as incremental update
    
    // ...
  }
}
```

---

## 6. CRITICAL GOTCHAS & COMMON FAILURES

### 6.1 PAdES-LTA Gotchas

| Gotcha | Symptom | Fix |
|--------|---------|-----|
| **ByteRange off-by-one** | Adobe: "byte range invalid" | Ensure `/ByteRange [0 offset1 offset2 offset3]` where `offset1 + offset3 = EOF` exactly. Test with hex dump. |
| **Missing EOL after %%EOF** | Adobe rejects signature after DSS added | Add `\n` after `%%EOF` before incremental update. Some TSAs add `\r\n`; normalize to `\n`. |
| **DSS in wrong incremental update** | Signature still validates but DSS ignored | DSS must be in **separate** incremental update **after** signature. If signature is in incremental update, DSS must come **after**. |
| **VRI key wrong** | DSS present but validation fails | VRI key = uppercase hex SHA1 of signature `/Contents` value (without `<>`). Use `sha1.convert(contentsBytes).toString().toUpperCase()`. |
| **Missing TSA cert in DSS** | Document timestamp validates but TSA cert chain missing | Include TSA certificate in `/Certs` array. Also include OCSP responder cert for TSA cert. |
| **DocTimeStamp /ByteRange includes /Contents** | Timestamp invalid | `/ByteRange` must **exclude** the `/Contents <...>` placeholder. Hash input = bytes `[0...offset1)` + bytes `[offset2...EOF)`. |
| **Xref offset wrong** | PDF reader can't find xref | `startxref` value must point to **first byte** of `xref` keyword. Off-by-one is common. |
| **Xref entry format** | PDF reader corrupts file | Each xref entry must be exactly 20 bytes: `nnnnnnnnnn ggggg n\n` or `nnnnnnnnnn ggggg f\n` (10 digits, space, 5 digits, space, 1 char, newline). |

### 6.2 CAdES-LTA Gotchas

| Gotcha | Symptom | Fix |
|--------|---------|-----|
| **Archive-time-stamp input wrong** | Timestamp validates but archive-timestamp fails | Input = DER(encapContentInfo) \|\| DER(signedAttrs) \|\| DER(unsignedAttrs_so_far). **Not** the original document. See RFC 5126 §6.4.1. |
| **Unsigned attributes not DER-encoded** | Validator rejects archive-timestamp | All unsigned attributes must be DER-encoded (even if rest of CMS is BER). Use `ASN1Sequence.encodedBytes` (not `valueBytes`). |
| **Missing certificate-values** | Revocation data present but certs missing | Add `certificate-values` **before** `revocation-values`. Order matters. |
| **OCSP responder cert missing** | OCSP response validates but responder cert chain incomplete | Include OCSP responder certificate in `certificate-values`. |
| **Nonce mismatch in OCSP** | OCSP response rejected | If you send nonce in OCSP request, response **must** contain same nonce. Either don't use nonce, or validate it. |
| **CRL/OCSP for wrong cert** | Revocation data present but doesn't match cert | Ensure OCSP/CRL is for the **exact** certificate (issuer, serial number). |

### 6.3 Network/TSA Gotchas

| Gotcha | Symptom | Fix |
|--------|---------|-----|
| **TSA timeout** | Request hangs | Set HTTP timeout (e.g., 30s). Retry with exponential backoff. Have fallback TSAs. |
| **TSA returns error status** | `PKIStatus != 0` | Check `statusString` field. Common: `tryLater(3)` → retry; `sigRequired(5)` → TSA wants signed request (rare). |
| **OCSP responder unreachable** | OCSP fetch fails | Extract responder URL from cert AIA extension. Have fallback to CRL. Cache OCSP responses. |
| **CRL too large** | CRL fetch times out | Some CRLs are 10+ MB. Stream download, don't load into memory. Cache aggressively. |
| **Cert chain incomplete** | Validation fails because intermediate missing | Fetch intermediate from AIA extension. Include in DSS/certificate-values. |

### 6.4 Dart-Specific Gotchas

| Gotcha | Symptom | Fix |
|--------|---------|-----|
| **ASN.1 relaxed parsing** | Parser silently ignores unknown tags | Use `ASN1Parser(bytes, relaxedParsing: false)` for strict mode. Test with known-good data first. |
| **DER vs BER encoding** | Archive-timestamp input wrong | Always use DER for archive-timestamp input. `asn1lib` defaults to DER for encoding; verify with `.encodedBytes` not `.valueBytes`. |
| **Uint8List concatenation** | Byte range off | Use `BytesBuilder` for concatenation, not string concatenation. Verify final length. |
| **PDF string encoding** | Xref/trailer corrupted | Use UTF-8 for PDF text. Use `utf8.encode()` explicitly. Don't mix string and bytes. |
| **HTTP body encoding** | TSA/OCSP request malformed | POST body must be raw bytes, not base64. Set `Content-Type` header correctly. |

---

## 7. IMPLEMENTATION CHECKLIST

### Phase 1: Foundation (Weeks 1–2)

- [ ] Implement `TspClient` (RFC 3161 encode/decode)
- [ ] Implement `OcspClient` (RFC 6960 encode/decode)
- [ ] Implement `CrlFetcher` (HTTP GET, cache)
- [ ] Implement `Asn1Utils` (DER normalization, OID helpers)
- [ ] Unit tests for each

### Phase 2: PAdES-LTA (Weeks 3–4)

- [ ] Implement `DssBuilder` (PDF dictionary construction)
- [ ] Implement `PdfIncrementalUpdate.addDss()`
- [ ] Implement `PdfIncrementalUpdate.addDocTimeStamp()`
- [ ] Implement `PadesLtaUpgrader` (orchestration)
- [ ] Integration tests with real PDFs

### Phase 3: CAdES-LTA (Weeks 5–6)

- [ ] Implement `CmsBuilder` (unsigned attributes)
- [ ] Implement archive-time-stamp-v3 input construction
- [ ] Implement `CadesLtaUpgrader` (orchestration)
- [ ] Integration tests with real CMS blobs

### Phase 4: Polish & Testing (Weeks 7–8)

- [ ] Error handling & retry logic
- [ ] Logging & diagnostics
- [ ] Performance optimization (caching, parallel fetches)
- [ ] Documentation & examples
- [ ] Validation against ETSI test vectors

---

## 8. REFERENCES

### Specifications
- ETSI EN 319 142-1 v1.1.1: https://www.etsi.org/deliver/etsi_en/319100_319199/31914201/01.01.01_60/en_31914201v010101p.pdf
- ETSI EN 319 122-1 v1.3.1: https://www.etsi.org/deliver/etsi_en/319100_319199/31912201/01.03.01_60/en_31912201v010301p.pdf
- RFC 3161: https://rfc-editor.org/rfc/rfc3161
- RFC 5652 (CMS): https://rfc-editor.org/rfc/rfc5652
- RFC 5280 (X.509): https://rfc-editor.org/rfc/rfc5280
- RFC 6960 (OCSP): https://rfc-editor.org/rfc/rfc6960
- RFC 5126 (CAdES): https://rfc-editor.org/rfc/rfc5126

### Dart Packages
- asn1lib: https://pub.dev/packages/asn1lib
- pkcs7: https://pub.dev/packages/pkcs7
- pdf_plus: https://github.com/insinfo/pdf_plus
- syncfusion_flutter_pdf: https://pub.dev/packages/syncfusion_flutter_pdf

### TSAs
- FreeTSA: https://freetsa.org/
- Register.it: https://www.register.it/assistenza/tsa/
- Aruba: https://www.aruba.it/

### Tools & References
- Digital Signature Service (DSS): https://ec.europa.eu/digital-building-blocks/DSS/
- AGID Italian Guidelines: https://docs.italia.it/AgID/
- NemLog-in3 PAdES-LTA Profile: https://www.ca1.gov.dk/media/ikzcopag/3c27b25a-c406-4b1d-b74c-c7bd9e4191a7.pdf

---

## 9. CONCLUSION

**Feasibility**: ✅ **High** — Pure Dart LTV upgrade is achievable with careful ASN.1 handling and PDF incremental update logic.

**Effort**: 6–8 weeks for production-ready implementation (foundation + PAdES + CAdES + testing).

**Key Risks**:
1. **Byte range off-by-one** in PDF incremental updates (mitigated by hex dump validation)
2. **Archive-time-stamp-v3 input construction** in CAdES (mitigated by RFC 5126 §6.4.1 reference)
3. **TSA/OCSP network reliability** (mitigated by retry logic + fallback TSAs)

**Recommendation**: Start with PAdES-LTA (simpler DSS structure), then move to CAdES-LTA (more complex unsigned attributes). Use `pdf_plus` as base for PDF manipulation; implement TSP/OCSP clients from scratch using `asn1lib`.

