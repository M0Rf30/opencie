// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/services/net/socks_connector.dart';

import 'fake_socks_server.dart';

/// `HttpClient` that reaches everything through [proxy].
HttpClient _client(SocksProxy proxy, {SecurityContext? context}) {
  final client = HttpClient(context: context);
  client.findProxy = (_) => 'DIRECT';
  client.connectionFactory = socksConnectionFactory(
    proxy,
    handshakeTimeout: const Duration(seconds: 5),
    context: context,
  );
  return client;
}

Future<String> _get(HttpClient client, Uri uri) async {
  final request = await client.getUrl(uri);
  final response = await request.close();
  return utf8.decode(await response.expand((c) => c).toList());
}

/// `false` when `openssl` can mint the throwaway test certificate, else the
/// skip reason.
final Object skipTls = () {
  try {
    final r = Process.runSync('openssl', ['version']);
    return r.exitCode == 0 ? false : 'openssl not available';
  } on ProcessException {
    // Intentional: no openssl on this machine → TLS tests are skipped.
    return 'openssl not available';
  }
}();

void main() {
  late HttpServer web;
  final hostHeaders = <String?>[];
  final started = <FakeSocksServer>[];

  setUp(() async {
    hostHeaders.clear();
    web = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    web.listen((req) {
      hostHeaders.add(req.headers.value('host'));
      req.response
        ..write('hello ${req.uri.path}')
        ..close();
    });
  });

  tearDown(() async {
    await web.close(force: true);
    for (final s in started) {
      await s.close();
    }
    started.clear();
  });

  Future<FakeSocksServer> fake({
    required int version,
    String? user,
    String? password,
    int? replyCode,
    bool stall = false,
    int? forceMethod,
  }) async {
    final s = await FakeSocksServer.start(
      version: version,
      requireUser: user,
      requirePassword: password,
      replyCode: replyCode,
      relayPort: web.port,
      stall: stall,
      forceMethod: forceMethod,
    );
    started.add(s);
    return s;
  }

  SocksProxy proxyFor(
    FakeSocksServer s, {
    String username = '',
    String password = '',
  }) => SocksProxy(
    version: s.version == 5 ? SocksVersion.socks5 : SocksVersion.socks4,
    host: '127.0.0.1',
    port: s.port,
    username: username,
    password: password,
  );

  group('SOCKS5', () {
    test(
      'no-auth GET uses the domain-name address type (remote DNS)',
      () async {
        final s = await fake(version: 5);
        final client = _client(proxyFor(s));
        addTearDown(() => client.close(force: true));

        final body = await _get(client, Uri.parse('http://tsa.test:80/a'));

        expect(body, 'hello /a');
        expect(s.errors, isEmpty);
        final seen = s.requests.single;
        expect(seen.host, 'tsa.test');
        expect(seen.port, 80);
        expect(seen.addressType, 3);
        expect(seen.offeredMethods, [0]);
        expect(seen.username, isNull);
        expect(hostHeaders.single, 'tsa.test');
      },
    );

    test('keep-alive: several requests over the tunnel', () async {
      final s = await fake(version: 5);
      final client = _client(proxyFor(s));
      addTearDown(() => client.close(force: true));
      final uri = Uri.parse('http://tsa.test:${web.port}');

      expect(await _get(client, uri.replace(path: '/1')), 'hello /1');
      expect(await _get(client, uri.replace(path: '/2')), 'hello /2');
      expect(s.errors, isEmpty);
    });

    test('RFC 1929 username/password are sent when configured', () async {
      final s = await fake(version: 5, user: 'alice', password: 's3cr:et');
      final client = _client(
        proxyFor(s, username: 'alice', password: 's3cr:et'),
      );
      addTearDown(() => client.close(force: true));

      expect(await _get(client, Uri.parse('http://tsa.test/x')), 'hello /x');

      final seen = s.requests.single;
      expect(seen.offeredMethods, [0, 2]);
      expect(seen.username, 'alice');
      expect(seen.password, 's3cr:et');
      expect(s.errors, isEmpty);
    });

    test(
      'a proxy that does not require auth ignores the credentials',
      () async {
        final s = await fake(version: 5);
        final client = _client(proxyFor(s, username: 'u', password: 'p'));
        addTearDown(() => client.close(force: true));

        expect(await _get(client, Uri.parse('http://tsa.test/x')), 'hello /x');
        expect(s.requests.single.username, isNull);
      },
    );

    test('IP literals use the IPv4 address type', () async {
      final s = await fake(version: 5);
      final client = _client(proxyFor(s));
      addTearDown(() => client.close(force: true));

      await _get(client, Uri.parse('http://127.0.0.1:${web.port}/ip'));

      expect(s.requests.single.addressType, 1);
      expect(s.requests.single.host, '127.0.0.1');
    });

    test('wrong password fails without leaking the password', () async {
      final s = await fake(version: 5, user: 'alice', password: 'right');
      final client = _client(proxyFor(s, username: 'alice', password: 'wrong'));
      addTearDown(() => client.close(force: true));

      await expectLater(
        _get(client, Uri.parse('http://tsa.test/x')),
        throwsA(
          isA<SocksException>()
              .having((e) => e.message, 'message', contains('authentication'))
              .having((e) => '$e', 'toString', isNot(contains('wrong'))),
        ),
      );
      expect(s.requests, isEmpty);
    });

    test('proxy demanding auth without credentials is a clear error', () async {
      final s = await fake(version: 5, user: 'alice', password: 'pw');
      final client = _client(proxyFor(s));
      addTearDown(() => client.close(force: true));

      await expectLater(
        _get(client, Uri.parse('http://tsa.test/x')),
        throwsA(
          isA<SocksException>().having(
            (e) => e.message,
            'message',
            contains('requires authentication'),
          ),
        ),
      );
    });

    test('a proxy that picks an unknown method is rejected', () async {
      final s = await fake(version: 5, forceMethod: 0x09);
      final client = _client(proxyFor(s));
      addTearDown(() => client.close(force: true));

      await expectLater(
        _get(client, Uri.parse('http://tsa.test/x')),
        throwsA(
          isA<SocksException>().having(
            (e) => e.message,
            'message',
            contains('unsupported authentication method'),
          ),
        ),
      );
    });

    const replies = {
      0x01: 'general failure',
      0x02: 'not allowed',
      0x03: 'network unreachable',
      0x04: 'host unreachable',
      0x05: 'connection refused',
      0x06: 'TTL expired',
      0x07: 'not supported',
      0x08: 'address type not supported',
      0x42: '0x42',
    };
    for (final entry in replies.entries) {
      test('reply code ${entry.key} maps to a clear error', () async {
        final s = await fake(version: 5, replyCode: entry.key);
        final client = _client(proxyFor(s));
        addTearDown(() => client.close(force: true));

        await expectLater(
          _get(client, Uri.parse('http://tsa.test/x')),
          throwsA(
            isA<SocksException>().having(
              (e) => e.message,
              'message',
              allOf(contains('SOCKS5'), contains(entry.value)),
            ),
          ),
        );
      });
    }
  });

  group('SOCKS4a', () {
    test('GET sends the host name with an empty user id', () async {
      final s = await fake(version: 4);
      final client = _client(proxyFor(s));
      addTearDown(() => client.close(force: true));

      final body = await _get(client, Uri.parse('http://tsa.test/a'));

      expect(body, 'hello /a');
      final seen = s.requests.single;
      expect(seen.host, 'tsa.test');
      expect(seen.addressType, 3);
      expect(seen.username, '');
      expect(s.errors, isEmpty);
    });

    test('the username is sent as the user id', () async {
      final s = await fake(version: 4);
      final client = _client(proxyFor(s, username: 'alice', password: 'x'));
      addTearDown(() => client.close(force: true));

      await _get(client, Uri.parse('http://tsa.test/a'));

      expect(s.requests.single.username, 'alice');
    });

    test('IPv4 literals are sent as plain SOCKS4 addresses', () async {
      final s = await fake(version: 4);
      final client = _client(proxyFor(s));
      addTearDown(() => client.close(force: true));

      await _get(client, Uri.parse('http://127.0.0.1:${web.port}/ip'));

      expect(s.requests.single.addressType, 1);
      expect(s.requests.single.host, '127.0.0.1');
    });

    test('IPv6 literals cannot be expressed in SOCKS4', () async {
      final s = await fake(version: 4);
      final client = _client(proxyFor(s));
      addTearDown(() => client.close(force: true));

      await expectLater(
        _get(client, Uri.parse('http://[::1]:${web.port}/')),
        throwsA(isA<SocksException>()),
      );
    });

    const rejections = {
      0x5B: 'rejected or failed',
      0x5C: 'identd',
      0x5D: 'does not match',
      0x00: 'unknown reply code',
    };
    for (final entry in rejections.entries) {
      test('reply ${entry.key} maps to a clear error', () async {
        final s = await fake(version: 4, replyCode: entry.key);
        final client = _client(proxyFor(s));
        addTearDown(() => client.close(force: true));

        await expectLater(
          _get(client, Uri.parse('http://tsa.test/x')),
          throwsA(
            isA<SocksException>().having(
              (e) => e.message,
              'message',
              allOf(contains('SOCKS4'), contains(entry.value)),
            ),
          ),
        );
      });
    }
  });

  group('failures', () {
    test('a silent proxy trips the handshake timeout', () async {
      final s = await fake(version: 5, stall: true);

      await expectLater(
        connectViaSocks(
          proxyFor(s),
          targetHost: 'tsa.test',
          targetPort: 80,
          handshakeTimeout: const Duration(milliseconds: 200),
        ),
        throwsA(
          isA<SocksException>().having(
            (e) => e.message,
            'message',
            contains('timed out'),
          ),
        ),
      );
    });

    test('an unreachable proxy is a SocksException, not a crash', () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();

      await expectLater(
        connectViaSocks(
          SocksProxy(
            version: SocksVersion.socks5,
            host: '127.0.0.1',
            port: port,
          ),
          targetHost: 'tsa.test',
          targetPort: 80,
        ),
        throwsA(
          isA<SocksException>().having(
            (e) => e.message,
            'message',
            contains('cannot reach'),
          ),
        ),
      );
    });

    test('a proxy hanging up mid-handshake is reported', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((c) => c.destroy());

      await expectLater(
        connectViaSocks(
          SocksProxy(
            version: SocksVersion.socks5,
            host: '127.0.0.1',
            port: server.port,
          ),
          targetHost: 'tsa.test',
          targetPort: 80,
        ),
        throwsA(isA<SocksException>()),
      );
    });

    test('a non-SOCKS peer is rejected', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((c) {
        c.add(ascii.encode('HTTP/1.1 400 Bad Request\r\n\r\n'));
        c.close();
      });

      await expectLater(
        connectViaSocks(
          SocksProxy(
            version: SocksVersion.socks5,
            host: '127.0.0.1',
            port: server.port,
          ),
          targetHost: 'tsa.test',
          targetPort: 80,
        ),
        throwsA(
          isA<SocksException>().having(
            (e) => e.message,
            'message',
            contains('not a SOCKS5 proxy'),
          ),
        ),
      );
    });

    test('over-long credentials are refused before any request', () async {
      final s = await fake(version: 5, user: 'u', password: 'p');

      await expectLater(
        connectViaSocks(
          proxyFor(s, username: 'u', password: 'p' * 300),
          targetHost: 'tsa.test',
          targetPort: 80,
        ),
        throwsA(isA<SocksException>()),
      );
      expect(s.requests, isEmpty);
    });

    test('cancelling the task closes the pending connection', () async {
      final s = await fake(version: 5, stall: true);
      final task = startSocksConnect(
        proxyFor(s),
        targetHost: 'tsa.test',
        targetPort: 80,
        handshakeTimeout: const Duration(seconds: 5),
      );
      final outcome = task.socket.then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      // Let the handshake reach the stalled proxy, then cancel.
      while (s.requests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      task.cancel();

      expect(await outcome, isA<Object>());
    });
  });

  group('https', () {
    test(
      'TLS is attempted on the tunnel (plain peer → handshake error)',
      () async {
        final s = await fake(version: 5);
        final client = _client(proxyFor(s));
        addTearDown(() => client.close(force: true));

        // `web` speaks plain HTTP; a socket handed back unsecured would "work".
        await expectLater(
          client.getUrl(Uri.parse('https://tsa.test:${web.port}/')),
          throwsA(isA<HandshakeException>()),
        );
        expect(s.requests.single.host, 'tsa.test');
      },
    );

    group('with a local TLS server', () {
      Directory? dir;
      late SecurityContext serverContext;
      late SecurityContext clientContext;

      setUpAll(() async {
        if (skipTls != false) return;
        final tmp = dir = await Directory.systemTemp.createTemp(
          'opencie_socks_tls',
        );
        final key = '${tmp.path}/key.pem';
        final cert = '${tmp.path}/cert.pem';
        final r = await Process.run('openssl', [
          'req',
          '-x509',
          '-newkey',
          'ec',
          '-pkeyopt',
          'ec_paramgen_curve:prime256v1',
          '-nodes',
          '-keyout',
          key,
          '-out',
          cert,
          '-days',
          '2',
          '-subj',
          '/CN=tsa.test',
          '-addext',
          'subjectAltName=DNS:tsa.test',
        ]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        serverContext = SecurityContext()
          ..useCertificateChain(cert)
          ..usePrivateKey(key);
        clientContext = SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificates(cert);
      });

      tearDownAll(() async {
        await dir?.delete(recursive: true);
      });

      test(
        'https GET is secured against the target host name',
        skip: skipTls,
        () async {
          final tls = await HttpServer.bindSecure(
            InternetAddress.loopbackIPv4,
            0,
            serverContext,
          );
          addTearDown(() => tls.close(force: true));
          tls.listen((req) {
            req.response
              ..write('secure ${req.requestedUri.host}')
              ..close();
          });
          final s = await FakeSocksServer.start(
            version: 5,
            relayPort: tls.port,
          );
          started.add(s);
          final client = _client(proxyFor(s), context: clientContext);
          addTearDown(() => client.close(force: true));

          final uri = Uri.parse('https://tsa.test:${tls.port}/');
          expect(await _get(client, uri), 'secure tsa.test');
          expect(s.requests.single.host, 'tsa.test');
          expect(s.requests.single.addressType, 3);
          expect(s.errors, isEmpty);
        },
      );

      test(
        'a certificate for another host is rejected',
        skip: skipTls,
        () async {
          final tls = await HttpServer.bindSecure(
            InternetAddress.loopbackIPv4,
            0,
            serverContext,
          );
          addTearDown(() => tls.close(force: true));
          tls.listen((req) => req.response.close());
          final s = await FakeSocksServer.start(
            version: 4,
            relayPort: tls.port,
          );
          started.add(s);

          await expectLater(
            connectViaSocks(
              proxyFor(s),
              targetHost: 'other.test',
              targetPort: tls.port,
              secure: true,
              context: clientContext,
            ),
            throwsA(isA<HandshakeException>()),
          );
        },
      );
    });
  });
}
