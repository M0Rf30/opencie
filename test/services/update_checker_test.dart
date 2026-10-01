// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opencie/services/update_checker.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _payload(String tag) => jsonEncode({
  'tag_name': tag,
  'html_url': 'https://github.com/M0Rf30/opencie/releases/tag/$tag',
  'published_at': '2026-09-01T10:00:00Z',
});

void main() {
  group('compareVersions', () {
    test('numeric ordering', () {
      expect(UpdateChecker.compareVersions('0.4.10', '0.4.3'), greaterThan(0));
      expect(UpdateChecker.compareVersions('0.4.3', '0.4.10'), lessThan(0));
      expect(UpdateChecker.compareVersions('1.0.0', '1.0.0'), 0);
      expect(UpdateChecker.compareVersions('1.0.0', '0.99.99'), greaterThan(0));
    });

    test('v prefix and build metadata are ignored', () {
      expect(UpdateChecker.compareVersions('v0.5.0', '0.5.0'), 0);
      expect(UpdateChecker.compareVersions('0.5.0+7', '0.5.0+3'), 0);
      expect(
        UpdateChecker.compareVersions('0.5.1+1', '0.5.0+9'),
        greaterThan(0),
      );
    });

    test('pre-release is lower than the release', () {
      expect(UpdateChecker.compareVersions('0.5.0-rc1', '0.5.0'), lessThan(0));
      expect(
        UpdateChecker.compareVersions('0.5.0', '0.5.0-rc1'),
        greaterThan(0),
      );
      expect(
        UpdateChecker.compareVersions('0.5.1-rc1', '0.5.0'),
        greaterThan(0),
      );
    });

    test('garbage is never newer', () {
      expect(UpdateChecker.compareVersions('abc', '0.1.0'), 0);
      expect(UpdateChecker.compareVersions('1.2', '0.1.0'), 0);
      expect(UpdateChecker.compareVersions('1.x.0', '0.1.0'), 0);
      expect(UpdateChecker.compareVersions('', ''), 0);
    });
  });

  group('fetchLatest', () {
    test('parses a sample payload', () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response(_payload('v0.5.0'), 200);
      });
      final info = await UpdateChecker.fetchLatest(
        client: client,
        appVersion: '0.4.3',
      );
      expect(info, isNotNull);
      expect(info!.version, '0.5.0');
      expect(info.url, contains('/releases/tag/v0.5.0'));
      expect(info.publishedAt, DateTime.utc(2026, 9, 1, 10));
      expect(seen.headers['Accept'], 'application/vnd.github+json');
      expect(seen.headers['User-Agent'], 'OpenCIE/0.4.3');
    });

    test('returns null on 404', () async {
      final client = MockClient((_) async => http.Response('nope', 404));
      expect(await UpdateChecker.fetchLatest(client: client), isNull);
    });

    test('returns null on bad JSON', () async {
      final client = MockClient((_) async => http.Response('{not json', 200));
      expect(await UpdateChecker.fetchLatest(client: client), isNull);
    });

    test('returns null on missing fields', () async {
      final client = MockClient((_) async => http.Response('{}', 200));
      expect(await UpdateChecker.fetchLatest(client: client), isNull);
    });

    test('returns null on network error', () async {
      final client = MockClient((_) async => throw TimeoutException('slow'));
      expect(await UpdateChecker.fetchLatest(client: client), isNull);
    });
  });

  group('checkIfDue', () {
    late int requests;
    late MockClient client;
    var clock = DateTime.utc(2026, 10, 1, 12);

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      requests = 0;
      clock = DateTime.utc(2026, 10, 1, 12);
      client = MockClient((_) async {
        requests++;
        return http.Response(_payload('v0.5.0'), 200);
      });
    });

    Future<UpdateInfo?> run({bool force = false}) => UpdateChecker.checkIfDue(
      force: force,
      client: client,
      now: () => clock,
      currentVersion: '0.4.3',
    );

    test('returns info only when latest is newer', () async {
      expect((await run())?.version, '0.5.0');
      clock = clock.add(const Duration(hours: 25));
      final same = await UpdateChecker.checkIfDue(
        client: client,
        now: () => clock,
        currentVersion: '0.5.0',
      );
      expect(same, isNull);
    });

    test(
      'throttles automatic checks to once per 24h; force bypasses',
      () async {
        await run();
        expect(requests, 1);

        clock = clock.add(const Duration(hours: 1));
        expect(await run(), isNull);
        expect(requests, 1);

        expect(await run(force: true), isNotNull);
        expect(requests, 2);

        clock = clock.add(const Duration(hours: 25));
        await run();
        expect(requests, 3);
      },
    );

    test(
      'dismissed version is suppressed automatically, not when forced',
      () async {
        await UpdateChecker.dismiss('0.5.0');
        expect(await run(), isNull);
        expect(requests, 1);

        final forced = await run(force: true);
        expect(forced?.version, '0.5.0');
      },
    );

    test('a newer release than the dismissed one still prompts', () async {
      await UpdateChecker.dismiss('0.4.9');
      expect((await run())?.version, '0.5.0');
    });
  });
}
