// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/constants/app_constants.dart';
import 'app_localizations.dart';

extension CieProgressL10n on AppLocalizations {
  /// Translates a PKCS#11 return code into a human-readable error reason.
  /// Used as the `{reason}` argument in operation-failed messages.
  String humanizeError(int code) {
    switch (code) {
      case AppConstants.ckrOk:
        return cieProgressDone;
      case AppConstants.ckrCancel:
      case AppConstants.ckrFunctionCanceled:
        return errCancelled;
      case AppConstants.ckrTokenNotPresent:
        return errCardNotFound;
      case AppConstants.ckrDeviceRemoved:
        return errCardMoved;
      case AppConstants.ckrDeviceError:
        return errCardError;
      case AppConstants.ckrPinExpired:
        return errPinExpired;
      case AppConstants.ckrPinInvalid:
      case AppConstants.ckrPinLenRange:
        return errPinInvalid;
      case AppConstants.ckrPinIncorrect:
        return signIncorrectPin;
      case AppConstants.ckrPinLocked:
        return ciePinLockedUsePuk;
      case AppConstants.ckrTokenNotRecognized:
        return errCardNotRecognized;
      case AppConstants.ckrAlreadyEnabled:
        return errAlreadyEnrolled;
      case AppConstants.ckrGeneralError:
      case AppConstants.ckrFunctionFailed:
      default:
        final hex = code
            .toUnsigned(32)
            .toRadixString(16)
            .toUpperCase()
            .padLeft(8, '0');
        return errUnknown('0x$hex');
    }
  }

  String localizeProgress(String raw) {
    switch (raw.trim()) {
      case 'Connessione alla CIE':
        return cieProgressConnecting;
      case 'CIE Connessa':
        return cieProgressConnected;
      case 'Verifica carta esistente':
        return cieProgressCheckingCard;
      case 'Lettura dati dalla CIE':
        return cieProgressReadingData;
      case 'Autenticazione...':
      case 'Authenticating...':
        return cieProgressAuthStart;
      case 'selected CIE applet':
        return cieProgressSelectApplet;
      case 'init DH Param':
        return cieProgressInitSecurity;
      case 'read DappPubKey':
        return cieProgressReadPublicKey;
      case 'InitExtAuthKeyParam':
        return cieProgressKeyExchangeSetup;
      case 'DHKeyExchange':
        return cieProgressKeyExchange;
      case 'DAPP':
        return cieProgressCardAuth;
      case 'VerifyPIN':
        return cieProgressVerifyPin;
      case 'verifyPIN ok':
        return cieProgressPinVerified;
      case 'Lettura seriale':
        return cieProgressReadSerial;
      case 'Lettura certificato':
      case 'Getting certificate from CIE...':
        return cieProgressReadCertificate;
      case 'Memorizzazione in cache':
        return cieProgressSaving;
      case 'Cambio PIN...':
      case 'Changing PIN...':
        return cieProgressChangingPin;
      case 'Cambio PIN eseguito':
      case 'PIN changed successfully':
        return cieProgressPinChanged;
      case 'Sblocco carta...':
      case 'Unblocking card...':
        return cieProgressUnblocking;
      case 'Sblocco carta eseguito':
      case 'Card unblocked':
        return cieProgressUnblocked;
      case 'Looking for CIE...':
        return cieProgressLookingForCie;
      case 'Starting signature...':
        return cieProgressSigning;
      case 'OK!':
        return cieProgressDone;
      default:
        return raw;
    }
  }
}
