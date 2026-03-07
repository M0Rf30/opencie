# EU Digital Identity & CSC API Technical Reference

**Complete 2025/2026 specifications for EUDI Wallet and CSC API v2 remote signing**

---

## 📚 Documentation Set

### 1. **EUDI_CSC_TECHNICAL_REFERENCE.md** (32 KB)
**Comprehensive technical specification document**

Complete reference covering:
- **PART A: EUDI WALLET ECOSYSTEM**
  - Architecture Reference Framework (ARF) 1.6
  - OpenID4VCI 1.0 (Credential Issuance)
  - OpenID4VP 1.0 (Credential Presentation)
  - ISO/IEC 18013-5 (mDL - Mobile Driving Licence)
  - SD-JWT VC (Selective Disclosure JWT Verifiable Credentials)
  - Italian PID Profile (IT-Wallet v1.4.0)
  - Dart/Flutter implementation guidance

- **PART B: CSC API v2 (Cloud Signature Consortium)**
  - CSC API v2.2 specification
  - OAuth 2.0 authorization flow with PKCE
  - Signature Activation Data (SAD)
  - Signature creation (signHash, signDoc)
  - Hash & signature algorithms
  - Known CSC providers (InfoCert, Aruba, Namirial, etc.)
  - Integration with PAdES/CAdES
  - Dart/Flutter CSC client implementation

**Use this for:** Deep technical understanding, implementation details, code examples

---

### 2. **EUDI_CSC_QUICK_REFERENCE.json** (13 KB)
**Structured JSON reference for quick lookup**

Machine-readable reference containing:
- Component metadata (versions, release dates, status)
- Protocol specifications (endpoints, parameters, formats)
- Credential formats (SD-JWT VC, mso_mdoc)
- Hash & signature algorithm OIDs
- CSC provider sandbox URLs
- Integration phase checklists
- Reference links

**Use this for:** Quick lookups, API integration, configuration, automation

---

### 3. **RESEARCH_SUMMARY.md** (11 KB)
**Executive summary with key findings**

High-level overview including:
- Current state of EUDI Wallet (May 2026)
- Current state of CSC API v2 (May 2026)
- Core protocols & their status
- Italian PID profile details
- Dart/Flutter situation & recommendations
- Technical highlights & architecture
- Implementation roadmap (Phase 6 & 7)
- Critical gotchas & warnings
- References & links

**Use this for:** Project planning, stakeholder communication, quick reference

---

## 🎯 Quick Start

### For EUDI Wallet Implementation
1. Read **RESEARCH_SUMMARY.md** → Understand the landscape
2. Review **EUDI_CSC_TECHNICAL_REFERENCE.md** Part A → Deep dive into protocols
3. Check **EUDI_CSC_QUICK_REFERENCE.json** → API endpoints & parameters
4. Implement using Dart packages: `pointycastle`, `cbor`, `jose`, `http`

### For CSC Remote Signing
1. Read **RESEARCH_SUMMARY.md** → Understand CSC API v2
2. Review **EUDI_CSC_TECHNICAL_REFERENCE.md** Part B → Protocol details
3. Check **EUDI_CSC_QUICK_REFERENCE.json** → Endpoints & algorithms
4. Test with sandbox: InfoCert, Aruba, or Namirial
5. Implement using Dart packages: `http`, `jose`, `pointycastle`

### For Italian CIE Integration
1. Read **RESEARCH_SUMMARY.md** → Italian PID profile section
2. Review **EUDI_CSC_TECHNICAL_REFERENCE.md** → Section 6 (Italian PID)
3. Check **EUDI_CSC_QUICK_REFERENCE.json** → Italian PID data model
4. Reference: https://github.com/italia/eid-wallet-it-docs (v1.4.0)

---

## 📋 Key Specifications (May 2026)

### EUDI Wallet
| Component | Version | Status | Published |
|-----------|---------|--------|-----------|
| ARF | 1.6 | Production | 2026-03-07 |
| OpenID4VCI | 1.0 | Final (RFC-track) | 2025-09-16 |
| OpenID4VP | 1.0 | Final (RFC-track) | 2025-07-09 |
| SD-JWT VC | draft-15 | IETF Standards Track | 2026-02-26 |
| ISO 18013-5 | 2021 | Published | 2021 |
| ISO 18013-7 | TS 2025 | Published | 2025 |
| IT-Wallet | 1.4.0 | Production | 2024 |

### CSC API
| Component | Version | Status | Published |
|-----------|---------|--------|-----------|
| CSC API | 2.2 | Production | 2025-11-06 |
| CSC API | 2.1.0.1 | Previous | 2025-01-22 |
| CSC API | 2.0.0.2 | Legacy | 2023-04-20 |

---

## 🔗 Official References

### EUDI Wallet
- **Architecture Reference Framework:** https://eudi.dev/2.7.0/architecture-and-reference-framework-main/
- **OpenID4VCI 1.0:** https://openid.net/specs/openid-4-verifiable-credential-issuance-1_0.html
- **OpenID4VP 1.0:** https://openid.net/specs/openid-4-verifiable-presentations-1_0.html
- **SD-JWT VC:** https://datatracker.ietf.org/doc/html/draft-ietf-oauth-sd-jwt-vc-15
- **ISO 18013-5:** https://www.iso.org/standard/69084.html
- **ISO 18013-7:** https://www.iso.org/standard/91154.html

### Italian Implementation
- **IT-Wallet Specs:** https://italia.github.io/eid-wallet-it-docs/versione-corrente/en/
- **IT-Wallet GitHub:** https://github.com/italia/eid-wallet-it-docs
- **IT-Wallet Python:** https://github.com/italia/eudi-wallet-it-python

### CSC API
- **CSC Consortium:** https://cloudsignatureconsortium.org/
- **CSC API v2.2:** https://cloudsignatureconsortium.org/resources/csc-api-v2-2/
- **CSC Providers:** https://cloudsignatureconsortium.org/members/

### Reference Implementations
- **EU Wallet GitHub:** https://github.com/eu-digital-identity-wallet
- **OpenID4VC Rust:** https://github.com/impierce/openid4vc
- **SD-JWT Python:** https://github.com/openwallet-foundation-labs/sd-jwt-python

---

## 🛠️ Dart/Flutter Packages

### Recommended Stack
```dart
// Cryptography
import 'package:pointycastle/export.dart';
import 'package:cryptography/cryptography.dart';

// CBOR (for mDL)
import 'package:cbor/cbor.dart';

// JWT/JWE
import 'package:jose/jose.dart';

// HTTP
import 'package:http/http.dart' as http;

// Secure Storage
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
```

### No Official Dart Library
- ❌ No official EUDI Wallet Dart library exists
- ✅ Wrap Kotlin/Swift libraries via platform channels
- ✅ Port from TypeScript (sd-jwt-js) or Rust (openid4vc)
- ✅ Use existing Dart packages for cryptography & HTTP

---

## ⚠️ Critical Gotchas

### EUDI Wallet
1. **Device Key Binding is Mandatory** - Every credential must be bound to device key
2. **Selective Disclosure Verification** - Must verify salted hashes, not just presence
3. **Trust Anchors** - Must validate issuer certificates against Trusted Lists
4. **Status List** - Must check revocation status before accepting credential
5. **Wallet Attestation** - Wallet Instance Attestation (WIA) required for issuance
6. **LoA High** - PID must be issued at Level of Assurance High

### CSC API v2
1. **SAD Lifetime** - SAD expires in 5-15 minutes; request new SAD for each session
2. **Token Lifecycle** - "service" scope token must be used in exact order: list → authorize → sign
3. **Signature Format** - Raw signature bytes (r,s for ECDSA); RP must wrap in PAdES/CAdES
4. **Certificate Chain** - Must include full chain; root cert NOT included in response
5. **PKCE Required** - Authorization Code flow MUST use PKCE
6. **Scope Separation** - "service" scope for credentials, "credential" scope for signing

---

## 📊 Implementation Phases

### Phase 6: CSC Remote Signing (Weeks 1-4)
- [ ] CSC API v2.2 client (Dart)
- [ ] OAuth 2.0 PKCE flow
- [ ] SAD handling
- [ ] Hash/signature algorithms
- [ ] PAdES/CAdES wrapping
- [ ] Certificate chain validation
- [ ] Sandbox testing

### Phase 7: EUDI Wallet (Weeks 5-12)
- [ ] OpenID4VCI credential request/response
- [ ] OpenID4VP presentation request/response
- [ ] SD-JWT VC support
- [ ] mso_mdoc (CBOR) support
- [ ] Device key binding
- [ ] Selective disclosure
- [ ] Wallet metadata discovery
- [ ] Trust anchor validation
- [ ] Status list revocation
- [ ] Italian PID compliance
- [ ] Cross-device QR flow
- [ ] Same-device redirect flow

---

## 📞 Support & Questions

### For EUDI Wallet
- **EU Digital Identity Cooperation Group (EDICG):** https://ec.europa.eu/transparency/expert-groups-register/
- **GitHub Issues:** https://github.com/eu-digital-identity-wallet/eudi-doc-architecture-and-reference-framework/issues
- **OpenID Foundation:** https://openid.net/

### For CSC API
- **Cloud Signature Consortium:** https://cloudsignatureconsortium.org/
- **CSC Members:** https://cloudsignatureconsortium.org/members/
- **Provider Support:** Contact InfoCert, Aruba, Namirial, etc.

### For Italian Implementation
- **AGID (Agency for Digital Italy):** https://www.agid.gov.it/
- **Department for Digital Transformation:** https://innovazione.gov.it/
- **GitHub Issues:** https://github.com/italia/eid-wallet-it-docs/issues

---

## 📄 Document Metadata

| Document | Size | Lines | Format | Updated |
|----------|------|-------|--------|---------|
| EUDI_CSC_TECHNICAL_REFERENCE.md | 32 KB | 1229 | Markdown | 2026-05-04 |
| EUDI_CSC_QUICK_REFERENCE.json | 13 KB | 358 | JSON | 2026-05-04 |
| RESEARCH_SUMMARY.md | 11 KB | ~400 | Markdown | 2026-05-04 |
| README_TECHNICAL_REFERENCE.md | This file | - | Markdown | 2026-05-04 |

---

## 📝 License & Attribution

These documents are based on:
- **Official EU Digital Identity Framework specifications** (public domain)
- **OpenID Foundation specifications** (public domain)
- **ISO/IEC standards** (referenced)
- **Cloud Signature Consortium specifications** (public domain)
- **Italian government technical specifications** (public domain)

**Status:** Production-Ready (May 2026)  
**Maintainer:** EU Digital Identity Cooperation Group (EDICG)  
**Last Verified:** May 2026

---

## 🚀 Getting Started

1. **Start here:** Read `RESEARCH_SUMMARY.md` (5 min)
2. **Deep dive:** Review `EUDI_CSC_TECHNICAL_REFERENCE.md` (30 min)
3. **Quick lookup:** Use `EUDI_CSC_QUICK_REFERENCE.json` (as needed)
4. **Implement:** Follow the implementation roadmap in Phase 6 & 7
5. **Test:** Use sandbox endpoints from CSC providers
6. **Deploy:** Follow Italian PID profile for compliance

---

**Questions?** Check the official references or contact the EU Digital Identity Cooperation Group.
