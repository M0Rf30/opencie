// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/core/constants/app_constants.dart';
import 'package:opencie/ffi/opencie_pkcs11.dart';
import 'package:opencie/models/signature_options.dart';
import 'package:opencie/providers/sign_backend_provider.dart';
import 'package:opencie/services/sign/sign_backend.dart';

/// Minimal fake [SignBackend] for provider override testing.
class _FakeSignBackend implements SignBackend {
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

void main() {
  group('signBackendProvider', () {
    test('resolves to Pkcs11SignBackend by default', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final backend = container.read(signBackendProvider);

      expect(backend, isA<Pkcs11SignBackend>());
      expect(backend, isA<SignBackend>());
    });

    test('can be overridden with a fake SignBackend', () {
      final fake = _FakeSignBackend();
      final container = ProviderContainer(
        overrides: [signBackendProvider.overrideWithValue(fake)],
      );
      addTearDown(container.dispose);

      final backend = container.read(signBackendProvider);

      expect(backend, same(fake));
      expect(backend, isA<SignBackend>());
    });
  });
}
