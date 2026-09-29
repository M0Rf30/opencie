// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:opencie/services/oidc/redirect_listener.dart';

void main() {
  group('OidcRedirectListener desktop loopback (OC-24)', () {
    test('start() binds a fresh server each time, releasing the previous '
        'port instead of reusing an already-consumed single-subscription '
        'stream', () async {
      final listener = OidcRedirectListener.testing(
        desktopCallbackTimeout: const Duration(seconds: 1),
      );

      await listener.start();
      final firstUri = listener.redirectUri;
      final firstPort = firstUri.port;

      // Abandon the first attempt without ever calling handleCallback(),
      // then start a second attempt — this must not throw and must not
      // reuse the first (still-bound) server/port.
      await listener.start();
      final secondUri = listener.redirectUri;

      expect(secondUri.port, isNot(firstPort));

      // The first server must actually be closed: connecting to its old
      // port should fail.
      await expectLater(
        HttpServer.bind(InternetAddress.loopbackIPv4, firstPort),
        completes,
      );

      await listener.stop();
    });

    test(
      'handleCallback() times out on an abandoned attempt and releases '
      'the server so a subsequent start()/handleCallback() succeeds',
      () async {
        final listener = OidcRedirectListener.testing(
          desktopCallbackTimeout: const Duration(milliseconds: 200),
        );

        await listener.start();
        final abandonedPort = listener.redirectUri.port;

        await expectLater(
          listener.handleCallback(),
          throwsA(isA<OidcCallbackException>()),
        );

        // A fresh attempt on a brand-new server must work normally — proof
        // the timed-out server was actually released rather than left wedged
        // on a single-subscription stream.
        await listener.start();
        expect(listener.redirectUri.port, isNot(abandonedPort));

        final pending = listener.handleCallback();
        final client = http.Client();
        try {
          final res = await client.get(listener.redirectUri);
          expect(res.statusCode, 200);
        } finally {
          client.close();
        }
        final callback = await pending;
        expect(callback.isSuccess, isFalse);
      },
    );

    test('a successful callback still closes the server (redirectUri throws '
        'afterwards)', () async {
      final listener = OidcRedirectListener.testing(
        desktopCallbackTimeout: const Duration(seconds: 5),
      );
      await listener.start();
      final uri = listener.redirectUri;

      final pending = listener.handleCallback();
      final client = http.Client();
      try {
        await client.get(
          uri.replace(queryParameters: {'code': 'abc', 'state': 'xyz'}),
        );
      } finally {
        client.close();
      }
      final callback = await pending;
      expect(callback.code, 'abc');
      expect(callback.state, 'xyz');

      expect(() => listener.redirectUri, throwsStateError);
    });
  });
}
