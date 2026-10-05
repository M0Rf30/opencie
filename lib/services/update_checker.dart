// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How the running copy of the app was distributed.
enum UpdateChannel { flatpak, android, windows, macos, linuxTarball }

/// Latest published release metadata.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.url,
    this.publishedAt,
  });

  /// Version without a leading `v`.
  final String version;

  /// Release page (`html_url`).
  final String url;
  final DateTime? publishedAt;
}

/// Checks GitHub for a newer release. Never throws.
class UpdateChecker {
  const UpdateChecker._();

  static const releasesUrl =
      'https://api.github.com/repos/M0Rf30/opencie/releases/latest';
  static const lastCheckKey = 'update_check_last_ms';
  static const dismissedKey = 'update_dismissed_version';
  static const checkInterval = Duration(hours: 24);
  static const _timeout = Duration(seconds: 10);

  /// Detects the distribution channel at runtime.
  static UpdateChannel detectChannel() {
    if (Platform.isAndroid) return UpdateChannel.android;
    if (Platform.isWindows) return UpdateChannel.windows;
    if (Platform.isMacOS) return UpdateChannel.macos;
    if (Platform.environment['FLATPAK_ID'] != null) {
      return UpdateChannel.flatpak;
    }
    return UpdateChannel.linuxTarball;
  }

  /// Fetches the latest release, or null on any failure.
  static Future<UpdateInfo?> fetchLatest({
    http.Client? client,
    String appVersion = 'unknown',
  }) async {
    final c = client ?? http.Client();
    try {
      final res = await c
          .get(
            Uri.parse(releasesUrl),
            headers: {
              'Accept': 'application/vnd.github+json',
              // No version: the comparison happens locally, so GitHub
              // doesn't need to learn which release this user runs.
              'User-Agent': 'OpenCIE',
            },
          )
          .timeout(_timeout);
      if (res.statusCode != 200) {
        debugPrint('UpdateChecker: HTTP ${res.statusCode}');
        return null;
      }
      final json = jsonDecode(utf8.decode(res.bodyBytes));
      if (json is! Map) return null;
      final tag = json['tag_name'];
      final url = json['html_url'];
      if (tag is! String || url is! String || tag.isEmpty) return null;
      final published = json['published_at'];
      return UpdateInfo(
        version: tag.startsWith('v') ? tag.substring(1) : tag,
        url: url,
        publishedAt: published is String ? DateTime.tryParse(published) : null,
      );
    } catch (e) {
      debugPrint('UpdateChecker: fetch failed: $e');
      return null;
    } finally {
      if (client == null) c.close();
    }
  }

  /// Parses `major.minor.patch[-pre][+build]`; null when malformed.
  static ({List<int> core, bool pre})? _parse(String raw) {
    var s = raw.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    final plus = s.indexOf('+');
    if (plus >= 0) s = s.substring(0, plus);
    var pre = false;
    final dash = s.indexOf('-');
    if (dash >= 0) {
      pre = true;
      s = s.substring(0, dash);
    }
    final parts = s.split('.');
    if (parts.length != 3) return null;
    final nums = <int>[];
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null || n < 0) return null;
      nums.add(n);
    }
    return (core: nums, pre: pre);
  }

  /// Returns >0 if [a] is newer than [b], <0 if older, 0 if equal.
  /// Unparseable input yields 0 so callers never prompt on doubt.
  static int compareVersions(String a, String b) {
    final pa = _parse(a);
    final pb = _parse(b);
    if (pa == null || pb == null) return 0;
    for (var i = 0; i < 3; i++) {
      final d = pa.core[i].compareTo(pb.core[i]);
      if (d != 0) return d;
    }
    if (pa.pre == pb.pre) return 0;
    return pa.pre ? -1 : 1;
  }

  /// Checks for an update. Automatic checks (`force == false`) are throttled
  /// to once per 24 h and skip a dismissed version.
  static Future<UpdateInfo?> checkIfDue({
    bool force = false,
    http.Client? client,
    DateTime Function()? now,
    String? currentVersion,
    SharedPreferences? prefs,
  }) async {
    try {
      final p = prefs ?? await SharedPreferences.getInstance();
      final nowMs = (now ?? DateTime.now)().millisecondsSinceEpoch;
      if (!force) {
        final last = p.getInt(lastCheckKey);
        if (last != null &&
            nowMs >= last &&
            nowMs - last < checkInterval.inMilliseconds) {
          return null;
        }
      }
      final current =
          currentVersion ?? (await PackageInfo.fromPlatform()).version;
      await p.setInt(lastCheckKey, nowMs);
      final latest = await fetchLatest(client: client, appVersion: current);
      if (latest == null) return null;
      if (compareVersions(latest.version, current) <= 0) return null;
      if (!force && p.getString(dismissedKey) == latest.version) return null;
      return latest;
    } catch (e) {
      debugPrint('UpdateChecker: check failed: $e');
      return null;
    }
  }

  /// Records that the user dismissed [version].
  static Future<void> dismiss(
    String version, {
    SharedPreferences? prefs,
  }) async {
    try {
      final p = prefs ?? await SharedPreferences.getInstance();
      await p.setString(dismissedKey, version);
    } catch (e) {
      debugPrint('UpdateChecker: dismiss failed: $e');
    }
  }
}

/// Outcome of a manual check.
enum ManualCheckStatus { upToDate, available, failed }

extension ManualCheck on UpdateChecker {
  /// Forced check that distinguishes "up to date" from "failed".
  static Future<({ManualCheckStatus status, UpdateInfo? info})> run({
    http.Client? client,
    String? currentVersion,
  }) async {
    try {
      final current =
          currentVersion ?? (await PackageInfo.fromPlatform()).version;
      final latest = await UpdateChecker.fetchLatest(
        client: client,
        appVersion: current,
      );
      if (latest == null) {
        return (status: ManualCheckStatus.failed, info: null);
      }
      if (UpdateChecker.compareVersions(latest.version, current) > 0) {
        return (status: ManualCheckStatus.available, info: latest);
      }
      return (status: ManualCheckStatus.upToDate, info: null);
    } catch (e) {
      debugPrint('UpdateChecker: manual check failed: $e');
      return (status: ManualCheckStatus.failed, info: null);
    }
  }
}
