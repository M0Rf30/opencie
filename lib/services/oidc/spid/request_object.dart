// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

/// Builds a signed JWT request object per AGID SPID/CIE spec.
class SpidRequestObject {
  SpidRequestObject._();

  /// Builds a signed request object JWT (RS256).
  ///
  /// Required claims in payload: iss, aud, client_id, response_type, scope,
  /// redirect_uri, state, nonce, code_challenge, code_challenge_method,
  /// acr_values, prompt, claims, iat, exp.
  ///
  /// Header includes: kid, alg=RS256, typ=oauth-authz-req+jwt.
  static String build({
    required String iss,
    required String aud,
    required String clientId,
    required String scope,
    required String redirectUri,
    required String state,
    required String nonce,
    required String codeChallenge,
    required String acrValue,
    required RSAPrivateKey privateKey,
    required String kid,
    String prompt = 'consent',
    Map<String, Object?>? claimsRequest,
    Duration ttl = const Duration(minutes: 1),
  }) {
    final now = DateTime.now();
    final exp = now.add(ttl);

    final payload = <String, Object?>{
      'iss': iss,
      'aud': aud,
      'client_id': clientId,
      'response_type': 'code',
      'scope': scope,
      'redirect_uri': redirectUri,
      'state': state,
      'nonce': nonce,
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
      'acr_values': acrValue,
      'prompt': prompt,
      'iat': (now.millisecondsSinceEpoch / 1000).floor(),
      'exp': (exp.millisecondsSinceEpoch / 1000).floor(),
      if (claimsRequest != null) ...{'claims': claimsRequest},
    };

    final jwt = JWT(
      payload,
      header: {
        'kid': kid,
        'alg': 'RS256',
        'typ': 'oauth-authz-req+jwt',
      },
    );
    return jwt.sign(
      privateKey,
      algorithm: JWTAlgorithm.RS256,
    );
  }
}
