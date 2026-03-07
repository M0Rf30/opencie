// SPDX-License-Identifier: GPL-3.0-or-later
import '../oidc_session.dart';
import 'acr.dart';
import 'claims.dart';

/// SPID/CIE authenticated session.
///
/// Wraps an [OidcSession] with SPID-specific profile, level, and attributes.
class SpidSession {
  SpidSession({
    required this.session,
    required this.profile,
    this.level,
    required this.attributes,
  });

  final OidcSession session;
  final SpidProfile profile;
  final SpidLevel? level;
  final SpidUserAttributes attributes;

  /// Convenience: issuer from wrapped session.
  String get issuer => session.issuer;

  /// Convenience: access token from wrapped session.
  String get accessToken => session.accessToken;

  Map<String, dynamic> toJson() => {
        'session': session.toJson(),
        'profile': profile.name,
        if (level != null) 'level': level!.acrValue,
        'attributes': attributes.toJson(),
      };
}
