// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';

/// Captures the OIDC authorization callback.
///
/// * Desktop: spins up a transient loopback HTTP server on `127.0.0.1:0`,
///   yielding a redirect URI of `http://127.0.0.1:<port>/`.
/// * Android: listens for `opencie://oidc/callback` via `app_links`.
///
/// In both cases the returned [OidcCallback] contains `code`, `state`,
/// and any error fields sent by the provider.
class OidcRedirectListener {
  OidcRedirectListener._();

  static OidcRedirectListener? _instance;
  static OidcRedirectListener get instance =>
      _instance ??= OidcRedirectListener._();

  Uri? _desktopRedirectUri;
  HttpServer? _desktopServer;
  StreamSubscription<String>? _androidSub;

  /// Returns the redirect URI to register with the IdP / pass in the
  /// authorize request.
  Uri get redirectUri {
    if (Platform.isAndroid) {
      return Uri.parse('opencie://oidc/callback');
    }
    if (_desktopRedirectUri == null) {
      throw StateError(
        'Desktop redirect URI not available until start() completes',
      );
    }
    return _desktopRedirectUri!;
  }

  /// Starts listening. On desktop this binds a loopback server first;
  /// on Android it subscribes to `app_links`.
  ///
  /// Returns a future that resolves once the listener is ready.
  Future<void> start() async {
    if (Platform.isAndroid) {
      // app_links stream is set up lazily on first listen in handleCallback.
      return;
    }
    _desktopServer ??= await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _desktopRedirectUri = Uri(
      scheme: 'http',
      host: _desktopServer!.address.host,
      port: _desktopServer!.port,
      path: '/',
    );
  }

  /// Waits for a single callback and returns it.
  ///
  /// Automatically calls [stop] after receiving the callback so the
  /// desktop server isn't left hanging.
  Future<OidcCallback> handleCallback() async {
    if (Platform.isAndroid) {
      final completer = Completer<OidcCallback>();
      _androidSub = AppLinks().stringLinkStream.listen(
        (link) {
          final uri = Uri.tryParse(link);
          if (uri != null && uri.scheme == 'opencie') {
            completer.complete(parseUri(uri));
          }
        },
        onError: completer.completeError,
      );
      try {
        return await completer.future;
      } finally {
        await _androidSub?.cancel();
        _androidSub = null;
      }
    }

    if (_desktopServer == null) {
      throw StateError('start() must be called before handleCallback()');
    }
    final request = await _desktopServer!.first;
    final uri = request.requestedUri;
    final callback = parseUri(uri);

    // Return a minimal success page so the browser isn't left spinning.
    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType.html
      ..write(_successHtml)
      ..close();

    await stop();
    return callback;
  }

  /// Cleans up resources.
  Future<void> stop() async {
    await _androidSub?.cancel();
    _androidSub = null;
    await _desktopServer?.close(force: true);
    _desktopServer = null;
    _desktopRedirectUri = null;
  }

  static OidcCallback parseUri(Uri uri) {
    final params = uri.queryParameters;
    return OidcCallback(
      code: params['code'],
      state: params['state'],
      error: params['error'],
      errorDescription: params['error_description'],
      errorUri: params['error_uri'],
    );
  }
}

/// Parsed OIDC authorization callback.
class OidcCallback {
  OidcCallback({
    this.code,
    this.state,
    this.error,
    this.errorDescription,
    this.errorUri,
  });

  final String? code;
  final String? state;
  final String? error;
  final String? errorDescription;
  final String? errorUri;

  bool get isSuccess => error == null && code != null && code!.isNotEmpty;

  void throwIfError() {
    if (isSuccess) return;
    final buf = StringBuffer(error ?? 'oidc_callback_error');
    if (errorDescription != null) buf.write(': $errorDescription');
    throw OidcCallbackException(buf.toString());
  }
}

class OidcCallbackException implements Exception {
  OidcCallbackException(this.message);
  final String message;
  @override
  String toString() => 'OidcCallbackException: $message';
}

const _successHtml = '''
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>OpenCIE</title>
<style>
body{font-family:sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#0f172a;color:#fff}
.box{text-align:center}
</style></head>
<body><div class="box">
<h2>OpenCIE</h2>
<p>Authentication completed. You can close this tab.</p>
</div></body></html>
''';
