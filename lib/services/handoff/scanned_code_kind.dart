// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

/// What a scanned QR value turned out to be, from the phone's point of view.
enum ScannedCodeKind {
  /// An OpenCIE pairing offer (JSON text).
  openCie,

  /// A QR for logging in to a website with the CIE (handled by another app).
  cieWebLogin,

  /// Anything else.
  other,
}

const _cieWebLoginHost = 'servizicie.interno.gov.it';

/// Classifies [raw] as scanned from a QR code.
ScannedCodeKind classifyScannedCode(String raw) {
  final text = raw.trim();
  if (text.startsWith('{')) return ScannedCodeKind.openCie;
  final uri = Uri.tryParse(text);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    final host = uri.host.toLowerCase();
    if (host == _cieWebLoginHost || host.endsWith('.$_cieWebLoginHost')) {
      return ScannedCodeKind.cieWebLogin;
    }
  }
  return ScannedCodeKind.other;
}
