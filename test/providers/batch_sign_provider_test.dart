// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:opencie/core/constants/app_constants.dart';
import 'package:opencie/ffi/opencie_pkcs11.dart';
import 'package:opencie/models/signature_options.dart';
import 'package:opencie/providers/batch_sign_provider.dart';
import 'package:opencie/providers/settings_provider.dart';
import 'package:opencie/providers/sign_backend_provider.dart';
import 'package:opencie/services/batch_sign/batch_sign_models.dart';
import 'package:opencie/services/sign/sign_backend.dart';
import 'package:opencie/services/sign/signature_upgrader.dart';

class _OkBackend implements SignBackend {
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
  }) async => const CieResult(returnValue: AppConstants.ckrOk);
}

class _RecordingUpgrader implements SignatureUpgrader {
  final paths = <String>[];
  final settingsSeen = <SignatureUpgradeSettings>[];

  @override
  Future<SignatureUpgradeResult> upgrade({
    required String path,
    required SignatureFormat format,
    required SignatureUpgradeSettings settings,
  }) async {
    paths.add(path);
    settingsSeen.add(settings);
    return const SignatureUpgradeResult(timestamped: true);
  }
}

Future<ProviderContainer> _container(
  _RecordingUpgrader upgrader, {
  required bool alwaysTimestamp,
}) async {
  SharedPreferences.setMockInitialValues({
    'opencie_settings': jsonEncode({
      'alwaysTimestamp': alwaysTimestamp,
      'validationType': ValidationType.crlOnly.name,
    }),
  });
  FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
  final container = ProviderContainer(
    overrides: [
      signBackendProvider.overrideWithValue(_OkBackend()),
      signatureUpgraderProvider.overrideWithValue(upgrader),
    ],
  );
  addTearDown(container.dispose);

  final loaded = Completer<void>();
  container.listen(settingsProvider, (_, s) {
    if (s.isLoaded && !loaded.isCompleted) loaded.complete();
  }, fireImmediately: true);
  await loaded.future.timeout(const Duration(seconds: 5));
  return container;
}

Future<BatchSignState> _runBatch(ProviderContainer container) async {
  final notifier = container.read(batchSignProvider.notifier);
  notifier.addFiles(['/tmp/opencie_batch/a.pdf'], SignatureFormat.pades);
  final done = Completer<BatchSignState>();
  container.listen(batchSignProvider, (_, s) {
    if (!s.isRunning &&
        s.items.isNotEmpty &&
        s.items.every((i) => i.status == BatchSignItemStatus.success) &&
        !done.isCompleted) {
      done.complete(s);
    }
  });
  await notifier.start(pin: '1234', pan: '');
  return done.future.timeout(const Duration(seconds: 5));
}

void main() {
  group('BatchSignNotifier timestamping', () {
    test(
      'alwaysTimestamp upgrades each file with the stored settings',
      () async {
        final upgrader = _RecordingUpgrader();
        final container = await _container(upgrader, alwaysTimestamp: true);

        final state = await _runBatch(container);

        expect(upgrader.paths, ['/tmp/opencie_batch/a_signed.pdf']);
        expect(
          upgrader.settingsSeen.single.validationType,
          ValidationType.crlOnly,
        );
        expect(state.items.single.timestamped, isTrue);
      },
    );

    test('alwaysTimestamp off: nothing is upgraded', () async {
      final upgrader = _RecordingUpgrader();
      final container = await _container(upgrader, alwaysTimestamp: false);

      final state = await _runBatch(container);

      expect(upgrader.paths, isEmpty);
      expect(state.items.single.timestamped, isFalse);
    });
  });
}
