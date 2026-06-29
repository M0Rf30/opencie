// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:opencie/services/cie_chip_reader.dart';

// ---------------------------------------------------------------------------
// TLV builder
// ---------------------------------------------------------------------------

/// Wraps [mrzString] (ASCII) into a minimal EF.DG1 BER-TLV byte buffer:
///
///   0x61 `<outer-len>`        — DG1 tag (constructed, single-byte)
///     0x5F 0x1F `<mrz-len>`  — MRZ data tag (two-byte long-form tag)
///       `<ASCII MRZ bytes>`
///
/// Only valid when mrz.length ≤ 124 so all lengths fit in one byte
/// (innerLen = 3 + mrzLen ≤ 127 < 0x80 → definite short form).
Uint8List _buildDg1(String mrzString) {
  final mrzBytes = Uint8List.fromList(mrzString.codeUnits);
  final mrzLen = mrzBytes.length; // ≤ 90 for TD1, ≤ 88 for TD3
  final innerLen = 2 + 1 + mrzLen; // tag(5F1F=2) + length(1) + value
  // Both ≤ 127 for any realistic MRZ, satisfying BER short-form encoding.

  final buf = BytesBuilder()
    ..addByte(0x61) // outer DG1 tag (constructed, bit 5 set)
    ..addByte(innerLen)
    ..addByte(0x5F) // inner MRZ tag high byte
    ..addByte(0x1F) // inner MRZ tag low byte (long-form marker: & 0x1F == 0x1F)
    ..addByte(mrzLen)
    ..add(mrzBytes);
  return buf.toBytes();
}

// ---------------------------------------------------------------------------
// MRZ constants — ICAO 9303 synthetic test vectors
// ---------------------------------------------------------------------------
//
// TD1 layout (3 × 30 = 90 chars):
//   Line1: docType(2) country(3) docNumber(9) check(1) optional(15)
//   Line2: DOB(6) check(1) sex(1) expiry(6) check(1) nationality(3)
//           optional(11) overallCheck(1)
//   Line3: surname<<givenNames (30)
//
// MrzParser reads:
//   docNumber   ← line1[5..13]   = "CA00000AA"
//   dob         ← line2[0..5]    = "800101"
//   expiry      ← line2[8..13]   = "990101"
//   nationality ← line2[15..17]  = "ITA"
//   names       ← _parseNames(line3)

// 30 chars: ID(2)+ITA(3)+CA00000AA(9)+0(1)+<×15
const _td1Line1 = 'IDITACA00000AA0<<<<<<<<<<<<<<<'; // 30

// 30 chars: 800101(6)+4(1)+M(1)+990101(6)+2(1)+ITA(3)+<×11+6(1)
const _td1Line2 = '8001014M9901012ITA<<<<<<<<<<<6'; // 30

// 30 chars: ROSSI(5)+<<(2)+MARIO(5)+<×18
const _td1Line3 = 'ROSSI<<MARIO<<<<<<<<<<<<<<<<<<'; // 30

const _td1Mrz = _td1Line1 + _td1Line2 + _td1Line3; // 90 chars

//
// TD3 layout (2 × 44 = 88 chars):
//   Line1: docType(2) country(3) surname<<givenNames(39)
//   Line2: docNumber(9) check(1) nationality(3) DOB(6) sex(1)
//           expiry(6) rest(18)
//
// MrzParser reads:
//   names       ← _parseNames(line1[5..43]) = ROSSI / MARIO
//   docNumber   ← line2[0..8]   = "YA1234567"
//   nationality ← line2[10..12] = "ITA"
//   dob         ← line2[13..18] = "800101"
//   expiry      ← line2[20..25] = "990101"

// 44 chars: P<(2)+ITA(3)+ROSSI<<MARIO(12)+<×27
const _td3Line1 = 'P<ITAROSSI<<MARIO<<<<<<<<<<<<<<<<<<<<<<<<<<<'; // 44

// 44 chars: YA1234567(9)+8(1)+ITA(3)+800101(6)+M(1)+990101(6)+0(1)+<×17
const _td3Line2 = 'YA12345678ITA800101M9901010<<<<<<<<<<<<<<<<<'; // 44

const _td3Mrz = _td3Line1 + _td3Line2; // 88 chars

void main() {
  // Sanity-check lengths at runtime (caught by the parser returning null).
  assert(_td1Mrz.length == 90, 'TD1 MRZ must be 90 chars');
  assert(_td3Mrz.length == 88, 'TD3 MRZ must be 88 chars');

  // ---------------------------------------------------------------------------
  // TD1 happy path (Italian CIE card format: 3 × 30)
  // ---------------------------------------------------------------------------
  group('MrzParser TD1 happy path', () {
    late MrzData result;

    setUpAll(() {
      final dg1 = _buildDg1(_td1Mrz);
      final parsed = MrzParser.parse(dg1);
      expect(parsed, isNotNull, reason: 'TD1 DG1 parse must succeed');
      result = parsed!;
    });

    test('document number is extracted and filler stripped', () {
      // line1.substring(5, 14) = "CA00000AA"
      expect(result.documentNumber, equals('CA00000AA'));
    });

    test('nationality code is correct', () {
      // line2.substring(15, 18) = "ITA"
      expect(result.nationality, equals('ITA'));
    });

    test('surname is parsed from line3 (field before <<)', () {
      expect(result.surname, equals('ROSSI'));
    });

    test('given names are parsed from line3 (field after <<)', () {
      expect(result.givenNames, equals('MARIO'));
    });

    test('date-of-birth yy=80 maps to 1980-01-01 (rollover: 80 > now%100)', () {
      // Impl: yy > (now % 100) → 1900 + yy.  Safe until year 2080.
      expect(result.dateOfBirth, equals(DateTime(1980, 1, 1)));
    });

    test(
      'expiry yy=99 maps to 2099-01-01 (99 >= now%100 throughout century)',
      () {
        // Impl: yy < (now % 100) → 2100 + yy; else 2000 + yy.
        // 99 is never < (now % 100) for any year before 2100.
        expect(result.expiry, equals(DateTime(2099, 1, 1)));
      },
    );
  });

  // ---------------------------------------------------------------------------
  // TD3 happy path (passport format: 2 × 44)
  // ---------------------------------------------------------------------------
  group('MrzParser TD3 happy path', () {
    late MrzData result;

    setUpAll(() {
      final dg1 = _buildDg1(_td3Mrz);
      final parsed = MrzParser.parse(dg1);
      expect(parsed, isNotNull, reason: 'TD3 DG1 parse must succeed');
      result = parsed!;
    });

    test('document number from line2[0..8]', () {
      expect(result.documentNumber, equals('YA1234567'));
    });

    test('nationality from line2[10..12]', () {
      expect(result.nationality, equals('ITA'));
    });

    test('surname from line1 names field (before <<)', () {
      expect(result.surname, equals('ROSSI'));
    });

    test('given names from line1 names field (after <<)', () {
      expect(result.givenNames, equals('MARIO'));
    });

    test('DOB yy=80 → 1980-01-01', () {
      expect(result.dateOfBirth, equals(DateTime(1980, 1, 1)));
    });

    test('expiry yy=99 → 2099-01-01', () {
      expect(result.expiry, equals(DateTime(2099, 1, 1)));
    });
  });

  // ---------------------------------------------------------------------------
  // Date-rollover edge cases via TD1 MRZ variants
  // ---------------------------------------------------------------------------
  group('MrzParser date-rollover edge cases', () {
    // Parse a TD1 MRZ using the fixed line1/line3 but a custom line2.
    MrzData? parseTd1WithLine2(String line2) {
      assert(line2.length == 30, 'line2 must be exactly 30 chars');
      return MrzParser.parse(_buildDg1(_td1Line1 + line2 + _td1Line3));
    }

    test('birth yy=00 → 2000-01-01 (0 never > now%100 in 21st century)', () {
      // yy=0 > 0..99 is only true when now%100=0, i.e. year 2100.  Safe.
      final r = parseTd1WithLine2('0001014M9901012ITA<<<<<<<<<<<6');
      expect(r, isNotNull);
      expect(r!.dateOfBirth, equals(DateTime(2000, 1, 1)));
    });

    test('birth yy=99 → 1999-01-01 (99 > now%100 for all years 2000-2099)', () {
      final r = parseTd1WithLine2('9901014M9901012ITA<<<<<<<<<<<6');
      expect(r, isNotNull);
      expect(r!.dateOfBirth, equals(DateTime(1999, 1, 1)));
    });
  });

  // ---------------------------------------------------------------------------
  // Invalid / malformed inputs
  // ---------------------------------------------------------------------------
  group('MrzParser rejects malformed inputs', () {
    test('empty Uint8List returns null', () {
      expect(MrzParser.parse(Uint8List(0)), isNull);
    });

    test('random garbage bytes return null', () {
      final bad = Uint8List.fromList([0x00, 0x01, 0x02, 0x03]);
      expect(MrzParser.parse(bad), isNull);
    });

    test('correct outer 0x61 tag but no inner 0x5F1F tag returns null', () {
      // Inner tag is 0x5F20 (not 0x5F1F) — _findTag never matches it.
      final buf = BytesBuilder()
        ..addByte(0x61) // outer DG1 tag
        ..addByte(6) // outer length = 6
        ..addByte(0x5F) // inner tag high
        ..addByte(0x20) // inner tag low  (≠ 0x1F → won't match 0x5F1F)
        ..addByte(3) // inner length
        ..addByte(0x41)
        ..addByte(0x42)
        ..addByte(0x43);
      expect(MrzParser.parse(buf.toBytes()), isNull);
    });

    test('MRZ payload with 10 chars (neither 88 nor 90) returns null', () {
      // Valid TLV structure, but MRZ string is too short.
      expect(MrzParser.parse(_buildDg1('ABCDEFGHIJ')), isNull);
    });

    test(
      'MRZ payload with 89 chars (between TD3 and TD1 lengths) returns null',
      () {
        final mrz89 = 'A' * 89;
        expect(MrzParser.parse(_buildDg1(mrz89)), isNull);
      },
    );
  });
}
