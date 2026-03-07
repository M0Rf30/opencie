# Long-Term Validation (LTV) Implementation Guide

## 📚 Documentation Structure

This directory contains comprehensive research and implementation guidance for adding Long-Term Validation (LTV) support to OpenCIE for PAdES-LTA and CAdES-LTA signatures.

### Documents

#### 1. **LTV_EXECUTIVE_SUMMARY.md** (8 KB) — START HERE
**For**: Project managers, architects, decision-makers  
**Contains**:
- Quick facts and timeline
- What must be embedded (checklists)
- Critical implementation details
- Dart ecosystem status
- Top 5 gotchas
- Success criteria

**Read time**: 10 minutes  
**Action**: Decide on architecture and timeline

---

#### 2. **LTV_RESEARCH_REPORT.md** (37 KB) — AUTHORITATIVE REFERENCE
**For**: Developers, architects, compliance officers  
**Contains**:
- **Section 1**: Specifications & profile requirements
  - ETSI EN 319 142-1 (PAdES)
  - ETSI EN 319 122-1 (CAdES)
  - RFC 3161, RFC 5652, RFC 6960, RFC 5280
  - AGID Italian profile deviations
  - Profile comparison checklists (B-B, B-T, B-LT, B-LTA, C-B, C-T, C-LT, C-LTA)

- **Section 2**: Concrete data structures
  - PAdES DSS dictionary (exact PDF keys, structure)
  - PAdES Document Time-Stamp (DocTimeStamp)
  - CAdES unsigned attributes (certificate-values, revocation-values, archive-time-stamp-v3)
  - ASN.1 OIDs reference table

- **Section 3**: Network protocols
  - RFC 3161 TimeStampReq/TimeStampResp ASN.1
  - HTTP transport (Content-Type headers)
  - Free Italian/EU TSAs (FreeTSA, Register.it, Aruba)
  - RFC 6960 OCSP (OCSPRequest/OCSPResponse, nonce handling)
  - RFC 5280 CRL (fetch & embed)

- **Section 4**: Dart ecosystem reality check
  - asn1lib (1.6.5) — ✅ Works, gaps: no DER normalization
  - pkcs7 (1.0.6) — ✅ Partial, gaps: no C-LTA unsigned attributes
  - pdf_plus (GitHub) — ✅ Excellent, gaps: no LTA upgrade APIs
  - syncfusion_flutter_pdf — ⚠️ Has `createLongTermValidity()` but undocumented
  - RFC 3161 — ❌ No Dart library (must implement)
  - OCSP — ❌ No Dart library (must implement)
  - CRL — ❌ No parser (just fetch raw DER)

- **Section 5**: Recommended architecture
  - Option B: Pure Dart LTV upgrader (RECOMMENDED)
  - Module structure
  - PAdES-B-B → B-LTA workflow
  - CAdES-B-B → C-LTA workflow
  - Key implementation details (TSP client, OCSP client, DSS builder, PDF incremental update)

- **Section 6**: Critical gotchas
  - PAdES-LTA: ByteRange off-by-one, missing EOL, DSS in wrong update, VRI key wrong, missing TSA cert, DocTimeStamp /ByteRange includes /Contents, xref offset wrong, xref entry format
  - CAdES-LTA: Archive-timestamp input wrong, unsigned attributes not DER-encoded, missing certificate-values, OCSP responder cert missing, nonce mismatch, CRL/OCSP for wrong cert
  - Network: TSA timeout, TSA error status, OCSP responder unreachable, CRL too large, cert chain incomplete
  - Dart: ASN.1 relaxed parsing, DER vs BER, Uint8List concatenation, PDF string encoding, HTTP body encoding

- **Section 7**: Implementation checklist
  - Phase 1: Foundation (TspClient, OcspClient, CrlFetcher, Asn1Utils)
  - Phase 2: PAdES-LTA (DssBuilder, PdfIncrementalUpdate, PadesLtaUpgrader)
  - Phase 3: CAdES-LTA (CmsBuilder, CadesLtaUpgrader)
  - Phase 4: Polish & testing

- **Section 8**: References (specs, packages, TSAs, tools)

**Read time**: 60 minutes (full), 20 minutes (skimming)  
**Action**: Understand requirements, identify gaps, plan implementation

---

#### 3. **LTV_TECHNICAL_REFERENCE.md** (20 KB) — CODE PATTERNS
**For**: Developers implementing the module  
**Contains**:
- Quick reference: OIDs & constants
- ASN.1 encoding patterns (4 patterns)
  - Build TimeStampReq
  - Parse TimeStampResp
  - Build OCSPRequest
  - DER normalization for archive-time-stamp
- PDF manipulation patterns (4 patterns)
  - Extract signature info
  - Calculate ByteRange for DocTimeStamp
  - Build incremental update
  - Build DocTimeStamp dictionary
- HTTP patterns (2 patterns)
  - POST to TSA
  - POST to OCSP responder
- Certificate extraction patterns (2 patterns)
  - Extract AIA extension (OCSP URL)
  - Extract CDP extension (CRL URL)
- Error handling patterns (2 patterns)
  - Retry with exponential backoff
  - Fallback TSAs
- Validation patterns (2 patterns)
  - Verify ByteRange integrity
  - Verify xref integrity
- Testing patterns (1 pattern)
  - Test vector for PAdES-LTA
- Performance optimization patterns (2 patterns)
  - Parallel revocation fetching
  - Caching OCSP responses
- Debugging patterns (1 pattern)
  - Hex dump for byte range verification

**Read time**: 30 minutes (reference)  
**Action**: Copy patterns, adapt to your code, test

---

## 🎯 Quick Start

### For Decision-Makers
1. Read **LTV_EXECUTIVE_SUMMARY.md** (10 min)
2. Review timeline and effort estimate
3. Decide on pure Dart vs. native FFI approach
4. Allocate 6–8 weeks for implementation

### For Architects
1. Read **LTV_EXECUTIVE_SUMMARY.md** (10 min)
2. Read **LTV_RESEARCH_REPORT.md** sections 1–5 (40 min)
3. Review recommended architecture
4. Plan module structure and dependencies
5. Identify gaps in Dart ecosystem

### For Developers
1. Read **LTV_EXECUTIVE_SUMMARY.md** (10 min)
2. Read **LTV_RESEARCH_REPORT.md** sections 2–6 (40 min)
3. Use **LTV_TECHNICAL_REFERENCE.md** as coding guide
4. Start with Phase 1 (TspClient)
5. Test with FreeTSA.org (free, no auth)

---

## 📋 Key Takeaways

### What Must Be Done
- ✅ Implement RFC 3161 TSP client (ASN.1 + HTTP)
- ✅ Implement RFC 6960 OCSP client (ASN.1 + HTTP)
- ✅ Build DSS dictionary for PAdES
- ✅ Build unsigned attributes for CAdES
- ✅ Handle PDF incremental updates (xref, trailer)
- ✅ Handle CMS unsigned attributes (DER encoding)

### What Already Exists
- ✅ asn1lib (ASN.1 encode/decode)
- ✅ pkcs7 (PKCS#7/CMS parsing)
- ✅ pdf_plus (PDF signing, validation, incremental updates)
- ✅ pointycastle (crypto primitives)

### What's Tricky
- ⚠️ ByteRange off-by-one in PDF (test with hex dump)
- ⚠️ Archive-timestamp-v3 input construction (RFC 5126 §6.4.1)
- ⚠️ DER normalization for CMS (always DER for archive-ts)
- ⚠️ Xref offset calculation (off-by-one is common)
- ⚠️ TSA/OCSP network reliability (retry + fallback)

### Recommended Approach
**Pure Dart LTV upgrader** (Option B):
- Load signed PDF/CMS from OpenCiePkcs11
- Fetch revocation data (OCSP + CRL)
- Build DSS / unsigned attributes
- Get timestamps from TSA
- Add as incremental update
- Save

**Timeline**: 6–8 weeks  
**Effort**: Medium (ASN.1 + PDF + network)  
**Risk**: Low–Medium (byte range is main gotcha)

---

## 🔗 External References

### Authoritative Specifications
- **ETSI EN 319 142-1 v1.1.1** (PAdES)
  - https://www.etsi.org/deliver/etsi_en/319100_319199/31914201/01.01.01_60/en_31914201v010101p.pdf
- **ETSI EN 319 122-1 v1.3.1** (CAdES)
  - https://www.etsi.org/deliver/etsi_en/319100_319199/31912201/01.03.01_60/en_31912201v010301p.pdf
- **RFC 3161** (Time-Stamp Protocol)
  - https://rfc-editor.org/rfc/rfc3161
- **RFC 5652** (Cryptographic Message Syntax)
  - https://rfc-editor.org/rfc/rfc5652
- **RFC 6960** (Online Certificate Status Protocol)
  - https://rfc-editor.org/rfc/rfc6960
- **RFC 5280** (X.509 Certificates)
  - https://rfc-editor.org/rfc/rfc5280
- **RFC 5126** (CMS Advanced Electronic Signatures)
  - https://rfc-editor.org/rfc/rfc5126

### Dart Packages
- **asn1lib** — https://pub.dev/packages/asn1lib
- **pkcs7** — https://pub.dev/packages/pkcs7
- **pdf_plus** — https://github.com/insinfo/pdf_plus
- **pointycastle** — https://pub.dev/packages/pointycastle

### Tools & Validation
- **Digital Signature Service (DSS)** — https://ec.europa.eu/digital-building-blocks/DSS/
- **ETSI Signature Checker** — https://www.etsi.org/
- **Adobe Acrobat** — PDF validation reference

### Free TSAs
- **FreeTSA** — https://freetsa.org/tsp
- **Register.it** — https://tsa.register.it/tsp
- **Aruba** — https://tsa.aruba.it

---

## 📞 Support

### Questions About Specs?
→ Refer to **LTV_RESEARCH_REPORT.md** sections 1–3

### Questions About Implementation?
→ Refer to **LTV_TECHNICAL_REFERENCE.md** code patterns

### Questions About Architecture?
→ Refer to **LTV_RESEARCH_REPORT.md** section 5

### Questions About Gotchas?
→ Refer to **LTV_RESEARCH_REPORT.md** section 6

### Questions About Timeline?
→ Refer to **LTV_EXECUTIVE_SUMMARY.md** or **LTV_RESEARCH_REPORT.md** section 7

---

## 📝 Document Metadata

| Document | Size | Sections | Read Time | Audience |
|----------|------|----------|-----------|----------|
| LTV_EXECUTIVE_SUMMARY.md | 8 KB | 10 | 10 min | Managers, architects |
| LTV_RESEARCH_REPORT.md | 37 KB | 9 | 60 min | Developers, architects |
| LTV_TECHNICAL_REFERENCE.md | 20 KB | 20 patterns | 30 min | Developers |
| **Total** | **65 KB** | — | **100 min** | — |

---

## ✅ Checklist Before Starting

- [ ] Read LTV_EXECUTIVE_SUMMARY.md
- [ ] Understand PAdES-B-LTA vs CAdES-C-LTA differences
- [ ] Know the 5 main gotchas
- [ ] Have access to ETSI specs (links provided)
- [ ] Have Dart environment set up
- [ ] Have test PDFs/CMS blobs ready
- [ ] Have access to free TSA (FreeTSA.org)
- [ ] Have Adobe Acrobat for validation
- [ ] Have ETSI Signature Checker for validation
- [ ] Allocate 6–8 weeks for implementation

---

## 🚀 Next Steps

1. **Week 1**: Review documentation, set up environment
2. **Week 2**: Implement TspClient (Phase 1)
3. **Week 3**: Implement OcspClient, CrlFetcher (Phase 1)
4. **Week 4**: Implement PAdES-LTA (Phase 2)
5. **Week 5**: Implement CAdES-LTA (Phase 3)
6. **Week 6**: Polish, error handling, logging (Phase 4)
7. **Week 7**: Testing, validation, documentation (Phase 4)
8. **Week 8**: Final review, deployment prep

---

**Report Date**: May 2026  
**Status**: Ready for implementation  
**Confidence**: High

