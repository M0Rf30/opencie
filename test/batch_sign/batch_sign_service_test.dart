// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/core/constants/app_constants.dart';
import 'package:opencie/ffi/opencie_pkcs11.dart';
import 'package:opencie/models/signature_options.dart';
import 'package:opencie/services/batch_sign/batch_sign_models.dart';
import 'package:opencie/services/batch_sign/batch_sign_service.dart';
import 'package:opencie/services/sign/sign_backend.dart';

/// Fake implementation of SignBackend for testing.
class _FakeSignBackend implements SignBackend {
  _FakeSignBackend({this.resultMap = const {}});

  /// Map of input file paths to CieResult to return.
  final Map<String, CieResult> resultMap;

  @override
  Future<CieResult> sign({
    required String inputPath,
    required String outputPath,
    required SignatureFormat format,
    required String pin,
    required String pan,
    int page = 0,
    double x = 0,
    double y = 0,
    double w = 0,
    double h = 0,
    ValueChanged<CieProgress>? onProgress,
  }) async {
    // Simulate progress callbacks
    if (onProgress != null) {
      onProgress(const CieProgress(percent: 25, message: 'Starting...'));
      onProgress(const CieProgress(percent: 50, message: 'Processing...'));
      onProgress(const CieProgress(percent: 75, message: 'Finalizing...'));
      onProgress(const CieProgress(percent: 100, message: 'Done'));
    }

    return resultMap[inputPath] ??
        const CieResult(returnValue: AppConstants.ckrOk);
  }
}

void main() {
  group('BatchSignService', () {
    test('All success: 3 items all return success', () async {
      final items = [
        BatchSignItem(
          inputPath: '/path/file1.pdf',
          format: SignatureFormat.pades,
        ),
        BatchSignItem(
          inputPath: '/path/file2.pdf',
          format: SignatureFormat.pades,
        ),
        BatchSignItem(
          inputPath: '/path/file3.pdf',
          format: SignatureFormat.pades,
        ),
      ];

      final backend = _FakeSignBackend(
        resultMap: {
          '/path/file1.pdf': const CieResult(returnValue: AppConstants.ckrOk),
          '/path/file2.pdf': const CieResult(returnValue: AppConstants.ckrOk),
          '/path/file3.pdf': const CieResult(returnValue: AppConstants.ckrOk),
        },
      );

      final service = BatchSignService(backend: backend);
      final states = <BatchSignState>[];

      await service
          .run(
            items: items,
            pin: '1234',
            pan: '',
            outputPathBuilder: (inputPath, format) =>
                inputPath.replaceAll('.pdf', '_signed.pdf'),
          )
          .forEach((state) => states.add(state));

      // Verify final state
      expect(states.isNotEmpty, true);
      final finalState = states.last;
      expect(finalState.successCount, 3);
      expect(finalState.failedCount, 0);
      expect(finalState.skippedCount, 0);
      expect(finalState.isRunning, false);

      // Verify all items are success
      for (final item in finalState.items) {
        expect(item.status, BatchSignItemStatus.success);
      }
    });

    test('PIN incorrect on first item aborts batch', () async {
      final items = [
        BatchSignItem(
          inputPath: '/path/file1.pdf',
          format: SignatureFormat.pades,
        ),
        BatchSignItem(
          inputPath: '/path/file2.pdf',
          format: SignatureFormat.pades,
        ),
        BatchSignItem(
          inputPath: '/path/file3.pdf',
          format: SignatureFormat.pades,
        ),
      ];

      final backend = _FakeSignBackend(
        resultMap: {
          '/path/file1.pdf': const CieResult(
            returnValue: AppConstants.ckrPinIncorrect,
          ),
          '/path/file2.pdf': const CieResult(returnValue: AppConstants.ckrOk),
          '/path/file3.pdf': const CieResult(returnValue: AppConstants.ckrOk),
        },
      );

      final service = BatchSignService(backend: backend);
      final states = <BatchSignState>[];

      await service
          .run(
            items: items,
            pin: 'wrong',
            pan: '',
            outputPathBuilder: (inputPath, format) =>
                inputPath.replaceAll('.pdf', '_signed.pdf'),
          )
          .forEach((state) => states.add(state));

      final finalState = states.last;
      expect(finalState.items[0].status, BatchSignItemStatus.failed);
      expect(finalState.items[1].status, BatchSignItemStatus.skipped);
      expect(finalState.items[2].status, BatchSignItemStatus.skipped);
      expect(finalState.isRunning, false);
    });

    test('PIN locked on first item aborts batch', () async {
      final items = [
        BatchSignItem(
          inputPath: '/path/file1.pdf',
          format: SignatureFormat.pades,
        ),
        BatchSignItem(
          inputPath: '/path/file2.pdf',
          format: SignatureFormat.pades,
        ),
      ];

      final backend = _FakeSignBackend(
        resultMap: {
          '/path/file1.pdf': const CieResult(
            returnValue: AppConstants.ckrPinLocked,
          ),
          '/path/file2.pdf': const CieResult(returnValue: AppConstants.ckrOk),
        },
      );

      final service = BatchSignService(backend: backend);
      final states = <BatchSignState>[];

      await service
          .run(
            items: items,
            pin: '1234',
            pan: '',
            outputPathBuilder: (inputPath, format) =>
                inputPath.replaceAll('.pdf', '_signed.pdf'),
          )
          .forEach((state) => states.add(state));

      final finalState = states.last;
      expect(finalState.items[0].status, BatchSignItemStatus.failed);
      expect(finalState.items[1].status, BatchSignItemStatus.skipped);
    });

    test('Generic failure on item 2 continues with item 3', () async {
      final items = [
        BatchSignItem(
          inputPath: '/path/file1.pdf',
          format: SignatureFormat.pades,
        ),
        BatchSignItem(
          inputPath: '/path/file2.pdf',
          format: SignatureFormat.pades,
        ),
        BatchSignItem(
          inputPath: '/path/file3.pdf',
          format: SignatureFormat.pades,
        ),
      ];

      final backend = _FakeSignBackend(
        resultMap: {
          '/path/file1.pdf': const CieResult(returnValue: AppConstants.ckrOk),
          '/path/file2.pdf': const CieResult(
            returnValue: AppConstants.ckrGeneralError,
          ),
          '/path/file3.pdf': const CieResult(returnValue: AppConstants.ckrOk),
        },
      );

      final service = BatchSignService(backend: backend);
      final states = <BatchSignState>[];

      await service
          .run(
            items: items,
            pin: '1234',
            pan: '',
            outputPathBuilder: (inputPath, format) =>
                inputPath.replaceAll('.pdf', '_signed.pdf'),
          )
          .forEach((state) => states.add(state));

      final finalState = states.last;
      expect(finalState.items[0].status, BatchSignItemStatus.success);
      expect(finalState.items[1].status, BatchSignItemStatus.failed);
      expect(finalState.items[2].status, BatchSignItemStatus.success);
      expect(finalState.successCount, 2);
      expect(finalState.failedCount, 1);
    });

    test('Batch completes with final state not running', () async {
      final items = [
        BatchSignItem(
          inputPath: '/path/file1.pdf',
          format: SignatureFormat.pades,
        ),
        BatchSignItem(
          inputPath: '/path/file2.pdf',
          format: SignatureFormat.pades,
        ),
      ];

      final backend = _FakeSignBackend(
        resultMap: {
          '/path/file1.pdf': const CieResult(returnValue: AppConstants.ckrOk),
          '/path/file2.pdf': const CieResult(returnValue: AppConstants.ckrOk),
        },
      );

      final service = BatchSignService(backend: backend);
      final states = <BatchSignState>[];

      await service
          .run(
            items: items,
            pin: '1234',
            pan: '',
            outputPathBuilder: (inputPath, format) =>
                inputPath.replaceAll('.pdf', '_signed.pdf'),
          )
          .forEach((state) => states.add(state));

      final finalState = states.last;
      expect(finalState.isRunning, false);
      expect(finalState.successCount, 2);
    });
  });
}
