// SPDX-License-Identifier: GPL-3.0-or-later

/// Application-wide constants.
class AppConstants {
  AppConstants._();

  // ---------------------------------------------------------------------------
  // Signature formats (ETSI standards)
  // ---------------------------------------------------------------------------

  static const String formatPades = 'pdf';
  static const String formatCades = 'p7m';
  static const String formatXades = 'xml';

  // ---------------------------------------------------------------------------
  // TSA defaults (FreeTSA — RFC 3161 compliant, non-qualified)
  // ---------------------------------------------------------------------------

  static const String defaultTsaUrl = 'https://freetsa.org/tsr';
  static const String defaultTsaUrlFallback = 'https://freetsa.org/tsr';

  // ---------------------------------------------------------------------------
  // Qualified Italian TSPs (for production / legal use)
  // ---------------------------------------------------------------------------

  static const Map<String, String> qualifiedTsaProviders = {
    'InfoCert': 'https://timestamp.infocert.it/tsa',
    'Aruba': 'https://servizi.arubapec.it/tsa/ngrequest.php',
    'Namirial': 'https://timestamp.namirial.com/tsa',
    'Poste Italiane': 'https://timestamp.poste.it/tsa',
  };

  // ---------------------------------------------------------------------------
  // CIE constants
  // ---------------------------------------------------------------------------

  static const int ciePinLength = 8;
  static const int ciePukLength = 8;

  // ---------------------------------------------------------------------------
  // PKCS#11 return codes (subset used in UI)
  // ---------------------------------------------------------------------------

  static const int ckrOk = 0x00000000;
  static const int ckrCancel = 0x00000001;
  static const int ckrGeneralError = 0x00000005;
  static const int ckrFunctionFailed = 0x00000006;
  static const int ckrDeviceError = 0x00000030;
  static const int ckrDeviceRemoved = 0x00000032;
  static const int ckrFunctionCanceled = 0x00000050;
  static const int ckrPinIncorrect = 0x000000A0;
  static const int ckrPinInvalid = 0x000000A1;
  static const int ckrPinLenRange = 0x000000A2;
  static const int ckrPinExpired = 0x000000A3;
  static const int ckrPinLocked = 0x000000A4;
  static const int ckrTokenNotPresent = 0x000000E0;
  static const int ckrTokenNotRecognized = 0x000000E1;
  static const int ckrAlreadyEnabled = 0x000000F0;

  // ---------------------------------------------------------------------------
  // File extensions
  // ---------------------------------------------------------------------------

  static const List<String> signableExtensions = [
    'pdf', 'xml', 'doc', 'docx', 'xls', 'xlsx', 'txt', 'csv', 'jpg', 'jpeg',
    'png', 'odt', 'ods', 'odp', 'rtf', 'p7m', // re-signing
  ];

  static const List<String> verifiableExtensions = [
    'pdf', 'p7m', 'p7s', 'xml', 'tsr', 'tsd',
  ];

  static const List<String> certificateExtensions = ['cer', 'crt', 'pem', 'der'];

  // ---------------------------------------------------------------------------
  // Layout breakpoints
  // ---------------------------------------------------------------------------

  static const double compactBreakpoint = 600;
  static const double mediumBreakpoint = 840;
  static const double expandedBreakpoint = 1200;

  // ---------------------------------------------------------------------------
  // Shared library name
  // ---------------------------------------------------------------------------

  static const String libraryName = 'opencie-pkcs11';

  // ---------------------------------------------------------------------------
  // OCSP / CRL
  // ---------------------------------------------------------------------------

  static const String euTrustedListUrl =
      'https://ec.europa.eu/tools/lotl/eu-lotl.xml';
  static const String italianTrustedListUrl =
      'https://eidas.agid.gov.it/TL/TSL-IT.xml';
}
