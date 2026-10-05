// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../models/proxy_config.dart';
import '../../models/tsa_config.dart';
import '../net/socks_connector.dart';

/// Thrown when the configured proxy cannot be honoured. The caller must
/// fail the network step instead of silently going direct, which would
/// bypass the user's proxy.
class UpgradeProxyException implements Exception {
  UpgradeProxyException(this.message);
  final String message;

  @override
  String toString() => 'UpgradeProxyException: $message';
}

/// Adds HTTP Basic credentials to requests sent to [host] only, so a
/// fallback TSA (or an OCSP/CRL host) never receives the primary TSA's
/// credentials.
class BasicAuthClient extends http.BaseClient {
  BasicAuthClient(
    this._inner, {
    required this.host,
    required String username,
    required String password,
  }) : _header = 'Basic ${base64Encode(utf8.encode('$username:$password'))}';

  final http.Client _inner;
  final String host;
  final String _header;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.host == host) {
      request.headers['Authorization'] = _header;
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

/// Builds the `HttpClient` honouring [proxy]:
///
/// - `none`: always direct.
/// - `system`: dart:io default (`http_proxy`/`https_proxy`/`no_proxy`).
/// - `manual` + HTTP: `PROXY host:port`, with Basic proxy credentials.
/// - `manual` + SOCKS4(a)/5: tunnelled through `HttpClient.connectionFactory`
///   (see `socks_connector.dart`), with remote DNS and, for SOCKS5, optional
///   username/password. Handshake failures surface as request errors.
HttpClient buildProxiedHttpClient(ProxyConfig proxy) {
  final client = HttpClient();
  switch (proxy.mode) {
    case ProxyMode.none:
      client.findProxy = (_) => 'DIRECT';
    case ProxyMode.system:
      break;
    case ProxyMode.manual:
      if (!proxy.isConfigured) {
        client.findProxy = (_) => 'DIRECT';
        break;
      }
      if (proxy.port <= 0 || proxy.port > 65535) {
        client.close(force: true);
        throw UpgradeProxyException('invalid proxy port ${proxy.port}');
      }
      if (proxy.type != ProxyType.http) {
        // The factory must see direct connections only (no env proxies).
        client.findProxy = (_) => 'DIRECT';
        client.connectionFactory = socksConnectionFactory(
          SocksProxy(
            version: proxy.type == ProxyType.socks4
                ? SocksVersion.socks4
                : SocksVersion.socks5,
            host: proxy.host,
            port: proxy.port,
            username: proxy.username,
            password: proxy.password,
          ),
        );
        break;
      }
      client.findProxy = (_) => 'PROXY ${proxy.host}:${proxy.port}';
      if (proxy.username.isNotEmpty) {
        client.addProxyCredentials(
          proxy.host,
          proxy.port,
          '',
          HttpClientBasicCredentials(proxy.username, proxy.password),
        );
      }
  }
  return client;
}

/// Production HTTP client for the post-sign upgrade (TSA + OCSP + CRL +
/// issuer fetches): proxy-aware, with the TSA's Basic credentials scoped to
/// the primary TSA host.
http.Client buildUpgradeHttpClient({
  required ProxyConfig proxy,
  required TsaConfig tsa,
}) {
  http.Client client = IOClient(buildProxiedHttpClient(proxy));
  final tsaHost = Uri.tryParse(tsa.serverUrl.trim())?.host ?? '';
  if (tsa.hasCredentials && tsaHost.isNotEmpty) {
    client = BasicAuthClient(
      client,
      host: tsaHost,
      username: tsa.username,
      password: tsa.password,
    );
  }
  return client;
}
