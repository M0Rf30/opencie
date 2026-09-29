// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/signature_options.dart';
import '../services/batch_sign/batch_sign_models.dart';
import '../services/batch_sign/batch_sign_service.dart';
import '../services/sign/output_path_resolver.dart';

class BatchSignNotifier extends Notifier<BatchSignState> {
  late BatchSignService _service;
  StreamSubscription<BatchSignState>? _subscription;

  @override
  BatchSignState build() {
    _service = BatchSignService();
    return const BatchSignState();
  }

  void addFiles(List<String> paths, SignatureFormat format) {
    final newItems = paths
        .map((path) => BatchSignItem(inputPath: path, format: format))
        .toList();
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

  Future<void> start({required String pin, required String pan}) async {
    _subscription?.cancel();

    _service = BatchSignService();
    state = state.copyWith(isRunning: true);

    final items = state.items;
    // Pre-resolve every output path asynchronously (via the shared
    // `resolveSignedOutputPath`, which uses package:path and knows about
    // Android's app-private documents directory) since the batch service's
    // `outputPathBuilder` callback itself must stay synchronous.
    final outputPaths = <String, String>{};
    for (final item in items) {
      outputPaths[_pathKey(item.inputPath, item.format)] =
          await resolveSignedOutputPath(item.inputPath, item.format);
    }

    _subscription = _service
        .run(
          items: items,
          pin: pin,
          pan: pan,
          outputPathBuilder: (inputPath, format) {
            final key = _pathKey(inputPath, format);
            final resolved = outputPaths[key];
            assert(
              resolved != null,
              'output path was not pre-resolved for $inputPath ($format)',
            );
            return resolved ?? inputPath;
          },
        )
        .listen(
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

  String _pathKey(String inputPath, SignatureFormat format) =>
      '$inputPath::${format.name}';
}

final batchSignProvider = NotifierProvider<BatchSignNotifier, BatchSignState>(
  BatchSignNotifier.new,
);
