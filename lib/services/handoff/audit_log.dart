// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// One handoff signing event. Append-only.
class HandoffAuditEntry {
  HandoffAuditEntry({
    required this.timestamp,
    required this.fileName,
    required this.sha256Hex,
    required this.byteSize,
    this.signerCommonName,
    this.signatureFormat,
    this.peerSasWords,
    this.outcome = 'success',
    this.errorMessage,
  });

  final DateTime timestamp;
  final String fileName;
  final String sha256Hex;
  final int byteSize;
  final String? signerCommonName;
  final String? signatureFormat;
  final List<String>? peerSasWords;

  /// 'success' | 'aborted' | 'failed'.
  final String outcome;
  final String? errorMessage;

  Map<String, Object?> toJson() => {
    'ts': timestamp.toUtc().toIso8601String(),
    'file': fileName,
    'sha256': sha256Hex,
    'size': byteSize,
    if (signerCommonName != null) 'cn': signerCommonName,
    if (signatureFormat != null) 'format': signatureFormat,
    if (peerSasWords != null) 'sas': peerSasWords,
    'outcome': outcome,
    if (errorMessage != null) 'error': errorMessage,
  };

  static HandoffAuditEntry fromJson(Map<String, Object?> j) {
    return HandoffAuditEntry(
      timestamp: DateTime.parse(j['ts'] as String).toLocal(),
      fileName: j['file'] as String,
      sha256Hex: j['sha256'] as String,
      byteSize: (j['size'] as num).toInt(),
      signerCommonName: j['cn'] as String?,
      signatureFormat: j['format'] as String?,
      peerSasWords: (j['sas'] as List?)?.cast<String>(),
      outcome: (j['outcome'] as String?) ?? 'success',
      errorMessage: j['error'] as String?,
    );
  }
}

/// Persistent JSON-Lines audit log for desktop handoff signing events.
///
/// File: `<applicationDocumentsDirectory>/handoff_audit.log`.
/// Each line is a single JSON object. Atomic-ish appends via `IOSink`.
class HandoffAuditLog {
  HandoffAuditLog._();

  static const _fileName = 'handoff_audit.log';

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, _fileName));
  }

  /// Append a single entry. Best-effort; swallows IO errors so a failed
  /// audit write never blocks a successful signature flow.
  static Future<void> append(HandoffAuditEntry entry) async {
    try {
      final f = await _file();
      await f.parent.create(recursive: true);
      final line = '${jsonEncode(entry.toJson())}\n';
      await f.writeAsString(line, mode: FileMode.append, flush: true);
    } catch (_) {
      // Audit failure must not break signing UX.
    }
  }

  /// Read all entries, newest first. Returns an empty list if the file is
  /// missing or any line fails to parse (skip malformed lines silently).
  static Future<List<HandoffAuditEntry>> readAll() async {
    try {
      final f = await _file();
      if (!await f.exists()) return const [];
      final lines = await f.readAsLines();
      final out = <HandoffAuditEntry>[];
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final j = jsonDecode(line) as Map<String, Object?>;
          out.add(HandoffAuditEntry.fromJson(j));
        } catch (_) {
          // Skip corrupt line.
        }
      }
      return out.reversed.toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// Wipe the log. Used by privacy controls (e.g. Settings → Clear audit log).
  static Future<void> clear() async {
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
