// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/foundation.dart';

import '../../ffi/opencie_pkcs11.dart';
import '../../models/signature_options.dart';

/// Abstract interface for signing operations.
abstract class SignBackend {
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
  });
}

/// Production implementation using OpenCiePkcs11.
class Pkcs11SignBackend implements SignBackend {
  Pkcs11SignBackend([OpenCiePkcs11? pkcs11]) : _pkcs11 = pkcs11 ?? OpenCiePkcs11.instance;

  final OpenCiePkcs11 _pkcs11;

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
  }) {
    return _pkcs11.sign(
      inputPath: inputPath,
      outputPath: outputPath,
      signatureType: format.nativeType,
      pin: pin,
      pan: pan,
      page: page,
      x: x,
      y: y,
      w: w,
      h: h,
      onProgress: onProgress,
    );
  }
}
