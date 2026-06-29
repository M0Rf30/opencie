// SPDX-License-Identifier: GPL-3.0-or-later

/// Signature verification result for a single signer.
///
/// Populated from `struct verifyInfo_t` in cie_ext.h.
class VerifyInfo {
  const VerifyInfo({
    required this.name,
    required this.surname,
    required this.commonName,
    required this.signingTime,
    required this.certificateAuthority,
    required this.certRevocationStatus,
    required this.isSignatureValid,
    required this.isCertificateValid,
  });

  final String name;
  final String surname;
  final String commonName;
  final String signingTime;
  final String certificateAuthority;

  /// 0 = not checked, 1 = valid, 2 = revoked, 3 = unknown.
  final int certRevocationStatus;

  final bool isSignatureValid;
  final bool isCertificateValid;

  bool get isFullyValid =>
      isSignatureValid &&
      (isCertificateValid ||
          certRevocationStatus == 3 ||
          certRevocationStatus == 4);

  String get displayName {
    final full = '$name $surname'.trim();
    return full.isNotEmpty ? full : commonName;
  }

  String get revocationStatusLabel {
    switch (certRevocationStatus) {
      case 0:
        return 'Good';
      case 1:
        return 'Revoked';
      case 2:
        return 'Suspended';
      case 3:
        return 'Unknown';
      case 4:
        return 'Not loaded';
      default:
        return 'Unknown';
    }
  }

  /// Extracts the human-readable CN from an OID-prefixed DN string.
  /// e.g. "2.5.4.3=Issuing sub CA...,2.5.4.10=Ministero..." → "Issuing sub CA..."
  String get caDisplayName {
    for (final segment in certificateAuthority.split(',')) {
      final s = segment.trim();
      if (s.startsWith('2.5.4.3=')) return s.substring('2.5.4.3='.length);
    }
    return certificateAuthority;
  }

  /// Parses UTCTime (YYMMDDHHMMSSZ) into a readable string.
  /// Returns empty string if the field is absent or unparseable.
  String get signingTimeFormatted {
    if (signingTime.isEmpty) return '';
    try {
      final s = signingTime.replaceAll('Z', '').trim();
      if (s.length < 12) return signingTime;
      final yy = int.parse(s.substring(0, 2));
      final year = yy >= 50 ? 1900 + yy : 2000 + yy;
      final month = int.parse(s.substring(2, 4));
      final day = int.parse(s.substring(4, 6));
      final hour = int.parse(s.substring(6, 8));
      final min = int.parse(s.substring(8, 10));
      final sec = int.parse(s.substring(10, 12));
      final months = [
        '',
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      return '$day ${months[month]} $year, '
          '${hour.toString().padLeft(2, '0')}:'
          '${min.toString().padLeft(2, '0')}:'
          '${sec.toString().padLeft(2, '0')} UTC';
    } catch (_) {
      return signingTime;
    }
  }
}
