// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opencie/models/proxy_config.dart';
import 'package:opencie/models/tsa_config.dart';
import 'package:opencie/services/net/socks_connector.dart';
import 'package:opencie/services/sign/upgrade_http_client.dart';

import '../net/fake_socks_server.dart';

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

    test('manual SOCKS proxies build a client (no longer rejected)', () {
      for (final type in const [ProxyType.socks4, ProxyType.socks5]) {
        buildProxiedHttpClient(
          ProxyConfig(
            mode: ProxyMode.manual,
            type: type,
            host: 'proxy.test',
            port: 1080,
          ),
        ).close(force: true);
      }
    });

    test('a SOCKS proxy with an invalid port is rejected', () {
      expect(
        () => buildProxiedHttpClient(
          const ProxyConfig(
            mode: ProxyMode.manual,
            type: ProxyType.socks5,
            host: 'proxy.test',
            port: 70000,
          ),
        ),
        throwsA(isA<UpgradeProxyException>()),
      );
    });

    group('through a SOCKS proxy', () {
      late HttpServer web;
      FakeSocksServer? proxy;

      setUp(() async {
        web = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        web.listen((req) {
          req.response
            ..write('ok ${req.uri.path}')
            ..close();
        });
      });

      tearDown(() async {
        await web.close(force: true);
        await proxy?.close();
        proxy = null;
      });

      Future<http.Client> clientVia(
        int version, {
        String user = '',
        String password = '',
        String? requireUser,
        String? requirePassword,
        int? replyCode,
      }) async {
        final fake = proxy = await FakeSocksServer.start(
          version: version,
          requireUser: requireUser,
          requirePassword: requirePassword,
          replyCode: replyCode,
          relayPort: web.port,
        );
        final client = buildUpgradeHttpClient(
          proxy: ProxyConfig(
            mode: ProxyMode.manual,
            type: version == 5 ? ProxyType.socks5 : ProxyType.socks4,
            host: '127.0.0.1',
            port: fake.port,
            username: user,
            password: password,
          ),
          tsa: const TsaConfig(serverUrl: 'http://tsa.test/tsr'),
        );
        addTearDown(client.close);
        return client;
      }

      test('SOCKS5 with authentication reaches an unresolvable host', () async {
        final client = await clientVia(
          5,
          user: 'alice',
          password: 'pw',
          requireUser: 'alice',
          requirePassword: 'pw',
        );

        final response = await client.get(Uri.parse('http://tsa.test/ocsp'));

        expect(response.body, 'ok /ocsp');
        expect(proxy!.requests.single.host, 'tsa.test');
        expect(proxy!.requests.single.username, 'alice');
      });

      test('SOCKS4a reaches an unresolvable host', () async {
        final client = await clientVia(4);

        final response = await client.get(Uri.parse('http://tsa.test/crl'));

        expect(response.body, 'ok /crl');
        expect(proxy!.requests.single.addressType, 3);
      });

      test('a refused SOCKS request surfaces as an error', () async {
        final client = await clientVia(5, replyCode: 5);

        await expectLater(
          client.get(Uri.parse('http://tsa.test/x')),
          throwsA(isA<SocksException>()),
        );
      });

      test('bad SOCKS credentials surface as an error', () async {
        final client = await clientVia(
          5,
          user: 'alice',
          password: 'different',
          requireUser: 'alice',
          requirePassword: 'pw',
        );

        await expectLater(
          client.get(Uri.parse('http://tsa.test/x')),
          throwsA(isA<SocksException>()),
        );
      });
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
