# SPID/CIE OpenID Connect Federation - Quick Reference Card
**For Flutter/Dart RP & Mock IdP Implementation**

---

## EXACT STRINGS (Copy-Paste Ready)

### ACR Values
```
SPID L1: https://www.spid.gov.it/SpidL1
SPID L2: https://www.spid.gov.it/SpidL2
SPID L3: https://www.spid.gov.it/SpidL3
CIE:     https://www.spid.gov.it/SpidL2  (same as SPID)
```

### Claim URIs (SPID)
```
Fiscal Number:  https://attributes.spid.gov.it/fiscalNumber
Name:           https://attributes.spid.gov.it/name
Family Name:    https://attributes.spid.gov.it/familyName
Date of Birth:  https://attributes.spid.gov.it/dateOfBirth
Place of Birth: https://attributes.spid.gov.it/placeOfBirth
Gender:         https://attributes.spid.gov.it/gender
Email:          https://attributes.spid.gov.it/email
Address:        https://attributes.spid.gov.it/address
Digital Addr:   https://attributes.spid.gov.it/digitalAddress
```

### Claim URIs (CIE - Standard OIDC)
```
Name:           given_name
Family Name:    family_name
Date of Birth:  birthdate
Gender:         gender
Email:          email
Fiscal Number:  https://attributes.eid.gov.it/fiscal_number
```

---

## CRITICAL REQUIREMENTS

### RP Entity Configuration
```json
{
  "metadata": {
    "openid_relying_party": {
      "client_id": "https://sp.example.it",
      "token_endpoint_auth_method": "private_key_jwt",
      "id_token_signed_response_alg": "RS256",
      "userinfo_signed_response_alg": "RS256",
      "grant_types": ["authorization_code", "refresh_token"],
      "response_types": ["code"]
    }
  }
}
```

### Authorization Request
```
✓ MUST: Signed request_object (JWT, RS256)
✓ MUST: PKCE with S256
✓ MUST: acr_values (space-separated, full URI)
✓ MUST: nonce (≥32 chars)
✓ MUST: state (≥32 chars)
✗ NOT: request_uri (use request param)
```

### Token Endpoint
```
✓ MUST: private_key_jwt client assertion
✓ MUST: code_verifier (PKCE)
✗ NOT: client_secret
```

### ID Token (SPID)
```
✓ MUST: acr claim
✓ MUST: nonce claim
✗ NOT: User attributes (use UserInfo endpoint)
```

### ID Token (CIE)
```
✓ MUST: acr claim
✓ MUST: nonce claim
✓ CAN: family_name, email (if requested in claims)
```

### UserInfo Endpoint
```
✓ SPID: Returns URI-style claims only
✓ CIE:  Returns standard OIDC + URI-style claims
✓ BOTH: Signed & encrypted response
```

---

## FEDERATION ENDPOINTS

### All Entities
```
GET /.well-known/openid-federation
GET /federation/resolve?sub=...&anchor=...
```

### OP/TA/SA Only
```
GET /federation/fetch?sub=...
GET /federation/list
GET /federation/trust_mark_status?trust_mark_id=...&subject=...
```

---

## ALGORITHMS

### MUST Support
```
Signature:        RS256, RS512
Key Encryption:   RSA-OAEP, RSA-OAEP-256
Content Encrypt:  A128CBC-HS256, A256CBC-HS512
```

### RECOMMENDED
```
Signature:        ES256, ES512, PS256, PS512
Key Encryption:   ECDH-ES, ECDH-ES+A128KW, ECDH-ES+A256KW (CIE only)
```

### FORBIDDEN
```
none, RSA1_5, HS256, HS384, HS512
```

---

## TRUST MARKS

### Structure
```json
{
  "iss": "https://agid.gov.it",
  "sub": "https://sp.example.it",
  "id": "https://registry.interno.gov.it/openid_relying_party/public/",
  "iat": 1704067200,
  "exp": 1735603200,
  "organization_type": "public",
  "id_code": { "ipa_code": "c_a123" }
}
```

### Validation
```
1. Static:  Verify JWT signature with issuer's public key
2. Dynamic: Query /trust_mark_status endpoint
3. Both:    Recommended for production
```

---

## SPID vs CIE DIFFERENCES

| Feature | SPID | CIE |
|---------|------|-----|
| Trust Anchor | AgID | Ministero dell'Interno |
| Claim namespace | `https://attributes.spid.gov.it/` | Mixed (standard + URI) |
| ID Token attrs | NO (UserInfo only) | YES (optional) |
| Encryption | Optional | Optional |
| ECDH support | NO | YES |
| Scope: profile | NO | YES (eIDAS Minimum Dataset) |

---

## COMMON MISTAKES

```
❌ acr_values="SpidL2"              → ✓ "https://www.spid.gov.it/SpidL2"
❌ request_uri parameter            → ✓ request parameter (signed JWT)
❌ Unencrypted request_object       → ✓ Signed (not encrypted)
❌ SPID attrs in ID Token           → ✓ In UserInfo endpoint
❌ CIE attrs as URI-style only      → ✓ Use standard OIDC names
❌ client_id="my-app"               → ✓ "https://sp.example.it"
❌ nonce="abc"                      → ✓ ≥32 alphanumeric chars
❌ Trailing slash in URLs           → ✓ Exact match required
❌ client_secret at token endpoint  → ✓ private_key_jwt only
❌ request_uri_not_supported error  → ✓ Use request param instead
```

---

## IMPLEMENTATION CHECKLIST

### RP (Relying Party)

- [ ] Generate RSA 2048+ bit key pair
- [ ] Create Entity Configuration with federation_entity + openid_relying_party metadata
- [ ] Publish at `/.well-known/openid-federation`
- [ ] Implement `/federation/resolve` endpoint
- [ ] Generate PKCE (code_verifier + code_challenge S256)
- [ ] Create signed request_object (RS256, ≥32 char nonce/state)
- [ ] POST to authorization endpoint with request parameter
- [ ] Verify authorization response (state, iss for CIE)
- [ ] Exchange code for tokens with private_key_jwt assertion
- [ ] Verify ID Token signature & claims (acr, nonce, aud)
- [ ] Call UserInfo endpoint with access_token
- [ ] Validate Trust Marks (static + dynamic)
- [ ] Cache Entity Configuration (update daily)

### OP (OpenID Provider)

- [ ] Generate RSA 2048+ bit key pair
- [ ] Create Entity Configuration with federation_entity + openid_provider metadata
- [ ] Publish at `/.well-known/openid-federation`
- [ ] Implement `/federation/resolve` endpoint
- [ ] Implement `/federation/fetch` endpoint
- [ ] Implement `/federation/list` endpoint
- [ ] Implement `/federation/trust_mark_status` endpoint
- [ ] Validate signed request_object (RS256)
- [ ] Verify PKCE code_challenge
- [ ] Verify private_key_jwt client assertion
- [ ] Return ID Token with acr + nonce claims
- [ ] Implement UserInfo endpoint (signed & encrypted)
- [ ] Support both SPID (URI-style) and CIE (standard OIDC) claims
- [ ] Publish Trust Marks in Entity Configuration
- [ ] Support acr_values: SpidL1, SpidL2, SpidL3

---

## FEDERATION ENTITY STATEMENT EXAMPLE

```json
{
  "iss": "https://agid.gov.it",
  "sub": "https://sp.example.it",
  "iat": 1704067200,
  "exp": 1704153600,
  "jwks": { "keys": [...] },
  "metadata": {
    "openid_relying_party": { ... }
  },
  "trust_mark_issuers": {
    "https://registry.interno.gov.it/openid_relying_party/public/": [
      "https://agid.gov.it"
    ]
  }
}
```

---

## PKCE GENERATION (Dart)

```dart
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

String codeVerifier = List.generate(
  128,
  (i) => 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~'[Random.secure().nextInt(66)]
).join();

String codeChallenge = base64Url
  .encode(sha256.convert(utf8.encode(codeVerifier)).bytes)
  .toString()
  .replaceAll('=', '');
```

---

## REQUEST OBJECT PAYLOAD (SPID)

```json
{
  "iss": "https://sp.example.it",
  "aud": "https://idp.spid.gov.it",
  "client_id": "https://sp.example.it",
  "response_type": "code",
  "scope": "openid profile email",
  "redirect_uri": "https://sp.example.it/callback",
  "state": "32-char-random-string-here",
  "nonce": "32-char-random-string-here",
  "code_challenge": "E9Mrozoa2owUednMg8_p5wqichJeuWMqFH7I80dP5YE",
  "code_challenge_method": "S256",
  "acr_values": "https://www.spid.gov.it/SpidL2",
  "prompt": "consent",
  "claims": {
    "userinfo": {
      "https://attributes.spid.gov.it/fiscalNumber": null,
      "https://attributes.spid.gov.it/name": null,
      "https://attributes.spid.gov.it/familyName": null
    }
  },
  "iat": 1704067200,
  "exp": 1704067300
}
```

---

## TOKEN ENDPOINT REQUEST

```
POST /token HTTP/1.1
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
&code=AUTH_CODE
&code_verifier=CODE_VERIFIER
&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
&client_assertion=JWT_ASSERTION
```

---

## USERINFO RESPONSE (SPID)

```json
{
  "sub": "SPID-1234567890",
  "https://attributes.spid.gov.it/name": "Mario",
  "https://attributes.spid.gov.it/familyName": "Rossi",
  "https://attributes.spid.gov.it/fiscalNumber": "TINIT-RSSMRA80A01H501U",
  "https://attributes.spid.gov.it/dateOfBirth": "1980-01-01",
  "https://attributes.spid.gov.it/email": "mario.rossi@example.it"
}
```

---

## USERINFO RESPONSE (CIE)

```json
{
  "sub": "CIE-9876543210",
  "given_name": "Mario",
  "family_name": "Rossi",
  "birthdate": "1980-01-01",
  "email": "mario.rossi@example.it",
  "https://attributes.eid.gov.it/fiscal_number": "TINIT-RSSMRA80A01H501U"
}
```

---

## 2025/2026 UPDATES

✓ **PKCE:** Now REQUIRED (was optional)  
✓ **acr_values:** Now REQUIRED (was optional)  
✓ **acr in ID Token:** Now REQUIRED (was optional)  
✓ **Trust Marks:** Mandatory exposure (was optional)  
✓ **EUDI Wallet:** Integration layer (2026 full rollout)  
✓ **No breaking changes:** All 2024 implementations remain valid  

---

## OFFICIAL SOURCES

- **AGID Specs:** https://docs.italia.it/italia/spid/spid-cie-oidc-docs/
- **AGID SPID:** https://www.agid.gov.it/it/piattaforme/spid
- **OIDC-FED 1.0:** https://openid.net/specs/openid-connect-federation-1_0.html
- **Demo IdP:** https://demo-idp-spid.pre.eid.gov.it/

---

**Last Updated:** May 2026  
**Status:** Current (AGID/IPZS 2025/2026)  
**For:** Flutter/Dart RP & Mock IdP Implementation
