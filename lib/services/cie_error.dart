// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import '../core/constants/app_constants.dart';
import '../core/l10n/app_localizations.dart';

/// Classified CIE card-operation failure.
///
/// Covers the failure modes `opencie-pkcs11` reports as PKCS#11 return
/// codes ([classifyCieError]) plus a few kinds no `CK_RV`/status-word path
/// currently reaches on their own:
///
/// - [readerNotFound] IS reachable, from `CKR_SLOT_ID_INVALID` (no PC/SC
///   reader attached — distinct from [cardNotPresent], which means a
///   reader exists but no card is on it).
/// - [extendedApduNotSupported] IS reachable, from SW `0x6D00`/`0x6E00`
///   (`CIE_ERR_INS_NOT_SUPPORTED` in `cie_ext.h`) — a reader/phone that
///   rejects the extended-length APDUs CIE operations require.
/// - [cardExpired] is NOT set by [classifyCieError]: no PKCS#11 return
///   code carries certificate-expiry information. Callers that already
///   parse the card's certificate (e.g. `cie_management_page.dart`'s
///   enrichment) should set this kind directly when `notAfter` is in the
///   past, so the shared message/hint copy stays in one place.
///
/// Deliberately still omitted: a wrong-CAN kind (OpenCIE has no CAN entry
/// path).
enum CieErrorKind {
  wrongPin,
  pinBlocked,
  wrongPinFormat,
  pinExpired,
  cardNotPresent,
  notACie,
  tagLost,
  cardCommunicationError,

  /// The card answered but does not expose the requested data (native
  /// FILE_NOT_FOUND, SW 6A82). Deterministic: retrying cannot help.
  chipDataUnavailable,
  cancelledByUser,
  alreadyEnrolled,
  readerNotFound,
  extendedApduNotSupported,
  cardExpired,

  /// Card answered but its chip/applet is not in the supported list. Comes
  /// from native kind 10 (`CIE_ERR_UNSUPPORTED_CARD`) together with
  /// `CKR_TOKEN_NOT_RECOGNIZED`. Not retryable.
  unsupportedCard,
  unknown,
}

/// Classifies a raw PKCS#11 return value from [CieResult.returnValue].
///
/// [statusWord] is the raw ISO 7816 status word from [CieResult.statusWord].
/// [nativeErrorKind] is the already-classified `cie_error_kind` from
/// [CieResult.nativeErrorKind] (the `cie_last_error` channel): when present
/// it is used directly instead of re-deriving a classification from
/// [statusWord] in Dart, so the two layers cannot drift out of sync.
/// [statusWord] remains as a fallback for libraries predating
/// `cie_last_error`, and only refines the generic codes (`ckrGeneralError`,
/// `ckrFunctionFailed`, `ckrDeviceError`) that the native layer falls back
/// to when it has no more specific `CK_RV` for a card failure — every other
/// `CK_RV` mapping below is authoritative and ignores both.
CieErrorKind classifyCieError(
  int returnValue, {
  int? statusWord,
  int? nativeErrorKind,
}) {
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
      // Native kind 10 (unsupported chip) refines the plain "not a CIE".
      return _kindFromNative(nativeErrorKind) == CieErrorKind.unsupportedCard
          ? CieErrorKind.unsupportedCard
          : CieErrorKind.notACie;
    case AppConstants.ckrDeviceRemoved:
      return CieErrorKind.tagLost;
    case AppConstants.ckrDeviceError:
    case AppConstants.ckrGeneralError:
    case AppConstants.ckrFunctionFailed:
      return _kindFromNative(nativeErrorKind) ??
          _classifyGenericFailure(statusWord);
    case AppConstants.ckrCancel:
    case AppConstants.ckrFunctionCanceled:
      return CieErrorKind.cancelledByUser;
    case AppConstants.ckrAlreadyEnabled:
      return CieErrorKind.alreadyEnrolled;
    case AppConstants.ckrSlotIdInvalid:
      return CieErrorKind.readerNotFound;
    default:
      return CieErrorKind.unknown;
  }
}

/// Maps opencie-pkcs11's already-classified `cie_error_kind` enum (from
/// `cie_last_error`, surfaced as [CieResult.nativeErrorKind]) directly onto
/// [CieErrorKind]. Values mirror `enum cie_error_kind` in `cie_ext.h`:
/// 0 NONE, 1 WRONG_PIN, 2 PIN_BLOCKED, 3 PIN_NOT_SET,
/// 4 SECURITY_NOT_SATISFIED, 5 FILE_NOT_FOUND (-> chipDataUnavailable), 6 WRONG_PARAMS,
/// 7 INS_NOT_SUPPORTED, 8 CARD_COMMUNICATION, 9 UNKNOWN,
/// 10 UNSUPPORTED_CARD.
///
/// Returns null for NONE/UNKNOWN/an absent value, letting the caller fall
/// back to [_classifyGenericFailure]'s status-word heuristic.
CieErrorKind? _kindFromNative(int? nativeErrorKind) {
  switch (nativeErrorKind) {
    case 1:
      return CieErrorKind.wrongPin;
    case 2:
      return CieErrorKind.pinBlocked;
    case 3:
      return CieErrorKind.wrongPinFormat;
    case 5: // CIE_ERR_FILE_NOT_FOUND (SW 6A82): data absent, not a link drop
      return CieErrorKind.chipDataUnavailable;
    case 4:
    case 6:
    case 8:
      return CieErrorKind.cardCommunicationError;
    case 7: // CIE_ERR_INS_NOT_SUPPORTED (SW 6D00/6E00)
      return CieErrorKind.extendedApduNotSupported;
    case 10: // CIE_ERR_UNSUPPORTED_CARD
      return CieErrorKind.unsupportedCard;
    case 0:
    case 9:
    default:
      return null;
  }
}

/// Refines a generic `CK_RV` failure using the ISO 7816 status word, when
/// [_kindFromNative] found no usable native classification. Falls back to
/// [CieErrorKind.cardCommunicationError] — the pre-existing mapping for
/// these `CK_RV` codes — for a null/zero [statusWord] or one this taxonomy
/// does not recognise.
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
    case 0x6D00:
    case 0x6E00:
      return CieErrorKind.extendedApduNotSupported;
    case 0x6982:
    case 0x6A82:
    case 0x6A80:
    case 0x6A86:
    case 0x6A88:
    case 0x6B00:
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
    case CieErrorKind.chipDataUnavailable:
      return l10n.cieErrorChipDataUnavailable;
    case CieErrorKind.cancelledByUser:
      return l10n.cieErrorCancelledByUser;
    case CieErrorKind.alreadyEnrolled:
      return l10n.cieErrorAlreadyEnrolled;
    case CieErrorKind.readerNotFound:
      return l10n.cieErrorReaderNotFound;
    case CieErrorKind.extendedApduNotSupported:
      return l10n.cieErrorExtendedApduNotSupported;
    case CieErrorKind.cardExpired:
      return l10n.cieErrorCardExpired;
    case CieErrorKind.unsupportedCard:
      return l10n.cieErrorUnsupportedCard;
    case CieErrorKind.unknown:
      return l10n.cieErrorUnknown(_hexCode(rawCode ?? 0));
  }
}

String _hexCode(int code) =>
    '0x${code.toUnsigned(32).toRadixString(16).toUpperCase().padLeft(8, '0')}';
