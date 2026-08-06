// SPDX-License-Identifier: GPL-3.0-or-later

// ignore_for_file: non_constant_identifier_names, camel_case_types
//
// Low-level FFI bindings to libopencie-pkcs11.
// Mirrors include/opencie/cie_ext.h exactly.

import 'dart:ffi';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// Type aliases matching PKCS#11 / CIE types
// ---------------------------------------------------------------------------

/// PKCS#11 CK_RV — unsigned long.
typedef CK_RV = UnsignedLong;
typedef CK_RV_Dart = int;

// ---------------------------------------------------------------------------
// Callback types
// ---------------------------------------------------------------------------

/// typedef CK_RV (*PROGRESS_CALLBACK)(int progress, const char* szMessage);
typedef ProgressCallbackNative =
    UnsignedLong Function(Int32 progress, Pointer<Utf8> szMessage);
typedef ProgressCallbackDart =
    int Function(int progress, Pointer<Utf8> szMessage);

/// typedef CK_RV (*COMPLETED_CALLBACK)(const char* szPan, const char* szName,
///                                     const char* ef_seriale);
typedef CompletedCallbackNative =
    UnsignedLong Function(
      Pointer<Utf8> szPan,
      Pointer<Utf8> szName,
      Pointer<Utf8> efSeriale,
    );

/// typedef CK_RV (*SIGN_COMPLETED_CALLBACK)(int ret);
typedef SignCompletedCallbackNative = UnsignedLong Function(Int32 ret);

// ---------------------------------------------------------------------------
// Struct: verifyInfo_t
// ---------------------------------------------------------------------------

const int _maxLen = 512;
const int _fieldLen = _maxLen * 2;

/// Mirrors `struct verifyInfo_t` from cie_ext.h.
final class VerifyInfoT extends Struct {
  @Array(_fieldLen)
  external Array<Uint8> _name;

  @Array(_fieldLen)
  external Array<Uint8> _surname;

  @Array(_fieldLen)
  external Array<Uint8> _cn;

  @Array(_fieldLen)
  external Array<Uint8> _signingTime;

  @Array(_fieldLen)
  external Array<Uint8> _cadn;

  @Int32()
  external int certRevocStatus;

  // cie_ext.h declares these as C `int` (4 bytes).
  @Int32()
  external int isSignValid;

  @Int32()
  external int isCertValid;
}

// ---------------------------------------------------------------------------
// Extension to read char arrays from VerifyInfoT
// ---------------------------------------------------------------------------

extension VerifyInfoTReader on Pointer<VerifyInfoT> {
  String get name => _readCharArray(ref._name);
  String get surname => _readCharArray(ref._surname);
  String get cn => _readCharArray(ref._cn);
  String get signingTime => _readCharArray(ref._signingTime);
  String get cadn => _readCharArray(ref._cadn);

  static String _readCharArray(Array<Uint8> arr) {
    final bytes = <int>[];
    for (var i = 0; i < _fieldLen; i++) {
      final b = arr[i];
      if (b == 0) break;
      bytes.add(b);
    }
    return String.fromCharCodes(bytes);
  }
}

// ---------------------------------------------------------------------------
// Native function signatures
// ---------------------------------------------------------------------------

// --- Enrollment ---

typedef CieEnableNative =
    UnsignedLong Function(
      Pointer<Utf8> szPAN,
      Pointer<Utf8> szPIN,
      Pointer<Int32> attempts,
      Pointer<NativeFunction<ProgressCallbackNative>> progressCallBack,
      Pointer<NativeFunction<CompletedCallbackNative>> completedCallBack,
    );
typedef CieEnableDart =
    int Function(
      Pointer<Utf8> szPAN,
      Pointer<Utf8> szPIN,
      Pointer<Int32> attempts,
      Pointer<NativeFunction<ProgressCallbackNative>> progressCallBack,
      Pointer<NativeFunction<CompletedCallbackNative>> completedCallBack,
    );

typedef CieIsEnabledNative = UnsignedLong Function(Pointer<Utf8> szPAN);
typedef CieIsEnabledDart = int Function(Pointer<Utf8> szPAN);

typedef CieDisableNative = UnsignedLong Function(Pointer<Utf8> szPAN);
typedef CieDisableDart = int Function(Pointer<Utf8> szPAN);

// --- PIN management ---

typedef CieChangePinNative =
    UnsignedLong Function(
      Pointer<Utf8> szCurrentPIN,
      Pointer<Utf8> szNewPIN,
      Pointer<Int32> attempts,
      Pointer<NativeFunction<ProgressCallbackNative>> progressCallBack,
    );
typedef CieChangePinDart =
    int Function(
      Pointer<Utf8> szCurrentPIN,
      Pointer<Utf8> szNewPIN,
      Pointer<Int32> attempts,
      Pointer<NativeFunction<ProgressCallbackNative>> progressCallBack,
    );

typedef CieUnblockPinNative =
    UnsignedLong Function(
      Pointer<Utf8> szPUK,
      Pointer<Utf8> szNewPIN,
      Pointer<Int32> attempts,
      Pointer<NativeFunction<ProgressCallbackNative>> progressCallBack,
    );
typedef CieUnblockPinDart =
    int Function(
      Pointer<Utf8> szPUK,
      Pointer<Utf8> szNewPIN,
      Pointer<Int32> attempts,
      Pointer<NativeFunction<ProgressCallbackNative>> progressCallBack,
    );

// --- Sign & Verify ---

typedef CieSignNative =
    UnsignedLong Function(
      Pointer<Utf8> inFilePath,
      Pointer<Utf8> type,
      Pointer<Utf8> pin,
      Pointer<Utf8> pan,
      Int32 page,
      Float x,
      Float y,
      Float w,
      Float h,
      Pointer<Uint8> imageData,
      Int32 imageDataLen,
      Pointer<Utf8> outFilePath,
      Pointer<NativeFunction<ProgressCallbackNative>> progressCallBack,
      Pointer<NativeFunction<SignCompletedCallbackNative>> completedCallBack,
    );
typedef CieSignDart =
    int Function(
      Pointer<Utf8> inFilePath,
      Pointer<Utf8> type,
      Pointer<Utf8> pin,
      Pointer<Utf8> pan,
      int page,
      double x,
      double y,
      double w,
      double h,
      Pointer<Uint8> imageData,
      int imageDataLen,
      Pointer<Utf8> outFilePath,
      Pointer<NativeFunction<ProgressCallbackNative>> progressCallBack,
      Pointer<NativeFunction<SignCompletedCallbackNative>> completedCallBack,
    );

typedef CieVerifyNative =
    Long Function(
      Pointer<Utf8> inFilePath,
      Pointer<Utf8> proxyAddress,
      Int32 proxyPort,
      Pointer<Utf8> usrPass,
    );
typedef CieVerifyDart =
    int Function(
      Pointer<Utf8> inFilePath,
      Pointer<Utf8> proxyAddress,
      int proxyPort,
      Pointer<Utf8> usrPass,
    );

typedef CieGetSignCountNative = UnsignedLong Function();
typedef CieGetSignCountDart = int Function();

typedef CieGetVerifyInfoNative =
    UnsignedLong Function(Int32 index, Pointer<VerifyInfoT> vInfos);
typedef CieGetVerifyInfoDart =
    int Function(int index, Pointer<VerifyInfoT> vInfos);

typedef CieExtractP7mNative =
    UnsignedLong Function(Pointer<Utf8> inFilePath, Pointer<Utf8> outFilePath);
typedef CieExtractP7mDart =
    int Function(Pointer<Utf8> inFilePath, Pointer<Utf8> outFilePath);

typedef CieReaderCountNative = Int32 Function();
typedef CieReaderCountDart = int Function();

typedef CieReaderWatchNative = Int32 Function(Int32 currentCount);
typedef CieReaderWatchDart = int Function(int currentCount);

typedef CieReaderNameNative = Int32 Function(Pointer<Utf8> buf, Int32 bufLen);
typedef CieReaderNameDart = int Function(Pointer<Utf8> buf, int bufLen);

// --- App-private data directory (Android only) ---

/// void cie_set_data_dir(const char* dir);
typedef CieSetDataDirNative = Void Function(Pointer<Utf8> dir);
typedef CieSetDataDirDart = void Function(Pointer<Utf8> dir);

// --- Low-level helpers ---

/// int make_digest_info(int algid, const unsigned char* pbtDigest,
///                      size_t btDigestLen, unsigned char* pbtDigestInfo,
///                      size_t* pbtDigestInfoLen);
typedef MakeDigestInfoNative =
    Int32 Function(
      Int32 algid,
      Pointer<Uint8> pbtDigest,
      Size btDigestLen,
      Pointer<Uint8> pbtDigestInfo,
      Pointer<Size> pbtDigestInfoLen,
    );
typedef MakeDigestInfoDart =
    int Function(
      int algid,
      Pointer<Uint8> pbtDigest,
      int btDigestLen,
      Pointer<Uint8> pbtDigestInfo,
      Pointer<Size> pbtDigestInfoLen,
    );

// --- Certificate retrieval ---

/// CK_RV cie_get_certificate(const char* pan,
///                            unsigned char** outDer,
///                            unsigned long* outLen);
typedef CieGetCertificateNative =
    Uint64 Function(
      Pointer<Utf8> pan,
      Pointer<Pointer<Uint8>> outDer,
      Pointer<Uint64> outLen,
    );
typedef CieGetCertificateDart =
    int Function(
      Pointer<Utf8> pan,
      Pointer<Pointer<Uint8>> outDer,
      Pointer<Uint64> outLen,
    );

// --- Timestamp ---

/// CK_RV cie_timestamp(const char* inFilePath, const char* tsaUrl,
///                     const char* tsaUsername, const char* tsaPassword,
///                     const char* outTokenPath,
///                     PROGRESS_CALLBACK progressCallBack);
typedef CieTimestampNative =
    UnsignedLong Function(
      Pointer<Utf8> inFilePath,
      Pointer<Utf8> tsaUrl,
      Pointer<Utf8> tsaUsername,
      Pointer<Utf8> tsaPassword,
      Pointer<Utf8> outTokenPath,
      Pointer<NativeFunction<ProgressCallbackNative>> progressCallBack,
    );
typedef CieTimestampDart =
    int Function(
      Pointer<Utf8> inFilePath,
      Pointer<Utf8> tsaUrl,
      Pointer<Utf8> tsaUsername,
      Pointer<Utf8> tsaPassword,
      Pointer<Utf8> outTokenPath,
      Pointer<NativeFunction<ProgressCallbackNative>> progressCallBack,
    );

// --- Combined DG1 + DG2 (single PACE session) ---

/// CK_RV cie_read_dgs(const char *pin,
///                    char *mrzOut, size_t *mrzLen,
///                    unsigned char *photoOut, size_t *photoLen);
typedef CieReadDgsNative =
    UnsignedLong Function(
      Pointer<Utf8> pin,
      Pointer<Uint8> mrzOut,
      Pointer<Size> mrzLen,
      Pointer<Uint8> photoOut,
      Pointer<Size> photoLen,
    );
typedef CieReadDgsDart =
    int Function(
      Pointer<Utf8> pin,
      Pointer<Uint8> mrzOut,
      Pointer<Size> mrzLen,
      Pointer<Uint8> photoOut,
      Pointer<Size> photoLen,
    );

// --- Last-error detail (thread-local) ---

/// CK_RV cie_last_error(cie_error_kind* outKind, uint16_t* outSw);
typedef CieLastErrorNative =
    UnsignedLong Function(Pointer<Int32> outKind, Pointer<Uint16> outSw);
typedef CieLastErrorDart =
    int Function(Pointer<Int32> outKind, Pointer<Uint16> outSw);
