// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/core/constants/app_constants.dart';
import 'package:opencie/ffi/opencie_pkcs11.dart';
import 'package:opencie/models/signature_options.dart';
import 'package:opencie/services/batch_sign/batch_sign_models.dart';
import 'package:opencie/services/batch_sign/batch_sign_service.dart';
import 'package:opencie/services/sign/sign_backend.dart';
import 'package:opencie/services/sign/signature_upgrader.dart';

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
    Uint8List? imageData,
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

/// Fake [SignatureUpgrader]: records the upgraded paths, no I/O.
class _FakeUpgrader implements SignatureUpgrader {
  _FakeUpgrader({
    this.result = const SignatureUpgradeResult(timestamped: true),
    this.throwError = false,
  });

  final SignatureUpgradeResult result;
  final bool throwError;
  final upgraded = <String>[];

  @override
  Future<SignatureUpgradeResult> upgrade({
    required String path,
    required SignatureFormat format,
    required SignatureUpgradeSettings settings,
  }) async {
    if (throwError) throw StateError('boom');
    upgraded.add(path);
    return result;
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

  group('BatchSignService timestamping', () {
    Future<BatchSignState> runBatch(
      List<BatchSignItem> items,
      _FakeUpgrader upgrader, {
      bool addTimestamp = true,
      Map<String, CieResult> results = const {},
    }) async {
      final service = BatchSignService(
        backend: _FakeSignBackend(resultMap: results),
        upgrader: upgrader,
      );
      final states = <BatchSignState>[];
      await service
          .run(
            items: items,
            pin: '1234',
            pan: '',
            outputPathBuilder: (inputPath, format) => '$inputPath.out',
            addTimestamp: addTimestamp,
          )
          .forEach(states.add);
      return states.last;
    }

    test('upgrades each signed file when addTimestamp is on', () async {
      final upgrader = _FakeUpgrader();
      final state = await runBatch([
        BatchSignItem(inputPath: '/a.pdf', format: SignatureFormat.pades),
        BatchSignItem(inputPath: '/b.pdf', format: SignatureFormat.pades),
      ], upgrader);

      expect(upgrader.upgraded, ['/a.pdf.out', '/b.pdf.out']);
      expect(state.successCount, 2);
      for (final item in state.items) {
        expect(item.timestamped, isTrue);
        expect(item.warning, isNull);
      }
    });

    test('does not upgrade when addTimestamp is off', () async {
      final upgrader = _FakeUpgrader();
      final state = await runBatch(
        [BatchSignItem(inputPath: '/a.pdf', format: SignatureFormat.pades)],
        upgrader,
        addTimestamp: false,
      );

      expect(upgrader.upgraded, isEmpty);
      expect(state.items.single.timestamped, isFalse);
      expect(state.items.single.warning, isNull);
    });

    test('skips XAdES: no upgrade, no warning', () async {
      final upgrader = _FakeUpgrader();
      final state = await runBatch([
        BatchSignItem(inputPath: '/a.xml', format: SignatureFormat.xades),
      ], upgrader);

      expect(upgrader.upgraded, isEmpty);
      expect(state.items.single.status, BatchSignItemStatus.success);
      expect(state.items.single.warning, isNull);
    });

    test('upgrade warning keeps the item successful and records it', () async {
      final upgrader = _FakeUpgrader(
        result: const SignatureUpgradeResult(
          warning: SignatureUpgradeWarning.timestampFailed,
          detail: 'TSA unreachable',
        ),
      );
      final state = await runBatch([
        BatchSignItem(inputPath: '/a.pdf', format: SignatureFormat.pades),
      ], upgrader);

      final item = state.items.single;
      expect(item.status, BatchSignItemStatus.success);
      expect(item.outputPath, '/a.pdf.out');
      expect(item.timestamped, isFalse);
      expect(item.warning, SignatureUpgradeWarning.timestampFailed);
      expect(item.warningDetail, 'TSA unreachable');
    });

    test('an upgrader that throws never fails the item', () async {
      final upgrader = _FakeUpgrader(throwError: true);
      final state = await runBatch([
        BatchSignItem(inputPath: '/a.pdf', format: SignatureFormat.pades),
        BatchSignItem(inputPath: '/b.pdf', format: SignatureFormat.pades),
      ], upgrader);

      expect(state.successCount, 2);
      expect(state.failedCount, 0);
      for (final item in state.items) {
        expect(item.warning, SignatureUpgradeWarning.timestampFailed);
      }
    });

    test('failed signature is never upgraded', () async {
      final upgrader = _FakeUpgrader();
      final state = await runBatch(
        [BatchSignItem(inputPath: '/a.pdf', format: SignatureFormat.pades)],
        upgrader,
        results: {
          '/a.pdf': const CieResult(returnValue: AppConstants.ckrGeneralError),
        },
      );

      expect(upgrader.upgraded, isEmpty);
      expect(state.failedCount, 1);
    });
  });
}
