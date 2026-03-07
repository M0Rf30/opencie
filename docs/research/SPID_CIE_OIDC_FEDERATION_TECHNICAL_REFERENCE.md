# SPID/CIE OpenID Connect Federation 1.0 - Technical Reference
**Italy 2025/2026 | AGID/IPZS Specifications**

---

## 1. ACR_VALUES (Authentication Context Class References)

### SPID acr_values
**Exact URIs (REQUIRED in all SPID implementations):**
```
https://www.spid.gov.it/SpidL1
https://www.spid.gov.it/SpidL2
https://www.spid.gov.it/SpidL3
```

**Metadata requirement:**
- `acr_values_supported` MUST contain all three values
- Operation: `subset_of`, `superset_of`
- Essential: `true`

**In Authorization Request:**
```
acr_values=https://www.spid.gov.it/SpidL2 https://www.spid.gov.it/SpidL3
```
(space-separated, in order of preference)

**In ID Token:**
- Claim `acr` is REQUIRED (unlike iGov where it's optional)
- Value returned MUST be >= requested level (OP can authenticate at higher level)

### CIE acr_values
**Status:** CIE uses same SPID acr_values URIs (NOT separate CIE-specific URIs)
```
https://www.spid.gov.it/SpidL1
https://www.spid.gov.it/SpidL2
https://www.spid.gov.it/SpidL3
```

**Trust Anchor:** Ministero dell'Interno (vs. AgID for SPID)

---

## 2. REQUIRED CLAIMS & SCOPES

### SPID Scopes
```
openid          # REQUIRED
profile         # Optional (returns default profile)
email           # Optional
```

### CIE Scopes
```
openid          # REQUIRED
profile         # Optional (Minimum Dataset eIDAS: family_name, given_name, birthdate, fiscal_number)
email           # Optional
```

### User Attributes - Full URI Names

**Namespace prefix:** `https://attributes.spid.gov.it/` (SPID) or `https://attributes.eid.gov.it/` (CIE)

| Attribute | SPID URI | CIE URI | Type | Notes |
|-----------|----------|---------|------|-------|
| Fiscal Number (Codice Fiscale) | `https://attributes.spid.gov.it/fiscalNumber` | `https://attributes.eid.gov.it/fiscal_number` | String | Format: `TINIT-ABCXYZ00W00Z000Z` |
| Given Name | `https://attributes.spid.gov.it/name` | `given_name` | String | Standard OIDC claim for CIE |
| Family Name | `https://attributes.spid.gov.it/familyName` | `family_name` | String | Standard OIDC claim for CIE |
| Date of Birth | `https://attributes.spid.gov.it/dateOfBirth` | `birthdate` | String | ISO8601: `YYYY-MM-DD` |
| Place of Birth | `https://attributes.spid.gov.it/placeOfBirth` | `https://attributes.eid.gov.it/place_of_birth` | String | |
| County of Birth | `https://attributes.spid.gov.it/countyOfBirth` | `https://attributes.eid.gov.it/county_of_birth` | String | |
| Gender | `https://attributes.spid.gov.it/gender` | `gender` | String | `M`, `F`, etc. |
| Email | `https://attributes.spid.gov.it/email` | `email` | String | |
| Address | `https://attributes.spid.gov.it/address` | `https://attributes.eid.gov.it/address` | String | |
| Digital Address | `https://attributes.spid.gov.it/digitalAddress` | `https://attributes.eid.gov.it/digital_address` | String | PEC |
| Mobile Phone | `https://attributes.spid.gov.it/mobilePhone` | `phone_number` | String | |
| SPID Code | `https://attributes.spid.gov.it/spidCode` | `https://attributes.eid.gov.it/spid_code` | String | Unique identifier |
| Company Name | `https://attributes.spid.gov.it/companyName` | `https://attributes.eid.gov.it/company_name` | String | |
| Registered Office | `https://attributes.spid.gov.it/registeredOffice` | `https://attributes.eid.gov.it/registered_office` | String | |
| VAT Code | `https://attributes.spid.gov.it/ivaCode` | `https://attributes.eid.gov.it/vat_number` | String | |
| ID Card | `https://attributes.spid.gov.it/idCard` | `https://attributes.eid.gov.it/document_details` | String | |
| Expiration Date | `https://attributes.spid.gov.it/expirationDate` | `https://attributes.eid.gov.it/expiration_date` | String | |

### Example Claims Request (SPID)
```json
{
  "id_token": {
    "nbf": { "essential": true },
    "jti": { "essential": true }
  },
  "userinfo": {
    "https://attributes.spid.gov.it/name": null,
    "https://attributes.spid.gov.it/familyName": null,
    "https://attributes.spid.gov.it/fiscalNumber": null,
    "https://attributes.spid.gov.it/dateOfBirth": null,
    "https://attributes.spid.gov.it/email": null
  }
}
```

### Example Claims Request (CIE)
```json
{
  "id_token": {
    "family_name": { "essential": true },
    "email": { "essential": true }
  },
  "userinfo": {
    "given_name": null,
    "family_name": null,
    "email": null,
    "https://attributes.eid.gov.it/fiscal_number": null
  }
}
```

---

## 3. FEDERATION ENTITY STATEMENT STRUCTURE

### Entity Configuration (EC) - /.well-known/openid-federation

**JWT Header:**
```json
{
  "alg": "RS256",
  "kid": "key-id",
  "typ": "entity-statement+jwt"
}
```

**JWT Payload - Common Claims (all entities):**
```json
{
  "iss": "https://entity.example.it",
  "sub": "https://entity.example.it",
  "iat": 1519032969,
  "exp": 1519033149,
  "jwks": {
    "keys": [
      {
        "kty": "RSA",
        "use": "sig",
        "kid": "key-id",
        "n": "...",
        "e": "AQAB"
      }
    ]
  }
}
```

**Additional Claims - Leaf Entities (RP/OP) & Intermediaries (SA):**
```json
{
  "authority_hints": [
    "https://trust-anchor.example.it"
  ],
  "trust_marks": [
    {
      "id": "https://registry.interno.gov.it/openid_relying_party/public/",
      "trust_mark": "eyJhbGc..."
    }
  ]
}
```

**Additional Claims - Trust Anchor (TA):**
```json
{
  "constraints": {
    "max_path_length": 2,
    "allowed_leaf_entity_types": [
      "openid_relying_party",
      "openid_provider"
    ]
  },
  "trust_mark_issuers": {
    "https://registry.interno.gov.it/openid_relying_party/public/": [
      "https://agid.gov.it",
      "https://intermediary.gov.it"
    ],
    "https://registry.interno.gov.it/openid_provider/public/": [
      "https://agid.gov.it"
    ]
  }
}
```

### Metadata Objects in EC

**RP must include:**
```json
{
  "metadata": {
    "federation_entity": {
      "organization_name": "Service Provider Name",
      "homepage_uri": "https://sp.example.it",
      "policy_uri": "https://sp.example.it/privacy",
      "logo_uri": "https://sp.example.it/logo.svg",
      "contacts": ["pec@sp.example.it"],
      "federation_resolve_endpoint": "https://sp.example.it/resolve"
    },
    "openid_relying_party": {
      "client_id": "https://sp.example.it",
      "client_registration_types": ["automatic"],
      "redirect_uris": ["https://sp.example.it/callback"],
      "response_types": ["code"],
      "grant_types": ["authorization_code", "refresh_token"],
      "token_endpoint_auth_method": "private_key_jwt",
      "id_token_signed_response_alg": "RS256",
      "userinfo_signed_response_alg": "RS256",
      "jwks": { "keys": [...] }
    }
  }
}
```

**OP must include:**
```json
{
  "metadata": {
    "federation_entity": { ... },
    "openid_provider": {
      "issuer": "https://idp.example.it",
      "authorization_endpoint": "https://idp.example.it/authorize",
      "token_endpoint": "https://idp.example.it/token",
      "userinfo_endpoint": "https://idp.example.it/userinfo",
      "introspection_endpoint": "https://idp.example.it/introspection",
      "revocation_endpoint": "https://idp.example.it/revocation",
      "jwks": { "keys": [...] },
      "scopes_supported": ["openid", "profile", "email"],
      "response_types_supported": ["code"],
      "response_modes_supported": ["query"],
      "grant_types_supported": ["authorization_code", "refresh_token"],
      "acr_values_supported": [
        "https://www.spid.gov.it/SpidL1",
        "https://www.spid.gov.it/SpidL2",
        "https://www.spid.gov.it/SpidL3"
      ],
      "subject_types_supported": ["pairwise"],
      "id_token_signing_alg_values_supported": ["RS256", "RS512"],
      "id_token_encryption_alg_values_supported": ["RSA-OAEP", "RSA-OAEP-256"],
      "id_token_encryption_enc_values_supported": ["A128CBC-HS256", "A256CBC-HS512"],
      "userinfo_signing_alg_values_supported": ["RS256", "RS512"],
      "userinfo_encrypted_response_alg_values_supported": ["RSA-OAEP", "RSA-OAEP-256"],
      "userinfo_encrypted_response_enc_values_supported": ["A128CBC-HS256", "A256CBC-HS512"],
      "request_object_signing_alg_values_supported": ["RS256", "RS512"],
      "request_authentication_methods_supported": {
        "authorization_endpoint": ["request_object"]
      },
      "request_authentication_signing_alg_values_supported": ["RS256", "RS512"],
      "code_challenge_methods_supported": ["S256"],
      "claims_supported": [
        "https://attributes.spid.gov.it/fiscalNumber",
        "https://attributes.spid.gov.it/name",
        "https://attributes.spid.gov.it/familyName",
        "https://attributes.spid.gov.it/dateOfBirth",
        "https://attributes.spid.gov.it/placeOfBirth",
        "https://attributes.spid.gov.it/gender",
        "https://attributes.spid.gov.it/email",
        "https://attributes.spid.gov.it/address",
        "https://attributes.spid.gov.it/digitalAddress"
      ],
      "client_registration_types_supported": ["automatic"]
    }
  }
}
```

---

## 4. TRUST MARKS

### Trust Mark Structure
**JWT Header:**
```json
{
  "alg": "RS256",
  "kid": "key-id",
  "typ": "trust-mark+jwt"
}
```

**JWT Payload:**
```json
{
  "iss": "https://agid.gov.it",
  "sub": "https://sp.example.it",
  "id": "https://registry.interno.gov.it/openid_relying_party/public/",
  "iat": 1519032969,
  "exp": 1519033149,
  "logo_uri": "https://registry.interno.gov.it/logo.svg",
  "ref": "https://registry.interno.gov.it/openid_relying_party/public/",
  "organization_type": "public",
  "id_code": {
    "ipa_code": "c_a123"
  },
  "email": "pec@sp.example.it",
  "organization_name": "Service Provider Name"
}
```

### Trust Mark Types (id values)
| Type | Entity | Format |
|------|--------|--------|
| `openid_relying_party` | RP | `https://registry.interno.gov.it/openid_relying_party/public/` |
| `openid_provider` | OP | `https://registry.interno.gov.it/openid_provider/public/` |
| `intermediate` | SA | `https://registry.interno.gov.it/intermediate/full/` or `/light/` |
| `oauth_resource` | AA | `https://registry.interno.gov.it/oauth_resource/public/` |

### Trust Mark Issuers (in TA EC)
```json
{
  "trust_mark_issuers": {
    "https://registry.interno.gov.it/openid_relying_party/public/": [
      "https://agid.gov.it",
      "https://intermediary.gov.it"
    ],
    "https://registry.interno.gov.it/openid_provider/public/": [
      "https://agid.gov.it"
    ]
  }
}
```

### Trust Mark Validation
1. **Static validation:** Verify JWT signature with issuer's public key
2. **Dynamic validation:** Query `trust_mark_status` endpoint
3. **Endpoint:** `https://issuer.example.it/trust_mark_status`

---

## 5. REQUEST_OBJECT REQUIREMENTS

### Signed Request Objects (REQUIRED)
- **Method:** JWT signed (NOT encrypted)
- **Signature algorithm:** RS256 (REQUIRED), RS512, ES256, ES512, PS256, PS512 (RECOMMENDED)
- **Delivery:** `request` parameter (NOT `request_uri`)

### Request Object JWT Header
```json
{
  "alg": "RS256",
  "kid": "rp-key-id",
  "typ": "JWT"
}
```

### Request Object JWT Payload
```json
{
  "iss": "https://sp.example.it",
  "aud": "https://idp.example.it",
  "client_id": "https://sp.example.it",
  "response_type": "code",
  "scope": "openid profile email",
  "redirect_uri": "https://sp.example.it/callback",
  "state": "random-state-32chars-minimum",
  "nonce": "random-nonce-32chars-minimum",
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
  "iat": 1519032969,
  "exp": 1519033149
}
```

### PKCE (REQUIRED)
```
code_challenge_method: S256 (REQUIRED)
code_challenge: base64url(sha256(code_verifier))
code_verifier: random string 43-128 chars [A-Za-z0-9._~-]
```

---

## 6. CLIENT AUTHENTICATION AT TOKEN ENDPOINT

### Method: private_key_jwt (REQUIRED)
```
token_endpoint_auth_method: "private_key_jwt"
```

### Client Assertion JWT
**Header:**
```json
{
  "alg": "RS256",
  "kid": "rp-key-id",
  "typ": "JWT"
}
```

**Payload:**
```json
{
  "iss": "https://sp.example.it",
  "sub": "https://sp.example.it",
  "aud": "https://idp.example.it/token",
  "iat": 1519032969,
  "exp": 1519033149,
  "jti": "unique-jwt-id"
}
```

**Token Endpoint Request:**
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

## 7. CRYPTOGRAPHIC ALGORITHMS

### MUST Support (Required)
| Algorithm | Operation | Use |
|-----------|-----------|-----|
| RS256 | Signature | All JWT signing (EC, ES, TM, request_object) |
| RS512 | Signature | Alternative signature |
| RSA-OAEP | Key Encryption | ID Token, UserInfo encryption |
| RSA-OAEP-256 | Key Encryption | ID Token, UserInfo encryption |
| A128CBC-HS256 | Content Encryption | ID Token, UserInfo encryption |
| A256CBC-HS512 | Content Encryption | ID Token, UserInfo encryption |

### RECOMMENDED Support
| Algorithm | Operation |
|-----------|-----------|
| ES256 | Signature |
| ES512 | Signature |
| PS256 | Signature |
| PS512 | Signature |
| ECDH-ES | Key Encryption (CIE only) |
| ECDH-ES+A128KW | Key Encryption (CIE only) |
| ECDH-ES+A256KW | Key Encryption (CIE only) |

### MUST NOT Support
- `none` (signature)
- `RSA1_5` (key encryption)
- `HS256`, `HS384`, `HS512` (symmetric signature)

### RSA Key Size
- Minimum: 2048 bits
- Recommended: 4096 bits

---

## 8. FEDERATION ENDPOINTS

### All Entities MUST expose:
```
/.well-known/openid-federation          # Entity Configuration
/resolve                                 # Resolve Entity Statement
```

### TA & SA MUST expose:
```
/fetch                                   # Fetch Entity Statement
/list                                    # Entity Listing
/trust_mark_status                       # Trust Mark Status
```

### AA MUST expose:
```
/trust_mark_status                       # Trust Mark Status
```

---

## 9. DIFFERENCES: SPID vs CIE

| Feature | SPID | CIE |
|---------|------|-----|
| **Trust Anchor** | AgID | Ministero dell'Interno |
| **Claim namespace** | `https://attributes.spid.gov.it/` | `https://attributes.eid.gov.it/` |
| **Standard claims** | URI-style only | Mix of standard OIDC + URI-style |
| **ID Token attributes** | NOT in ID Token (UserInfo only) | Can be in ID Token or UserInfo |
| **Scope: profile** | Not standard | Returns Minimum Dataset eIDAS |
| **Encryption** | Not required | Optional (id_token_encrypted_response_alg) |
| **ECDH algorithms** | Not supported | Supported |
| **client_id format** | HTTPS URL | HTTPS URL |
| **redirect_uris** | HTTPS only | HTTPS + custom schemes (mobile) |

---

## 10. RECENT CHANGES & 2025/2026 UPDATES

### eIDAS 2.0 & EUDI Wallet Integration
- **Status:** EUDI Wallet officially launched 2025, full implementation by 2026
- **Impact on SPID/CIE:** 
  - SPID/CIE will serve as PID (Person Identification Data) providers for EUDI Wallet initialization
  - SPID remains national identification system
  - CIE may evolve as primary tool for EU-level access
  - No immediate replacement of SPID/CIE; interoperability layer added

### OpenID Connect Federation 1.0 Adoption
- **Mandatory for new integrations:** OIDC strongly recommended over SAML2
- **Government incentive:** €3,000 subsidy for OIDC migration (vs. SAML2 training)
- **Timeline:** All PA must support OIDC by 2026

### Key Spec Updates (2025/2026)
1. **PKCE:** Now REQUIRED (was optional in iGov)
2. **acr_values:** REQUIRED (was optional in iGov)
3. **acr claim in ID Token:** REQUIRED (was optional in iGov)
4. **Trust Marks:** Mandatory exposure (not optional as in OIDC-FED)
5. **Automatic client registration:** Only mode supported (explicit registration removed)

### No Breaking Changes
- All existing SPID/CIE OIDC implementations remain valid
- Backward compatible with 2024 specs
- No new acr_values introduced

---

## 11. IMPLEMENTATION GOTCHAS

### Common Pitfalls

1. **acr_values format:** Must be full URI, NOT just `L2` or `SpidL2`
   ```
   ✓ https://www.spid.gov.it/SpidL2
   ✗ SpidL2
   ✗ L2
   ```

2. **Request object signature:** MUST be signed, NOT encrypted
   ```
   ✓ JWT with "alg": "RS256"
   ✗ JWE with "alg": "RSA-OAEP"
   ```

3. **SPID attributes in ID Token:** NOT allowed
   ```
   ✓ Request in claims.userinfo
   ✗ Request in claims.id_token
   ```

4. **CIE standard claims:** Use standard OIDC names, NOT URI-style
   ```
   ✓ "family_name": "Rossi"
   ✗ "https://attributes.eid.gov.it/family_name": "Rossi"
   ```

5. **Trust Anchor URLs:** Must match exactly in authority_hints
   ```
   ✓ "https://agid.gov.it"
   ✗ "https://agid.gov.it/"  (trailing slash breaks validation)
   ```

6. **Scope parameter:** Must appear in BOTH HTTP request AND request object payload
   ```
   POST /authorize?scope=openid%20profile
   
   {
     "scope": "openid profile",
     ...
   }
   ```

7. **client_id:** Must be HTTPS URL, not opaque string
   ```
   ✓ "https://sp.example.it"
   ✗ "my-client-id"
   ```

8. **Nonce & State:** Minimum 32 alphanumeric characters
   ```
   ✓ "MBzGqyf9QytD28eupyWhSqMj78WNqpc2"
   ✗ "abc123"
   ```

9. **Trust Mark validation:** Check both static (signature) AND dynamic (status endpoint)
   - Static: Verify JWT signature with issuer's public key
   - Dynamic: Query `/trust_mark_status` endpoint for revocation

10. **Entity Configuration caching:** Update daily (not just on startup)

---

## 12. REFERENCE IMPLEMENTATIONS

### Official Reference Code
- **Python:** https://github.com/italia/spid-cie-oidc-django
- **PHP:** https://github.com/italia/spid-cie-oidc-php
- **Django config example:**
  ```python
  OIDCFED_PROVIDER_PROFILES_DEFAULT_ACR = {
      'spid': 'https://www.spid.gov.it/SpidL2',
      'cie': 'https://www.spid.gov.it/SpidL2'
  }
  ```

### Demo IdP
- **SPID Demo:** https://demo-idp-spid.pre.eid.gov.it/
- **Test users:** Available with various acr_values and attributes

---

## 13. OFFICIAL DOCUMENTATION SOURCES

- **AGID SPID/CIE OIDC Specs:** https://docs.italia.it/italia/spid/spid-cie-oidc-docs/
- **AGID Official:** https://www.agid.gov.it/it/piattaforme/spid
- **OpenID Federation 1.0:** https://openid.net/specs/openid-connect-federation-1_0.html
- **iGov Profile:** https://openid.net/specs/openid-igov-oauth2-1_0.html

---

## 14. QUICK REFERENCE: SPID vs CIE CLAIM NAMES

### Fiscal Number
```
SPID: "https://attributes.spid.gov.it/fiscalNumber"
CIE:  "https://attributes.eid.gov.it/fiscal_number"
```

### Name
```
SPID: "https://attributes.spid.gov.it/name"
CIE:  "given_name"  (standard OIDC)
```

### Family Name
```
SPID: "https://attributes.spid.gov.it/familyName"
CIE:  "family_name"  (standard OIDC)
```

### Date of Birth
```
SPID: "https://attributes.spid.gov.it/dateOfBirth"
CIE:  "birthdate"  (standard OIDC)
```

### Gender
```
SPID: "https://attributes.spid.gov.it/gender"
CIE:  "gender"  (standard OIDC)
```

### Email
```
SPID: "https://attributes.spid.gov.it/email"
CIE:  "email"  (standard OIDC)
```

---

**Document Version:** 1.0 (May 2026)  
**Status:** Current (AGID/IPZS 2025/2026 specifications)  
**Last Updated:** 2026-05-04
