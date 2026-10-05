// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import '../core/constants/app_constants.dart';

enum SignatureFormat {
  pades(AppConstants.formatPades, 'PAdES (PDF)', '.pdf'),
  cades(AppConstants.formatCades, 'CAdES (.p7m)', '.p7m'),
  xades(AppConstants.formatXades, 'XAdES (XML)', '.xml');

  const SignatureFormat(this.nativeType, this.displayName, this.extension);

  final String nativeType;
  final String displayName;
  final String extension;

  /// Whether the post-sign LTV/timestamp upgrade (PAdES-LT/LTA, CAdES-LT/LTA)
  /// exists for this format. There is no XAdES upgrader, so a timestamp
  /// cannot be applied to `.xml` signatures.
  bool get supportsTimestamp => this != SignatureFormat.xades;
}

class SignatureOptions {
  const SignatureOptions({
    this.format = SignatureFormat.pades,
    this.graphicSignature = false,
    this.page = 0,
    this.x = 0.02,
    this.y = 0.02,
    this.width = 0.50,
    this.height = 0.095,
    this.imageData,
    this.addTimestamp = false,
    this.alignedFieldName,
  });

  final SignatureFormat format;
  final bool graphicSignature;
  final int page;
  final double x;
  final double y;
  final double width;
  final double height;

  /// Name of the AcroForm signature field this placement was snapped to,
  /// or null for free placement. UI metadata only — the native signer
  /// always creates a brand-new signature field, so this does not change
  /// what gets passed to the sign call.
  final String? alignedFieldName;
  final Uint8List? imageData;
  final bool addTimestamp;

  /// Whether a timestamp will actually be requested for this signature:
  /// the toggle is on and the format can carry one.
  bool get timestampRequested => addTimestamp && format.supportsTimestamp;

  SignatureOptions copyWith({
    SignatureFormat? format,
    bool? graphicSignature,
    int? page,
    double? x,
    double? y,
    double? width,
    double? height,
    Uint8List? imageData,
    bool? addTimestamp,
    String? alignedFieldName,
    bool clearAlignedFieldName = false,
  }) {
    return SignatureOptions(
      format: format ?? this.format,
      graphicSignature: graphicSignature ?? this.graphicSignature,
      page: page ?? this.page,
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      imageData: imageData ?? this.imageData,
      addTimestamp: addTimestamp ?? this.addTimestamp,
      alignedFieldName: clearAlignedFieldName
          ? null
          : (alignedFieldName ?? this.alignedFieldName),
    );
  }
}
