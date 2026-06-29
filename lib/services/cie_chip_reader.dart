// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

/// Service for reading and parsing ICAO 9303 data groups from the CIE chip.
///
/// Provides:
///   - [CieChipReader.readAndEnrich] — reads DG1 (MRZ) and DG2 (photo) from
///     the chip and returns an [EnrolledCard] enriched with parsed fields.
///   - [MrzParser] — parses raw DG1 TLV bytes into [MrzData].
///   - [PhotoExtractor] — extracts displayable image bytes from raw DG2 TLV.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueChanged, debugPrint;

import '../ffi/opencie_pkcs11.dart';
import '../models/enrolled_card.dart';

// ---------------------------------------------------------------------------
// Public result types
// ---------------------------------------------------------------------------

/// Parsed MRZ fields from EF.DG1.
class MrzData {
  const MrzData({
    required this.surname,
    required this.givenNames,
    required this.expiry,
    required this.documentNumber,
    required this.nationality,
    required this.dateOfBirth,
  });

  final String surname;
  final String givenNames;
  final DateTime? expiry;
  final String documentNumber;
  final String nationality;
  final DateTime? dateOfBirth;
}

/// Combined chip data from DG1 + DG2.
class ChipData {
  const ChipData({this.mrz, this.photoBytes});

  final MrzData? mrz;

  /// PNG bytes decoded from EF.DG2, ready for [Image.memory].
  final Uint8List? photoBytes;
}

// ---------------------------------------------------------------------------
// MRZ TLV parser
// ---------------------------------------------------------------------------

/// Parses raw EF.DG1 TLV bytes into [MrzData].
///
/// EF.DG1 structure (ICAO 9303 part 10):
/// ```
///   61 <len>          — DG1 tag
///     5F1F <len>      — MRZ data tag
///       <MRZ lines>  — TD1: 3×30 chars, TD3: 2×44 chars
/// ```
class MrzParser {
  /// Parse raw DG1 TLV bytes. Returns null if the structure is invalid.
  static MrzData? parse(Uint8List dg1Bytes) {
    try {
      final mrzBytes = _findTag(dg1Bytes, 0, dg1Bytes.length, 0x5F1F);
      if (mrzBytes == null || mrzBytes.isEmpty) return null;

      final mrz = String.fromCharCodes(mrzBytes).replaceAll('\x00', '');
      return _parseMrzString(mrz);
    } catch (_) {
      // Intentional: malformed or truncated BER-TLV structure. Return null so
      // the caller skips MRZ enrichment rather than propagating a parse error.
      return null;
    }
  }

  /// Recursively search for a two-byte tag in BER-TLV encoded data.
  static Uint8List? _findTag(
    Uint8List data,
    int offset,
    int end,
    int targetTag,
  ) {
    while (offset < end) {
      if (offset >= data.length) break;

      // Read tag (may be 1 or 2 bytes)
      int tag = data[offset];
      int tagLen = 1;
      if ((tag & 0x1F) == 0x1F) {
        if (offset + 1 >= data.length) break;
        tag = (tag << 8) | data[offset + 1];
        tagLen = 2;
      }
      offset += tagLen;

      // Read length
      if (offset >= data.length) break;
      int len;
      if (data[offset] < 0x80) {
        len = data[offset];
        offset += 1;
      } else if (data[offset] == 0x81) {
        if (offset + 1 >= data.length) break;
        len = data[offset + 1];
        offset += 2;
      } else if (data[offset] == 0x82) {
        if (offset + 2 >= data.length) break;
        len = (data[offset + 1] << 8) | data[offset + 2];
        offset += 3;
      } else {
        break;
      }

      if (offset + len > data.length) break;

      if (tag == targetTag) {
        return Uint8List.sublistView(data, offset, offset + len);
      }

      // If this is a constructed tag (bit 6 of first tag byte set), recurse
      final firstByte = tagLen == 1 ? (tag & 0xFF) : ((tag >> 8) & 0xFF);
      if ((firstByte & 0x20) != 0) {
        final inner = _findTag(data, offset, offset + len, targetTag);
        if (inner != null) return inner;
      }

      offset += len;
    }
    return null;
  }

  /// Parse a raw MRZ string (TD1 3×30 or TD3 2×44).
  static MrzData? _parseMrzString(String mrz) {
    final clean = mrz.replaceAll(RegExp(r'\s'), '');

    if (clean.length == 90) {
      return _parseTd1(clean);
    } else if (clean.length == 88) {
      return _parseTd3(clean);
    }
    return null;
  }

  /// Parse TD1 MRZ (3 lines × 30 chars).
  ///
  /// Line 1: doc type (2) + country (3) + doc number (9) + check (1) + optional (15)
  /// Line 2: DOB (6) + check (1) + sex (1) + expiry (6) + check (1) + nationality (3) + optional (11) + check (1)
  /// Line 3: surname<<givennames (30)
  static MrzData? _parseTd1(String mrz) {
    if (mrz.length < 90) return null;
    final line1 = mrz.substring(0, 30);
    final line2 = mrz.substring(30, 60);
    final line3 = mrz.substring(60, 90);

    final docNumber = line1.substring(5, 14).replaceAll('<', '');
    final dob = _parseDate(line2.substring(0, 6), isBirth: true);
    final expiry = _parseDate(line2.substring(8, 14), isBirth: false);
    final nationality = line2.substring(15, 18).replaceAll('<', '');
    final names = _parseNames(line3);

    return MrzData(
      surname: names.$1,
      givenNames: names.$2,
      expiry: expiry,
      documentNumber: docNumber,
      nationality: nationality,
      dateOfBirth: dob,
    );
  }

  /// Parse TD3 MRZ (2 lines × 44 chars).
  ///
  /// Line 1: doc type (2) + country (3) + surname<<givennames (39)
  /// Line 2: doc number (9) + check (1) + nationality (3) + DOB (6) + check (1) + sex (1) + expiry (6) + check (1) + optional (14) + check (1)
  static MrzData? _parseTd3(String mrz) {
    if (mrz.length < 88) return null;
    final line1 = mrz.substring(0, 44);
    final line2 = mrz.substring(44, 88);

    final names = _parseNames(line1.substring(5));
    final docNumber = line2.substring(0, 9).replaceAll('<', '');
    final nationality = line2.substring(10, 13).replaceAll('<', '');
    final dob = _parseDate(line2.substring(13, 19), isBirth: true);
    final expiry = _parseDate(line2.substring(20, 26), isBirth: false);

    return MrzData(
      surname: names.$1,
      givenNames: names.$2,
      expiry: expiry,
      documentNumber: docNumber,
      nationality: nationality,
      dateOfBirth: dob,
    );
  }

  /// Split a name field "SURNAME<<GIVEN<NAMES" into (surname, givenNames).
  static (String, String) _parseNames(String field) {
    final parts = field.split('<<');
    final surname = (parts.isNotEmpty ? parts[0] : '')
        .replaceAll('<', ' ')
        .trim();
    final given = (parts.length > 1 ? parts[1] : '')
        .replaceAll('<', ' ')
        .trim();
    return (surname, given);
  }

  /// Parse a 6-digit YYMMDD date string.
  ///
  /// For expiry dates, years 00–30 are interpreted as 2000–2030;
  /// years 31–99 as 1931–1999 (ICAO 9303 convention).
  /// For birth dates, the same heuristic applies but reversed.
  static DateTime? _parseDate(String s, {required bool isBirth}) {
    if (s.length != 6) return null;
    final yy = int.tryParse(s.substring(0, 2));
    final mm = int.tryParse(s.substring(2, 4));
    final dd = int.tryParse(s.substring(4, 6));
    if (yy == null || mm == null || dd == null) return null;
    if (mm < 1 || mm > 12 || dd < 1 || dd > 31) return null;

    final now = DateTime.now().year;
    int year;
    if (isBirth) {
      year = yy > (now % 100) ? 1900 + yy : 2000 + yy;
    } else {
      year = yy < (now % 100) ? 2100 + yy : 2000 + yy;
    }

    try {
      return DateTime(year, mm, dd);
    } catch (_) {
      // Intentional: DateTime constructor throws on out-of-range values
      // (e.g. day=0 from a garbled MRZ field); leave the date field null.
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Photo extractor
// ---------------------------------------------------------------------------

/// Extracts displayable image bytes from raw EF.DG2 data.
///
/// The native [cie_read_photo] function already decodes JPEG2000 to PNG using
/// OpenJPEG, so in the common case the bytes returned are already a valid PNG.
/// This class handles the fallback case where the native library was built
/// without OpenJPEG support and returns raw DG2 TLV bytes instead.
class PhotoExtractor {
  /// Extract image bytes from raw DG2 data. Returns null if not found.
  ///
  /// Checks for a PNG header first (native decode succeeded). If not PNG,
  /// falls back to scanning for a JPEG SOI marker in the raw TLV.
  static Uint8List? extract(Uint8List dg2Bytes) {
    if (dg2Bytes.isEmpty) return null;

    // PNG signature: 89 50 4E 47 0D 0A 1A 0A
    if (dg2Bytes.length >= 8 &&
        dg2Bytes[0] == 0x89 &&
        dg2Bytes[1] == 0x50 &&
        dg2Bytes[2] == 0x4E &&
        dg2Bytes[3] == 0x47) {
      return dg2Bytes; // Already PNG from native decode
    }

    // JPEG SOI: FF D8 FF — scan for it in case raw TLV was returned
    for (int i = 0; i < dg2Bytes.length - 2; i++) {
      if (dg2Bytes[i] == 0xFF &&
          dg2Bytes[i + 1] == 0xD8 &&
          dg2Bytes[i + 2] == 0xFF) {
        return Uint8List.sublistView(dg2Bytes, i);
      }
    }

    return null;
  }
}

// ---------------------------------------------------------------------------
// High-level reader
// ---------------------------------------------------------------------------

/// Reads DG1 (MRZ) and DG2 (photo) from the CIE chip and returns parsed data.
class CieChipReader {
  const CieChipReader._();

  /// Read chip data and return an [EnrolledCard] enriched with MRZ + photo.
  ///
  /// Uses [cie_read_dgs] to read DG1 and DG2 in a single PACE session.
  /// If either read fails, the corresponding field in the result is null.
  /// The original [card] is returned unchanged on total failure.
  static Future<EnrolledCard> readAndEnrich({
    required EnrolledCard card,
    required String pin,
    ValueChanged<CieProgress>? onProgress,
  }) async {
    final pkcs11 = OpenCiePkcs11.instance;

    MrzData? mrz;
    Uint8List? photoBytes;

    try {
      final (rawMrz, rawPhoto) = await pkcs11.readDgs(
        pin: pin,
        onProgress: onProgress,
      );

      if (rawMrz != null && rawMrz.isNotEmpty) {
        mrz = MrzParser.parse(rawMrz);
      }
      if (rawPhoto != null && rawPhoto.isNotEmpty) {
        photoBytes = PhotoExtractor.extract(rawPhoto);
      }
    } catch (e) {
      debugPrint(
        'CieChipReader.readAndEnrich: chip read failed (mrz/photo unavailable): $e',
      );
      // Intentional: NFC/PACE read failures must not crash the enrolment UI;
      // unread fields remain null and the original card is returned below.
    }

    if (mrz == null && photoBytes == null) return card;

    return card.copyWith(
      mrzSurname: mrz?.surname,
      mrzGivenNames: mrz?.givenNames,
      mrzExpiry: mrz?.expiry,
      photoBytes: photoBytes,
    );
  }
}
