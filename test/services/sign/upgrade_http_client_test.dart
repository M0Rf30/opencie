// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opencie/models/proxy_config.dart';
import 'package:opencie/models/tsa_config.dart';
import 'package:opencie/services/sign/upgrade_http_client.dart';

void main() {
  group('BasicAuthClient', () {
    test('sends credentials only to the primary TSA host', () async {
      final seen = <String, String?>{};
      final inner = MockClient((request) async {
        seen[request.url.host] = request.headers['Authorization'];
        return http.Response('', 200);
      });
      final client = BasicAuthClient(
        inner,
        host: 'primary.tsa.test',
        username: 'user',
        password: 'p:w',
      );

      await client.post(Uri.parse('https://primary.tsa.test/tsr'));
      await client.post(Uri.parse('https://fallback.tsa.test/tsr'));

      expect(
        seen['primary.tsa.test'],
        'Basic ${base64Encode(utf8.encode('user:p:w'))}',
      );
      expect(seen['fallback.tsa.test'], isNull);
    });
  });

  group('buildProxiedHttpClient', () {
    test('direct, system and manual HTTP proxies build a client', () {
      for (final proxy in const [
        ProxyConfig(),
        ProxyConfig(mode: ProxyMode.system),
        ProxyConfig(
          mode: ProxyMode.manual,
          host: 'proxy.test',
          port: 3128,
          username: 'u',
          password: 'p',
        ),
      ]) {
        buildProxiedHttpClient(proxy).close(force: true);
      }
    });

    test('manual SOCKS proxies are rejected rather than bypassed', () {
      expect(
        () => buildProxiedHttpClient(
          const ProxyConfig(
            mode: ProxyMode.manual,
            type: ProxyType.socks4,
            host: 'proxy.test',
            port: 1080,
          ),
        ),
        throwsA(isA<UpgradeProxyException>()),
      );
    });

    test('a manual proxy without a valid port is rejected', () {
      expect(
        () => buildProxiedHttpClient(
          const ProxyConfig(mode: ProxyMode.manual, host: 'proxy.test'),
        ),
        throwsA(isA<UpgradeProxyException>()),
      );
    });
  });

  group('buildUpgradeHttpClient', () {
    test('wraps with Basic auth only when credentials are configured', () {
      final plain = buildUpgradeHttpClient(
        proxy: const ProxyConfig(),
        tsa: const TsaConfig(serverUrl: 'https://tsa.test/tsr'),
      );
      final authed = buildUpgradeHttpClient(
        proxy: const ProxyConfig(),
        tsa: const TsaConfig(
          serverUrl: 'https://tsa.test/tsr',
          username: 'u',
          password: 'p',
        ),
      );

      expect(plain, isNot(isA<BasicAuthClient>()));
      expect(authed, isA<BasicAuthClient>());
      plain.close();
      authed.close();
    });
  });
}
