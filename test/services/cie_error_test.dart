// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';

import 'package:opencie/core/constants/app_constants.dart';
import 'package:opencie/core/l10n/app_localizations_en.dart';
import 'package:opencie/core/l10n/app_localizations_it.dart';
import 'package:opencie/services/cie_error.dart';

void main() {
  final en = AppLocalizationsEn();
  final it = AppLocalizationsIt();

  group('classifyCieError', () {
    final cases = <int, CieErrorKind>{
      AppConstants.ckrPinIncorrect: CieErrorKind.wrongPin,
      AppConstants.ckrPinLocked: CieErrorKind.pinBlocked,
      AppConstants.ckrPinInvalid: CieErrorKind.wrongPinFormat,
      AppConstants.ckrPinLenRange: CieErrorKind.wrongPinFormat,
      AppConstants.ckrPinExpired: CieErrorKind.pinExpired,
      AppConstants.ckrTokenNotPresent: CieErrorKind.cardNotPresent,
      AppConstants.ckrTokenNotRecognized: CieErrorKind.notACie,
      AppConstants.ckrDeviceRemoved: CieErrorKind.tagLost,
      AppConstants.ckrDeviceError: CieErrorKind.cardCommunicationError,
      AppConstants.ckrGeneralError: CieErrorKind.cardCommunicationError,
      AppConstants.ckrFunctionFailed: CieErrorKind.cardCommunicationError,
      AppConstants.ckrCancel: CieErrorKind.cancelledByUser,
      AppConstants.ckrFunctionCanceled: CieErrorKind.cancelledByUser,
      AppConstants.ckrAlreadyEnabled: CieErrorKind.alreadyEnrolled,
      AppConstants.ckrSlotIdInvalid: CieErrorKind.readerNotFound,
    };

    cases.forEach((code, expected) {
      test(
        '0x${code.toRadixString(16)} classifies as $expected',
        () => expect(classifyCieError(code), expected),
      );
    });

    test('an unmapped return code classifies as unknown', () {
      expect(classifyCieError(0x12345678), CieErrorKind.unknown);
    });

    test('ckrOk (success) classifies as unknown', () {
      // classifyCieError is only ever called on failure paths; ckrOk has no
      // dedicated kind and must not be silently mapped onto another one.
      expect(classifyCieError(AppConstants.ckrOk), CieErrorKind.unknown);
    });

    test('a specific CK_RV wins over a contradictory status word', () {
      expect(
        classifyCieError(AppConstants.ckrPinLocked, statusWord: 0x6300),
        CieErrorKind.pinBlocked,
      );
    });

    test('ckrGeneralError + 0x6983 (blocked) refines to pinBlocked', () {
      expect(
        classifyCieError(AppConstants.ckrGeneralError, statusWord: 0x6983),
        CieErrorKind.pinBlocked,
      );
    });

    test('ckrGeneralError + 0x63Cx refines to wrongPin', () {
      for (var low = 0; low <= 0xF; low++) {
        final sw = 0x63C0 + low;
        expect(
          classifyCieError(AppConstants.ckrGeneralError, statusWord: sw),
          CieErrorKind.wrongPin,
          reason: '0x${sw.toRadixString(16)} should refine to wrongPin',
        );
      }
    });

    test('ckrGeneralError + null statusWord falls back to the pre-existing '
        'kind', () {
      expect(
        classifyCieError(AppConstants.ckrGeneralError),
        CieErrorKind.cardCommunicationError,
      );
    });

    test(
      'ckrGeneralError + 0 statusWord falls back to the pre-existing kind',
      () {
        expect(
          classifyCieError(AppConstants.ckrGeneralError, statusWord: 0),
          CieErrorKind.cardCommunicationError,
        );
      },
    );

    test('ckrGeneralError + an unclassified status word falls back to the '
        'pre-existing kind', () {
      expect(
        classifyCieError(AppConstants.ckrGeneralError, statusWord: 0x1234),
        CieErrorKind.cardCommunicationError,
      );
    });

    test('OC-44: nativeErrorKind wins over a contradictory status word for a '
        'generic CK_RV failure', () {
      // native kind 1 == CIE_ERR_WRONG_PIN, but statusWord looks like a
      // pin-blocked SW; the native classification must take precedence.
      expect(
        classifyCieError(
          AppConstants.ckrGeneralError,
          statusWord: 0x6983,
          nativeErrorKind: 1,
        ),
        CieErrorKind.wrongPin,
      );
    });

    test('OC-44: every non-trivial native cie_error_kind maps correctly', () {
      const expected = {
        1: CieErrorKind.wrongPin,
        2: CieErrorKind.pinBlocked,
        3: CieErrorKind.wrongPinFormat,
        4: CieErrorKind.cardCommunicationError,
        5: CieErrorKind.cardCommunicationError,
        6: CieErrorKind.cardCommunicationError,
        7: CieErrorKind.extendedApduNotSupported,
        8: CieErrorKind.cardCommunicationError,
      };
      expected.forEach((kind, want) {
        expect(
          classifyCieError(AppConstants.ckrGeneralError, nativeErrorKind: kind),
          want,
          reason: 'native kind $kind',
        );
      });
    });

    test('OC-44: CIE_ERR_NONE (0) and CIE_ERR_UNKNOWN (9) fall back to the '
        'status-word heuristic instead of masking it', () {
      expect(
        classifyCieError(
          AppConstants.ckrGeneralError,
          statusWord: 0x6983,
          nativeErrorKind: 0,
        ),
        CieErrorKind.pinBlocked,
      );
      expect(
        classifyCieError(
          AppConstants.ckrGeneralError,
          statusWord: 0x6983,
          nativeErrorKind: 9,
        ),
        CieErrorKind.pinBlocked,
      );
    });

    test('ckrGeneralError + 0x6D00/0x6E00 (INS/CLA not supported) refines to '
        'extendedApduNotSupported', () {
      expect(
        classifyCieError(AppConstants.ckrGeneralError, statusWord: 0x6D00),
        CieErrorKind.extendedApduNotSupported,
      );
      expect(
        classifyCieError(AppConstants.ckrGeneralError, statusWord: 0x6E00),
        CieErrorKind.extendedApduNotSupported,
      );
    });
  });

  group('cieErrorMessage — wrongPin', () {
    test('renders the attempt count when remainingAttempts is non-null', () {
      expect(
        cieErrorMessage(en, CieErrorKind.wrongPin, remainingAttempts: 2),
        en.cieIncorrectPinAttempts(2),
      );
      expect(
        cieErrorMessage(it, CieErrorKind.wrongPin, remainingAttempts: 2),
        it.cieIncorrectPinAttempts(2),
      );
    });

    test('renders the plain string when remainingAttempts is null', () {
      expect(cieErrorMessage(en, CieErrorKind.wrongPin), en.signIncorrectPin);
      expect(cieErrorMessage(it, CieErrorKind.wrongPin), it.signIncorrectPin);
    });
  });

  test('cieErrorMessage — pinBlocked reuses ciePinLockedUsePuk', () {
    expect(cieErrorMessage(en, CieErrorKind.pinBlocked), en.ciePinLockedUsePuk);
    expect(cieErrorMessage(it, CieErrorKind.pinBlocked), it.ciePinLockedUsePuk);
  });

  group('cieErrorMessage — every other kind has a non-generic message', () {
    final kinds = {
      CieErrorKind.wrongPinFormat: (AppLocalizationsEn l) =>
          l.cieErrorWrongPinFormat,
      CieErrorKind.pinExpired: (AppLocalizationsEn l) => l.cieErrorPinExpired,
      CieErrorKind.cardNotPresent: (AppLocalizationsEn l) =>
          l.cieErrorCardNotPresent,
      CieErrorKind.notACie: (AppLocalizationsEn l) => l.cieErrorNotACie,
      CieErrorKind.tagLost: (AppLocalizationsEn l) => l.cieErrorTagLost,
      CieErrorKind.cardCommunicationError: (AppLocalizationsEn l) =>
          l.cieErrorCardCommunicationError,
      CieErrorKind.cancelledByUser: (AppLocalizationsEn l) =>
          l.cieErrorCancelledByUser,
      CieErrorKind.alreadyEnrolled: (AppLocalizationsEn l) =>
          l.cieErrorAlreadyEnrolled,
      CieErrorKind.readerNotFound: (AppLocalizationsEn l) =>
          l.cieErrorReaderNotFound,
      CieErrorKind.extendedApduNotSupported: (AppLocalizationsEn l) =>
          l.cieErrorExtendedApduNotSupported,
      CieErrorKind.cardExpired: (AppLocalizationsEn l) => l.cieErrorCardExpired,
    };

    kinds.forEach((kind, expected) {
      test('$kind', () {
        expect(cieErrorMessage(en, kind), expected(en));
      });
    });

    test('unknown embeds the raw code as hex', () {
      expect(
        cieErrorMessage(en, CieErrorKind.unknown, rawCode: 0xDEAD),
        en.cieErrorUnknown('0x0000DEAD'),
      );
    });

    test('unknown without a rawCode still returns a valid message', () {
      expect(
        cieErrorMessage(en, CieErrorKind.unknown),
        en.cieErrorUnknown('0x00000000'),
      );
    });
  });
}
