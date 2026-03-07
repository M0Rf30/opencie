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
    this.reason,
    this.location,
  });

  final SignatureFormat format;
  final bool graphicSignature;
  final int page;
  final double x;
  final double y;
  final double width;
  final double height;
  final Uint8List? imageData;
  final bool addTimestamp;
  final String? reason;
  final String? location;

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
    String? reason,
    String? location,
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
      reason: reason ?? this.reason,
      location: location ?? this.location,
    );
  }
}
