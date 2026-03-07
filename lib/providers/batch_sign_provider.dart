// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/signature_options.dart';
import '../services/batch_sign/batch_sign_models.dart';
import '../services/batch_sign/batch_sign_service.dart';

class BatchSignNotifier extends Notifier<BatchSignState> {
  late BatchSignService _service;
  StreamSubscription<BatchSignState>? _subscription;

  @override
  BatchSignState build() {
    _service = BatchSignService();
    return const BatchSignState();
  }

  void addFiles(List<String> paths, SignatureFormat format) {
    final newItems = paths.map((path) => BatchSignItem(inputPath: path, format: format)).toList();
    state = state.copyWith(items: [...state.items, ...newItems]);
  }

  void removeAt(int index) {
    if (index >= 0 && index < state.items.length) {
      final updated = [...state.items];
      updated.removeAt(index);
      state = state.copyWith(items: updated);
    }
  }

  void clear() {
    state = const BatchSignState();
  }

  Future<void> start({
    required String pin,
    required String pan,
  }) async {
    _subscription?.cancel();

    _service = BatchSignService();
    state = state.copyWith(isRunning: true);

    _subscription = _service.run(
      items: state.items,
      pin: pin,
      pan: pan,
      outputPathBuilder: (inputPath, format) {
        // Synchronous wrapper - we'll use the async version in a blocking way
        // For batch signing, we resolve paths upfront
        return _resolvePathSync(inputPath, format);
      },
    ).listen(
      (newState) {
        state = newState;
      },
      onError: (error) {
        state = state.copyWith(isRunning: false);
      },
    );
  }

  void cancel() {
    _service.cancel();
  }



  /// Synchronous path resolution (simplified for batch mode).
  /// In production, paths should be pre-resolved before starting the batch.
  String _resolvePathSync(String inputPath, SignatureFormat format) {
    // This is a simplified sync version - in real usage, paths should be
    // resolved asynchronously before calling start()
    final lastSlash = inputPath.lastIndexOf('/');
    final dir = lastSlash >= 0 ? inputPath.substring(0, lastSlash) : '.';
    final fileName = lastSlash >= 0 ? inputPath.substring(lastSlash + 1) : inputPath;

    final baseName = format == SignatureFormat.pades
        ? fileName
        : _stripSignatureExtension(fileName);
    final signedName = format == SignatureFormat.pades
        ? _addSignedSuffix(baseName)
        : '$baseName${format.extension}';

    return '$dir/$signedName';
  }

  String _addSignedSuffix(String name) {
    final lastDot = name.lastIndexOf('.');
    if (lastDot < 0) return '${name}_signed';
    final base = name.substring(0, lastDot);
    final ext = name.substring(lastDot);
    return '${base}_signed$ext';
  }

  String _stripSignatureExtension(String name) {
    const extensions = ['.p7m', '.xml'];
    for (final ext in extensions) {
      if (name.toLowerCase().endsWith(ext)) {
        return name.substring(0, name.length - ext.length);
      }
    }
    return name;
  }
}

final batchSignProvider = NotifierProvider<BatchSignNotifier, BatchSignState>(
  BatchSignNotifier.new,
);
