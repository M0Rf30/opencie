# SPID/CIE OpenID Connect Federation Documentation
**Complete Technical Reference for Italian Digital Identity Integration**

---

## 📚 Documentation Files

This directory contains comprehensive technical documentation for implementing SPID/CIE OpenID Connect Federation 1.0 (AGID/IPZS 2025/2026 specifications).

### 1. **SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md** (18.9 KB)
**Complete technical specification reference**

Contains:
- ✅ Exact ACR values (SPID L1/L2/L3, CIE)
- ✅ All claim names & URIs (SPID vs CIE)
- ✅ Federation entity statement structure
- ✅ Trust marks format & validation
- ✅ Request object requirements (RS256, PS256, ES256)
- ✅ Client authentication (private_key_jwt)
- ✅ Cryptographic algorithms (MUST/RECOMMENDED/FORBIDDEN)
- ✅ Federation endpoints (/.well-known/openid-federation, /resolve, /fetch, /list, /trust_mark_status)
- ✅ SPID vs CIE differences
- ✅ 2025/2026 updates (PKCE required, acr_values required, Trust Marks mandatory)
- ✅ Common implementation gotchas

**Use this for:** Exact technical specs, algorithm selection, claim mapping, federation structure

---

### 2. **SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md** (20.7 KB)
**JSON & code examples for all endpoints**

Contains:
- ✅ RP Entity Configuration (complete JSON)
- ✅ Authorization Request (SPID & CIE variants)
- ✅ Signed Request Object payloads
- ✅ Token Endpoint request/response
- ✅ ID Token examples (SPID & CIE)
- ✅ UserInfo Endpoint responses
- ✅ OP Entity Configuration
- ✅ Trust Mark validation (static & dynamic)
- ✅ Federation Resolve Endpoint
- ✅ Dart/Flutter code snippets (PKCE, request object signing)

**Use this for:** Copy-paste JSON examples, understanding request/response flow, Dart implementation patterns

---

### 3. **SPID_CIE_QUICK_REFERENCE.md** (9.2 KB)
**Quick lookup card for developers**

Contains:
- ✅ Exact strings (copy-paste ready)
- ✅ Critical requirements checklist
- ✅ Federation endpoints summary
- ✅ Algorithm quick reference
- ✅ Trust marks structure
- ✅ SPID vs CIE comparison table
- ✅ Common mistakes & fixes
- ✅ Implementation checklist
- ✅ PKCE generation (Dart)
- ✅ Request object payload template

**Use this for:** Quick lookups, copy-paste strings, implementation checklist, common mistakes

---

### 4. **IMPLEMENTATION_ROADMAP.md** (15+ KB)
**Step-by-step implementation guide for OpenCIE project**

Contains:
- ✅ RP-9 (Flutter/Dart Relying Party) implementation phases
- ✅ AS-3 (Mock SPID IdP) implementation phases
- ✅ AS-4 (Mock CIE IdP) implementation phases
- ✅ Code structure & class organization
- ✅ Test users for mock IdPs
- ✅ Testing checklist
- ✅ Timeline & milestones
- ✅ Security considerations

**Use this for:** Project planning, component breakdown, implementation order, testing strategy

---

## 🎯 Quick Start

### For RP (Relying Party) Implementation
1. Read: **SPID_CIE_QUICK_REFERENCE.md** (5 min overview)
2. Reference: **SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md** § 1-6 (ACR, claims, request objects)
3. Code: **SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md** § 1-6 (JSON examples)
4. Plan: **IMPLEMENTATION_ROADMAP.md** § RP-9 (step-by-step)

### For OP (Identity Provider) Implementation
1. Read: **SPID_CIE_QUICK_REFERENCE.md** (5 min overview)
2. Reference: **SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md** § 3-8 (federation, trust marks, algorithms)
3. Code: **SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md** § 7-10 (OP examples)
4. Plan: **IMPLEMENTATION_ROADMAP.md** § AS-3/AS-4 (step-by-step)

---

## 📋 Key Facts (2025/2026)

### ACR Values (EXACT STRINGS)
```
SPID L1: https://www.spid.gov.it/SpidL1
SPID L2: https://www.spid.gov.it/SpidL2
SPID L3: https://www.spid.gov.it/SpidL3
CIE:     https://www.spid.gov.it/SpidL2  (same as SPID)
```

### Critical Requirements
- ✅ **PKCE:** REQUIRED (S256 only)
- ✅ **acr_values:** REQUIRED (in authorization request)
- ✅ **acr claim:** REQUIRED (in ID Token)
- ✅ **Request Object:** REQUIRED (signed JWT, RS256)
- ✅ **Client Auth:** REQUIRED (private_key_jwt only)
- ✅ **Trust Marks:** REQUIRED (mandatory exposure)
- ✅ **Automatic Registration:** Only mode supported

### SPID vs CIE
| Feature | SPID | CIE |
|---------|------|-----|
| Trust Anchor | AgID | Ministero dell'Interno |
| Claim namespace | `https://attributes.spid.gov.it/` | Standard OIDC + URI-style |
| ID Token attrs | NO (UserInfo only) | YES (optional) |
| Encryption | Optional | Optional |
| ECDH support | NO | YES |

### Recent Changes (2025/2026)
- ✅ PKCE now REQUIRED (was optional)
- ✅ acr_values now REQUIRED (was optional)
- ✅ acr in ID Token now REQUIRED (was optional)
- ✅ Trust Marks mandatory exposure (was optional)
- ✅ EUDI Wallet integration layer (2026 full rollout)
- ✅ No breaking changes (all 2024 implementations remain valid)

---

## 🔗 Official Sources

- **AGID SPID/CIE OIDC Specs:** https://docs.italia.it/italia/spid/spid-cie-oidc-docs/
- **AGID Official:** https://www.agid.gov.it/it/piattaforme/spid
- **OpenID Federation 1.0:** https://openid.net/specs/openid-connect-federation-1_0.html
- **iGov Profile:** https://openid.net/specs/openid-igov-oauth2-1_0.html
- **Demo IdP:** https://demo-idp-spid.pre.eid.gov.it/

---

## 🚀 Implementation Status

### RP-9 (Flutter/Dart Relying Party)
- [ ] Phase 1: Federation Setup (Entity Configuration, /resolve endpoint)
- [ ] Phase 2: Authentication Flow (PKCE, request object, token exchange)
- [ ] Phase 3: Federation Trust (EC caching, Trust Mark validation)
- [ ] Phase 4: User Session Management (User model, session storage)

### AS-3 (Mock SPID IdP)
- [ ] Phase 1: Federation Setup (Entity Configuration, federation endpoints)
- [ ] Phase 2: Authorization Endpoint (request object validation)
- [ ] Phase 3: Token Endpoint (client assertion, ID Token generation)
- [ ] Phase 4: UserInfo Endpoint (SPID attributes, encryption)
- [ ] Phase 5: Test Users (L1, L2, L3 variants)

### AS-4 (Mock CIE IdP)
- [ ] Same as AS-3 with CIE-specific differences (standard OIDC claims, encryption support)

---

## 📖 Document Structure

```
SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md
├── 1. ACR_VALUES (SPID L1/L2/L3, CIE)
├── 2. REQUIRED CLAIMS & SCOPES
├── 3. FEDERATION ENTITY STATEMENT STRUCTURE
├── 4. TRUST MARKS
├── 5. REQUEST_OBJECT REQUIREMENTS
├── 6. CLIENT AUTHENTICATION AT TOKEN ENDPOINT
├── 7. CRYPTOGRAPHIC ALGORITHMS
├── 8. FEDERATION ENDPOINTS
├── 9. DIFFERENCES: SPID vs CIE
├── 10. RECENT CHANGES & 2025/2026 UPDATES
├── 11. IMPLEMENTATION GOTCHAS
├── 12. REFERENCE IMPLEMENTATIONS
├── 13. OFFICIAL DOCUMENTATION SOURCES
└── 14. QUICK REFERENCE: SPID vs CIE CLAIM NAMES

SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md
├── 1. RELYING PARTY (RP) - ENTITY CONFIGURATION
├── 2. AUTHORIZATION REQUEST (SPID)
├── 3. AUTHORIZATION REQUEST (CIE)
├── 4. TOKEN ENDPOINT REQUEST
├── 5. TOKEN ENDPOINT RESPONSE
├── 6. USERINFO ENDPOINT RESPONSE
├── 7. OPENID PROVIDER (OP) - ENTITY CONFIGURATION
├── 8. TRUST MARK VALIDATION
├── 9. FEDERATION RESOLVE ENDPOINT
└── 10. DART/FLUTTER IMPLEMENTATION HINTS

SPID_CIE_QUICK_REFERENCE.md
├── EXACT STRINGS (Copy-Paste Ready)
├── CRITICAL REQUIREMENTS
├── FEDERATION ENDPOINTS
├── ALGORITHMS
├── TRUST MARKS
├── SPID vs CIE DIFFERENCES
├── COMMON MISTAKES
├── IMPLEMENTATION CHECKLIST
├── PKCE GENERATION (Dart)
├── REQUEST OBJECT PAYLOAD (SPID)
├── TOKEN ENDPOINT REQUEST
├── USERINFO RESPONSE (SPID & CIE)
├── 2025/2026 UPDATES
└── OFFICIAL SOURCES

IMPLEMENTATION_ROADMAP.md
├── RP-9: SPID/CIE RELYING PARTY (Flutter/Dart)
│   ├── Phase 1: Federation Setup
│   ├── Phase 2: Authentication Flow
│   ├── Phase 3: Federation Trust
│   └── Phase 4: User Session Management
├── AS-3: MOCK SPID IDENTITY PROVIDER
│   ├── Phase 1: Federation Setup
│   ├── Phase 2: Authorization Endpoint
│   ├── Phase 3: Token Endpoint
│   ├── Phase 4: UserInfo Endpoint
│   └── Phase 5: Test Users
├── AS-4: MOCK CIE IDENTITY PROVIDER
├── TESTING CHECKLIST
├── TIMELINE
└── SECURITY CONSIDERATIONS
```

---

## ✅ Verification Checklist

Before implementation, verify:
- [ ] You have read SPID_CIE_QUICK_REFERENCE.md
- [ ] You understand the exact ACR value URIs
- [ ] You know the difference between SPID and CIE claim names
- [ ] You understand PKCE (S256 only)
- [ ] You understand request_object signing (RS256, NOT encrypted)
- [ ] You understand private_key_jwt (client assertion)
- [ ] You understand Trust Mark validation (static + dynamic)
- [ ] You understand federation endpoints (/.well-known/openid-federation, /resolve, /fetch, /list, /trust_mark_status)
- [ ] You have reviewed SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md for your use case
- [ ] You have a plan from IMPLEMENTATION_ROADMAP.md

---

## 🔐 Security Reminders

1. **HTTPS Only:** All endpoints must use HTTPS
2. **Key Storage:** Use secure storage for private keys (Flutter Secure Storage)
3. **PKCE:** Always use S256 (not plain)
4. **Nonce & State:** Minimum 32 alphanumeric characters
5. **Signature Verification:** Always verify JWT signatures
6. **Trust Marks:** Validate both static (signature) and dynamic (status endpoint)
7. **Encryption:** Use RSA-OAEP + A256CBC-HS512 for UserInfo
8. **Token Expiration:** ID Token ≤ 10 minutes, access_token ≤ 1 hour
9. **Rate Limiting:** Implement on token endpoint
10. **CORS:** Restrict to known origins

---

## 📞 Support

For questions about SPID/CIE specifications:
- **AGID:** https://www.agid.gov.it/it/piattaforme/spid
- **Documentation:** https://docs.italia.it/italia/spid/spid-cie-oidc-docs/
- **Demo IdP:** https://demo-idp-spid.pre.eid.gov.it/

For OpenCIE project questions:
- See IMPLEMENTATION_ROADMAP.md for component-specific guidance
- Review SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md for code patterns

---

**Document Version:** 1.0 (May 2026)  
**Status:** Current (AGID/IPZS 2025/2026 specifications)  
**Last Updated:** 2026-05-04  
**For:** OpenCIE Project (RP-9, AS-3, AS-4)
