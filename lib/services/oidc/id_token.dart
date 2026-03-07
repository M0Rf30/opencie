// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

import 'jwks.dart';

/// Parsed and verified ID token claims.
class IdToken {
  IdToken({
    required this.issuer,
    required this.subject,
    required this.audience,
    required this.expiration,
    required this.issuedAt,
    this.nonce,
    this.authTime,
    this.acr,
    this.raw,
  });

  final String issuer;
  final String subject;
  final String audience;
  final DateTime expiration;
  final DateTime issuedAt;
  final String? nonce;
  final DateTime? authTime;
  final String? acr;

  /// Full payload map for claim extraction beyond the typed surface.
  final Map<String, Object?>? raw;

  /// Validates signature + time + issuer + audience + nonce.
  ///
  /// [expectedIssuer] and [expectedClientId] must match the values used in
  /// the authorize request. [expectedNonce] is the exact `nonce` parameter
  /// sent to the provider; if `null` nonce checking is skipped.
  ///
  /// [clockTolerance] allows small clock skew (default 5 s).
  static Future<IdToken> verify({
    required String tokenString,
    required JwksClient jwks,
    required Uri jwksUri,
    required String expectedIssuer,
    required String expectedClientId,
    String? expectedNonce,
    Duration clockTolerance = const Duration(seconds: 5),
  }) async {
    // Decode header to pick the right key from the JWKS.
    final decoded = JWT.decode(tokenString);
    final header = decoded.header;
    final kid = header?['kid'] as String?;

    if (kid == null || kid.isEmpty) {
      throw const IdTokenVerificationException('ID token missing kid in header');
    }

    final jwk = await jwks.getKey(jwksUri, kid);
    if (jwk == null) {
      throw IdTokenVerificationException('key "$kid" not found in JWKS');
    }

    final key = JWTKey.fromJWK(jwk.raw!);

    // Verify signature and built-in claims.
    final jwt = JWT.verify(
      tokenString,
      key,
      checkExpiresIn: true,
      checkNotBefore: true,
      issuer: expectedIssuer,
      audience: Audience.one(expectedClientId),
    );

    final payload = jwt.payload as Map<String, dynamic>;

    // Manual iat future check (JWT.verify doesn't guard against future iat).
    final now = DateTime.now().toUtc();
    if (payload['iat'] is num) {
      final iat = DateTime.fromMillisecondsSinceEpoch(
        ((payload['iat'] as num) * 1000).toInt(),
        isUtc: true,
      );
      if (iat.isAfter(now.add(clockTolerance))) {
        throw const IdTokenVerificationException('token issued in the future');
      }
    }

    // Nonce check.
    if (expectedNonce != null) {
      final nonce = payload['nonce'];
      if (nonce != expectedNonce) {
        throw IdTokenVerificationException(
          'nonce mismatch: expected "$expectedNonce", got "$nonce"',
        );
      }
    }

    DateTime? optDt(Object? v) => v is num
        ? DateTime.fromMillisecondsSinceEpoch(
            (v * 1000).toInt(),
            isUtc: true,
          )
        : null;

    return IdToken(
      issuer: jwt.issuer!,
      subject: jwt.subject!,
      audience: jwt.audience!.first,
      expiration: optDt(payload['exp'])!,
      issuedAt: optDt(payload['iat'])!,
      nonce: payload['nonce'] as String?,
      authTime: optDt(payload['auth_time']),
      acr: payload['acr'] as String?,
      raw: payload.cast<String, Object?>(),
    );
  }
}

class IdTokenVerificationException implements Exception {
  const IdTokenVerificationException(this.message);
  final String message;
  @override
  String toString() => 'IdTokenVerificationException: $message';
}
