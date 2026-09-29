// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/core/constants/app_constants.dart';
import 'package:opencie/ffi/opencie_pkcs11.dart';
import 'package:opencie/models/enrolled_card.dart';
import 'package:opencie/services/cie_chip_reader.dart';
import 'package:opencie/services/cie_error.dart';

/// Wraps [mrzString] (ASCII) into a minimal EF.DG1 BER-TLV byte buffer.
/// Mirrors mrz_parser_test.dart's fixture builder.
Uint8List _buildDg1(String mrzString) {
  final mrzBytes = Uint8List.fromList(mrzString.codeUnits);
  final mrzLen = mrzBytes.length;
  final innerLen = 2 + 1 + mrzLen;

  final buf = BytesBuilder()
    ..addByte(0x61)
    ..addByte(innerLen)
    ..addByte(0x5F)
    ..addByte(0x1F)
    ..addByte(mrzLen)
    ..add(mrzBytes);
  return buf.toBytes();
}

// 30 chars each — TD1 MRZ, synthetic fixture (no real personal data).
const _td1Line1 = 'IDITACA00000AA0<<<<<<<<<<<<<<<';
const _td1Line2 = '8001014M9901012ITA<<<<<<<<<<<6';
const _td1Line3 = 'ROSSI<<MARIO<<<<<<<<<<<<<<<<<<';
const _td1Mrz = _td1Line1 + _td1Line2 + _td1Line3;

/// Minimal valid PNG signature — enough for [PhotoExtractor.extract] to
/// recognize it as an already-decoded photo.
final _pngBytes = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x01, 0x02, 0x03,
]);

const _card = EnrolledCard(pan: '1234567890123456', name: '', serial: 'SERIAL');

void main() {
  group('CieChipReader.readAndEnrich outcome mapping', () {
    test('complete read: mrz + photo both present, errorKind null', () async {
      final outcome = await CieChipReader.readAndEnrich(
        card: _card,
        pin: '12345678',
        readDgs: ({required pin, onProgress}) async => CieReadDgsResult(
          returnValue: AppConstants.ckrOk,
          mrzBytes: _buildDg1(_td1Mrz),
          photoBytes: _pngBytes,
        ),
      );

      expect(outcome.mrzRead, isTrue);
      expect(outcome.photoRead, isTrue);
      expect(outcome.isComplete, isTrue);
      expect(outcome.errorKind, isNull);
      expect(outcome.card.mrzSurname, 'ROSSI');
      expect(outcome.card.photoBytes, _pngBytes);
    });

    test('transport failure (rv != 0, no data): both missing, classified '
        'errorKind', () async {
      final outcome = await CieChipReader.readAndEnrich(
        card: _card,
        pin: '12345678',
        readDgs: ({required pin, onProgress}) async => const CieReadDgsResult(
          returnValue: AppConstants.ckrDeviceError,
          statusWord: 0x6987, // garbled SM data — RF link drop mid-read
        ),
      );

      expect(outcome.mrzRead, isFalse);
      expect(outcome.photoRead, isFalse);
      expect(outcome.isComplete, isFalse);
      expect(outcome.errorKind, isNotNull);
      // Original card is returned unchanged on total failure.
      expect(outcome.card, same(_card));
    });

    test('partial read (mrz only): photo missing, errorKind set, card '
        'enriched with what was read', () async {
      final outcome = await CieChipReader.readAndEnrich(
        card: _card,
        pin: '12345678',
        readDgs: ({required pin, onProgress}) async => CieReadDgsResult(
          returnValue: AppConstants.ckrOk,
          mrzBytes: _buildDg1(_td1Mrz),
          photoBytes: null,
        ),
      );

      expect(outcome.mrzRead, isTrue);
      expect(outcome.photoRead, isFalse);
      expect(outcome.isComplete, isFalse);
      expect(outcome.errorKind, CieErrorKind.cardCommunicationError);
      expect(outcome.card.mrzSurname, 'ROSSI');
      expect(outcome.card.photoBytes, isNull);
    });

    test('wrong PIN: classified as wrongPin, never retried by the caller '
        'contract (isPinStatusErrorKind)', () async {
      final outcome = await CieChipReader.readAndEnrich(
        card: _card,
        pin: '00000000',
        readDgs: ({required pin, onProgress}) async =>
            const CieReadDgsResult(returnValue: AppConstants.ckrPinIncorrect),
      );

      expect(outcome.isComplete, isFalse);
      expect(outcome.errorKind, CieErrorKind.wrongPin);
    });

    test(
      'native call throws: swallowed, reported as cardCommunicationError',
      () async {
        final outcome = await CieChipReader.readAndEnrich(
          card: _card,
          pin: '12345678',
          readDgs: ({required pin, onProgress}) async {
            throw StateError('simulated RF link drop');
          },
        );

        expect(outcome.mrzRead, isFalse);
        expect(outcome.photoRead, isFalse);
        expect(outcome.errorKind, CieErrorKind.cardCommunicationError);
        expect(outcome.card, same(_card));
      },
    );
  });
}
