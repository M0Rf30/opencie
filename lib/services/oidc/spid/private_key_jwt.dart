// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

/// Client assertion type for private_key_jwt.
const kClientAssertionType =
    'urn:ietf:params:oauth:client-assertion-type:jwt-bearer';

/// Builds a client assertion JWT for token endpoint authentication.
class PrivateKeyJwt {
  PrivateKeyJwt._();

  /// Builds a signed client assertion JWT (RS256).
  ///
  /// Payload: iss=clientId, sub=clientId, aud=tokenEndpoint, jti=random, iat, exp.
  /// Header: alg=RS256, typ=JWT, kid.
  static String build({
    required String clientId,
    required Uri tokenEndpoint,
    required RSAPrivateKey privateKey,
    required String kid,
    Duration ttl = const Duration(minutes: 5),
  }) {
    final now = DateTime.now();
    final exp = now.add(ttl);
    final jti = _randomJti();

    final payload = {
      'iss': clientId,
      'sub': clientId,
      'aud': tokenEndpoint.toString(),
      'jti': jti,
      'iat': (now.millisecondsSinceEpoch / 1000).floor(),
      'exp': (exp.millisecondsSinceEpoch / 1000).floor(),
    };

    final jwt = JWT(
      payload,
      header: {'alg': 'RS256', 'typ': 'JWT', 'kid': kid},
    );
    return jwt.sign(privateKey, algorithm: JWTAlgorithm.RS256);
  }
}

String _randomJti() {
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final r = Random.secure();
  return List.generate(16, (_) => chars[r.nextInt(chars.length)]).join();
}
