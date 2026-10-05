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
import 'cie_error.dart';

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
  /// For expiry dates, CIE documents are always issued in the 2000s for the
  /// foreseeable future, so years 00-99 are interpreted as 2000-2099.
  /// For birth dates, years greater than the current two-digit year are
  /// interpreted as 1900-1999 (the holder was born last century); otherwise
  /// 2000-2099 (ICAO 9303 convention).
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
      year = 2000 + yy;
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

/// Outcome of [CieChipReader.readAndEnrich]: what was actually read from
/// the chip, so callers can show a precise message instead of silently
/// saving a card with missing photo/MRZ.
class ChipReadOutcome {
  const ChipReadOutcome({
    required this.card,
    required this.mrzRead,
    required this.photoRead,
    this.errorKind,
  });

  /// The card, enriched with whichever of MRZ/photo were read.
  final EnrolledCard card;

  /// True when EF.DG1 (MRZ) was read and parsed successfully.
  final bool mrzRead;

  /// True when EF.DG2 (photo) was read and extracted successfully.
  final bool photoRead;

  /// Classified reason MRZ and/or photo are missing, or null when both
  /// were read (or no read was attempted — see [mrzRead]/[photoRead]).
  final CieErrorKind? errorKind;

  /// True when both MRZ and photo were read.
  bool get isComplete => mrzRead && photoRead;
}

/// Reads DG1 (MRZ) and DG2 (photo) from the CIE chip (PACE with the CAN)
/// and returns parsed data.
class CieChipReader {
  const CieChipReader._();

  /// Read chip data and return a [ChipReadOutcome] describing what was
  /// read and, when something is missing, why.
  ///
  /// Uses `cie_read_dgs_can` to read DG1 and DG2 in a single PACE-CAN session.
  /// Never throws for a failed/partial chip read: transport failures
  /// (dropped RF link mid-DH-exchange, garbled secure-messaging frame,
  /// etc.) are classified via [classifyCieError] and reported through
  /// [ChipReadOutcome.errorKind] instead, so the UI can offer a retry
  /// rather than silently saving an incomplete card.
  static Future<ChipReadOutcome> readAndEnrich({
    required EnrolledCard card,
    required String can,
    ValueChanged<CieProgress>? onProgress,

    /// Injectable for tests. Defaults to [OpenCiePkcs11.instance.readDgsCan].
    Future<CieReadDgsResult> Function({
      required String can,
      ValueChanged<CieProgress>? onProgress,
    })?
    readDgs,
  }) {
    final read = readDgs ?? OpenCiePkcs11.instance.readDgsCan;
    return _run(
      card,
      () => read(can: can, onProgress: onProgress),
      // No PIN is ever sent on this path: a "wrong PIN" classification
      // (e.g. a library without native kind 11) is really a wrong CAN.
      secretIsCan: true,
    );
  }

  /// Fallback for readers that cannot send the extended APDUs PACE-CAN
  /// needs ([CieErrorKind.extendedApduNotSupported] from
  /// [readAndEnrich]): reads the same data through the PIN-authenticated
  /// `cie_read_dgs`. A wrong PIN is reported as [CieErrorKind.wrongPin] and
  /// must never be retried by the caller; SW 6A82 comes back as
  /// [CieErrorKind.chipDataUnavailable].
  static Future<ChipReadOutcome> readAndEnrichWithPin({
    required EnrolledCard card,
    required String pin,
    ValueChanged<CieProgress>? onProgress,

    /// Injectable for tests. Defaults to [OpenCiePkcs11.instance.readDgs].
    Future<CieReadDgsResult> Function({
      required String pin,
      ValueChanged<CieProgress>? onProgress,
    })?
    readDgs,
  }) {
    final read = readDgs ?? OpenCiePkcs11.instance.readDgs;
    return _run(
      card,
      () => read(pin: pin, onProgress: onProgress),
      secretIsCan: false,
    );
  }

  static Future<ChipReadOutcome> _run(
    EnrolledCard card,
    Future<CieReadDgsResult> Function() call, {
    required bool secretIsCan,
  }) async {
    MrzData? mrz;
    Uint8List? photoBytes;
    CieErrorKind? errorKind;

    try {
      final result = await call();

      if (!result.isSuccess) {
        errorKind = classifyCieError(
          result.returnValue,
          statusWord: result.statusWord,
          nativeErrorKind: result.nativeErrorKind,
        );
        if (secretIsCan && errorKind == CieErrorKind.wrongPin) {
          errorKind = CieErrorKind.wrongCan;
        }
      } else {
        final rawMrz = result.mrzBytes;
        final rawPhoto = result.photoBytes;
        if (rawMrz != null && rawMrz.isNotEmpty) {
          mrz = MrzParser.parse(rawMrz);
        }
        if (rawPhoto != null && rawPhoto.isNotEmpty) {
          photoBytes = PhotoExtractor.extract(rawPhoto);
        }
        if (mrz == null || photoBytes == null) {
          // Native call reported success but a DG came back empty: still
          // surface a generic communication error rather than pretending
          // nothing is wrong.
          errorKind = CieErrorKind.cardCommunicationError;
        }
      }
    } catch (e) {
      debugPrint('CieChipReader: chip read failed (mrz/photo unavailable): $e');
      errorKind = CieErrorKind.cardCommunicationError;
    }

    final enrichedCard = (mrz == null && photoBytes == null)
        ? card
        : card.copyWith(
            mrzSurname: mrz?.surname,
            mrzGivenNames: mrz?.givenNames,
            mrzExpiry: mrz?.expiry,
            photoBytes: photoBytes,
          );

    return ChipReadOutcome(
      card: enrichedCard,
      mrzRead: mrz != null,
      photoRead: photoBytes != null,
      errorKind: (mrz != null && photoBytes != null) ? null : errorKind,
    );
  }
}

/// How many times a chip read is re-run after
/// [CieErrorKind.cardResetRequired] (the user lifts the card and puts it
/// back each time) before giving up.
const int chipReadMaxResetRetries = 3;

/// Drives a chip read to completion, re-running [attempt] while the outcome
/// is incomplete and a retry is wanted.
///
/// [attempt] receives the outcome of the previous attempt (so the enriched
/// card is carried over) and MUST reuse the secret (CAN/PIN) the caller
/// already holds: this helper never sees or stores it.
///
/// A [CieErrorKind.cardResetRequired] outcome is handled here, bounded by
/// [maxResetRetries]: [onResetRequired] is asked to show the "lift the card
/// and put it back" instruction. It receives the number of retries still
/// left (0 means this is the last one: show the message without Retry) and
/// returns true when the user chose Retry. Every other incomplete outcome
/// is delegated to [shouldRetry] (attempt index starts at 0).
///
/// Returns the last outcome; never throws on its own.
Future<ChipReadOutcome> runChipReadLoop({
  required ChipReadOutcome initial,
  required Future<ChipReadOutcome> Function(ChipReadOutcome previous) attempt,
  required Future<bool> Function(ChipReadOutcome outcome, int attempt)
  shouldRetry,
  required Future<bool> Function(ChipReadOutcome outcome, int retriesLeft)
  onResetRequired,
  int maxResetRetries = chipReadMaxResetRetries,
}) async {
  var outcome = initial;
  var resetRetries = 0;
  for (var i = 0; ; i++) {
    outcome = await attempt(outcome);
    if (outcome.isComplete) break;
    if (outcome.errorKind == CieErrorKind.cardResetRequired) {
      final left = maxResetRetries - resetRetries;
      final retry = await onResetRequired(outcome, left < 0 ? 0 : left);
      if (!retry || left <= 0) break;
      resetRetries++;
      continue;
    }
    if (!await shouldRetry(outcome, i)) break;
  }
  return outcome;
}
