// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import '../core/constants/app_constants.dart';
import '../core/l10n/app_localizations.dart';

/// Classified CIE card-operation failure.
///
/// Narrowed to the failure modes `opencie-pkcs11` actually reports as
/// PKCS#11 return codes.
///
/// Deliberately omitted: a wrong-CAN kind (OpenCIE has no CAN entry path)
/// and certificate-status / extended-APDU kinds (`opencie-pkcs11` never
/// returns those as PKCS#11 codes). They would be dead branches no return
/// value can ever reach.
enum CieErrorKind {
  wrongPin,
  pinBlocked,
  wrongPinFormat,
  pinExpired,
  cardNotPresent,
  notACie,
  tagLost,
  cardCommunicationError,
  cancelledByUser,
  alreadyEnrolled,
  unknown,
}

/// Classifies a raw PKCS#11 return value from [CieResult.returnValue].
///
/// [statusWord] is the raw ISO 7816 status word from [CieResult.statusWord],
/// when available. It only refines the generic codes (`ckrGeneralError`,
/// `ckrFunctionFailed`, `ckrDeviceError`) that the native layer falls back
/// to when it has no more specific `CK_RV` for a card failure — every other
/// `CK_RV` mapping below is authoritative and ignores [statusWord].
CieErrorKind classifyCieError(int returnValue, {int? statusWord}) {
  switch (returnValue) {
    case AppConstants.ckrPinIncorrect:
      return CieErrorKind.wrongPin;
    case AppConstants.ckrPinLocked:
      return CieErrorKind.pinBlocked;
    case AppConstants.ckrPinInvalid:
    case AppConstants.ckrPinLenRange:
      return CieErrorKind.wrongPinFormat;
    case AppConstants.ckrPinExpired:
      return CieErrorKind.pinExpired;
    case AppConstants.ckrTokenNotPresent:
      return CieErrorKind.cardNotPresent;
    case AppConstants.ckrTokenNotRecognized:
      return CieErrorKind.notACie;
    case AppConstants.ckrDeviceRemoved:
      return CieErrorKind.tagLost;
    case AppConstants.ckrDeviceError:
    case AppConstants.ckrGeneralError:
    case AppConstants.ckrFunctionFailed:
      return _classifyGenericFailure(statusWord);
    case AppConstants.ckrCancel:
    case AppConstants.ckrFunctionCanceled:
      return CieErrorKind.cancelledByUser;
    case AppConstants.ckrAlreadyEnabled:
      return CieErrorKind.alreadyEnrolled;
    default:
      return CieErrorKind.unknown;
  }
}

/// Refines a generic `CK_RV` failure using the ISO 7816 status word, when
/// one is available. Falls back to [CieErrorKind.cardCommunicationError] —
/// the pre-existing mapping for these `CK_RV` codes — for a null/zero
/// [statusWord] or one this taxonomy does not recognise.
CieErrorKind _classifyGenericFailure(int? statusWord) {
  if (statusWord == null || statusWord == 0) {
    return CieErrorKind.cardCommunicationError;
  }
  if ((statusWord >= 0x63C0 && statusWord <= 0x63CF) ||
      statusWord == 0x6300 ||
      statusWord == 0x6700) {
    return CieErrorKind.wrongPin;
  }
  switch (statusWord) {
    case 0x6983:
      return CieErrorKind.pinBlocked;
    case 0x6984:
      return CieErrorKind.wrongPinFormat;
    case 0x6982:
    case 0x6A82:
    case 0x6A80:
    case 0x6A86:
    case 0x6A88:
    case 0x6B00:
    case 0x6D00:
    case 0x6E00:
      return CieErrorKind.cardCommunicationError;
    default:
      return CieErrorKind.cardCommunicationError;
  }
}

/// Localised title + recovery instruction for the classified failure.
///
/// [remainingAttempts] renders the attempt count for [CieErrorKind.wrongPin]
/// when known; every other kind ignores it.
///
/// [rawCode] is an additive, optional extra: when [kind] is
/// [CieErrorKind.unknown], it is rendered (as hex) in the fallback message
/// for support/diagnostic purposes. Omitting it still yields a valid message
/// — every documented call of `cieErrorMessage(l10n, kind, remainingAttempts:
/// …)` keeps working unchanged.
String cieErrorMessage(
  AppLocalizations l10n,
  CieErrorKind kind, {
  int? remainingAttempts,
  int? rawCode,
}) {
  switch (kind) {
    case CieErrorKind.wrongPin:
      return remainingAttempts != null
          ? l10n.cieIncorrectPinAttempts(remainingAttempts)
          : l10n.signIncorrectPin;
    case CieErrorKind.pinBlocked:
      return l10n.ciePinLockedUsePuk;
    case CieErrorKind.wrongPinFormat:
      return l10n.cieErrorWrongPinFormat;
    case CieErrorKind.pinExpired:
      return l10n.cieErrorPinExpired;
    case CieErrorKind.cardNotPresent:
      return l10n.cieErrorCardNotPresent;
    case CieErrorKind.notACie:
      return l10n.cieErrorNotACie;
    case CieErrorKind.tagLost:
      return l10n.cieErrorTagLost;
    case CieErrorKind.cardCommunicationError:
      return l10n.cieErrorCardCommunicationError;
    case CieErrorKind.cancelledByUser:
      return l10n.cieErrorCancelledByUser;
    case CieErrorKind.alreadyEnrolled:
      return l10n.cieErrorAlreadyEnrolled;
    case CieErrorKind.unknown:
      return l10n.cieErrorUnknown(_hexCode(rawCode ?? 0));
  }
}

String _hexCode(int code) =>
    '0x${code.toUnsigned(32).toRadixString(16).toUpperCase().padLeft(8, '0')}';
