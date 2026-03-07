// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

class EnrolledCard {
  const EnrolledCard({
    required this.pan,
    this.name = '',
    this.serial = '',
    this.notBefore,
    this.notAfter,
    this.issuer,
    this.subject,
    this.certSerial,
    this.keyAlgorithm,
    this.mrzSurname,
    this.mrzGivenNames,
    this.mrzExpiry,
    this.photoBytes,
  });

  final String pan;
  final String name;
  final String serial;

  /// Certificate validity start (from X.509 notBefore field).
  final DateTime? notBefore;

  /// Certificate expiry date (from X.509 notAfter field).
  final DateTime? notAfter;

  /// Issuer distinguished name string.
  final String? issuer;

  /// Subject distinguished name string.
  final String? subject;

  /// Certificate serial number (hex string).
  final String? certSerial;

  /// Key algorithm short name (e.g. "RSA", "EC").
  final String? keyAlgorithm;

  /// Surname from MRZ DG1.
  final String? mrzSurname;

  /// Given names from MRZ DG1.
  final String? mrzGivenNames;

  /// Expiry date from MRZ DG1 (YYMMDD parsed).
  final DateTime? mrzExpiry;

  /// Portrait photo bytes from DG2.
  final Uint8List? photoBytes;

  String get displayName {
    if (mrzSurname != null && mrzSurname!.trim().isNotEmpty) {
      final given = mrzGivenNames?.trim() ?? '';
      return given.isNotEmpty
          ? '${mrzSurname!.trim()} ${given.split(' ').first}'
          : mrzSurname!.trim();
    }
    return name.trim().isNotEmpty
        ? name.trim()
        : 'CIE ${pan.substring(pan.length > 6 ? pan.length - 6 : 0)}';
  }

  EnrolledCard copyWith({
    String? pan,
    String? name,
    String? serial,
    DateTime? notBefore,
    DateTime? notAfter,
    String? issuer,
    String? subject,
    String? certSerial,
    String? keyAlgorithm,
    String? mrzSurname,
    String? mrzGivenNames,
    DateTime? mrzExpiry,
    Uint8List? photoBytes,
  }) => EnrolledCard(
    pan: pan ?? this.pan,
    name: name ?? this.name,
    serial: serial ?? this.serial,
    notBefore: notBefore ?? this.notBefore,
    notAfter: notAfter ?? this.notAfter,
    issuer: issuer ?? this.issuer,
    subject: subject ?? this.subject,
    certSerial: certSerial ?? this.certSerial,
    keyAlgorithm: keyAlgorithm ?? this.keyAlgorithm,
    mrzSurname: mrzSurname ?? this.mrzSurname,
    mrzGivenNames: mrzGivenNames ?? this.mrzGivenNames,
    mrzExpiry: mrzExpiry ?? this.mrzExpiry,
    photoBytes: photoBytes ?? this.photoBytes,
  );

  Map<String, dynamic> toJson() => {
    'pan': pan,
    'name': name,
    'serial': serial,
    if (notBefore != null) 'notBefore': notBefore!.toIso8601String(),
    if (notAfter != null) 'notAfter': notAfter!.toIso8601String(),
    if (issuer != null) 'issuer': issuer,
    if (subject != null) 'subject': subject,
    if (certSerial != null) 'certSerial': certSerial,
    if (keyAlgorithm != null) 'keyAlgorithm': keyAlgorithm,
    if (mrzSurname != null) 'mrzSurname': mrzSurname,
    if (mrzGivenNames != null) 'mrzGivenNames': mrzGivenNames,
    if (mrzExpiry != null) 'mrzExpiry': mrzExpiry!.toIso8601String(),
    if (photoBytes != null) 'photoBytes': base64Encode(photoBytes!),
  };

  factory EnrolledCard.fromJson(Map<String, dynamic> m) => EnrolledCard(
    pan: m['pan'] as String? ?? '',
    name: m['name'] as String? ?? '',
    serial: m['serial'] as String? ?? '',
    notBefore: m['notBefore'] != null
        ? DateTime.tryParse(m['notBefore'] as String)
        : null,
    notAfter: m['notAfter'] != null
        ? DateTime.tryParse(m['notAfter'] as String)
        : null,
    issuer: m['issuer'] as String?,
    subject: m['subject'] as String?,
    certSerial: m['certSerial'] as String?,
    keyAlgorithm: m['keyAlgorithm'] as String?,
    mrzSurname: m['mrzSurname'] as String?,
    mrzGivenNames: m['mrzGivenNames'] as String?,
    mrzExpiry: m['mrzExpiry'] != null
        ? DateTime.tryParse(m['mrzExpiry'] as String)
        : null,
    photoBytes: m['photoBytes'] != null
        ? base64Decode(m['photoBytes'] as String)
        : null,
  );

  @override
  bool operator ==(Object other) => other is EnrolledCard && other.pan == pan;

  @override
  int get hashCode => pan.hashCode;
}
