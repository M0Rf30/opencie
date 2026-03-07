// SPDX-License-Identifier: GPL-3.0-or-later

import '../../models/signature_options.dart';
import '../sign/sign_backend.dart';
import 'batch_sign_models.dart';

/// Service for batch signing operations.
/// Streams BatchSignState updates as files are signed sequentially.
class BatchSignService {
  BatchSignService({SignBackend? backend})
      : _backend = backend ?? Pkcs11SignBackend();

  final SignBackend _backend;
  bool _cancelled = false;

  /// Streams BatchSignState updates as the batch progresses.
  /// Cancellation is cooperative: caller calls cancel() and the loop stops
  /// after the currently-signing file completes.
  Stream<BatchSignState> run({
    required List<BatchSignItem> items,
    required String pin,
    required String pan,
    required String Function(String inputPath, SignatureFormat fmt) outputPathBuilder,
  }) async* {
    _cancelled = false;

    var state = BatchSignState(items: items, isRunning: true);
    yield state;

    for (int i = 0; i < items.length; i++) {
      if (_cancelled) {
        // Mark remaining as cancelled
        final updatedItems = [
          ...state.items.sublist(0, i),
          ...state.items.sublist(i).map((item) => item.copyWith(status: BatchSignItemStatus.cancelled)),
        ];
        yield state.copyWith(items: updatedItems, isRunning: false);
        break;
      }

      final item = items[i];
      final outputPath = outputPathBuilder(item.inputPath, item.format);

      // Update to signing status
      var updatedItems = [
        ...state.items.sublist(0, i),
        item.copyWith(status: BatchSignItemStatus.signing),
        ...state.items.sublist(i + 1),
      ];
      state = state.copyWith(items: updatedItems, currentIndex: i);
      yield state;

      // Call sign with progress callback
      try {
        final result = await _backend.sign(
          inputPath: item.inputPath,
          outputPath: outputPath,
          format: item.format,
          pin: pin,
          pan: pan,
          onProgress: (progress) {
            // Update progress for current item
            final progressRatio = progress.percent / 100.0;
            updatedItems = [
              ...state.items.sublist(0, i),
              item.copyWith(
                status: BatchSignItemStatus.signing,
                progress: progressRatio,
                message: progress.message,
              ),
              ...state.items.sublist(i + 1),
            ];
            // Note: we don't yield here to avoid too many updates
            // The final state update below will reflect the last progress
          },
        );

        if (result.isSuccess) {
          // Success
          updatedItems = [
            ...state.items.sublist(0, i),
            item.copyWith(
              status: BatchSignItemStatus.success,
              progress: 1.0,
              outputPath: outputPath,
            ),
            ...state.items.sublist(i + 1),
          ];
          state = state.copyWith(items: updatedItems);
          yield state;
        } else if (result.isPinIncorrect) {
          // PIN incorrect - abort batch
          updatedItems = [
            ...state.items.sublist(0, i),
            item.copyWith(
              status: BatchSignItemStatus.failed,
              errorCode: result.returnValue,
              message: 'PIN incorrect',
            ),
            ...state.items.sublist(i + 1).map((it) => it.copyWith(status: BatchSignItemStatus.skipped)),
          ];
          state = state.copyWith(items: updatedItems, isRunning: false);
          yield state;
          break;
        } else if (result.isPinLocked) {
          // PIN locked - abort batch
          updatedItems = [
            ...state.items.sublist(0, i),
            item.copyWith(
              status: BatchSignItemStatus.failed,
              errorCode: result.returnValue,
              message: 'PIN locked',
            ),
            ...state.items.sublist(i + 1).map((it) => it.copyWith(status: BatchSignItemStatus.skipped)),
          ];
          state = state.copyWith(items: updatedItems, isRunning: false);
          yield state;
          break;
        } else {
          // Generic failure - continue with next file
          updatedItems = [
            ...state.items.sublist(0, i),
            item.copyWith(
              status: BatchSignItemStatus.failed,
              errorCode: result.returnValue,
              message: 'Error code: ${result.returnValue}',
            ),
            ...state.items.sublist(i + 1),
          ];
          state = state.copyWith(items: updatedItems);
          yield state;
        }
      } catch (e) {
        // Exception during signing
        updatedItems = [
          ...state.items.sublist(0, i),
          item.copyWith(
            status: BatchSignItemStatus.failed,
            message: e.toString(),
          ),
          ...state.items.sublist(i + 1),
        ];
        state = state.copyWith(items: updatedItems);
        yield state;
      }
    }

    // Final state: not running
    state = state.copyWith(isRunning: false, currentIndex: -1);
    yield state;
  }

  /// Signal cooperative stop. The current file will complete, then remaining
  /// files will be marked as cancelled.
  void cancel() {
    _cancelled = true;
  }
}
