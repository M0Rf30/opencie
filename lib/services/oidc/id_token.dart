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
  /// [allowedAlgs] should be the provider's advertised
  /// `id_token_signing_alg_values_supported` (OC-36): when given and
  /// non-empty, the token's header `alg` must be one of them, so a
  /// compromised/downgraded algorithm can't slip through even if the JWKS
  /// key itself would technically verify it. `alg: "none"` is always
  /// rejected regardless of [allowedAlgs].
  ///
  /// [clockTolerance] allows small clock skew (default 5 s).
  static Future<IdToken> verify({
    required String tokenString,
    required JwksClient jwks,
    required Uri jwksUri,
    required String expectedIssuer,
    required String expectedClientId,
    String? expectedNonce,
    List<String>? allowedAlgs,
    Duration clockTolerance = const Duration(seconds: 5),
  }) async {
    // Decode header to pick the right key from the JWKS.
    final decoded = JWT.decode(tokenString);
    final header = decoded.header;
    final alg = header?['alg'] as String?;

    if (alg == null || alg.isEmpty || alg.toLowerCase() == 'none') {
      throw const IdTokenVerificationException(
        'ID token missing or unsigned (alg) in header',
      );
    }
    if (allowedAlgs != null &&
        allowedAlgs.isNotEmpty &&
        !allowedAlgs.contains(alg)) {
      throw IdTokenVerificationException(
        'ID token alg "$alg" not in provider-advertised '
        'id_token_signing_alg_values_supported $allowedAlgs',
      );
    }

    final kid = header?['kid'] as String?;
    final keys = await jwks.fetch(jwksUri);
    JwksKey jwk;
    if (kid != null && kid.isNotEmpty) {
      final found = keys.cast<JwksKey?>().firstWhere(
        (k) => k?.kid == kid,
        orElse: () => null,
      );
      if (found == null) {
        throw IdTokenVerificationException('key "$kid" not found in JWKS');
      }
      jwk = found;
    } else {
      // Missing kid is only unambiguous when the JWKS publishes exactly
      // one key (OC-36): some real IdPs omit kid for single-key JWKS,
      // which RFC 7517 permits — there's nothing to disambiguate. Two or
      // more keys with no kid is a genuine error, not tolerated.
      if (keys.length != 1) {
        throw IdTokenVerificationException(
          'ID token missing kid in header and JWKS has ${keys.length} '
          'keys (ambiguous)',
        );
      }
      jwk = keys.single;
    }

    if (jwk.alg.isNotEmpty && jwk.alg != alg) {
      throw IdTokenVerificationException(
        'ID token alg "$alg" does not match JWKS key "${jwk.kid}" alg '
        '"${jwk.alg}"',
      );
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
        ? DateTime.fromMillisecondsSinceEpoch((v * 1000).toInt(), isUtc: true)
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
