# SPID/CIE OIDC Federation - Implementation Roadmap for OpenCIE
**Mapping to RP-9, AS-3, AS-4 Components**

---

## OVERVIEW

Your OpenCIE project needs to implement:
1. **RP-9:** SPID/CIE Relying Party (Flutter/Dart)
2. **AS-3:** Mock SPID Identity Provider
3. **AS-4:** Mock CIE Identity Provider

All three must comply with **AGID/IPZS OpenID Connect Federation 1.0** specifications (2025/2026).

---

## RP-9: SPID/CIE RELYING PARTY (Flutter/Dart)

### Phase 1: Federation Setup

#### 1.1 Generate Keys
```dart
// Generate RSA 2048+ bit key pair
// Store in secure storage (Flutter Secure Storage)
// Use for:
//   - Entity Configuration signing
//   - Request Object signing
//   - Client assertion signing
```

#### 1.2 Entity Configuration (/.well-known/openid-federation)
```dart
class EntityConfigurationService {
  Future<String> getEntityConfiguration() async {
    // Return JWT with:
    // - federation_entity metadata
    // - openid_relying_party metadata
    // - authority_hints: ["https://agid.gov.it"]
    // - trust_marks: [TM from onboarding]
    
    // See: SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md § 1
  }
}
```

#### 1.3 Federation Resolve Endpoint (/federation/resolve)
```dart
class FederationResolveService {
  Future<Map> resolveEntityStatement({
    required String subject,
    required String anchor,
  }) async {
    // Return:
    // - entity_configuration (JWT)
    // - entity_statements (JWT array)
    // - trust_chain (URL array)
    // - trust_marks (JWT array)
    
    // See: SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md § 9
  }
}
```

### Phase 2: Authentication Flow

#### 2.1 PKCE Generation
```dart
class PKCEService {
  Map<String, String> generatePKCE() {
    // Generate code_verifier (128 chars)
    // Calculate code_challenge = base64url(sha256(code_verifier))
    // Return: {code_verifier, code_challenge, code_challenge_method: "S256"}
    
    // See: SPID_CIE_QUICK_REFERENCE.md § PKCE GENERATION
  }
}
```

#### 2.2 Request Object Creation
```dart
class RequestObjectService {
  Future<String> createSignedRequestObject({
    required String clientId,
    required String idpIssuer,
    required String redirectUri,
    required String acrValue,  // https://www.spid.gov.it/SpidL2
    required String codeChallenge,
    required Map<String, dynamic> claims,
  }) async {
    // Create JWT payload with:
    // - iss: clientId
    // - aud: idpIssuer
    // - acr_values: acrValue
    // - code_challenge, code_challenge_method: "S256"
    // - nonce: random ≥32 chars
    // - state: random ≥32 chars
    // - claims: {userinfo: {...}}
    // - iat, exp
    
    // Sign with RS256
    // Return JWT string
    
    // See: SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md § 2-3
  }
}
```

#### 2.3 Authorization Request
```dart
class AuthorizationService {
  Future<String> buildAuthorizationUrl({
    required String idpIssuer,
    required String requestObject,
    required String codeChallenge,
  }) async {
    // POST to: {idpIssuer}/authorize
    // Parameters:
    //   - scope: "openid profile email"
    //   - code_challenge: codeChallenge
    //   - code_challenge_method: "S256"
    //   - request: requestObject (signed JWT)
    
    // Return: authorization code + state
    
    // See: SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md § 2-3
  }
}
```

#### 2.4 Token Exchange
```dart
class TokenService {
  Future<TokenResponse> exchangeCodeForToken({
    required String idpIssuer,
    required String code,
    required String codeVerifier,
    required String clientId,
  }) async {
    // Create client assertion JWT:
    // - iss: clientId
    // - sub: clientId
    // - aud: {idpIssuer}/token
    // - iat, exp, jti
    // Sign with RS256
    
    // POST to: {idpIssuer}/token
    // Parameters:
    //   - grant_type: "authorization_code"
    //   - code: code
    //   - code_verifier: codeVerifier
    //   - client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
    //   - client_assertion: clientAssertionJWT
    
    // Return: {access_token, id_token, refresh_token}
    
    // See: SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md § 4
  }
}
```

#### 2.5 ID Token Validation
```dart
class IDTokenValidator {
  Future<Map> validateIDToken({
    required String idToken,
    required String clientId,
    required String nonce,
    required String idpIssuer,
  }) async {
    // Verify JWT signature with IdP's public key
    // Check claims:
    //   - iss == idpIssuer
    //   - aud == clientId
    //   - nonce == nonce (sent in request)
    //   - acr == one of: https://www.spid.gov.it/SpidL1/L2/L3
    //   - exp > now
    //   - iat < now
    
    // Return: decoded payload
    
    // See: SPID_CIE_TECHNICAL_REFERENCE.md § 5
  }
}
```

#### 2.6 UserInfo Endpoint
```dart
class UserInfoService {
  Future<Map> getUserInfo({
    required String idpIssuer,
    required String accessToken,
  }) async {
    // GET {idpIssuer}/userinfo
    // Header: Authorization: Bearer {accessToken}
    
    // Response is signed & encrypted JWT
    // Decrypt & verify signature
    
    // SPID returns:
    //   - https://attributes.spid.gov.it/fiscalNumber
    //   - https://attributes.spid.gov.it/name
    //   - https://attributes.spid.gov.it/familyName
    //   - https://attributes.spid.gov.it/dateOfBirth
    //   - https://attributes.spid.gov.it/email
    
    // CIE returns:
    //   - given_name, family_name, birthdate, email (standard OIDC)
    //   - https://attributes.eid.gov.it/fiscal_number
    
    // See: SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md § 6
  }
}
```

### Phase 3: Federation Trust

#### 3.1 Entity Configuration Caching
```dart
class EntityConfigurationCache {
  Future<Map> getEntityConfiguration({
    required String entityUrl,
  }) async {
    // Check cache (update daily)
    // If stale, fetch from: {entityUrl}/.well-known/openid-federation
    // Verify JWT signature
    // Cache for 24 hours
    
    // Return: decoded payload
  }
}
```

#### 3.2 Trust Mark Validation
```dart
class TrustMarkValidator {
  Future<bool> validateTrustMark({
    required String trustMarkJWT,
    required String expectedSubject,
    required String expectedId,
  }) async {
    // Static validation:
    //   - Verify JWT signature with issuer's public key
    //   - Check: sub == expectedSubject
    //   - Check: id == expectedId
    //   - Check: exp > now
    
    // Dynamic validation:
    //   - Query issuer's /trust_mark_status endpoint
    //   - Verify: active == true
    
    // Return: true if valid, false otherwise
    
    // See: SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md § 8
  }
}
```

#### 3.3 Trust Chain Validation
```dart
class TrustChainValidator {
  Future<bool> validateTrustChain({
    required List<String> trustChain,
    required String trustAnchor,
  }) async {
    // Verify chain from RP → TA
    // Each step must have valid Entity Statement
    // Each step must have valid Trust Mark
    // Final step must reach trustAnchor
    
    // Return: true if valid, false otherwise
  }
}
```

### Phase 4: User Session Management

#### 4.1 User Model
```dart
class User {
  final String sub;  // Subject (unique ID from IdP)
  final String? name;
  final String? familyName;
  final String? fiscalNumber;  // Codice Fiscale
  final String? email;
  final String? dateOfBirth;
  final String? gender;
  final String? placeOfBirth;
  final String? address;
  final String acrValue;  // https://www.spid.gov.it/SpidL2
  final String idpIssuer;  // https://idp.spid.gov.it
  final DateTime issuedAt;
  final DateTime expiresAt;
  
  // For SPID: use fiscalNumber as unique identifier
  // For CIE: use sub (from ID Token)
}
```

#### 4.2 Session Storage
```dart
class SessionManager {
  Future<void> saveSession({
    required User user,
    required String accessToken,
    required String? refreshToken,
  }) async {
    // Store in secure storage:
    // - User data (encrypted)
    // - Access token (encrypted)
    // - Refresh token (encrypted)
    // - Session expiration
  }
  
  Future<User?> getSession() async {
    // Retrieve from secure storage
    // Check if expired
    // Return user or null
  }
  
  Future<void> clearSession() async {
    // Delete all session data
  }
}
```

---

## AS-3: MOCK SPID IDENTITY PROVIDER

### Phase 1: Federation Setup

#### 1.1 Entity Configuration
```python
# Django/FastAPI endpoint: /.well-known/openid-federation

{
  "iss": "https://mock-spid-idp.example.it",
  "sub": "https://mock-spid-idp.example.it",
  "iat": 1704067200,
  "exp": 1704153600,
  "jwks": { "keys": [...] },
  "metadata": {
    "federation_entity": {
      "organization_name": "Mock SPID Identity Provider",
      "homepage_uri": "https://mock-spid-idp.example.it",
      "policy_uri": "https://mock-spid-idp.example.it/privacy",
      "logo_uri": "https://mock-spid-idp.example.it/logo.svg",
      "contacts": ["support@mock-spid-idp.example.it"],
      "federation_resolve_endpoint": "https://mock-spid-idp.example.it/federation/resolve"
    },
    "openid_provider": {
      "issuer": "https://mock-spid-idp.example.it",
      "authorization_endpoint": "https://mock-spid-idp.example.it/authorize",
      "token_endpoint": "https://mock-spid-idp.example.it/token",
      "userinfo_endpoint": "https://mock-spid-idp.example.it/userinfo",
      "introspection_endpoint": "https://mock-spid-idp.example.it/introspection",
      "revocation_endpoint": "https://mock-spid-idp.example.it/revocation",
      "jwks": { "keys": [...] },
      "scopes_supported": ["openid", "profile", "email"],
      "response_types_supported": ["code"],
      "grant_types_supported": ["authorization_code", "refresh_token"],
      "acr_values_supported": [
        "https://www.spid.gov.it/SpidL1",
        "https://www.spid.gov.it/SpidL2",
        "https://www.spid.gov.it/SpidL3"
      ],
      "subject_types_supported": ["pairwise"],
      "id_token_signing_alg_values_supported": ["RS256", "RS512"],
      "userinfo_signing_alg_values_supported": ["RS256", "RS512"],
      "request_object_signing_alg_values_supported": ["RS256", "RS512"],
      "request_authentication_methods_supported": {
        "authorization_endpoint": ["request_object"]
      },
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
  },
  "trust_marks": [
    {
      "id": "https://registry.interno.gov.it/openid_provider/public/",
      "trust_mark": "eyJhbGc..."
    }
  ]
}
```

#### 1.2 Federation Endpoints
```python
# /federation/resolve
# /federation/fetch
# /federation/list
# /federation/trust_mark_status

# See: SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md § 9
```

### Phase 2: Authorization Endpoint

#### 2.1 Request Object Validation
```python
def validate_request_object(request_jwt: str, client_id: str) -> dict:
    """
    Validate signed request_object from RP
    
    1. Verify JWT signature with RP's public key
    2. Check: iss == client_id
    3. Check: aud == this IdP's issuer
    4. Check: exp > now
    5. Check: acr_values is valid (SpidL1/L2/L3)
    6. Check: code_challenge present
    7. Check: nonce present (≥32 chars)
    8. Check: state present (≥32 chars)
    
    Return: decoded payload
    """
    pass
```

#### 2.2 Authorization Endpoint
```python
@app.post("/authorize")
def authorize(
    scope: str,
    code_challenge: str,
    code_challenge_method: str,
    request: str,  # Signed JWT
):
    """
    1. Validate request_object
    2. Extract: client_id, redirect_uri, acr_values, nonce, state
    3. Redirect to login page (mock: auto-login with test user)
    4. Generate authorization code
    5. Redirect to: redirect_uri?code=CODE&state=STATE&iss=ISSUER
    
    See: SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md § 2
    """
    pass
```

### Phase 3: Token Endpoint

#### 3.1 Client Assertion Validation
```python
def validate_client_assertion(assertion_jwt: str, client_id: str) -> dict:
    """
    Validate private_key_jwt from RP
    
    1. Verify JWT signature with RP's public key
    2. Check: iss == client_id
    3. Check: sub == client_id
    4. Check: aud == this IdP's token endpoint
    5. Check: exp > now
    6. Check: jti is unique (prevent replay)
    
    Return: decoded payload
    """
    pass
```

#### 3.2 Token Endpoint
```python
@app.post("/token")
def token(
    grant_type: str,
    code: str,
    code_verifier: str,
    client_assertion_type: str,
    client_assertion: str,
):
    """
    1. Validate client_assertion
    2. Verify authorization code
    3. Verify PKCE: sha256(code_verifier) == code_challenge
    4. Generate ID Token with:
       - iss: this IdP's issuer
       - sub: user's unique ID
       - aud: client_id
       - acr: requested acr_value
       - nonce: from request_object
       - iat, exp, jti
    5. Generate access_token
    6. Generate refresh_token
    7. Return: {access_token, id_token, refresh_token, expires_in}
    
    See: SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md § 4-5
    """
    pass
```

### Phase 4: UserInfo Endpoint

#### 4.1 UserInfo Endpoint
```python
@app.get("/userinfo")
def userinfo(authorization: str):  # Bearer token
    """
    1. Validate access_token
    2. Get user data from database
    3. Create JWT payload with SPID attributes:
       - https://attributes.spid.gov.it/fiscalNumber
       - https://attributes.spid.gov.it/name
       - https://attributes.spid.gov.it/familyName
       - https://attributes.spid.gov.it/dateOfBirth
       - https://attributes.spid.gov.it/placeOfBirth
       - https://attributes.spid.gov.it/gender
       - https://attributes.spid.gov.it/email
       - https://attributes.spid.gov.it/address
       - https://attributes.spid.gov.it/digitalAddress
    4. Sign with RS256
    5. Encrypt with RSA-OAEP + A256CBC-HS512
    6. Return: JWE string
    
    See: SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md § 6
    """
    pass
```

### Phase 5: Test Users

```python
TEST_USERS = {
    "spid_l1": {
        "sub": "SPID-L1-USER",
        "name": "Mario",
        "familyName": "Rossi",
        "fiscalNumber": "TINIT-RSSMRA80A01H501U",
        "dateOfBirth": "1980-01-01",
        "placeOfBirth": "Roma",
        "gender": "M",
        "email": "mario.rossi@example.it",
        "address": "Via Roma 1, 00100 Roma",
        "digitalAddress": "mario.rossi@pec.example.it",
        "acr": "https://www.spid.gov.it/SpidL1",
    },
    "spid_l2": {
        "sub": "SPID-L2-USER",
        "name": "Luigi",
        "familyName": "Bianchi",
        "fiscalNumber": "TINIT-BNCLUGI80A01H501U",
        "dateOfBirth": "1980-01-01",
        "placeOfBirth": "Milano",
        "gender": "M",
        "email": "luigi.bianchi@example.it",
        "address": "Via Milano 1, 20100 Milano",
        "digitalAddress": "luigi.bianchi@pec.example.it",
        "acr": "https://www.spid.gov.it/SpidL2",
    },
    "spid_l3": {
        "sub": "SPID-L3-USER",
        "name": "Anna",
        "familyName": "Verdi",
        "fiscalNumber": "TINIT-VRDANNA80A01H501U",
        "dateOfBirth": "1980-01-01",
        "placeOfBirth": "Napoli",
        "gender": "F",
        "email": "anna.verdi@example.it",
        "address": "Via Napoli 1, 80100 Napoli",
        "digitalAddress": "anna.verdi@pec.example.it",
        "acr": "https://www.spid.gov.it/SpidL3",
    },
}
```

---

## AS-4: MOCK CIE IDENTITY PROVIDER

### Differences from SPID

1. **Trust Anchor:** Ministero dell'Interno (not AgID)
2. **Claim names:** Standard OIDC (not URI-style)
   - `given_name` instead of `https://attributes.spid.gov.it/name`
   - `family_name` instead of `https://attributes.spid.gov.it/familyName`
   - `birthdate` instead of `https://attributes.spid.gov.it/dateOfBirth`
   - `gender` instead of `https://attributes.spid.gov.it/gender`
   - `email` instead of `https://attributes.spid.gov.it/email`
3. **ID Token:** Can include standard OIDC claims (optional)
4. **Encryption:** Supported (ECDH-ES, ECDH-ES+A128KW, ECDH-ES+A256KW)
5. **Scope: profile:** Returns Minimum Dataset eIDAS

### Implementation

```python
# AS-4 is identical to AS-3 except:

# 1. Entity Configuration issuer
"iss": "https://mock-cie-idp.example.it"

# 2. Claims in UserInfo (standard OIDC + URI-style)
{
  "sub": "CIE-USER-ID",
  "given_name": "Mario",
  "family_name": "Rossi",
  "birthdate": "1980-01-01",
  "gender": "M",
  "email": "mario.rossi@example.it",
  "https://attributes.eid.gov.it/fiscal_number": "TINIT-RSSMRA80A01H501U",
  "https://attributes.eid.gov.it/place_of_birth": "Roma",
  "https://attributes.eid.gov.it/address": "Via Roma 1, 00100 Roma"
}

# 3. ID Token can include standard claims
{
  "iss": "https://mock-cie-idp.example.it",
  "sub": "CIE-USER-ID",
  "aud": "https://sp.example.it",
  "acr": "https://www.spid.gov.it/SpidL2",
  "family_name": "Rossi",
  "email": "mario.rossi@example.it",
  "iat": 1704067200,
  "exp": 1704070800,
  "nonce": "nonce-value"
}

# 4. Support encryption algorithms
"id_token_encryption_alg_values_supported": [
  "RSA-OAEP", "RSA-OAEP-256",
  "ECDH-ES", "ECDH-ES+A128KW", "ECDH-ES+A256KW"
]
```

---

## TESTING CHECKLIST

### RP-9 (Flutter/Dart)

- [ ] Generate RSA key pair
- [ ] Publish Entity Configuration
- [ ] Implement /federation/resolve
- [ ] Generate PKCE correctly
- [ ] Create signed request_object (RS256)
- [ ] POST to /authorize with request parameter
- [ ] Receive authorization code
- [ ] Exchange code with private_key_jwt
- [ ] Validate ID Token (signature, claims, nonce)
- [ ] Call UserInfo endpoint
- [ ] Parse SPID attributes (URI-style)
- [ ] Parse CIE attributes (standard OIDC)
- [ ] Validate Trust Marks (static + dynamic)
- [ ] Handle refresh token
- [ ] Handle logout

### AS-3 (Mock SPID IdP)

- [ ] Publish Entity Configuration
- [ ] Implement /federation/resolve
- [ ] Validate signed request_object
- [ ] Validate PKCE
- [ ] Generate authorization code
- [ ] Validate private_key_jwt
- [ ] Generate ID Token with acr + nonce
- [ ] Generate access_token
- [ ] Implement UserInfo endpoint (signed & encrypted)
- [ ] Return SPID attributes (URI-style)
- [ ] Support all acr_values (L1, L2, L3)
- [ ] Implement refresh token
- [ ] Implement revocation endpoint

### AS-4 (Mock CIE IdP)

- [ ] Same as AS-3 except:
- [ ] Return standard OIDC claims in UserInfo
- [ ] Support ID Token encryption
- [ ] Support ECDH algorithms
- [ ] Return Minimum Dataset eIDAS with scope=profile

---

## DOCUMENTATION REFERENCES

1. **SPID_CIE_OIDC_FEDERATION_TECHNICAL_REFERENCE.md**
   - Complete technical specs
   - All claim names & URIs
   - Algorithms & requirements
   - Trust marks & federation

2. **SPID_CIE_OIDC_IMPLEMENTATION_EXAMPLES.md**
   - JSON examples for all endpoints
   - Request/response payloads
   - Dart/Flutter code snippets
   - Python/FastAPI examples

3. **SPID_CIE_QUICK_REFERENCE.md**
   - Copy-paste ready strings
   - Common mistakes
   - Implementation checklist
   - Quick lookup tables

---

## TIMELINE

### Month 1: RP-9 Foundation
- [ ] Key generation & storage
- [ ] Entity Configuration endpoint
- [ ] Federation resolve endpoint
- [ ] PKCE generation

### Month 2: RP-9 Authentication
- [ ] Request object creation
- [ ] Authorization request
- [ ] Token exchange
- [ ] ID Token validation

### Month 3: RP-9 User Data
- [ ] UserInfo endpoint integration
- [ ] SPID attribute parsing
- [ ] CIE attribute parsing
- [ ] Session management

### Month 4: AS-3 Foundation
- [ ] Entity Configuration
- [ ] Federation endpoints
- [ ] Authorization endpoint
- [ ] Token endpoint

### Month 5: AS-3 Completion
- [ ] UserInfo endpoint
- [ ] Test users
- [ ] Trust marks
- [ ] Integration with RP-9

### Month 6: AS-4 & Testing
- [ ] AS-4 implementation (CIE variant)
- [ ] End-to-end testing
- [ ] Trust chain validation
- [ ] Security review

---

## SECURITY CONSIDERATIONS

1. **Key Storage:** Use Flutter Secure Storage for RP private keys
2. **HTTPS Only:** All endpoints must use HTTPS
3. **PKCE:** Always use S256 (not plain)
4. **Nonce & State:** Minimum 32 alphanumeric characters
5. **Token Expiration:** ID Token ≤ 10 minutes, access_token ≤ 1 hour
6. **Signature Verification:** Always verify JWT signatures
7. **Trust Marks:** Validate both static (signature) and dynamic (status endpoint)
8. **Encryption:** Use RSA-OAEP + A256CBC-HS512 for UserInfo
9. **CORS:** Restrict to known origins
10. **Rate Limiting:** Implement on token endpoint

---

**Document Version:** 1.0 (May 2026)  
**Status:** Implementation Guide  
**For:** OpenCIE Project (RP-9, AS-3, AS-4)
