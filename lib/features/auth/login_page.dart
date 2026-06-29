// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/l10n/app_localizations.dart';
import '../../services/oidc/discovery.dart';
import '../../services/oidc/oidc_auth_service.dart';
import '../../services/oidc/oidc_session.dart';
import '../../services/oidc/redirect_listener.dart';
import '../../widgets/oc_gradient_button.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key, required this.issuer, required this.clientId});

  final String issuer;
  final String clientId;

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  bool _busy = false;
  String? _error;

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final discovery = await OidcDiscoveryClient.instance.fetch(
        Uri.parse(widget.issuer),
      );
      if (!discovery.supportsPkceS256) {
        throw Exception('Provider does not support PKCE S256');
      }

      final listener = OidcRedirectListener.instance;
      await listener.start();

      final service = OidcAuthService(
        onLaunchUrl: (url) =>
            launchUrl(url, mode: LaunchMode.externalApplication),
        onListenForCallback: (redirectUri, state) => listener.handleCallback(),
      );

      final session = await service.authenticate(
        issuer: widget.issuer,
        clientId: widget.clientId,
        redirectUri: listener.redirectUri.toString(),
        scope: 'openid profile email',
      );

      final prefs = await SharedPreferences.getInstance();
      await OidcSession.save(prefs, session);

      if (mounted) {
        context.go('/profile');
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.oidcLoginTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.shield_outlined,
                  size: 64,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 24),
                Text(
                  l10n.oidcLoginTitle,
                  style: theme.textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                if (_busy)
                  const CircularProgressIndicator()
                else
                  OcGradientButton(
                    onPressed: _login,
                    label: l10n.oidcLoginButton,
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
