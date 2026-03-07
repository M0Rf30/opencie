# SPID/CIE OpenID Connect Federation - Implementation Examples
**JSON & Code Snippets for RP & OP Integration**

---

## 1. RELYING PARTY (RP) - ENTITY CONFIGURATION

### RP Entity Configuration Response (/.well-known/openid-federation)

```json
{
  "iss": "https://sp.example.it",
  "sub": "https://sp.example.it",
  "iat": 1704067200,
  "exp": 1704153600,
  "jwks": {
    "keys": [
      {
        "kty": "RSA",
        "use": "sig",
        "kid": "rp-sig-key-2025",
        "n": "0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tSoc_BJECPebWKRXjBZCiFV4n3oknjhMstn64tZ_2W-5JsGY4Hc5n9yBXArwl93lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2QvzqY368QQMicAtaSqzs8KJZgnYb9c7d0zgdAZHzu6qMQvRL5hajrn1n91CbOpbISD08qNLyrdkt-bFTWhAI4vMQFh6WeZu0fM4lFd2NcRwr3XPksINHaQ-G_xBniIqbw0Ls1jF44-csFCur-kEgU8awapJzKnqDKgw",
        "e": "AQAB"
      }
    ]
  },
  "metadata": {
    "federation_entity": {
      "organization_name": "Example Service Provider",
      "homepage_uri": "https://sp.example.it",
      "policy_uri": "https://sp.example.it/privacy",
      "logo_uri": "https://sp.example.it/logo.svg",
      "contacts": ["pec@sp.example.it"],
      "federation_resolve_endpoint": "https://sp.example.it/federation/resolve"
    },
    "openid_relying_party": {
      "client_id": "https://sp.example.it",
      "client_registration_types": ["automatic"],
      "redirect_uris": [
        "https://sp.example.it/auth/callback",
        "https://sp.example.it/auth/callback/spid",
        "https://sp.example.it/auth/callback/cie"
      ],
      "response_types": ["code"],
      "grant_types": ["authorization_code", "refresh_token"],
      "token_endpoint_auth_method": "private_key_jwt",
      "id_token_signed_response_alg": "RS256",
      "userinfo_signed_response_alg": "RS256",
      "jwks": {
        "keys": [
          {
            "kty": "RSA",
            "use": "sig",
            "kid": "rp-sig-key-2025",
            "n": "0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tSoc_BJECPebWKRXjBZCiFV4n3oknjhMstn64tZ_2W-5JsGY4Hc5n9yBXArwl93lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2QvzqY368QQMicAtaSqzs8KJZgnYb9c7d0zgdAZHzu6qMQvRL5hajrn1n91CbOpbISD08qNLyrdkt-bFTWhAI4vMQFh6WeZu0fM4lFd2NcRwr3XPksINHaQ-G_xBniIqbw0Ls1jF44-csFCur-kEgU8awapJzKnqDKgw",
            "e": "AQAB"
          }
        ]
      }
    }
  },
  "authority_hints": [
    "https://agid.gov.it"
  ],
  "trust_marks": [
    {
      "id": "https://registry.interno.gov.it/openid_relying_party/public/",
      "trust_mark": "eyJhbGciOiJSUzI1NiIsImtpZCI6ImFnaWQta2V5LWlkIiwidHlwIjoidHJ1c3QtbWFyaytqd3QifQ.eyJpc3MiOiJodHRwczovL2FnaWQuZ292Lml0IiwiYXVkIjoiaHR0cHM6Ly9zcC5leGFtcGxlLml0Iiwic3ViIjoiaHR0cHM6Ly9zcC5leGFtcGxlLml0IiwiaWQiOiJodHRwczovL3JlZ2lzdHJ5LmludGVybm8uZ292Lml0L29wZW5pZF9yZWx5aW5nX3BhcnR5L3B1YmxpYy8iLCJpYXQiOjE3MDQwNjcyMDAsImV4cCI6MTczNTYwMzIwMCwibG9nb191cmkiOiJodHRwczovL3JlZ2lzdHJ5LmludGVybm8uZ292Lml0L2xvZ28uc3ZnIiwicmVmIjoiaHR0cHM6Ly9yZWdpc3RyeS5pbnRlcm5vLmdvdi5pdC9vcGVuaWRfcmVseWluZ19wYXJ0eS9wdWJsaWMvIiwib3JnYW5pemF0aW9uX3R5cGUiOiJwdWJsaWMiLCJpZF9jb2RlIjp7ImlwYV9jb2RlIjoiYzAxMjM0In0sImVtYWlsIjoicGVjQHNwLmV4YW1wbGUuaXQiLCJvcmdhbml6YXRpb25fbmFtZSI6IkV4YW1wbGUgU2VydmljZSBQcm92aWRlciJ9.signature"
    }
  ]
}
```

---

## 2. AUTHORIZATION REQUEST (SPID)

### HTTP Request with Signed Request Object

```http
POST /authorize HTTP/1.1
Host: idp.spid.gov.it
Content-Type: application/x-www-form-urlencoded

scope=openid%20profile%20email
&code_challenge=E9Mrozoa2owUednMg8_p5wqichJeuWMqFH7I80dP5YE
&code_challenge_method=S256
&request=eyJhbGciOiJSUzI1NiIsImtpZCI6InJwLXNpZy1rZXktMjAyNSIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJodHRwczovL3NwLmV4YW1wbGUuaXQiLCJhdWQiOiJodHRwczovL2lkcC5zcGlkLmdvdi5pdCIsImNsaWVudF9pZCI6Imh0dHBzOi8vc3AuZXhhbXBsZS5pdCIsInJlc3BvbnNlX3R5cGUiOiJjb2RlIiwic2NvcGUiOiJvcGVuaWQgcHJvZmlsZSBlbWFpbCIsInJlZGlyZWN0X3VyaSI6Imh0dHBzOi8vc3AuZXhhbXBsZS5pdC9hdXRoL2NhbGxiYWNrIiwic3RhdGUiOiJNQnpHcXl5ZjlReXREMjhldXB5V2hTcU1qNzhXTnE1SnNHWTRIYzVuOXlCWEFyd2wiLCJub25jZSI6Im5vbmNlLXZhbHVlLWF0LWxlYXN0LTMyLWNoYXJzLWhlcmUiLCJjb2RlX2NoYWxsZW5nZSI6IkU5TXJvem9hMm93VWVkbk1nOF9wNXdxaWNoSmV1V01xRkg3STgwZFA1WUUiLCJjb2RlX2NoYWxsZW5nZV9tZXRob2QiOiJTMjU2IiwiYWNyX3ZhbHVlcyI6Imh0dHBzOi8vd3d3LnNwaWQuZ292Lml0L1NwaWRMMiIsInByb21wdCI6ImNvbnNlbnQiLCJjbGFpbXMiOnsidXNlcmluZm8iOnsiZmlzY2FsX251bWJlciI6bnVsbCwibmFtZSI6bnVsbCwiZmFtaWx5X25hbWUiOm51bGwsImRhdGVPZkJpcnRoIjpudWxsLCJlbWFpbCI6bnVsbH19LCJpYXQiOjE3MDQwNjcyMDAsImV4cCI6MTcwNDA2NzMwMH0.signature
```

### Decoded Request Object Payload

```json
{
  "iss": "https://sp.example.it",
  "aud": "https://idp.spid.gov.it",
  "client_id": "https://sp.example.it",
  "response_type": "code",
  "scope": "openid profile email",
  "redirect_uri": "https://sp.example.it/auth/callback",
  "state": "MBzGqyf9QytD28eupyWhSqMj78WNq5JsGY4Hc5n9yBXArwl",
  "nonce": "nonce-value-at-least-32-chars-here",
  "code_challenge": "E9Mrozoa2owUednMg8_p5wqichJeuWMqFH7I80dP5YE",
  "code_challenge_method": "S256",
  "acr_values": "https://www.spid.gov.it/SpidL2",
  "prompt": "consent",
  "claims": {
    "userinfo": {
      "https://attributes.spid.gov.it/fiscalNumber": null,
      "https://attributes.spid.gov.it/name": null,
      "https://attributes.spid.gov.it/familyName": null,
      "https://attributes.spid.gov.it/dateOfBirth": null,
      "https://attributes.spid.gov.it/email": null
    }
  },
  "iat": 1704067200,
  "exp": 1704067300
}
```

---

## 3. AUTHORIZATION REQUEST (CIE)

### HTTP Request with Signed Request Object

```http
POST /authorize HTTP/1.1
Host: idp.cie.gov.it
Content-Type: application/x-www-form-urlencoded

scope=openid%20profile%20email
&client_id=https%3A%2F%2Fsp.example.it
&response_type=code
&code_challenge=E9Mrozoa2owUednMg8_p5wqichJeuWMqFH7I80dP5YE
&code_challenge_method=S256
&request=eyJhbGciOiJSUzI1NiIsImtpZCI6InJwLXNpZy1rZXktMjAyNSIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJodHRwczovL3NwLmV4YW1wbGUuaXQiLCJhdWQiOiJodHRwczovL2lkcC5jaWUuZ292Lml0IiwiY2xpZW50X2lkIjoiaHR0cHM6Ly9zcC5leGFtcGxlLml0IiwicmVzcG9uc2VfdHlwZSI6ImNvZGUiLCJzY29wZSI6Im9wZW5pZCBwcm9maWxlIGVtYWlsIiwicmVkaXJlY3RfdXJpIjoiaHR0cHM6Ly9zcC5leGFtcGxlLml0L2F1dGgvY2FsbGJhY2siLCJzdGF0ZSI6IkZZWmlPTDlMZjJDZUt1TlQySnp4aUxSRGluazB1Y2QiLCJub25jZSI6Ik1CekcxeWYxMjM0NTY3ODkwYWJjZGVmZ2hpamtsbW5vcCIsImNvZGVfY2hhbGxlbmdlIjoiRTlNcm96b2Eyb3dVZWRuTWc4X3A1d3FpY2hKZXVXTXFGSDdJODBkUDVZRSIsImNvZGVfY2hhbGxlbmdlX21ldGhvZCI6IlMyNTYiLCJhY3JfdmFsdWVzIjoiaHR0cHM6Ly93d3cuc3BpZC5nb3YuaXQvU3BpZEwyIiwicHJvbXB0IjoiY29uc2VudCIsImNsYWltcyI6eyJpZF90b2tlbiI6eyJmYW1pbHlfbmFtZSI6eyJlc3NlbnRpYWwiOnRydWV9LCJlbWFpbCI6eyJlc3NlbnRpYWwiOnRydWV9fSwidXNlcmluZm8iOnsiZ2l2ZW5fbmFtZSI6bnVsbCwiZmFtaWx5X25hbWUiOm51bGwsImVtYWlsIjpudWxsLCJodHRwczovL2F0dHJpYnV0ZXMuZWlkLmdvdi5pdC9maXNjYWxfbnVtYmVyIjpudWxsfX0sImlhdCI6MTcwNDA2NzIwMCwiZXhwIjoxNzA0MDY3MzAwfQ.signature
```

### Decoded Request Object Payload (CIE)

```json
{
  "iss": "https://sp.example.it",
  "aud": "https://idp.cie.gov.it",
  "client_id": "https://sp.example.it",
  "response_type": "code",
  "scope": "openid profile email",
  "redirect_uri": "https://sp.example.it/auth/callback",
  "state": "FYZiOL9Lf2CeKuNT2JzxiLRDink0ucd",
  "nonce": "MBzG1yf1234567890abcdefghijklmnop",
  "code_challenge": "E9Mrozoa2owUednMg8_p5wqichJeuWMqFH7I80dP5YE",
  "code_challenge_method": "S256",
  "acr_values": "https://www.spid.gov.it/SpidL2",
  "prompt": "consent",
  "claims": {
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
  },
  "iat": 1704067200,
  "exp": 1704067300
}
```

---

## 4. TOKEN ENDPOINT REQUEST

### Client Assertion JWT (private_key_jwt)

```json
{
  "iss": "https://sp.example.it",
  "sub": "https://sp.example.it",
  "aud": "https://idp.spid.gov.it/token",
  "iat": 1704067200,
  "exp": 1704067260,
  "jti": "unique-jwt-id-12345"
}
```

### Token Endpoint Request

```http
POST /token HTTP/1.1
Host: idp.spid.gov.it
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
&code=SplxlOBeZQQYbYS6WxSbIA
&code_verifier=dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXo
&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
&client_assertion=eyJhbGciOiJSUzI1NiIsImtpZCI6InJwLXNpZy1rZXktMjAyNSIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJodHRwczovL3NwLmV4YW1wbGUuaXQiLCJzdWIiOiJodHRwczovL3NwLmV4YW1wbGUuaXQiLCJhdWQiOiJodHRwczovL2lkcC5zcGlkLmdvdi5pdC90b2tlbiIsImlhdCI6MTcwNDA2NzIwMCwiZXhwIjoxNzA0MDY3MjYwLCJqdGkiOiJ1bmlxdWUtand0LWlkLTEyMzQ1In0.signature
```

---

## 5. TOKEN ENDPOINT RESPONSE

### Successful Response (SPID)

```json
{
  "access_token": "SlAV32hkKG",
  "token_type": "Bearer",
  "expires_in": 3600,
  "refresh_token": "8xLOxBtZp8",
  "id_token": "eyJhbGciOiJSUzI1NiIsImtpZCI6ImlkcC1zaWctMjAyNSIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJodHRwczovL2lkcC5zcGlkLmdvdi5pdCIsInN1YiI6IlNQSUQtMTIzNDU2Nzg5MCIsImF1ZCI6Imh0dHBzOi8vc3AuZXhhbXBsZS5pdCIsImFjciI6Imh0dHBzOi8vd3d3LnNwaWQuZ292Lml0L1NwaWRMMiIsImF0X2hhc2giOiJxaXloNFhQSkdzT1oybWVBeUxrZlciLCJpYXQiOjE3MDQwNjcyMDAsIm5iZiI6MTcwNDA2NzIwMCwiZXhwIjoxNzA0MDcwODAwLCJqdGkiOiJud3c0SjB6TXdSazRrUmJRNTNHN3oiLCJub25jZSI6Ik1CekcxeWYxMjM0NTY3ODkwYWJjZGVmZ2hpamtsbW5vcCJ9.signature"
}
```

### Decoded ID Token (SPID)

```json
{
  "iss": "https://idp.spid.gov.it",
  "sub": "SPID-1234567890",
  "aud": "https://sp.example.it",
  "acr": "https://www.spid.gov.it/SpidL2",
  "at_hash": "qiyh4XPJGsOZ2mEAyLkfW",
  "iat": 1704067200,
  "nbf": 1704067200,
  "exp": 1704070800,
  "jti": "nww4J0zMwRk4kRbQ53G7z",
  "nonce": "MBzG1yf1234567890abcdefghijklmnop"
}
```

### Decoded ID Token (CIE)

```json
{
  "iss": "https://idp.cie.gov.it",
  "sub": "CIE-9876543210",
  "aud": "https://sp.example.it",
  "acr": "https://www.spid.gov.it/SpidL2",
  "family_name": "Rossi",
  "email": "mario.rossi@example.it",
  "email_verified": true,
  "at_hash": "qiyh4XPJGsOZ2mEAyLkfW",
  "iat": 1704067200,
  "nbf": 1704067200,
  "exp": 1704070800,
  "jti": "nww4J0zMwRk4kRbQ53G7z",
  "nonce": "MBzG1yf1234567890abcdefghijklmnop"
}
```

---

## 6. USERINFO ENDPOINT RESPONSE

### SPID UserInfo Response (Signed & Encrypted)

```json
{
  "sub": "SPID-1234567890",
  "https://attributes.spid.gov.it/name": "Mario",
  "https://attributes.spid.gov.it/familyName": "Rossi",
  "https://attributes.spid.gov.it/fiscalNumber": "TINIT-RSSMRA80A01H501U",
  "https://attributes.spid.gov.it/dateOfBirth": "1980-01-01",
  "https://attributes.spid.gov.it/placeOfBirth": "Roma",
  "https://attributes.spid.gov.it/gender": "M",
  "https://attributes.spid.gov.it/email": "mario.rossi@example.it",
  "https://attributes.spid.gov.it/address": "Via Roma 1, 00100 Roma",
  "https://attributes.spid.gov.it/digitalAddress": "mario.rossi@pec.example.it"
}
```

### CIE UserInfo Response (Signed & Encrypted)

```json
{
  "sub": "CIE-9876543210",
  "given_name": "Mario",
  "family_name": "Rossi",
  "birthdate": "1980-01-01",
  "gender": "M",
  "email": "mario.rossi@example.it",
  "email_verified": true,
  "https://attributes.eid.gov.it/fiscal_number": "TINIT-RSSMRA80A01H501U",
  "https://attributes.eid.gov.it/place_of_birth": "Roma",
  "https://attributes.eid.gov.it/address": "Via Roma 1, 00100 Roma"
}
```

---

## 7. OPENID PROVIDER (OP) - ENTITY CONFIGURATION

### OP Entity Configuration Response

```json
{
  "iss": "https://idp.spid.gov.it",
  "sub": "https://idp.spid.gov.it",
  "iat": 1704067200,
  "exp": 1704153600,
  "jwks": {
    "keys": [
      {
        "kty": "RSA",
        "use": "sig",
        "kid": "idp-sig-key-2025",
        "n": "0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tSoc_BJECPebWKRXjBZCiFV4n3oknjhMstn64tZ_2W-5JsGY4Hc5n9yBXArwl93lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2QvzqY368QQMicAtaSqzs8KJZgnYb9c7d0zgdAZHzu6qMQvRL5hajrn1n91CbOpbISD08qNLyrdkt-bFTWhAI4vMQFh6WeZu0fM4lFd2NcRwr3XPksINHaQ-G_xBniIqbw0Ls1jF44-csFCur-kEgU8awapJzKnqDKgw",
        "e": "AQAB"
      }
    ]
  },
  "metadata": {
    "federation_entity": {
      "organization_name": "SPID Identity Provider",
      "homepage_uri": "https://idp.spid.gov.it",
      "policy_uri": "https://idp.spid.gov.it/privacy",
      "logo_uri": "https://idp.spid.gov.it/logo.svg",
      "contacts": ["support@idp.spid.gov.it"],
      "federation_resolve_endpoint": "https://idp.spid.gov.it/federation/resolve"
    },
    "openid_provider": {
      "issuer": "https://idp.spid.gov.it",
      "authorization_endpoint": "https://idp.spid.gov.it/authorize",
      "token_endpoint": "https://idp.spid.gov.it/token",
      "userinfo_endpoint": "https://idp.spid.gov.it/userinfo",
      "introspection_endpoint": "https://idp.spid.gov.it/introspection",
      "revocation_endpoint": "https://idp.spid.gov.it/revocation",
      "jwks": {
        "keys": [
          {
            "kty": "RSA",
            "use": "sig",
            "kid": "idp-sig-key-2025",
            "n": "0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tSoc_BJECPebWKRXjBZCiFV4n3oknjhMstn64tZ_2W-5JsGY4Hc5n9yBXArwl93lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2QvzqY368QQMicAtaSqzs8KJZgnYb9c7d0zgdAZHzu6qMQvRL5hajrn1n91CbOpbISD08qNLyrdkt-bFTWhAI4vMQFh6WeZu0fM4lFd2NcRwr3XPksINHaQ-G_xBniIqbw0Ls1jF44-csFCur-kEgU8awapJzKnqDKgw",
            "e": "AQAB"
          }
        ]
      },
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
        "https://attributes.spid.gov.it/countyOfBirth",
        "https://attributes.spid.gov.it/gender",
        "https://attributes.spid.gov.it/email",
        "https://attributes.spid.gov.it/address",
        "https://attributes.spid.gov.it/digitalAddress",
        "https://attributes.spid.gov.it/mobilePhone",
        "https://attributes.spid.gov.it/spidCode",
        "https://attributes.spid.gov.it/companyName",
        "https://attributes.spid.gov.it/registeredOffice",
        "https://attributes.spid.gov.it/ivaCode",
        "https://attributes.spid.gov.it/idCard",
        "https://attributes.spid.gov.it/expirationDate"
      ],
      "client_registration_types_supported": ["automatic"]
    }
  },
  "trust_marks": [
    {
      "id": "https://registry.interno.gov.it/openid_provider/public/",
      "trust_mark": "eyJhbGciOiJSUzI1NiIsImtpZCI6ImFnaWQta2V5LWlkIiwidHlwIjoidHJ1c3QtbWFyaytqd3QifQ.eyJpc3MiOiJodHRwczovL2FnaWQuZ292Lml0IiwiYXVkIjoiaHR0cHM6Ly9pZHAuc3BpZC5nb3YuaXQiLCJzdWIiOiJodHRwczovL2lkcC5zcGlkLmdvdi5pdCIsImlkIjoiaHR0cHM6Ly9yZWdpc3RyeS5pbnRlcm5vLmdvdi5pdC9vcGVuaWRfcHJvdmlkZXIvcHVibGljLyIsImlhdCI6MTcwNDA2NzIwMCwiZXhwIjoxNzM1NjAzMjAwLCJsb2dvX3VyaSI6Imh0dHBzOi8vcmVnaXN0cnkuaW50ZXJuby5nb3YuaXQvbG9nby5zdmciLCJyZWYiOiJodHRwczovL3JlZ2lzdHJ5LmludGVybm8uZ292Lml0L29wZW5pZF9wcm92aWRlci9wdWJsaWMvIiwib3JnYW5pemF0aW9uX3R5cGUiOiJwdWJsaWMiLCJpZF9jb2RlIjp7ImlwYV9jb2RlIjoiYzAwMDAwIn0sImVtYWlsIjoic3VwcG9ydEBpZHAuc3BpZC5nb3YuaXQiLCJvcmdhbml6YXRpb25fbmFtZSI6IlNQSUQgSWRlbnRpdHkgUHJvdmlkZXIifQ.signature"
    }
  ]
}
```

---

## 8. TRUST MARK VALIDATION

### Static Validation (Signature Check)

```python
import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.backends import default_backend

# Get issuer's public key from their Entity Configuration
issuer_ec = requests.get("https://agid.gov.it/.well-known/openid-federation").json()
issuer_jwks = issuer_ec["jwks"]

# Find the key used to sign the trust mark
trust_mark_jwt = "eyJhbGciOiJSUzI1NiIsImtpZCI6ImFnaWQta2V5LWlkIiwidHlwIjoidHJ1c3QtbWFyaytqd3QifQ..."
header = jwt.get_unverified_header(trust_mark_jwt)
kid = header["kid"]

# Find matching key in JWKS
key_data = next(k for k in issuer_jwks["keys"] if k["kid"] == kid)

# Verify signature
try:
    payload = jwt.decode(
        trust_mark_jwt,
        key_data,
        algorithms=["RS256"],
        options={"verify_signature": True}
    )
    print("Trust Mark signature valid")
    print(f"Issuer: {payload['iss']}")
    print(f"Subject: {payload['sub']}")
    print(f"Expiration: {payload['exp']}")
except jwt.InvalidSignatureError:
    print("Trust Mark signature invalid!")
```

### Dynamic Validation (Status Endpoint)

```python
import requests

# Query trust mark status endpoint
trust_mark_id = "https://registry.interno.gov.it/openid_relying_party/public/"
issuer = "https://agid.gov.it"

response = requests.get(
    f"{issuer}/trust_mark_status",
    params={
        "trust_mark_id": trust_mark_id,
        "subject": "https://sp.example.it"
    }
)

status = response.json()
if status["active"]:
    print("Trust Mark is active")
else:
    print("Trust Mark has been revoked")
```

---

## 9. FEDERATION RESOLVE ENDPOINT

### Request

```http
GET /federation/resolve?sub=https://sp.example.it&anchor=https://agid.gov.it HTTP/1.1
Host: idp.spid.gov.it
```

### Response

```json
{
  "entity_configuration": "eyJhbGciOiJSUzI1NiIsImtpZCI6InJwLXNpZy1rZXktMjAyNSIsInR5cCI6ImVudGl0eS1zdGF0ZW1lbnQrand0In0...",
  "entity_statements": [
    "eyJhbGciOiJSUzI1NiIsImtpZCI6ImFnaWQta2V5LWlkIiwidHlwIjoiZW50aXR5LXN0YXRlbWVudCrand0In0...",
    "eyJhbGciOiJSUzI1NiIsImtpZCI6InRhLWtleS1pZCIsInR5cCI6ImVudGl0eS1zdGF0ZW1lbnQrand0In0..."
  ],
  "trust_chain": [
    "https://sp.example.it",
    "https://agid.gov.it",
    "https://trust-anchor.gov.it"
  ],
  "trust_marks": [
    {
      "id": "https://registry.interno.gov.it/openid_relying_party/public/",
      "trust_mark": "eyJhbGciOiJSUzI1NiIsImtpZCI6ImFnaWQta2V5LWlkIiwidHlwIjoidHJ1c3QtbWFyaytqd3QifQ..."
    }
  ]
}
```

---

## 10. DART/FLUTTER IMPLEMENTATION HINTS

### PKCE Generation (Dart)

```dart
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

class PKCEGenerator {
  static const _chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
  
  static String _generateRandomString(int length) {
    final random = Random.secure();
    return List.generate(length, (index) => _chars[random.nextInt(_chars.length)]).join();
  }
  
  static Map<String, String> generatePKCE() {
    final codeVerifier = _generateRandomString(128);
    final bytes = utf8.encode(codeVerifier);
    final digest = sha256.convert(bytes);
    final codeChallenge = base64Url.encode(digest.bytes).replaceAll('=', '');
    
    return {
      'code_verifier': codeVerifier,
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
    };
  }
}
```

### Request Object Signing (Dart)

```dart
import 'package:jose/jose.dart';

Future<String> createSignedRequestObject({
  required String clientId,
  required String issuer,
  required String audience,
  required String redirectUri,
  required String state,
  required String nonce,
  required String codeChallenge,
  required String acr,
  required JsonWebKey signingKey,
}) async {
  final now = DateTime.now();
  final payload = {
    'iss': issuer,
    'aud': audience,
    'client_id': clientId,
    'response_type': 'code',
    'scope': 'openid profile email',
    'redirect_uri': redirectUri,
    'state': state,
    'nonce': nonce,
    'code_challenge': codeChallenge,
    'code_challenge_method': 'S256',
    'acr_values': acr,
    'prompt': 'consent',
    'claims': {
      'userinfo': {
        'https://attributes.spid.gov.it/fiscalNumber': null,
        'https://attributes.spid.gov.it/name': null,
        'https://attributes.spid.gov.it/familyName': null,
      }
    },
    'iat': now.millisecondsSinceEpoch ~/ 1000,
    'exp': now.add(Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000,
  };
  
  final builder = JsonWebSignatureBuilder()
    ..jsonContent = payload
    ..addRecipient(signingKey, algorithm: 'RS256');
  
  final jws = builder.build();
  return jws.toCompactSerialization();
}
```

---

**Document Version:** 1.0 (May 2026)  
**Status:** Current (AGID/IPZS 2025/2026 specifications)
