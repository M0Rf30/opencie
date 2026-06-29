// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import '../crl/crl_models.dart';
import '../ocsp/ocsp_models.dart';

/// Validation material to embed in PDF DSS.
class PdfValidationMaterial {
  PdfValidationMaterial({
    this.certificates = const [], // DER bytes per cert
    this.crls = const [],
    this.ocspResponses = const [],
  });
  final List<Uint8List> certificates;
  final List<CrlData> crls;
  final List<OcspResponse> ocspResponses;

  bool get isEmpty =>
      certificates.isEmpty && crls.isEmpty && ocspResponses.isEmpty;
}

class PadesException implements Exception {
  PadesException(this.message);
  final String message;
  @override
  String toString() => 'PadesException: $message';
}
