// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'discovery.dart';
import 'oidc_session.dart';
import 'token_exchange.dart';

/// Thrown by the `request` callback passed to [TokenRefresher.withFreshToken]
/// to signal that the call failed with HTTP 401 and should be retried once
/// after a token refresh.
class UnauthorizedException implements Exception {
  const UnauthorizedException([this.message = 'Unauthorized']);
  final String message;
  @override
  String toString() => 'UnauthorizedException: $message';
}

/// Keeps an [OidcSession] fresh across its lifetime in memory.
///
/// An access token that is expired (or a 401 from a request that used it)
/// triggers exactly one
/// `refresh_token` redemption; every caller that shows up while that
/// redemption is in flight shares it — single-flight — instead of each
/// firing its own; once it resolves, every queued caller retries its own
/// request exactly once. A request that 401s again after that single retry
/// is left to fail rather than looping.
///
/// This class is in-memory only and never persists anything itself — see
/// [onRefreshed].
class TokenRefresher {
  TokenRefresher({
    required OidcSession session,
    required OidcDiscovery discovery,
    TokenExchanger? exchanger,
    Duration expirySkew = const Duration(seconds: 30),
    this.onRefreshed,
  }) : _session = session,
       _discovery = discovery,
       _exchanger = exchanger ?? TokenExchanger(),
       _expirySkew = expirySkew;

  final OidcDiscovery _discovery;
  final TokenExchanger _exchanger;
  final Duration _expirySkew;

  OidcSession _session;
  Future<OidcSession>? _inFlightRefresh;

  /// Invoked with the new [OidcSession] right after each successful
  /// refresh, before any queued waiter resumes. This is the persistence
  /// hook: wire it to write through T2's secure-storage-backed session
  /// store so a rotated refresh token is durably saved before the old one
  /// is discarded. Never invoked on failure — [session] still reflects the
  /// last good state in that case.
  final void Function(OidcSession session)? onRefreshed;

  /// The current session. Updated in place after each successful refresh.
  OidcSession get session => _session;

  /// Runs [request] with a valid access token.
  ///
  /// Refreshes proactively first when the current token is expired or
  /// within the configured expiry skew. If [request] throws
  /// [UnauthorizedException] (a 401), refreshes reactively and retries
  /// [request] exactly once; a second [UnauthorizedException] from that
  /// retry propagates as-is rather than triggering another refresh.
  ///
  /// A failed refresh — [TokenRefreshException] — propagates to every
  /// caller currently waiting on it (see single-flight below); none of
  /// them hang.
  Future<T> withFreshToken<T>(
    Future<T> Function(String accessToken) request,
  ) async {
    if (_isNearExpiry(_session)) {
      await _refresh();
    }

    try {
      return await request(_session.accessToken);
    } on UnauthorizedException {
      await _refresh();
      return await request(_session.accessToken);
    }
  }

  bool _isNearExpiry(OidcSession s) {
    final expiresAt = s.expiresAt;
    if (expiresAt == null) return s.isExpired;
    return DateTime.now().isAfter(expiresAt.subtract(_expirySkew));
  }

  /// Redeems the refresh token, single-flight: concurrent callers await the
  /// one in-flight [Future] instead of each starting their own redemption.
  /// The check-then-start below never crosses an `await`, so no interleaved
  /// caller can slip in between the null check and setting
  /// [_inFlightRefresh] — Dart's event loop is single-threaded, so this is
  /// enough to make the read-modify-write atomic.
  Future<void> _refresh() async {
    final inFlight = _inFlightRefresh;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final future = _doRefresh();
    _inFlightRefresh = future;
    try {
      final refreshed = await future;
      _session = refreshed;
      onRefreshed?.call(refreshed);
    } finally {
      _inFlightRefresh = null;
    }
  }

  Future<OidcSession> _doRefresh() async {
    final refreshToken = _session.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      throw TokenRefreshException.terminal('No refresh token available');
    }

    final res = await _exchanger.refresh(
      discovery: _discovery,
      clientId: _session.clientId,
      refreshToken: refreshToken,
    );

    return OidcSession(
      issuer: _session.issuer,
      clientId: _session.clientId,
      idToken: _session.idToken,
      idTokenRaw: _session.idTokenRaw,
      accessToken: res.accessToken,
      tokenType: res.tokenType,
      // RFC 6749 §6: a new refresh_token, when present, replaces the old
      // one. Falls back to the redeemed token only when the server didn't
      // rotate it — the old value is never reused once a new one arrives.
      refreshToken: res.refreshToken ?? refreshToken,
      expiresAt: res.expiresIn != null
          ? DateTime.now().add(Duration(seconds: res.expiresIn!))
          : null,
      userinfoClaims: _session.userinfoClaims,
    );
  }
}
