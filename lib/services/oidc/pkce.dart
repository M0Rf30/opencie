// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// PKCE (RFC 7636) helpers for the OIDC auth-code flow.
///
/// All values are URL-safe base64 without padding, per RFC 4648 §5.
class OidcPkce {
  OidcPkce({required this.codeVerifier, required this.codeChallenge});

  /// 43–128 char verifier from the unreserved set.
  final String codeVerifier;

  /// `BASE64URL(SHA256(codeVerifier))`.
  final String codeChallenge;

  /// Always 'S256' — only method we generate.
  String get codeChallengeMethod => 'S256';

  /// Generates a fresh PKCE pair using a cryptographically secure RNG.
  static Future<OidcPkce> generate({int length = 64}) async {
    if (length < 43 || length > 128) {
      throw ArgumentError.value(length, 'length', 'must be in [43, 128]');
    }
    final verifier = _randomBase64Url(length);
    final hash = await Sha256().hash(utf8.encode(verifier));
    final challenge = _b64Url(Uint8List.fromList(hash.bytes));
    return OidcPkce(codeVerifier: verifier, codeChallenge: challenge);
  }
}

/// Cryptographically random `state` and `nonce` values.
class OidcNonces {
  OidcNonces._();

  /// CSRF guard returned in the redirect.
  static String state({int byteLength = 24}) =>
      _b64Url(_randomBytes(byteLength));

  /// Replay guard echoed in the ID token's `nonce` claim.
  static String nonce({int byteLength = 24}) =>
      _b64Url(_randomBytes(byteLength));
}

/// Builds the authorize URL for an auth-code+PKCE flow.
class OidcAuthorizeRequest {
  OidcAuthorizeRequest({
    required this.authorizationEndpoint,
    required this.clientId,
    required this.redirectUri,
    required this.scopes,
    required this.state,
    required this.nonce,
    required this.pkce,
    this.acrValues,
    this.prompt,
    this.loginHint,
    this.uiLocales,
    this.extra,
  });

  final Uri authorizationEndpoint;
  final String clientId;
  final Uri redirectUri;
  final List<String> scopes;
  final String state;
  final String nonce;
  final OidcPkce pkce;

  /// Optional space-separated ACR values (e.g. SPID L1/L2/L3 URIs).
  final List<String>? acrValues;
  final String? prompt;
  final String? loginHint;
  final List<String>? uiLocales;

  /// Additional non-standard parameters appended verbatim.
  final Map<String, String>? extra;

  /// Final URL the user agent should open.
  Uri build() {
    final params = <String, String>{
      'response_type': 'code',
      'client_id': clientId,
      'redirect_uri': redirectUri.toString(),
      'scope': scopes.join(' '),
      'state': state,
      'nonce': nonce,
      'code_challenge': pkce.codeChallenge,
      'code_challenge_method': pkce.codeChallengeMethod,
    };
    if (acrValues != null && acrValues!.isNotEmpty) {
      params['acr_values'] = acrValues!.join(' ');
    }
    if (prompt != null) params['prompt'] = prompt!;
    if (loginHint != null) params['login_hint'] = loginHint!;
    if (uiLocales != null && uiLocales!.isNotEmpty) {
      params['ui_locales'] = uiLocales!.join(' ');
    }
    if (extra != null) params.addAll(extra!);

    return authorizationEndpoint.replace(
      queryParameters: {...authorizationEndpoint.queryParameters, ...params},
    );
  }
}

// --- helpers ---

const _alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

String _randomBase64Url(int length) {
  final r = Random.secure();
  final sb = StringBuffer();
  for (var i = 0; i < length; i++) {
    sb.write(_alphabet[r.nextInt(_alphabet.length)]);
  }
  return sb.toString();
}

Uint8List _randomBytes(int n) {
  final r = Random.secure();
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = r.nextInt(256);
  }
  return out;
}

String _b64Url(Uint8List bytes) => base64Url.encode(bytes).replaceAll('=', '');
