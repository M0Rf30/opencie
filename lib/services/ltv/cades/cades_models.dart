// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import '../crl/crl_models.dart';
import '../ocsp/ocsp_models.dart';

/// Validation material to embed into a CAdES signature for long-term validity.
class ValidationMaterial {
  ValidationMaterial({
    this.certificates = const [],     // Each entry is a DER-encoded X.509 Certificate
    this.crls = const [],             // CrlData (we'll use rawCrl)
    this.ocspResponses = const [],    // OcspResponse (we'll extract BasicOCSPResponse)
  });

  final List<Uint8List> certificates;
  final List<CrlData> crls;
  final List<OcspResponse> ocspResponses;

  bool get isEmpty => certificates.isEmpty && crls.isEmpty && ocspResponses.isEmpty;
}

class CadesException implements Exception {
  CadesException(this.message);
  final String message;
  @override
  String toString() => 'CadesException: $message';
}
