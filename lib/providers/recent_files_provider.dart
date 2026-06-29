// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

const _kMaxRecent = 15;
const _kPrefsKey = 'opencie_recent_verify_files';

class RecentFile {
  const RecentFile({required this.path, required this.addedAt});

  final String path;
  final DateTime addedAt;

  String get fileName => path.split(Platform.pathSeparator).last;

  String get extension {
    final dot = fileName.lastIndexOf('.');
    return dot >= 0 ? fileName.substring(dot + 1).toUpperCase() : '';
  }

  Map<String, dynamic> toJson() => {
    'path': path,
    'addedAt': addedAt.toIso8601String(),
  };

  static RecentFile fromJson(Map<String, dynamic> m) => RecentFile(
    path: m['path'] as String,
    addedAt: DateTime.parse(m['addedAt'] as String),
  );
}

class RecentFilesNotifier extends Notifier<List<RecentFile>> {
  RecentFilesNotifier(this._key);

  final String _key;

  @override
  List<RecentFile> build() {
    Future.microtask(load);
    return const [];
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List)
          .whereType<Map<String, dynamic>>()
          .map(RecentFile.fromJson)
          .toList();
      state = list;
    } catch (e) {
      // Intentional fallback: corrupt or schema-mismatched JSON is discarded so
      // a bad persistence entry never breaks the app on launch.
      debugPrint(
        'RecentFilesNotifier.load[$_key]: corrupt JSON, resetting to empty: $e',
      );
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(state.map((f) => f.toJson()).toList()),
    );
  }

  void add(String path) {
    final updated = [
      RecentFile(path: path, addedAt: DateTime.now()),
      ...state.where((f) => f.path != path),
    ];
    state = updated.take(_kMaxRecent).toList();
    _save();
  }

  void clear() {
    state = const [];
    _save();
  }
}

final recentFilesProvider =
    NotifierProvider<RecentFilesNotifier, List<RecentFile>>(
      () => RecentFilesNotifier(_kPrefsKey),
    );

/// Holds a file path that the verify page should open immediately.
/// Sign page writes here before navigating to /verify.
class _PendingVerifyFileNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  // ignore: use_setters_to_change_properties
  void set(String? value) => state = value;
}

final pendingVerifyFileProvider =
    NotifierProvider<_PendingVerifyFileNotifier, String?>(
      _PendingVerifyFileNotifier.new,
    );

const _kSignedPrefsKey = 'opencie_recent_sign_files';

final recentSignedFilesProvider =
    NotifierProvider<RecentFilesNotifier, List<RecentFile>>(
      () => RecentFilesNotifier(_kSignedPrefsKey),
    );
