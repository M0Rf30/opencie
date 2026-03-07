# EU Digital Identity & CSC API v2 - Technical Reference (2025/2026)

**Last Updated:** May 2026  
**Status:** Production-Ready (ARF 1.6, OpenID4VCI/VP Final, CSC API v2.2)

---

## PART A: EUDI WALLET ECOSYSTEM

### 1. ARCHITECTURE REFERENCE FRAMEWORK (ARF)

#### Current Version
- **ARF 1.6** (March 2026) - Latest stable release
- **ARF 1.4.0** (November 2024) - Previous stable
- **Legal Basis:** eIDAS Regulation 2024/1183 + 5 Implementing Regulations (CIR 2024/2977, CIR 2025/846-849, CIR 2025/1566-1572, etc.)
- **Official Repository:** https://github.com/eu-digital-identity-wallet/eudi-doc-architecture-and-reference-framework
- **Documentation:** https://eudi.dev/1.4.0/arf/ (also available at 2.7.0 for latest)

#### Key Components

| Component | Purpose | Format(s) | Status |
|-----------|---------|-----------|--------|
| **PID** (Person Identification Data) | Core identity credential | SD-JWT VC, mso_mdoc | Mandatory |
| **mDL** (Mobile Driving Licence) | ISO 18013-5 credential | mso_mdoc | Mandatory |
| **EAA** (Electronic Attestation of Attributes) | Qualified/non-qualified attributes | SD-JWT VC, mso_mdoc | Mandatory |
| **QES** (Qualified Electronic Signature) | Remote signing via QSCD | CSC API v2.x | Mandatory |
| **Pseudonyms** | Unlinkable identifiers | SD-JWT VC | Optional |

#### Ecosystem Roles
1. **Wallet Provider** - Distributes certified Wallet Solution
2. **PID Provider** - Issues Person Identification Data (LoA High)
3. **QEAA Provider** - Issues Qualified EAA (QTSP)
4. **PuB-EAA Provider** - Public body authentic source EAA
5. **EAA Provider** - Non-qualified EAA
6. **Relying Party** - Service requesting credentials
7. **Trusted Lists Registrar** - Maintains trust anchors
8. **QES Remote Creation Service Provider** - Remote QSCD via CSC API

---

### 2. OPENID4VCI (Verifiable Credential Issuance)

**Specification:** OpenID for Verifiable Credential Issuance 1.0  
**Published:** 16 September 2025 (Final)  
**Status:** RFC-track, widely implemented  
**Reference:** https://openid.net/specs/openid-4-verifiable-credential-issuance-1_0.html

#### Protocol Flow

```
Wallet                          Issuer
  |                               |
  |---(1) Credential Offer------->|
  |       (QR code or URL)         |
  |                               |
  |---(2) Authorization Request--->|
  |       (PKCE, DPoP optional)    |
  |                               |
  |<---(3) Authorization Code-----|
  |                               |
  |---(4) Token Request---------->|
  |       (code, code_verifier)    |
  |                               |
  |<---(5) Access Token-----------|
  |       (c_nonce for proof)      |
  |                               |
  |---(6) Credential Request----->|
  |       (format, proof)          |
  |                               |
  |<---(7) Credential Response----|
  |       (credential, c_nonce)    |
```

#### Endpoints

| Endpoint | Method | Purpose | Auth |
|----------|--------|---------|------|
| `/.well-known/openid-credential-issuer` | GET | Metadata discovery | None |
| `/authorization` | GET/POST | OAuth 2.0 authorization | None |
| `/token` | POST | Access token issuance | Client credentials |
| `/credential` | POST | Credential issuance | Bearer token |
| `/batch_credential` | POST | Batch issuance | Bearer token |
| `/deferred_credential` | POST | Deferred issuance | Bearer token |
| `/notification` | POST | Wallet notifications | Bearer token |

#### Credential Formats

```json
{
  "format": "mso_mdoc",  // ISO 18013-5 mdoc
  "doctype": "org.iso.18013.5.1.mDL",
  "claims": {
    "org.iso.18013.5.1": [
      "family_name", "given_name", "birth_date", "issue_date", "expiry_date"
    ]
  }
}
```

```json
{
  "format": "dc+sd-jwt",  // SD-JWT VC (IETF draft)
  "vct": "https://example.com/credentials/identity",
  "claims": {
    "given_name": {},
    "family_name": {},
    "birthdate": {}
  }
}
```

#### Proof Object (JWT)

```json
{
  "proof_type": "jwt",
  "jwt": "eyJhbGciOiJFUzI1NiIsInR5cCI6Im9wZW5pZDR2Y2ktcHJvb2Yrand0In0..."
}
```

**Proof JWT Claims:**
- `iss`: Wallet client_id
- `aud`: Issuer URL
- `iat`: Issued at (current time)
- `exp`: Expiration (iat + 5 min recommended)
- `nonce`: c_nonce from issuer
- `proof_type`: "jwt"

#### Metadata Response

```json
{
  "credential_issuer": "https://issuer.example.com",
  "authorization_server": "https://issuer.example.com",
  "credential_endpoint": "https://issuer.example.com/credential",
  "batch_credential_endpoint": "https://issuer.example.com/batch_credential",
  "deferred_credential_endpoint": "https://issuer.example.com/deferred_credential",
  "notification_endpoint": "https://issuer.example.com/notification",
  "credential_configurations_supported": {
    "org.iso.18013.5.1.mDL": {
      "format": "mso_mdoc",
      "doctype": "org.iso.18013.5.1.mDL",
      "cryptographic_binding_methods_supported": ["cose_key"],
      "credential_signing_alg_values_supported": ["ES256"],
      "display": [
        {
          "name": "Mobile Driving Licence",
          "locale": "en-US"
        }
      ]
    },
    "eu.europa.ec.eudi.pid.1": {
      "format": "dc+sd-jwt",
      "vct": "https://example.com/credentials/identity",
      "claims": {
        "given_name": { "display": [{ "name": "Given Name" }] },
        "family_name": { "display": [{ "name": "Family Name" }] }
      }
    }
  }
}
```

---

### 3. OPENID4VP (Verifiable Presentations)

**Specification:** OpenID for Verifiable Presentations 1.0  
**Published:** 9 July 2025 (Final)  
**Status:** RFC-track, widely implemented  
**Reference:** https://openid.net/specs/openid-4-verifiable-presentations-1_0.html

#### Protocol Flow (Same Device)

```
Verifier                        Wallet
  |                               |
  |---(1) Authorization Request-->|
  |       (DCQL query)             |
  |                               |
  |<---(2) Authorization Response-|
  |       (vp_token)               |
```

#### Protocol Flow (Cross Device - QR Code)

```
Verifier                        Wallet
  |                               |
  |---(1) QR Code (Request URI)-->|
  |                               |
  |<---(2) POST wallet_metadata---|
  |                               |
  |---(3) Request Object--------->|
  |       (DCQL query)             |
  |                               |
  |<---(4) HTTP POST response-----|
  |       (vp_token)               |
```

#### Authorization Request Parameters

```json
{
  "response_type": "vp_token",
  "client_id": "https://verifier.example.com",
  "redirect_uri": "https://verifier.example.com/callback",
  "response_mode": "direct_post",
  "response_uri": "https://verifier.example.com/response",
  "dcql_query": {
    "credentials": [
      {
        "id": "org.iso.18013.5.1.mDL",
        "format": {
          "mso_mdoc": {
            "alg": ["ES256", "ES384"]
          }
        },
        "claims": {
          "org.iso.18013.5.1": {
            "family_name": {},
            "given_name": {},
            "birth_date": {}
          }
        }
      }
    ]
  },
  "client_metadata": {
    "vp_formats_supported": {
      "mso_mdoc": {
        "alg": ["ES256"]
      },
      "dc+sd-jwt": {
        "alg": ["ES256"]
      }
    }
  }
}
```

#### VP Token Response

```json
{
  "vp_token": [
    {
      "format": "mso_mdoc",
      "presentation": "..."  // CBOR-encoded mdoc
    }
  ]
}
```

#### DCQL (Digital Credentials Query Language)

```json
{
  "credentials": [
    {
      "id": "pid_credential",
      "format": {
        "dc+sd-jwt": {
          "alg": ["ES256"]
        }
      },
      "claims": {
        "given_name": {},
        "family_name": {},
        "birthdate": {}
      }
    },
    {
      "id": "mdl_credential",
      "format": {
        "mso_mdoc": {
          "alg": ["ES256"]
        }
      },
      "claims": {
        "org.iso.18013.5.1": {
          "family_name": {},
          "driving_privileges": {}
        }
      }
    }
  ],
  "credential_sets": [
    {
      "options": ["pid_credential", "mdl_credential"]
    }
  ]
}
```

#### Response Modes

| Mode | Transport | Use Case |
|------|-----------|----------|
| `fragment` | URL fragment | Same device, small response |
| `query` | URL query | Same device, small response |
| `form_post` | HTML form POST | Same device, larger response |
| `direct_post` | HTTP POST | Cross-device, any size |
| `direct_post.jwt` | Encrypted HTTP POST | Cross-device, confidential |

---

### 4. ISO/IEC 18013-5 (mDL - Mobile Driving Licence)

**Standard:** ISO/IEC 18013-5:2021  
**Extended by:** ISO/IEC TS 18013-7:2025 (online presentation)  
**Format:** CBOR (Concise Binary Object Representation)  
**Cryptography:** COSE (CBOR Object Signing and Encryption)

#### Data Structure

```
MobileSecurityObject (MSO)
├── version: "1.0"
├── digestAlgorithm: "SHA-256"
├── valueDigests: {
│   "org.iso.18013.5.1": {
│     "family_name": [salt, digest],
│     "given_name": [salt, digest],
│     "birth_date": [salt, digest],
│     ...
│   }
├── deviceKeyInfo: {
│   "deviceKey": COSE_Key (P-256),
│   "keyAuthorizations": [...],
│   "keyInfo": {...}
├── validityInfo: {
│   "signed": <date>,
│   "validFrom": <date>,
│   "validUntil": <date>
├── issuerAuth: COSE_Sign1 {
│   "protected": {...},
│   "unprotected": {...},
│   "payload": MSO,
│   "signature": <issuer_signature>
```

#### Device Engagement (QR Code / NFC)

```json
{
  "version": "1.0",
  "security": {
    "cipherSuiteIdentifier": 1,
    "publicKey": {...}
  },
  "transferMethods": [
    {
      "type": 1,  // BLE
      "version": 1,
      "peripheralServerMode": true
    },
    {
      "type": 2,  // NFC
      "version": 1
    }
  ],
  "options": {
    "oidc": [1, "https://reader.example.com", "token123"],
    "webApi": [1, "https://reader.example.com/api", "token123"]
  }
}
```

#### Namespaces

| Namespace | Purpose | Attributes |
|-----------|---------|-----------|
| `org.iso.18013.5.1` | mDL core | family_name, given_name, birth_date, issue_date, expiry_date, document_number, driving_privileges |
| `org.iso.18013.5.1.aamva` | US-specific | jurisdiction_code, aamva_version_number |
| `eu.europa.ec.eudi.pid.1` | EU PID | given_name, family_name, birth_date, unique_id, issuance_date, expiry_date |

#### Selective Disclosure

Per-element signing enables selective disclosure:
```
Issuer signs: H(salt || "family_name" || "Smith")
Wallet reveals: salt, "family_name", "Smith"
Verifier verifies: H(salt || "family_name" || "Smith") ∈ MSO.valueDigests
```

---

### 5. SD-JWT VC (Selective Disclosure JWT Verifiable Credentials)

**Specification:** draft-ietf-oauth-sd-jwt-vc-15 (February 2026)  
**Base Spec:** RFC 9901 (Selective Disclosure for JWTs)  
**Status:** IETF Standards Track (near-final)  
**Reference:** https://datatracker.ietf.org/doc/html/draft-ietf-oauth-sd-jwt-vc-15

#### Structure

```
SD-JWT VC = Issuer-signed JWT ~ Disclosure1 ~ Disclosure2 ~ ... ~ Disclosuren
```

#### Issuer-Signed JWT

```json
{
  "alg": "ES256",
  "typ": "vc+sd-jwt",
  "x5c": ["cert_chain"]
}
.
{
  "iss": "https://issuer.example.com",
  "sub": "user@example.com",
  "iat": 1234567890,
  "exp": 1234654290,
  "vct": "https://example.com/credentials/identity",
  "_sd": [
    "H_G3jK2L9mN4oP5qR6sT7uV8wX9yZ0aB1cD2eF3gH4",
    "I_H4kL3m5oN6pQ7rS8tU9vW0xY1zA2bC3dE4fG5hI6"
  ],
  "cnf": {
    "jwk": {
      "kty": "EC",
      "crv": "P-256",
      "x": "...",
      "y": "..."
    }
  }
}
```

#### Disclosures (Base64url-encoded JSON arrays)

```
Disclosure 1: ["salt1", "given_name", "John"]
Disclosure 2: ["salt2", "family_name", "Smith"]
Disclosure 3: ["salt3", "birthdate", "1990-01-01"]
```

#### Key Binding JWT

```json
{
  "alg": "ES256",
  "typ": "kb+jwt"
}
.
{
  "iss": "https://wallet.example.com",
  "aud": "https://verifier.example.com",
  "iat": 1234567890,
  "nonce": "nonce123",
  "sd_hash": "H_G3jK2L9mN4oP5qR6sT7uV8wX9yZ0aB1cD2eF3gH4"
}
```

#### Presentation

```
Presented SD-JWT VC = JWT ~ Disclosure1 ~ Disclosure3 ~ KB-JWT
(Disclosure2 omitted - family_name not disclosed)
```

#### Credential Format Identifier

```
"dc+sd-jwt"  // EUDI Wallet standard format
```

---

### 6. ITALIAN PID PROFILE (IT-Wallet)

**Repository:** https://github.com/italia/eid-wallet-it-docs  
**Version:** 1.4.0 (stable)  
**Legal Basis:** Decreto-Legge n. 19 (2 March 2024), converted by Legge n. 56 (29 April 2024)  
**Implementing Authority:** Department for Digital Transformation, IPZS, PagoPA, AGID

#### PID Data Model (SD-JWT VC Format)

```json
{
  "iss": "https://pid-provider.it",
  "sub": "unique_id_IT",
  "iat": 1234567890,
  "exp": 1234654290,
  "vct": "https://example.com/credentials/identity",
  "_sd": [
    "H_given_name",
    "H_family_name",
    "H_birth_date",
    "H_unique_id"
  ],
  "cnf": {
    "jwk": { "kty": "EC", "crv": "P-256", "x": "...", "y": "..." }
  }
}
```

#### PID Data Model (mso_mdoc Format)

```
doctype: "eu.europa.ec.eudi.pid.1"
namespace: "eu.europa.ec.eudi.pid.1"
claims:
  - given_name
  - family_name
  - birth_date
  - unique_id
  - issuance_date
  - expiry_date
```

#### Issuance Flow

1. **User Identification** - eID Substantial Authentication with MRTD verification
2. **Credential Request** - OpenID4VCI authorization code flow
3. **Proof of Possession** - JWT proof with device key binding
4. **Credential Response** - SD-JWT VC or mso_mdoc

#### Trust Infrastructure

- **Trusted Lists:** Italian PID Providers registered in EU Trusted Lists
- **Access Certificates:** X.509 certificates for PID Provider authentication
- **Revocation:** Status List Token (Token Status List spec)

#### Wallet Attestation

- **Wallet Instance Attestation (WIA):** Proves wallet authenticity
- **Key Attestation:** Proves device key binding
- **Wallet Trust Evidence (WTE):** Overall wallet trustworthiness

---

### 7. DART/FLUTTER LIBRARIES FOR EUDI WALLET

#### Official EU Libraries

| Library | Language | Purpose | Status |
|---------|----------|---------|--------|
| `eudi-lib-android-wallet-core` | Kotlin | Android wallet core | Production |
| `eudi-lib-ios-wallet-core` | Swift | iOS wallet core | Production |
| `eudi-lib-jvm-sdjwt` | Kotlin | SD-JWT support | Production |
| `eudi-lib-sdjwt-swift` | Swift | SD-JWT support | Production |
| `eudi-wallet-it-python` | Python | Italian wallet RP/issuer | Production |

#### Dart/Flutter Options

**No official Dart library exists.** Recommended approaches:

1. **Wrap Kotlin/Swift libraries** via platform channels
   ```dart
   // Example: Call Kotlin library from Flutter
   const platform = MethodChannel('com.example.eudi/wallet');
   final result = await platform.invokeMethod('issueCredential', {...});
   ```

2. **Port from TypeScript/JavaScript**
   - `sd-jwt-js` (TypeScript) → Dart port
   - `openid4vc` (Rust) → WASM → Dart

3. **Use existing Dart packages**
   - `pointycastle` - Cryptography (ECDSA, SHA-256)
   - `cbor` - CBOR encoding/decoding
   - `jose` - JWT/JWE support
   - `http` - HTTP client for OpenID4VCI/VP

#### Recommended Stack for Flutter

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

// Local storage
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
```

#### Implementation Checklist

- [ ] OpenID4VCI credential request/response
- [ ] OpenID4VP presentation request/response
- [ ] SD-JWT VC issuance & presentation
- [ ] mso_mdoc (CBOR) encoding/decoding
- [ ] Device key binding (ECDSA P-256)
- [ ] Selective disclosure (hash verification)
- [ ] Wallet metadata discovery
- [ ] Trust anchor validation (X.509)
- [ ] Status list revocation check
- [ ] Secure key storage (Keystore/Keychain)

---

## PART B: CSC API v2 (Cloud Signature Consortium)

### 1. CSC API SPECIFICATION

**Current Version:** CSC API v2.2 (6 November 2025)  
**Previous:** CSC API v2.1.0.1 (22 January 2025), v2.0.0.2 (20 April 2023)  
**Official Repository:** https://cloudsignatureconsortium.org/resources/download-api-specifications/  
**Base URI Format:** `https://service.domain.org/xxx/csc/v2/`

#### Core Endpoints

| Endpoint | Method | Purpose | Auth | Response |
|----------|--------|---------|------|----------|
| `/info` | GET/POST | Service metadata | None | JSON |
| `/oauth2/authorize` | GET | OAuth 2.0 authorization | None | Redirect |
| `/oauth2/token` | POST | Access token issuance | Client credentials | JSON |
| `/oauth2/revoke` | POST | Token revocation | Client credentials | JSON |
| `/credentials/list` | POST | List user credentials | Bearer (service scope) | JSON |
| `/credentials/info` | POST | Get credential details | Bearer (service scope) | JSON |
| `/credentials/authorize` | POST | Authorize credential use | Bearer (service scope) | JSON (SAD) |
| `/signatures/signHash` | POST | Sign hash(es) | Bearer (credential scope) | JSON |
| `/signatures/signDoc` | POST | Sign document(s) | Bearer (credential scope) | JSON |
| `/signatures/timestamp` | POST | Get timestamp | Bearer (credential scope) | JSON |

---

### 2. OAUTH 2.0 AUTHORIZATION FLOW

#### Authorization Code Flow with PKCE

```
Client                          Authorization Server
  |                                    |
  |---(1) Authorization Request------->|
  |       (client_id, redirect_uri,    |
  |        code_challenge, scope)      |
  |                                    |
  |<---(2) Redirect to Login-----------|
  |                                    |
  |---(3) User Authentication--------->|
  |       (username, password, OTP)    |
  |                                    |
  |<---(4) Authorization Code----------|
  |       (code, state)                |
  |                                    |
  |---(5) Token Request--------------->|
  |       (code, code_verifier,        |
  |        client_id, client_secret)   |
  |                                    |
  |<---(6) Access Token----------------|
  |       (access_token, expires_in)   |
```

#### Authorization Request

```
GET /oauth2/authorize?
  client_id=my-app-id
  &redirect_uri=https://app.example.com/callback
  &response_type=code
  &scope=service%20credential
  &code_challenge=E9Mrozoa2owUednMEfp_rZxsIrxVArok2coQAiWyDqw
  &code_challenge_method=S256
  &state=xyz123
```

**Scopes:**
- `service` - Access to `/credentials/list`, `/credentials/info`, `/credentials/authorize`
- `credential` - Access to `/signatures/signHash`, `/signatures/signDoc`
- `credential.read` - Read-only credential access

#### Token Request

```json
POST /oauth2/token
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
&code=SplxlOBeZQQYbYS6WxSbIA
&code_verifier=dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXo
&client_id=my-app-id
&client_secret=my-app-secret
```

#### Token Response

```json
{
  "access_token": "SlAV32hkKG",
  "token_type": "Bearer",
  "expires_in": 3600,
  "refresh_token": "8xLOxBtZp8",
  "scope": "service credential"
}
```

---

### 3. SIGNATURE ACTIVATION DATA (SAD)

**Purpose:** Authorize signature creation on HSM  
**Lifetime:** Typically 5-15 minutes  
**Scope:** Single or multiple signatures

#### SAD Request

```json
POST /credentials/authorize
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "credentialID": "key-id-12345",
  "numSignatures": 1,
  "hashAlgorithmOID": "2.16.840.1.101.3.4.2.1",  // SHA-256
  "signAlgo": "1.2.840.10045.4.3.2",  // ECDSA with SHA-256
  "SAD": null,
  "signatureQualifier": "nonRepudiation"
}
```

#### SAD Response

```json
{
  "SAD": "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9...",
  "expiresIn": 600,
  "signAlgo": "1.2.840.10045.4.3.2"
}
```

**SAD JWT Claims:**
- `iss`: CSC service issuer
- `sub`: User identifier
- `aud`: Credential ID
- `iat`: Issued at
- `exp`: Expiration (iat + expiresIn)
- `nonce`: Unique identifier
- `numSignatures`: Number of signatures authorized

---

### 4. SIGNATURE CREATION

#### signHash Request

```json
POST /signatures/signHash
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "credentialID": "key-id-12345",
  "SAD": "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9...",
  "hashAlgorithmOID": "2.16.840.1.101.3.4.2.1",  // SHA-256
  "hashes": [
    "base64url_encoded_hash_1",
    "base64url_encoded_hash_2"
  ],
  "signAlgo": "1.2.840.10045.4.3.2",  // ECDSA with SHA-256
  "clientData": "optional_app_data"
}
```

#### signHash Response

```json
{
  "signatures": [
    "base64url_encoded_signature_1",
    "base64url_encoded_signature_2"
  ],
  "signAlgo": "1.2.840.10045.4.3.2"
}
```

**Signature Format:**
- **RSA:** PKCS#1 v1.5 padding (raw signature bytes)
- **ECDSA:** (r, s) concatenated (raw signature bytes)
- **EdDSA:** Raw signature bytes

#### signDoc Request

```json
POST /signatures/signDoc
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "credentialID": "key-id-12345",
  "SAD": "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9...",
  "documents": [
    {
      "documentID": "doc-1",
      "document": "base64url_encoded_pdf_or_xml",
      "mimeType": "application/pdf"
    }
  ],
  "signAlgo": "1.2.840.10045.4.3.2",
  "signatureQualifier": "nonRepudiation",
  "clientData": "optional_app_data"
}
```

#### signDoc Response

```json
{
  "signatures": [
    {
      "documentID": "doc-1",
      "signature": "base64url_encoded_signature",
      "signAlgo": "1.2.840.10045.4.3.2"
    }
  ]
}
```

---

### 5. HASH ALGORITHMS & SIGNATURE ALGORITHMS

#### Supported Hash Algorithms

| OID | Algorithm | Hex Digest Size |
|-----|-----------|-----------------|
| `2.16.840.1.101.3.4.2.1` | SHA-256 | 32 bytes |
| `2.16.840.1.101.3.4.2.2` | SHA-384 | 48 bytes |
| `2.16.840.1.101.3.4.2.3` | SHA-512 | 64 bytes |
| `1.3.14.3.2.26` | SHA-1 | 20 bytes (deprecated) |

#### Supported Signature Algorithms

| OID | Algorithm | Key Type | Hash |
|-----|-----------|----------|------|
| `1.2.840.10045.4.3.2` | ECDSA with SHA-256 | EC P-256 | SHA-256 |
| `1.2.840.10045.4.3.3` | ECDSA with SHA-384 | EC P-384 | SHA-384 |
| `1.2.840.10045.4.3.4` | ECDSA with SHA-512 | EC P-521 | SHA-512 |
| `1.2.840.113549.1.1.11` | RSA with SHA-256 | RSA 2048+ | SHA-256 |
| `1.2.840.113549.1.1.12` | RSA with SHA-384 | RSA 2048+ | SHA-384 |
| `1.2.840.113549.1.1.13` | RSA with SHA-512 | RSA 2048+ | SHA-512 |
| `1.3.101.112` | EdDSA | Ed25519 | SHA-512 |

---

### 6. CREDENTIAL MANAGEMENT

#### credentials/list Request

```json
POST /credentials/list
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "userID": "user@example.com",
  "credentialFilter": {
    "keyUsage": ["nonRepudiation"],
    "keyType": ["RSA", "EC"]
  }
}
```

#### credentials/list Response

```json
{
  "credentials": [
    {
      "credentialID": "key-id-12345",
      "cert": "base64url_encoded_x509_cert",
      "certChain": [
        "base64url_encoded_issuer_cert",
        "base64url_encoded_root_cert"
      ],
      "status": "enabled",
      "keyUsage": ["nonRepudiation"],
      "keyType": "EC",
      "keySize": 256,
      "algorithms": [
        "1.2.840.10045.4.3.2",  // ECDSA with SHA-256
        "1.2.840.10045.4.3.3"   // ECDSA with SHA-384
      ]
    }
  ]
}
```

#### credentials/info Request

```json
POST /credentials/info
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "credentialID": "key-id-12345"
}
```

#### credentials/info Response

```json
{
  "credentialID": "key-id-12345",
  "cert": "base64url_encoded_x509_cert",
  "certChain": [
    "base64url_encoded_issuer_cert",
    "base64url_encoded_root_cert"
  ],
  "status": "enabled",
  "keyUsage": ["nonRepudiation"],
  "keyType": "EC",
  "keySize": 256,
  "algorithms": [
    "1.2.840.10045.4.3.2",
    "1.2.840.10045.4.3.3"
  ],
  "multisign": 1,
  "lang": "en"
}
```

---

### 7. SERVICE METADATA

#### /info Request

```
GET /info
```

#### /info Response

```json
{
  "specs": ["http://www.cloudsignatureconsortium.org/csc/v2"],
  "methods": [
    "info",
    "oauth2/authorize",
    "oauth2/token",
    "oauth2/revoke",
    "credentials/list",
    "credentials/info",
    "credentials/authorize",
    "signatures/signHash",
    "signatures/signDoc",
    "signatures/timestamp"
  ],
  "oauth2": "https://auth.example.com/oauth2",
  "oauth2Issuer": "https://auth.example.com",
  "credentialStatusService": "https://service.example.com/status",
  "lang": ["en", "it"],
  "maxConcurrentRequests": 10,
  "maxRequestSize": 1048576
}
```

---

### 8. KNOWN CSC PROVIDERS (2025/2026)

#### Production Providers

| Provider | Country | Sandbox | Endpoint |
|----------|---------|---------|----------|
| **InfoCert** | IT | Yes | https://cscsandbox.infocert.it/csc/v2 |
| **Aruba** | IT | Yes | https://cscsandbox.arubapec.it/csc/v2 |
| **Namirial** | IT/EU | Yes | https://sandbox.namirial.com/csc/v2 |
| **Intesi Group** | IT | Yes | https://sandbox.intesigroup.com/csc/v2 |
| **BankID** | NO | Yes | https://trust-driver-stub-lsp.test.cleverbase.com/csc/v2 |
| **Buypass** | NO | Yes | https://api.esign.qa-04.buypass.no/csc/v2 |

#### Sandbox Credentials

```
Client ID: test-client
Client Secret: test-secret
User ID: test@example.com
Password: TestPassword123!
OTP: 123456 (if required)
```

---

### 9. INTEGRATION WITH PADES/CADES

#### PAdES (PDF Advanced Electronic Signature)

```
1. Hash PDF document (SHA-256)
2. Request SAD from CSC
3. Call /signatures/signHash with hash
4. Receive raw signature bytes
5. Embed signature in PDF using iText/PDFBox
   - Signature dictionary
   - Signature value (DER-encoded)
   - Certificate chain
   - Timestamp (optional)
```

#### CAdES (CMS Advanced Electronic Signature)

```
1. Create CMS structure (RFC 5652)
2. Hash content (SHA-256)
3. Request SAD from CSC
4. Call /signatures/signHash with hash
5. Receive raw signature bytes
6. Embed in CMS SignerInfo
   - signatureAlgorithm
   - signature (raw bytes)
   - signingCertificate
   - signedAttributes
   - unsignedAttributes (timestamp)
```

#### Signature Wrapping (RP Responsibility)

```
Raw signature from CSC (r, s for ECDSA)
    ↓
DER encode: SEQUENCE { INTEGER r, INTEGER s }
    ↓
Embed in PAdES/CAdES structure
    ↓
Add certificate chain
    ↓
Add timestamp (optional)
    ↓
Final signed document
```

---

### 10. DART/FLUTTER CSC CLIENT

#### Recommended Approach: OpenAPI Code Generation

```bash
# Download CSC API v2.2 OpenAPI spec
curl -O https://cloudsignatureconsortium.org/csc-api-v2-2-openapi.yaml

# Generate Dart client
openapi-generator-cli generate \
  -i csc-api-v2-2-openapi.yaml \
  -g dart \
  -o ./csc_client
```

#### Manual Implementation Stack

```dart
import 'package:http/http.dart' as http;
import 'package:jose/jose.dart';
import 'package:pointycastle/export.dart';
import 'dart:convert';

class CSCClient {
  final String baseUrl;
  final String clientId;
  final String clientSecret;
  String? accessToken;
  String? refreshToken;

  CSCClient({
    required this.baseUrl,
    required this.clientId,
    required this.clientSecret,
  });

  // OAuth 2.0 token request
  Future<void> authenticate(String username, String password) async {
    final response = await http.post(
      Uri.parse('$baseUrl/oauth2/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'password',
        'username': username,
        'password': password,
        'client_id': clientId,
        'client_secret': clientSecret,
        'scope': 'service credential',
      },
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      accessToken = data['access_token'];
      refreshToken = data['refresh_token'];
    } else {
      throw Exception('Authentication failed: ${response.body}');
    }
  }

  // List credentials
  Future<List<Map<String, dynamic>>> listCredentials() async {
    final response = await http.post(
      Uri.parse('$baseUrl/credentials/list'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({}),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return List<Map<String, dynamic>>.from(data['credentials']);
    } else {
      throw Exception('Failed to list credentials: ${response.body}');
    }
  }

  // Authorize credential use (get SAD)
  Future<String> authorizeCredential(String credentialId) async {
    final response = await http.post(
      Uri.parse('$baseUrl/credentials/authorize'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'credentialID': credentialId,
        'numSignatures': 1,
        'hashAlgorithmOID': '2.16.840.1.101.3.4.2.1',  // SHA-256
        'signAlgo': '1.2.840.10045.4.3.2',  // ECDSA with SHA-256
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['SAD'];
    } else {
      throw Exception('Failed to authorize credential: ${response.body}');
    }
  }

  // Sign hash
  Future<String> signHash(
    String credentialId,
    String sad,
    String hash,
  ) async {
    final response = await http.post(
      Uri.parse('$baseUrl/signatures/signHash'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'credentialID': credentialId,
        'SAD': sad,
        'hashAlgorithmOID': '2.16.840.1.101.3.4.2.1',
        'hashes': [hash],
        'signAlgo': '1.2.840.10045.4.3.2',
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['signatures'][0];
    } else {
      throw Exception('Failed to sign hash: ${response.body}');
    }
  }
}
```

---

## INTEGRATION CHECKLIST

### Phase 6: CSC Remote Signing
- [ ] CSC API v2.2 client implementation
- [ ] OAuth 2.0 PKCE flow
- [ ] SAD (Signature Activation Data) handling
- [ ] Hash algorithm support (SHA-256/384/512)
- [ ] Signature algorithm support (ECDSA, RSA, EdDSA)
- [ ] PAdES/CAdES signature wrapping
- [ ] Certificate chain validation
- [ ] Timestamp integration
- [ ] Error handling & retry logic
- [ ] Sandbox testing (InfoCert, Aruba, Namirial)

### Phase 7: EUDI Wallet Integration
- [ ] OpenID4VCI credential issuance
- [ ] OpenID4VP credential presentation
- [ ] SD-JWT VC support
- [ ] mso_mdoc (CBOR) support
- [ ] Device key binding (ECDSA P-256)
- [ ] Selective disclosure
- [ ] Wallet metadata discovery
- [ ] Trust anchor validation
- [ ] Status list revocation check
- [ ] Italian PID profile compliance
- [ ] Cross-device QR code flow
- [ ] Same-device redirect flow

---

## REFERENCES

### Official Specifications
- **ARF 1.6:** https://eudi.dev/2.7.0/architecture-and-reference-framework-main/
- **OpenID4VCI 1.0:** https://openid.net/specs/openid-4-verifiable-credential-issuance-1_0.html
- **OpenID4VP 1.0:** https://openid.net/specs/openid-4-verifiable-presentations-1_0.html
- **SD-JWT VC:** https://datatracker.ietf.org/doc/html/draft-ietf-oauth-sd-jwt-vc-15
- **ISO 18013-5:** https://www.iso.org/standard/69084.html
- **ISO 18013-7:** https://www.iso.org/standard/91154.html
- **CSC API v2.2:** https://cloudsignatureconsortium.org/resources/csc-api-v2-2/

### Italian Implementation
- **IT-Wallet Specs:** https://italia.github.io/eid-wallet-it-docs/versione-corrente/en/
- **IT-Wallet Python:** https://github.com/italia/eudi-wallet-it-python

### Reference Implementations
- **EU Wallet Reference:** https://github.com/eu-digital-identity-wallet
- **OpenID4VC Rust:** https://github.com/impierce/openid4vc
- **SD-JWT Python:** https://github.com/openwallet-foundation-labs/sd-jwt-python

---

**Document Status:** Production-Ready  
**Last Verified:** May 2026  
**Maintainer:** EU Digital Identity Cooperation Group (EDICG)
