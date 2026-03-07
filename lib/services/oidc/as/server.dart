// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'key_pair.dart';

/// Profile for the mock IdP: generic, SPID, or CIE.
enum MockIdpProfile { generic, spid, cie }

/// User data for the mock IdP.
class MockIdpUser {
  const MockIdpUser({
    this.subject = 'mock-user-1',
    this.fiscalNumber = 'TINIT-RSSMRA80A01H501U',
    this.name = 'Mario',
    this.familyName = 'Rossi',
    this.dateOfBirth = '1980-01-01',
    this.placeOfBirth = 'Roma',
    this.gender = 'M',
    this.email = 'mario.rossi@example.it',
  });

  final String subject;
  final String fiscalNumber;
  final String name;
  final String familyName;
  final String dateOfBirth;
  final String placeOfBirth;
  final String gender;
  final String email;
}

/// A minimal OIDC Provider (mock IdP) for integration testing.
///
/// Runs on `127.0.0.1:0` (random port) and auto-approves all authorization
/// requests. Use [baseUrl] after [start] to configure the RP's issuer.
class MockIdpServer {
  MockIdpServer({
    this.profile = MockIdpProfile.generic,
    this.user = const MockIdpUser(),
  }) : _keyPair = MockIdpKeyPair.generate();

  final MockIdpProfile profile;
  final MockIdpUser user;
  final MockIdpKeyPair _keyPair;
  HttpServer? _server;

  Uri? get baseUrl => _server == null
      ? null
      : Uri(scheme: 'http', host: _server!.address.host, port: _server!.port);

  final Map<String, _AuthRequest> _codes = {};
  final Map<String, _Session> _accessTokens = {};

  Future<void> start() async {
    final router = Router()
      ..get('/.well-known/openid-configuration', _discovery)
      ..get('/.well-known/openid-federation', _federation)
      ..get('/jwks.json', _jwks)
      ..get('/authorize', _authorize)
      ..post('/token', _token)
      ..get('/userinfo', _userinfo)
      ..get('/federation/trust_mark_status', _trustMarkStatus)
      ..get('/federation/list', _federationList);

    final handler = const Pipeline()
        .addMiddleware(logRequests())
        .addHandler(router.call);

    _server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Response _discovery(Request req) {
    final base = baseUrl!;
    final scopes = ['openid', 'profile', 'email'];
    final acrValues = [
      'https://www.spid.gov.it/SpidL1',
      'https://www.spid.gov.it/SpidL2',
      'https://www.spid.gov.it/SpidL3',
    ];
    return Response.ok(
      json.encode({
        'issuer': base.toString(),
        'authorization_endpoint': base.replace(path: '/authorize').toString(),
        'token_endpoint': base.replace(path: '/token').toString(),
        'jwks_uri': base.replace(path: '/jwks.json').toString(),
        'userinfo_endpoint': base.replace(path: '/userinfo').toString(),
        'scopes_supported': scopes,
        'response_types_supported': ['code'],
        'id_token_signing_alg_values_supported': ['RS256'],
        'token_endpoint_auth_methods_supported': ['private_key_jwt'],
        'code_challenge_methods_supported': ['S256'],
        'acr_values_supported': acrValues,
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  Response _jwks(Request req) {
    return Response.ok(
      json.encode({'keys': [_keyPair.jwk]}),
      headers: {'content-type': 'application/json'},
    );
  }

  Response _authorize(Request req) {
    final params = req.requestedUri.queryParameters;
    var clientId = params['client_id'];
    var redirectUri = params['redirect_uri'];
    var state = params['state'];
    var nonce = params['nonce'];
    var codeChallenge = params['code_challenge'];
    var codeChallengeMethod = params['code_challenge_method'];
    var scope = params['scope'] ?? 'openid';
    var acrValues = params['acr_values'];

    // Handle request parameter (signed JWT)
    final requestParam = params['request'];
    if (requestParam != null) {
      try {
        final decoded = JWT.decode(requestParam);
        final payload = decoded.payload as Map<String, dynamic>;
        // Merge JWT payload over query params (JWT takes precedence)
        clientId = payload['client_id'] ?? clientId;
        redirectUri = payload['redirect_uri'] ?? redirectUri;
        state = payload['state'] ?? state;
        nonce = payload['nonce'] ?? nonce;
        codeChallenge = payload['code_challenge'] ?? codeChallenge;
        codeChallengeMethod = payload['code_challenge_method'] ?? codeChallengeMethod;
        scope = payload['scope'] ?? scope;
        acrValues = payload['acr_values'] ?? acrValues;
      } catch (e) {
        return Response(400, body: 'invalid request parameter');
      }
    }

    if (clientId == null || redirectUri == null) {
      return Response(400, body: 'missing client_id or redirect_uri');
    }

    final code = _randomCode();
    _codes[code] = _AuthRequest(
      clientId: clientId,
      redirectUri: redirectUri,
      codeChallenge: codeChallenge,
      codeChallengeMethod: codeChallengeMethod,
      nonce: nonce,
      scope: scope,
      acrValues: acrValues,
    );

    final redirect = Uri.parse(redirectUri).replace(
      queryParameters: {
        'code': code,
        // ignore: use_null_aware_elements
        if (state != null) 'state': state,
      },
    );
    return Response.found(redirect.toString());
  }

  Future<Response> _token(Request req) async {
    final body = await req.readAsString();
    final params = Uri.splitQueryString(body);

    final grantType = params['grant_type'];
    final code = params['code'];
    final redirectUri = params['redirect_uri'];
    var clientId = params['client_id'];
    final codeVerifier = params['code_verifier'];
    final clientAssertionType = params['client_assertion_type'];
    final clientAssertion = params['client_assertion'];

    if (grantType != 'authorization_code') {
      return _jsonError(400, 'unsupported_grant_type');
    }
    if (code == null || !_codes.containsKey(code)) {
      return _jsonError(400, 'invalid_grant');
    }

    final authReq = _codes.remove(code)!;

    // Handle private_key_jwt client authentication
    if (clientAssertionType != null) {
      if (clientAssertionType != 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer') {
        return _jsonError(400, 'invalid_client');
      }
      if (clientAssertion == null) {
        return _jsonError(401, 'invalid_client');
      }
      try {
        final decoded = JWT.decode(clientAssertion);
        final payload = decoded.payload as Map<String, dynamic>;
        final iss = payload['iss'];
        final sub = payload['sub'];
        final aud = payload['aud'];
        final exp = payload['exp'] as int?;
        final iat = payload['iat'] as int?;
        final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;

        // Validate structural correctness
        if (iss == null || sub == null || aud == null) {
          return _jsonError(401, 'invalid_client');
        }
        if (iss != sub) {
          return _jsonError(401, 'invalid_client');
        }
        if (exp == null || exp <= now) {
          return _jsonError(401, 'invalid_client');
        }
        if (iat != null && iat > now + 60) {
          return _jsonError(401, 'invalid_client');
        }
        // Use iss as clientId if not provided in form
        clientId = clientId ?? iss;
      } catch (e) {
        return _jsonError(401, 'invalid_client');
      }
    }

    if (authReq.redirectUri != redirectUri || authReq.clientId != clientId) {
      return _jsonError(400, 'invalid_grant');
    }

    // Basic PKCE check (S256 only).
    if (authReq.codeChallenge != null && codeVerifier != null) {
      // In a real IdP we'd hash the verifier; mock auto-approves.
    }

    final accessToken = _randomCode();
    final idToken = _buildIdToken(authReq);

    _accessTokens[accessToken] = _Session(
      subject: user.subject,
      scope: authReq.scope,
    );

    return Response.ok(
      json.encode({
        'access_token': accessToken,
        'token_type': 'Bearer',
        'expires_in': 3600,
        'id_token': idToken,
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  Response _userinfo(Request req) {
    final auth = req.headers['Authorization'] ?? '';
    final token = auth.startsWith('Bearer ') ? auth.substring(7) : '';
    final session = _accessTokens[token];
    if (session == null) {
      return _jsonError(401, 'invalid_token');
    }

    final claims = <String, dynamic>{'sub': session.subject};

    switch (profile) {
      case MockIdpProfile.generic:
        claims['name'] = 'Mock User';
        claims['email'] = 'mock@example.com';
      case MockIdpProfile.spid:
        // SPID: URI-keyed claims only, no standard name/email
        claims['https://attributes.spid.gov.it/fiscalNumber'] = user.fiscalNumber;
        claims['https://attributes.spid.gov.it/name'] = user.name;
        claims['https://attributes.spid.gov.it/familyName'] = user.familyName;
        claims['https://attributes.spid.gov.it/dateOfBirth'] = user.dateOfBirth;
        claims['https://attributes.spid.gov.it/placeOfBirth'] = user.placeOfBirth;
        claims['https://attributes.spid.gov.it/gender'] = user.gender;
        claims['https://attributes.spid.gov.it/email'] = user.email;
      case MockIdpProfile.cie:
        // CIE: standard OIDC + URI-style fiscal number
        claims['given_name'] = user.name;
        claims['family_name'] = user.familyName;
        claims['birthdate'] = user.dateOfBirth;
        claims['email'] = user.email;
        claims['gender'] = user.gender;
        claims['https://attributes.eid.gov.it/fiscal_number'] = user.fiscalNumber;
    }

    return Response.ok(
      json.encode(claims),
      headers: {'content-type': 'application/json'},
    );
  }

  String _buildIdToken(_AuthRequest authReq) {
    final acrValue = authReq.acrValues != null
        ? authReq.acrValues!.split(' ').first
        : 'https://www.spid.gov.it/SpidL2';
    final jwt = JWT(
      {
        'iss': baseUrl!.toString(),
        'sub': user.subject,
        'aud': authReq.clientId,
        'iat': DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
        'exp': DateTime.now().toUtc().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
        if (authReq.nonce != null) 'nonce': authReq.nonce,
        'acr': acrValue,
      },
      header: {'kid': _keyPair.kid},
    );
    return jwt.sign(
      _keyPair.privateKey,
      algorithm: JWTAlgorithm.RS256,
    );
  }

  Response _federation(Request req) {
    final base = baseUrl!.toString();
    final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final exp = now + (24 * 3600); // 24 hours

    // Build trust mark JWT
    final trustMarkPayload = {
      'iss': base,
      'sub': base,
      'id': 'https://registry.example.it/openid_provider/public/',
      'iat': now,
      'exp': now + (365 * 24 * 3600), // 365 days
      'organization_type': 'public',
    };
    final trustMarkJwt = JWT(trustMarkPayload, header: {'kid': _keyPair.kid, 'alg': 'RS256'})
        .sign(_keyPair.privateKey, algorithm: JWTAlgorithm.RS256);

    // Build entity configuration payload
    final payload = {
      'iss': base,
      'sub': base,
      'iat': now,
      'exp': exp,
      'jwks': {
        'keys': [_keyPair.jwk]
      },
      'metadata': {
        'openid_provider': {
          'issuer': base,
          'authorization_endpoint': baseUrl!.replace(path: '/authorize').toString(),
          'token_endpoint': baseUrl!.replace(path: '/token').toString(),
          'userinfo_endpoint': baseUrl!.replace(path: '/userinfo').toString(),
          'jwks_uri': baseUrl!.replace(path: '/jwks.json').toString(),
          'scopes_supported': ['openid', 'profile', 'email'],
          'response_types_supported': ['code'],
          'id_token_signing_alg_values_supported': ['RS256'],
          'token_endpoint_auth_methods_supported': ['private_key_jwt'],
          'code_challenge_methods_supported': ['S256'],
          'acr_values_supported': [
            'https://www.spid.gov.it/SpidL1',
            'https://www.spid.gov.it/SpidL2',
            'https://www.spid.gov.it/SpidL3',
          ],
        },
        'federation_entity': {
          'organization_name': 'Mock IdP',
          'homepage_uri': base,
          'policy_uri': '$base/policy',
          'contacts': ['test@example.it'],
        },
      },
      'trust_marks': [
        {
          'id': 'https://registry.example.it/openid_provider/public/',
          'trust_mark': trustMarkJwt,
        }
      ],
      'authority_hints': [],
    };

    final entityJwt = JWT(payload, header: {
      'alg': 'RS256',
      'kid': _keyPair.kid,
      'typ': 'entity-statement+jwt',
    }).sign(_keyPair.privateKey, algorithm: JWTAlgorithm.RS256);

    return Response.ok(
      entityJwt,
      headers: {'content-type': 'application/jwt'},
    );
  }

  Response _trustMarkStatus(Request req) {
    final params = req.requestedUri.queryParameters;
    final trustMarkId = params['trust_mark_id'];
    final sub = params['sub'];
    final base = baseUrl!.toString();

    final active = trustMarkId == 'https://registry.example.it/openid_provider/public/' && sub == base;

    return Response.ok(
      json.encode({'active': active}),
      headers: {'content-type': 'application/json'},
    );
  }

  Response _federationList(Request req) {
    return Response.ok(
      json.encode([]),
      headers: {'content-type': 'application/json'},
    );
  }

  Response _jsonError(int status, String error) => Response(
    status,
    body: json.encode({'error': error}),
    headers: {'content-type': 'application/json'},
  );

  static String _randomCode() {
    final r = Random.secure();
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = r.nextInt(256);
    }
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}

class _AuthRequest {
  _AuthRequest({
    required this.clientId,
    required this.redirectUri,
    this.codeChallenge,
    this.codeChallengeMethod,
    this.nonce,
    required this.scope,
    this.acrValues,
  });
  final String clientId;
  final String redirectUri;
  final String? codeChallenge;
  final String? codeChallengeMethod;
  final String? nonce;
  final String scope;
  final String? acrValues;
}

class _Session {
  _Session({required this.subject, required this.scope});
  final String subject;
  final String scope;
}
