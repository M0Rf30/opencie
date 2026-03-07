# LTV Implementation — Executive Summary

## What You Need to Know

### The Goal
Upgrade PAdES-B-B and CAdES-B-B signatures (produced by OpenCiePkcs11) to **PAdES-B-LTA** and **CAdES-C-LTA** in pure Dart, enabling long-term validation of Italian CIE smart card signatures.

### Why It Matters
- **PAdES-B-LTA** = signature + timestamp + revocation data + document timestamp
- **CAdES-C-LTA** = signature + timestamp + revocation data + archive timestamp
- Both protect against algorithm obsolescence and certificate expiration
- Required for legal compliance in Italy (eIDAS Regulation)

---

## Quick Facts

| Aspect | Detail |
|--------|--------|
| **Specs** | ETSI EN 319 142-1 (PAdES), EN 319 122-1 (CAdES), RFC 3161 (TSP), RFC 6960 (OCSP) |
| **Effort** | 6–8 weeks (foundation + PAdES + CAdES + testing) |
| **Complexity** | Medium (ASN.1 + PDF incremental updates + network) |
| **Dart Readiness** | 70% (ASN.1 lib exists, PDF basics exist, TSP/OCSP must be built) |
| **Risk Level** | Low–Medium (byte range off-by-one is the main gotcha) |
| **Recommended Approach** | Pure Dart upgrader module (Option B) |

---

## What Must Be Embedded

### PAdES-B-LTA Checklist
```
✅ Original signature (from OpenCiePkcs11)
✅ Signature timestamp (RFC 3161 token)
✅ DSS dictionary with:
   ✅ All certificates (signing cert, intermediates, TSA cert, OCSP responder certs)
   ✅ OCSP responses for cert chain
   ✅ CRLs (optional, OCSP preferred)
✅ Document timestamp (second RFC 3161 token over DSS)
```

### CAdES-C-LTA Checklist
```
✅ Original signature (from OpenCiePkcs11)
✅ Signature timestamp (RFC 3161 token)
✅ Unsigned attributes (in order):
   ✅ certificate-values (all certs)
   ✅ revocation-values (OCSP + CRL)
   ✅ archive-time-stamp-v3 (RFC 3161 token over special input)
```

---

## Critical Implementation Details

### 1. PAdES DSS Dictionary
- **Location**: `/Catalog /DSS`
- **Keys**: `/Certs`, `/OCSPs`, `/CRLs`, `/VRI`
- **Format**: Indirect references to streams (e.g., `5 0 R`)
- **Gotcha**: Must be in separate incremental update **after** signature

### 2. PAdES Document Time-Stamp
- **Type**: `/DocTimeStamp` (not `/Sig`)
- **SubFilter**: `/ETSI.RFC3161`
- **ByteRange**: Covers entire file (including DSS), excludes `/Contents` placeholder
- **Gotcha**: Off-by-one byte range = Adobe rejects signature

### 3. CAdES Archive-Time-Stamp-v3
- **OID**: `1.2.840.113549.1.9.16.2.48`
- **Input**: DER(encapContentInfo) || DER(signedAttrs) || DER(unsignedAttrs_so_far)
- **NOT**: The original document
- **Gotcha**: Wrong input = timestamp validates but archive-timestamp fails

### 4. RFC 3161 TSP
- **Request**: TimeStampReq (ASN.1 DER)
- **Response**: TimeStampResp (ASN.1 DER)
- **Transport**: HTTP POST, `Content-Type: application/timestamp-query`
- **Free TSAs**: FreeTSA.org, Register.it, Aruba (all Italian/EU)

### 5. RFC 6960 OCSP
- **Request**: OCSPRequest (ASN.1 DER)
- **Response**: OCSPResponse (ASN.1 DER)
- **Responder URL**: Extract from cert AIA extension
- **Nonce**: If you send it, response must contain same nonce

---

## Dart Ecosystem Status

### What Exists ✅
- **asn1lib** (1.6.5) — ASN.1 encode/decode (BER/DER)
- **pkcs7** (1.0.6) — PKCS#7/CMS parsing, basic TSP support
- **pdf_plus** (GitHub, active) — PDF signing, validation, incremental updates
- **pointycastle** (1.1.0) — Crypto primitives, X.509 parsing

### What's Missing ❌
- **RFC 3161 TSP client** — Must implement (ASN.1 + HTTP)
- **RFC 6960 OCSP client** — Must implement (ASN.1 + HTTP)
- **CAdES unsigned attributes** — pkcs7 doesn't expose C-LTA construction
- **PAdES LTA upgrade** — pdf_plus doesn't expose LTA APIs

### Verdict
**Feasible in pure Dart** with ~2–3 weeks of ASN.1 + network code.

---

## Recommended Architecture

```
opencie/lib/ltv/
├── tsp_client.dart              # RFC 3161 (you build this)
├── ocsp_client.dart             # RFC 6960 (you build this)
├── crl_fetcher.dart             # HTTP GET + cache
├── dss_builder.dart             # PDF DSS dictionary
├── cms_builder.dart             # CMS unsigned attributes
├── pdf_incremental_update.dart  # PDF xref/trailer
├── pades_lta_upgrader.dart      # Orchestration: B-B → B-LTA
├── cades_lta_upgrader.dart      # Orchestration: B-B → C-LTA
└── asn1_utils.dart              # DER helpers
```

**Workflow**:
1. Load signed PDF/CMS from OpenCiePkcs11
2. Extract cert chain
3. Fetch OCSP + CRL (parallel)
4. Build DSS / unsigned attributes
5. Get document/archive timestamp from TSA
6. Add as incremental update
7. Save

---

## Top 5 Gotchas

| # | Gotcha | Symptom | Fix |
|---|--------|---------|-----|
| 1 | **ByteRange off-by-one** | Adobe: "byte range invalid" | Verify with hex dump: `offset1 + offset3 = EOF` exactly |
| 2 | **Missing EOL after %%EOF** | Signature invalid after DSS added | Add `\n` after `%%EOF` before incremental update |
| 3 | **Archive-timestamp input wrong** | Timestamp validates but archive-ts fails | Input = DER(encapContentInfo) \|\| DER(signedAttrs) \|\| DER(unsignedAttrs), NOT document |
| 4 | **Xref offset wrong** | PDF reader can't find xref | `startxref` must point to **first byte** of `xref` keyword |
| 5 | **TSA timeout** | Request hangs | Set HTTP timeout (30s), retry with backoff, have fallback TSAs |

---

## Free Italian TSAs (2025/2026)

| TSA | URL | Auth | Notes |
|-----|-----|------|-------|
| **FreeTSA** | https://freetsa.org/tsp | None | RFC 3161, P-384 ECDSA (since 2026-03), no logs |
| **Register.it** | https://tsa.register.it/tsp | None | Italian QTSP, qualified |
| **Aruba** | https://tsa.aruba.it | None | Italian QTSP, qualified |

**Recommendation**: Use FreeTSA as primary (reliable, free), Register.it as fallback.

---

## Implementation Timeline

| Phase | Duration | Deliverable |
|-------|----------|-------------|
| **1. Foundation** | 2 weeks | TspClient, OcspClient, CrlFetcher, Asn1Utils |
| **2. PAdES-LTA** | 2 weeks | DssBuilder, PdfIncrementalUpdate, PadesLtaUpgrader |
| **3. CAdES-LTA** | 2 weeks | CmsBuilder, CadesLtaUpgrader |
| **4. Polish** | 2 weeks | Error handling, logging, tests, docs |
| **Total** | **8 weeks** | Production-ready LTV module |

---

## Success Criteria

- [ ] PAdES-B-B → PAdES-B-LTA upgrade works
- [ ] CAdES-B-B → CAdES-C-LTA upgrade works
- [ ] Adobe Acrobat validates upgraded PDFs
- [ ] ETSI Signature Checker validates upgraded signatures
- [ ] Byte ranges verified with hex dump
- [ ] Xref integrity verified
- [ ] TSA/OCSP/CRL fetching works with fallbacks
- [ ] Unit tests for ASN.1 encode/decode
- [ ] Integration tests with real PDFs/CMS
- [ ] Documentation with examples

---

## Key References

### Specifications (Authoritative)
- **ETSI EN 319 142-1 v1.1.1** — PAdES baseline profiles
- **ETSI EN 319 122-1 v1.3.1** — CAdES baseline profiles
- **RFC 3161** — Time-Stamp Protocol
- **RFC 5652** — Cryptographic Message Syntax
- **RFC 6960** — Online Certificate Status Protocol
- **RFC 5126** — CMS Advanced Electronic Signatures

### Tools & Validation
- **Digital Signature Service (DSS)** — https://ec.europa.eu/digital-building-blocks/DSS/
- **ETSI Signature Checker** — https://www.etsi.org/
- **Adobe Acrobat** — PDF validation reference

### Dart Packages
- **asn1lib** — https://pub.dev/packages/asn1lib
- **pkcs7** — https://pub.dev/packages/pkcs7
- **pdf_plus** — https://github.com/insinfo/pdf_plus

---

## Next Steps

1. **Review** this research report with your team
2. **Decide** on architecture (pure Dart vs. native FFI)
3. **Prototype** TspClient (simplest component)
4. **Test** with FreeTSA.org (free, no auth)
5. **Iterate** on PAdES-LTA (simpler than CAdES-LTA)
6. **Validate** with Adobe Acrobat + ETSI tools
7. **Document** with real examples

---

## Questions?

Refer to:
- **LTV_RESEARCH_REPORT.md** — Full technical details
- **LTV_TECHNICAL_REFERENCE.md** — Code patterns & examples
- **ETSI specs** — Authoritative source
- **RFC documents** — Network protocol details

---

**Report Date**: May 2026  
**Status**: Ready for implementation  
**Confidence**: High (specs are stable, Dart ecosystem is sufficient)

