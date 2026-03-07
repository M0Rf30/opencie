# SPID/CIE OpenID Connect Federation - Complete Documentation Index

**Research Completion Date:** May 2026  
**Status:** ✅ COMPLETE & CURRENT  
**Total Documentation:** 79.3 KB across 5 files

---

## 📑 Quick Navigation

### 🚀 START HERE
1. **[README_SPID_CIE_DOCS.md](README_SPID_CIE_DOCS.md)** (10 KB)
   - Overview of all documentation
   - Quick start guide
   - Key facts summary
   - Implementation status

### 📚 TECHNICAL REFERENCE
2. **[SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md](SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md)** (18.9 KB)
   - Complete technical specification
   - All ACR values, claim names, algorithms
   - Federation structure & trust marks
   - 2025/2026 updates

### 💻 IMPLEMENTATION EXAMPLES
3. **[SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md](SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md)** (20.7 KB)
   - JSON examples for all endpoints
   - Request/response payloads
   - Dart/Flutter code snippets
   - Trust mark validation

### ⚡ QUICK REFERENCE
4. **[SPID_CIE_QUICK_REFERENCE.md](SPID_CIE_QUICK_REFERENCE.md)** (9.2 KB)
   - Copy-paste ready strings
   - Critical requirements
   - Common mistakes & fixes
   - Implementation checklist

### 🛣️ IMPLEMENTATION ROADMAP
5. **[IMPLEMENTATION_ROADMAP.md](IMPLEMENTATION_ROADMAP.md)** (20.5 KB)
   - RP-9 (Flutter/Dart RP) - 4 phases
   - AS-3 (Mock SPID IdP) - 5 phases
   - AS-4 (Mock CIE IdP) - CIE variant
   - Testing & timeline

---

## 🎯 By Use Case

### For RP (Relying Party) Developers
1. Read: [SPID_CIE_QUICK_REFERENCE.md](SPID_CIE_QUICK_REFERENCE.md) (5 min)
2. Reference: [SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md](SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md) § 1-6
3. Code: [SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md](SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md) § 1-6
4. Plan: [IMPLEMENTATION_ROADMAP.md](IMPLEMENTATION_ROADMAP.md) § RP-9

### For OP (Identity Provider) Developers
1. Read: [SPID_CIE_QUICK_REFERENCE.md](SPID_CIE_QUICK_REFERENCE.md) (5 min)
2. Reference: [SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md](SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md) § 3-8
3. Code: [SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md](SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md) § 7-10
4. Plan: [IMPLEMENTATION_ROADMAP.md](IMPLEMENTATION_ROADMAP.md) § AS-3/AS-4

### For Project Managers
1. Read: [README_SPID_CIE_DOCS.md](README_SPID_CIE_DOCS.md)
2. Review: [IMPLEMENTATION_ROADMAP.md](IMPLEMENTATION_ROADMAP.md) § Timeline & Milestones
3. Check: [IMPLEMENTATION_ROADMAP.md](IMPLEMENTATION_ROADMAP.md) § Testing Checklist

### For Security Reviewers
1. Reference: [SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md](SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md) § 7 (Algorithms)
2. Check: [IMPLEMENTATION_ROADMAP.md](IMPLEMENTATION_ROADMAP.md) § Security Considerations
3. Review: [SPID_CIE_QUICK_REFERENCE.md](SPID_CIE_QUICK_REFERENCE.md) § Security Reminders

---

## 📋 Key Facts at a Glance

### ACR Values (EXACT STRINGS)
```
SPID L1: https://www.spid.gov.it/SpidL1
SPID L2: https://www.spid.gov.it/SpidL2
SPID L3: https://www.spid.gov.it/SpidL3
CIE:     https://www.spid.gov.it/SpidL2  (same as SPID)
```

### Critical Requirements
- ✅ PKCE: REQUIRED (S256 only)
- ✅ acr_values: REQUIRED (in authorization request)
- ✅ acr claim: REQUIRED (in ID Token)
- ✅ Request Object: REQUIRED (signed JWT, RS256)
- ✅ Client Auth: REQUIRED (private_key_jwt only)
- ✅ Trust Marks: REQUIRED (mandatory exposure)

### SPID vs CIE
| Feature | SPID | CIE |
|---------|------|-----|
| Trust Anchor | AgID | Ministero dell'Interno |
| Claim namespace | `https://attributes.spid.gov.it/` | Standard OIDC + URI |
| ID Token attrs | NO (UserInfo only) | YES (optional) |
| Encryption | Optional | Optional |
| ECDH support | NO | YES |

### 2025/2026 Updates
- ✅ PKCE now REQUIRED (was optional)
- ✅ acr_values now REQUIRED (was optional)
- ✅ acr in ID Token now REQUIRED (was optional)
- ✅ Trust Marks mandatory exposure (was optional)
- ✅ EUDI Wallet integration (2026 full rollout)
- ✅ NO BREAKING CHANGES (all 2024 implementations remain valid)

---

## 🔍 Find Information By Topic

### ACR Values & Authentication Levels
- [SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md](SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md) § 1
- [SPID_CIE_QUICK_REFERENCE.md](SPID_CIE_QUICK_REFERENCE.md) § EXACT STRINGS

### User Attributes & Claims
- [SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md](SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md) § 2
- [SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md](SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md) § 14
- [SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md](SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md) § 6

### Federation Entity Configuration
- [SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md](SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md) § 3
- [SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md](SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md) § 1, 7

### Trust Marks
- [SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md](SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md) § 4
- [SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md](SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md) § 8
- [SPID_CIE_QUICK_REFERENCE.md](SPID_CIE_QUICK_REFERENCE.md) § TRUST MARKS

### Request Objects & PKCE
- [SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md](SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md) § 5
- [SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md](SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md) § 2-3
- [SPID_CIE_QUICK_REFERENCE.md](SPID_CIE_QUICK_REFERENCE.md) § PKCE GENERATION

### Client Authentication
- [SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md](SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md) § 6
- [SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md](SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md) § 4

### Cryptographic Algorithms
- [SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md](SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md) § 7
- [SPID_CIE_QUICK_REFERENCE.md](SPID_CIE_QUICK_REFERENCE.md) § ALGORITHMS

### Federation Endpoints
- [SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md](SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md) § 8
- [SPID_CIE_QUICK_REFERENCE.md](SPID_CIE_QUICK_REFERENCE.md) § FEDERATION ENDPOINTS

### SPID vs CIE Differences
- [SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md](SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md) § 9
- [SPID_CIE_QUICK_REFERENCE.md](SPID_CIE_QUICK_REFERENCE.md) § SPID vs CIE DIFFERENCES

### 2025/2026 Updates
- [SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md](SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md) § 10
- [README_SPID_CIE_DOCS.md](README_SPID_CIE_DOCS.md) § Recent Changes

### Common Mistakes
- [SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md](SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md) § 11
- [SPID_CIE_QUICK_REFERENCE.md](SPID_CIE_QUICK_REFERENCE.md) § COMMON MISTAKES

### Implementation Roadmap
- [IMPLEMENTATION_ROADMAP.md](IMPLEMENTATION_ROADMAP.md) § RP-9 (Flutter/Dart RP)
- [IMPLEMENTATION_ROADMAP.md](IMPLEMENTATION_ROADMAP.md) § AS-3 (Mock SPID IdP)
- [IMPLEMENTATION_ROADMAP.md](IMPLEMENTATION_ROADMAP.md) § AS-4 (Mock CIE IdP)

### Security Considerations
- [IMPLEMENTATION_ROADMAP.md](IMPLEMENTATION_ROADMAP.md) § SECURITY CONSIDERATIONS
- [README_SPID_CIE_DOCS.md](README_SPID_CIE_DOCS.md) § Security Reminders

---

## 📊 Document Statistics

| Document | Size | Sections | Examples | Tables |
|----------|------|----------|----------|--------|
| README_SPID_CIE_DOCS.md | 10.0 KB | 8 | 0 | 2 |
| SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md | 18.9 KB | 14 | 5 | 4 |
| SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md | 20.7 KB | 10 | 20+ | 0 |
| SPID_CIE_QUICK_REFERENCE.md | 9.2 KB | 15 | 8 | 4 |
| IMPLEMENTATION_ROADMAP.md | 20.5 KB | 12 | 10+ | 1 |
| **TOTAL** | **79.3 KB** | **50+** | **40+** | **10+** |

---

## ✅ Verification Checklist

Before implementation, verify:
- [ ] You have read [README_SPID_CIE_DOCS.md](README_SPID_CIE_DOCS.md)
- [ ] You understand the exact ACR value URIs
- [ ] You know the difference between SPID and CIE claim names
- [ ] You understand PKCE (S256 only)
- [ ] You understand request_object signing (RS256, NOT encrypted)
- [ ] You understand private_key_jwt (client assertion)
- [ ] You understand Trust Mark validation (static + dynamic)
- [ ] You understand federation endpoints
- [ ] You have reviewed [SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md](SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md)
- [ ] You have a plan from [IMPLEMENTATION_ROADMAP.md](IMPLEMENTATION_ROADMAP.md)

---

## 🔗 Official Sources

- **AGID SPID/CIE OIDC Specs:** https://docs.italia.it/italia/spid/spid-cie-oidc-docs/
- **AGID SPID Platform:** https://www.agid.gov.it/it/piattaforme/spid
- **OpenID Federation 1.0:** https://openid.net/specs/openid-connect-federation-1_0.html
- **iGov Profile:** https://openid.net/specs/openid-igov-oauth2-1_0.html
- **Demo IdP:** https://demo-idp-spid.pre.eid.gov.it/

---

## 📞 Support

For questions about SPID/CIE specifications:
- See [README_SPID_CIE_DOCS.md](README_SPID_CIE_DOCS.md) § Support

For OpenCIE project questions:
- See [IMPLEMENTATION_ROADMAP.md](IMPLEMENTATION_ROADMAP.md) for component-specific guidance
- Review [SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md](SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md) for code patterns

---

**Document Version:** 1.0 (May 2026)  
**Status:** ✅ COMPLETE & CURRENT  
**Last Updated:** 2026-05-04  
**For:** OpenCIE Project (RP-9, AS-3, AS-4)
