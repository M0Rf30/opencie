// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n/app_localizations.dart';
import '../../providers/settings_provider.dart';
import '../../services/oidc/discovery.dart';
import '../../services/oidc/oidc_session.dart';
import '../../services/oidc/token_exchange.dart';
import '../../services/oidc/token_refresher.dart';
import '../../services/oidc/userinfo.dart';
import '../../services/secure_store.dart';
import '../../widgets/oc_gradient_button.dart';

class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  OidcSession? _session;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final session = await OidcSession.load();
    if (!mounted) {
      return;
    }
    if (session == null) {
      setState(() {
        _session = null;
        _loading = false;
      });
      return;
    }

    var displaySession = session;
    try {
      final discovery = await OidcDiscoveryClient.instance.fetch(
        Uri.parse(session.issuer),
      );
      final refresher = TokenRefresher(
        session: session,
        discovery: discovery,
        onRefreshed: (refreshed) => _saveSession(refreshed),
      );
      final userinfoEndpoint = discovery.userinfoEndpoint;
      if (userinfoEndpoint != null) {
        final claims = await refresher.withFreshToken(
          (accessToken) => UserInfoClient().fetch(
            userinfoEndpoint,
            accessToken,
            expectedSubject: refresher.session.idToken.subject,
          ),
        );
        final refreshed = refresher.session;
        displaySession = OidcSession(
          issuer: refreshed.issuer,
          clientId: refreshed.clientId,
          idToken: refreshed.idToken,
          idTokenRaw: refreshed.idTokenRaw,
          accessToken: refreshed.accessToken,
          tokenType: refreshed.tokenType,
          refreshToken: refreshed.refreshToken,
          expiresAt: refreshed.expiresAt,
          userinfoClaims: claims,
        );
      } else {
        displaySession = refresher.session;
      }
    } on TokenRefreshException catch (e) {
      if (e.isTerminal) {
        await _clearSession();
        if (mounted) {
          context.go('/login');
        }
        return;
      }
      // Transient refresh failure: keep showing the last known-good
      // session instead of logging the user out.
    } on Exception {
      // Offline or discovery failure: keep showing the stored session
      // rather than breaking the screen.
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _session = displaySession;
      _loading = false;
    });
  }

  Future<void> _logout() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.oidcLogoutButton),
        content: Text(l10n.oidcLogoutConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(MaterialLocalizations.of(context).okButtonLabel),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _clearSession();
    if (mounted) {
      context.go('/login');
    }
  }

  /// Persists a refreshed session, tolerating a secure store that can't be
  /// reached (locked keyring, no Secret Service). The refreshed tokens stay
  /// in memory for this run; only cross-restart persistence is affected.
  Future<void> _saveSession(OidcSession session) async {
    try {
      await OidcSession.save(session);
    } on SecureStoreException {
      ref.read(settingsProvider.notifier).flagSecureStorageUnavailable();
    }
  }

  /// Clears the persisted session, tolerating a secure store that can't be
  /// reached. The app still treats the user as logged out for this run.
  Future<void> _clearSession() async {
    try {
      await OidcSession.clear();
    } on SecureStoreException {
      ref.read(settingsProvider.notifier).flagSecureStorageUnavailable();
    }
  }

  Widget _tile(String label, String? value) {
    final theme = Theme.of(context);
    return ListTile(
      title: Text(label, style: theme.textTheme.bodySmall),
      subtitle: Text(
        value ?? '—',
        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final session = _session;
    if (session == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.oidcProfileTitle)),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                AppLocalizations.of(context).profileNotLoggedIn,
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 16),
              OcGradientButton(
                onPressed: () => context.go('/login'),
                label: l10n.oidcLoginButton,
              ),
            ],
          ),
        ),
      );
    }

    final claims = session.userinfoClaims ?? session.idToken.raw ?? {};

    return Scaffold(
      appBar: AppBar(title: Text(l10n.oidcProfileTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Column(
              children: [
                _tile(l10n.oidcProfileSubject, session.idToken.subject),
                _tile(l10n.oidcProfileName, session.displayName),
                _tile(l10n.oidcProfileEmail, claims['email'] as String?),
                const Divider(),
                ListTile(
                  leading: Icon(Icons.logout, color: theme.colorScheme.error),
                  title: Text(
                    l10n.oidcLogoutButton,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  onTap: _logout,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
