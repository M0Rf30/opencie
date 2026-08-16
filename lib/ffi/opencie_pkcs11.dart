// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/constants/app_constants.dart';
import 'models/verify_info.dart';
import 'opencie_bindings.dart';

// ---------------------------------------------------------------------------
// Isolate-level state & FFI callbacks
//
// These top-level globals are per-isolate, so each Isolate.run() invocation
// gets its own copy. The main isolate never touches them.
// ---------------------------------------------------------------------------

/// Per-isolate SendPort for forwarding progress events to the main isolate.
SendPort? _activeProgressPort;

/// Per-isolate storage for the cie_enable completed callback data.
/// Set by [_onCompleted]; read back in [OpenCiePkcs11.enable].
List<String>? _completedData;

/// Open the native library. Each isolate may call this; the OS caches the
/// underlying handle so repeated opens are cheap (just a dlopen refcount bump).
DynamicLibrary _openLib() {
  const name = AppConstants.libraryName;
  if (Platform.isLinux) return DynamicLibrary.open('lib$name.so');
  if (Platform.isWindows) return DynamicLibrary.open('$name.dll');
  if (Platform.isMacOS) return DynamicLibrary.open('lib$name.dylib');
  if (Platform.isAndroid) return DynamicLibrary.open('lib$name.so');
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}

/// FFI progress callback — sends [percent, message] to the main isolate.
/// Called synchronously by native code on the worker thread.
int _onProgress(int progress, Pointer<Utf8> message) {
  try {
    _activeProgressPort?.send([progress, message.toDartString()]);
  } catch (_) {
    // Never throw from an FFI callback.
  }
  return 0;
}

/// FFI enrolment-completed callback — stashes cardholder info for the caller.
int _onCompleted(Pointer<Utf8> pan, Pointer<Utf8> name, Pointer<Utf8> serial) {
  try {
    _completedData = [
      pan.toDartString(),
      name.toDartString(),
      serial.toDartString(),
    ];
  } catch (e) {
    // Never throw from an FFI callback; log the Pointer conversion failure.
    debugPrint(
      '_onCompleted: failed to read FFI strings (enrolment data lost): $e',
    );
  }
  return 0;
}

/// FFI sign-completed callback — result comes from the return value of
/// cie_sign, so this is a no-op.
int _onSignCompleted(int ret) => 0;

/// Cached soft lookup for `cie_last_error`. Per-isolate, matching the other
/// top-level state in this file: each [Isolate.run] invocation gets its own
/// copy, so the lookup (and its result) always happens on the isolate that
/// made the failing native call.
CieLastErrorDart? _cieLastErrorFn;
bool _cieLastErrorLookupDone = false;

/// Detail for the most recent failed `cie_*` call on the calling thread, or
/// null when the loaded library predates `cie_last_error`.
///
/// Must be called on the same isolate/thread as the failing native call —
/// the native record is thread-local.
({int kind, int statusWord})? lastNativeError() {
  if (!_cieLastErrorLookupDone) {
    _cieLastErrorLookupDone = true;
    try {
      _cieLastErrorFn = _openLib()
          .lookupFunction<CieLastErrorNative, CieLastErrorDart>(
            'cie_last_error',
          );
    } catch (_) {
      // Symbol not exported by the loaded library: degrade to "no detail".
      _cieLastErrorFn = null;
    }
  }
  final fn = _cieLastErrorFn;
  if (fn == null) return null;

  final kindPtr = calloc<Int32>();
  final swPtr = calloc<Uint16>();
  try {
    fn(kindPtr, swPtr);
    return (kind: kindPtr.value, statusWord: swPtr.value);
  } finally {
    calloc.free(kindPtr);
    calloc.free(swPtr);
  }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// High-level Dart wrapper around `libopencie-pkcs11`.
///
/// Long-running native calls (enable, sign, changePin, unblockPin) run in a
/// background isolate via [Isolate.run] to keep the UI responsive. Progress
/// callbacks are forwarded to the main isolate through a [SendPort].
class OpenCiePkcs11 {
  OpenCiePkcs11._();

  static OpenCiePkcs11? _instance;
  static DynamicLibrary? _lib;

  /// Singleton access. Loads the native library on first call.
  static OpenCiePkcs11 get instance {
    _instance ??= OpenCiePkcs11._();
    return _instance!;
  }

  /// The loaded native library (main-isolate handle for synchronous lookups).
  DynamicLibrary get lib {
    _lib ??= _openLib();
    return _lib!;
  }

  /// Initialize the native library's app-private data directory.
  /// Android only: the library uses this for its OCSP/CRL cache.
  /// Call once during app startup before any sign/verify operation.
  Future<void> initDataDir() async {
    if (!Platform.isAndroid) return;
    final dir = await getApplicationDocumentsDirectory();
    final fn = lib.lookupFunction<CieSetDataDirNative, CieSetDataDirDart>(
      'cie_set_data_dir',
    );
    final ptr = dir.path.toNativeUtf8();
    try {
      fn(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  // Lazy lookups for quick synchronous operations (main isolate only).
  late final _cieIsEnabled = lib
      .lookupFunction<CieIsEnabledNative, CieIsEnabledDart>('cie_is_enabled');
  late final _cieDisable = lib.lookupFunction<CieDisableNative, CieDisableDart>(
    'cie_disable',
  );
  late final _cieReaderCount = lib
      .lookupFunction<CieReaderCountNative, CieReaderCountDart>(
        'cie_reader_count',
      );
  late final _cieReaderName = lib
      .lookupFunction<CieReaderNameNative, CieReaderNameDart>(
        'cie_reader_name',
      );

  // ---------------------------------------------------------------------------
  // Enrollment
  // ---------------------------------------------------------------------------

  /// Enroll a CIE card. Returns [CieResult] with remaining attempts on error.
  ///
  /// The operation runs in a background isolate. [onProgress] is called on the
  /// main isolate with percentage (0–100) and a status message.
  Future<CieResult> enable({
    required String pan,
    required String pin,
    ValueChanged<CieProgress>? onProgress,
  }) async {
    return _withProgress(onProgress, (progressPort) async {
      return await Isolate.run(() {
        _activeProgressPort = progressPort;
        _completedData = null;

        final lib = _openLib();
        final fn = lib.lookupFunction<CieEnableNative, CieEnableDart>(
          'cie_enable',
        );

        final panPtr = pan.toNativeUtf8();
        final pinPtr = pin.toNativeUtf8();
        final attemptsPtr = calloc<Int32>();

        try {
          final rv = fn(
            panPtr,
            pinPtr,
            attemptsPtr,
            Pointer.fromFunction<ProgressCallbackNative>(_onProgress, 0),
            Pointer.fromFunction<CompletedCallbackNative>(_onCompleted, 0),
          );
          return CieResult(
            returnValue: rv,
            remainingAttempts: attemptsPtr.value,
            statusWord: rv == AppConstants.ckrOk
                ? null
                : lastNativeError()?.statusWord,
            enrolledPan: _completedData?.elementAtOrNull(0),
            enrolledName: _completedData?.elementAtOrNull(1),
            enrolledSerial: _completedData?.elementAtOrNull(2),
          );
        } finally {
          calloc.free(panPtr);
          calloc.free(pinPtr);
          calloc.free(attemptsPtr);
          _activeProgressPort = null;
          _completedData = null;
        }
      });
    });
  }

  /// Return number of PC/SC slots. Used internally for change detection.
  int readerCount() {
    try {
      return _cieReaderCount();
    } catch (e) {
      // 0 may indicate an FFI/PKCS11 init failure, not only 'no readers attached'.
      debugPrint('OpenCiePkcs11.readerCount: FFI exception: $e');
      return 0;
    }
  }

  /// Return the name of the first PC/SC reader, or null if none connected.
  String? readerName() {
    const bufLen = 256;
    final buf = calloc<Uint8>(bufLen);
    try {
      final found = _cieReaderName(buf.cast<Utf8>(), bufLen);
      if (found == 0) return null;
      return buf.cast<Utf8>().toDartString();
    } catch (_) {
      // Intentional fallback: FFI call failed (e.g. library not yet loaded); return null.
      return null;
    } finally {
      calloc.free(buf);
    }
  }

  /// Stream that emits the first reader name (or null) whenever it changes.
  /// Desktop-only; on Android emits nothing.
  Stream<String?> watchReaders() async* {
    if (Platform.isAndroid) return;

    final receiver = ReceivePort();
    yield readerName();

    final isolate = await Isolate.spawn(_readerWatchLoop, receiver.sendPort);

    try {
      await for (final msg in receiver) {
        if (msg is String?) yield msg;
      }
    } finally {
      isolate.kill(priority: Isolate.immediate);
      receiver.close();
    }
  }

  /// Interval between polls in [_readerWatchLoop]. Polling replaces the old
  /// blocking native watch call (`SCardGetStatusChange(hCtx, INFINITE,
  /// ...)`), which parked the spawned isolate's OS thread inside native
  /// code. `Isolate.kill(priority: Isolate.immediate)` cannot interrupt
  /// that, so app shutdown used to hang until a reader was physically
  /// unplugged. Each poll is just two cheap native calls (a few ms).
  static const Duration _readerPollInterval = Duration(seconds: 1);

  static Future<void> _readerWatchLoop(SendPort port) async {
    final lib = _openLib();
    final countFn = lib
        .lookupFunction<CieReaderCountNative, CieReaderCountDart>(
          'cie_reader_count',
        );
    final nameFn = lib.lookupFunction<CieReaderNameNative, CieReaderNameDart>(
      'cie_reader_name',
    );

    String? readName() {
      const bufLen = 256;
      final buf = calloc<Uint8>(bufLen);
      try {
        final found = nameFn(buf.cast<Utf8>(), bufLen);
        if (found == 0) return null;
        return buf.cast<Utf8>().toDartString();
      } finally {
        calloc.free(buf);
      }
    }

    int current = countFn();
    port.send(readName());

    while (true) {
      await Future<void>.delayed(_readerPollInterval);
      final next = countFn();
      if (next == current) continue;
      current = next;
      port.send(readName());
    }
  }

  /// Check if a card is enrolled. Quick synchronous call.
  bool isEnabled(String pan) {
    final panPtr = pan.toNativeUtf8();
    try {
      return _cieIsEnabled(panPtr) == 1;
    } finally {
      calloc.free(panPtr);
    }
  }

  /// Remove enrollment for a card. Quick synchronous call.
  int disable(String pan) {
    final panPtr = pan.toNativeUtf8();
    try {
      return _cieDisable(panPtr);
    } finally {
      calloc.free(panPtr);
    }
  }

  // ---------------------------------------------------------------------------
  // PIN management
  // ---------------------------------------------------------------------------

  /// Change PIN. Returns remaining attempts on error.
  Future<CieResult> changePin({
    required String currentPin,
    required String newPin,
    ValueChanged<CieProgress>? onProgress,
  }) async {
    return _withProgress(onProgress, (progressPort) async {
      return await Isolate.run(() {
        _activeProgressPort = progressPort;

        final lib = _openLib();
        final fn = lib.lookupFunction<CieChangePinNative, CieChangePinDart>(
          'cie_change_pin',
        );

        final curPtr = currentPin.toNativeUtf8();
        final newPtr = newPin.toNativeUtf8();
        final attemptsPtr = calloc<Int32>();

        try {
          final rv = fn(
            curPtr,
            newPtr,
            attemptsPtr,
            Pointer.fromFunction<ProgressCallbackNative>(_onProgress, 0),
          );
          return CieResult(
            returnValue: rv,
            remainingAttempts: attemptsPtr.value,
            statusWord: rv == AppConstants.ckrOk
                ? null
                : lastNativeError()?.statusWord,
          );
        } finally {
          calloc.free(curPtr);
          calloc.free(newPtr);
          calloc.free(attemptsPtr);
          _activeProgressPort = null;
        }
      });
    });
  }

  /// Unblock PIN using PUK.
  Future<CieResult> unblockPin({
    required String puk,
    required String newPin,
    ValueChanged<CieProgress>? onProgress,
  }) async {
    return _withProgress(onProgress, (progressPort) async {
      return await Isolate.run(() {
        _activeProgressPort = progressPort;

        final lib = _openLib();
        final fn = lib.lookupFunction<CieUnblockPinNative, CieUnblockPinDart>(
          'cie_unblock_pin',
        );

        final pukPtr = puk.toNativeUtf8();
        final newPtr = newPin.toNativeUtf8();
        final attemptsPtr = calloc<Int32>();

        try {
          final rv = fn(
            pukPtr,
            newPtr,
            attemptsPtr,
            Pointer.fromFunction<ProgressCallbackNative>(_onProgress, 0),
          );
          return CieResult(
            returnValue: rv,
            remainingAttempts: attemptsPtr.value,
            statusWord: rv == AppConstants.ckrOk
                ? null
                : lastNativeError()?.statusWord,
          );
        } finally {
          calloc.free(pukPtr);
          calloc.free(newPtr);
          calloc.free(attemptsPtr);
          _activeProgressPort = null;
        }
      });
    });
  }

  // ---------------------------------------------------------------------------
  // Signing
  // ---------------------------------------------------------------------------

  /// Sign a document using the CIE card.
  Future<CieResult> sign({
    required String inputPath,
    required String outputPath,
    required String signatureType,
    required String pin,
    required String pan,
    int page = 0,
    double x = 0,
    double y = 0,
    double w = 0,
    double h = 0,
    Uint8List? imageData,
    ValueChanged<CieProgress>? onProgress,
  }) async {
    return _withProgress(onProgress, (progressPort) async {
      return await Isolate.run(() {
        _activeProgressPort = progressPort;

        final lib = _openLib();
        final fn = lib.lookupFunction<CieSignNative, CieSignDart>('cie_sign');

        final inPtr = inputPath.toNativeUtf8();
        final outPtr = outputPath.toNativeUtf8();
        final typePtr = signatureType.toNativeUtf8();
        final pinPtr = pin.toNativeUtf8();
        final panPtr = pan.toNativeUtf8();

        Pointer<Uint8> imgPtr = nullptr;
        if (imageData != null && imageData.isNotEmpty) {
          imgPtr = calloc<Uint8>(imageData.length);
          imgPtr.asTypedList(imageData.length).setAll(0, imageData);
        }

        try {
          final rv = fn(
            inPtr,
            typePtr,
            pinPtr,
            panPtr,
            page,
            x,
            y,
            w,
            h,
            imgPtr,
            imageData?.length ?? 0,
            outPtr,
            Pointer.fromFunction<ProgressCallbackNative>(_onProgress, 0),
            Pointer.fromFunction<SignCompletedCallbackNative>(
              _onSignCompleted,
              0,
            ),
          );
          return CieResult(returnValue: rv);
        } finally {
          calloc.free(inPtr);
          calloc.free(outPtr);
          calloc.free(typePtr);
          calloc.free(pinPtr);
          calloc.free(panPtr);
          if (imageData != null && imageData.isNotEmpty) calloc.free(imgPtr);
          _activeProgressPort = null;
        }
      });
    });
  }

  // ---------------------------------------------------------------------------
  // Verification
  // ---------------------------------------------------------------------------

  /// Verify a signed document. Returns list of [VerifyInfo] for each signature.
  Future<List<VerifyInfo>> verify({
    required String inputPath,
    String? proxyAddress,
    int proxyPort = 0,
    String? proxyUserPass,
  }) async {
    return Isolate.run(() {
      final lib = _openLib();

      final cieVerify = lib.lookupFunction<CieVerifyNative, CieVerifyDart>(
        'cie_verify',
      );
      final cieGetSignCount = lib
          .lookupFunction<CieGetSignCountNative, CieGetSignCountDart>(
            'cie_get_sign_count',
          );
      final cieGetVerifyInfo = lib
          .lookupFunction<CieGetVerifyInfoNative, CieGetVerifyInfoDart>(
            'cie_get_verify_info',
          );

      final inPtr = inputPath.toNativeUtf8();
      final proxyPtr = proxyAddress?.toNativeUtf8() ?? nullptr;
      final passPtr = proxyUserPass?.toNativeUtf8() ?? nullptr;

      try {
        final rv = cieVerify(inPtr, proxyPtr.cast(), proxyPort, passPtr.cast());

        // cie_verify returns a signed long: negative values are errors,
        // 0 means success (use cie_get_sign_count for the actual count).
        if (rv < 0) {
          // Show the error as its unsigned hex representation for diagnostics.
          final hex = rv.toUnsigned(64).toRadixString(16);
          throw Exception('cie_verify failed: 0x$hex');
        }

        final count = cieGetSignCount();
        final results = <VerifyInfo>[];

        for (var i = 0; i < count; i++) {
          final infoPtr = calloc<VerifyInfoT>();
          try {
            cieGetVerifyInfo(i, infoPtr);
            results.add(
              VerifyInfo(
                name: infoPtr.name,
                surname: infoPtr.surname,
                commonName: infoPtr.cn,
                signingTime: infoPtr.signingTime,
                certificateAuthority: infoPtr.cadn,
                certRevocationStatus: infoPtr.ref.certRevocStatus,
                isSignatureValid: infoPtr.ref.isSignValid != 0,
                isCertificateValid: infoPtr.ref.isCertValid != 0,
              ),
            );
          } finally {
            calloc.free(infoPtr);
          }
        }
        return results;
      } finally {
        calloc.free(inPtr);
        if (proxyAddress != null) calloc.free(proxyPtr);
        if (proxyUserPass != null) calloc.free(passPtr);
      }
    });
  }

  /// Retrieve the DER-encoded X.509 certificate for an enrolled CIE card.
  ///
  /// Returns the raw DER bytes, or null if the card is not enrolled or an
  /// error occurs. Runs in a background isolate to avoid blocking the UI.
  Future<Uint8List?> getCertificate(String pan) async {
    return Isolate.run(() {
      final lib = _openLib();
      final fn = lib
          .lookupFunction<CieGetCertificateNative, CieGetCertificateDart>(
            'cie_get_certificate',
          );

      final panPtr = pan.toNativeUtf8();
      final outDerPtr = calloc<Pointer<Uint8>>();
      final outLenPtr = calloc<Uint64>();

      try {
        final rv = fn(panPtr, outDerPtr, outLenPtr);
        if (rv != 0) return null; // CKR_OK == 0

        final len = outLenPtr.value;
        if (len == 0) return null;

        final der = Uint8List.fromList(outDerPtr.value.asTypedList(len));
        calloc.free(outDerPtr.value); // free malloc'd buffer from native side
        return der;
      } finally {
        calloc.free(panPtr);
        calloc.free(outDerPtr);
        calloc.free(outLenPtr);
      }
    });
  }

  /// Read both DG1 (MRZ) and DG2 (photo) in a single PACE session.
  ///
  /// Returns a record `(mrzBytes, photoBytes)`. Either element may be null on
  /// error. Runs in a background isolate. Requires the card PIN.
  Future<(Uint8List?, Uint8List?)> readDgs({
    required String pin,
    ValueChanged<CieProgress>? onProgress,
  }) async {
    return _withProgress(onProgress, (progressPort) async {
      return await Isolate.run(() {
        _activeProgressPort = progressPort;
        final lib = _openLib();
        final fn = lib.lookupFunction<CieReadDgsNative, CieReadDgsDart>(
          'cie_read_dgs',
        );

        const mrzBufLen = 4096;
        const photoBufLen = 524288; // 512 KiB
        final pinPtr = pin.toNativeUtf8();
        final mrzPtr = calloc<Uint8>(mrzBufLen);
        final mrzLenPtr = calloc<Size>();
        final photoPtr = calloc<Uint8>(photoBufLen);
        final photoLenPtr = calloc<Size>();
        mrzLenPtr.value = mrzBufLen;
        photoLenPtr.value = photoBufLen;

        try {
          final rv = fn(pinPtr, mrzPtr, mrzLenPtr, photoPtr, photoLenPtr);
          if (rv != 0) return (null, null);

          final mrzLen = mrzLenPtr.value;
          final photoLen = photoLenPtr.value;
          final mrzBytes = mrzLen > 0
              ? Uint8List.fromList(mrzPtr.asTypedList(mrzLen))
              : null;
          final photoBytes = photoLen > 0
              ? Uint8List.fromList(photoPtr.asTypedList(photoLen))
              : null;
          return (mrzBytes, photoBytes);
        } finally {
          calloc.free(pinPtr);
          calloc.free(mrzPtr);
          calloc.free(mrzLenPtr);
          calloc.free(photoPtr);
          calloc.free(photoLenPtr);
          _activeProgressPort = null;
        }
      });
    });
  }

  /// Extract original document from a .p7m envelope.
  Future<CieResult> extractP7m({
    required String inputPath,
    required String outputPath,
  }) async {
    return Isolate.run(() {
      final lib = _openLib();
      final fn = lib.lookupFunction<CieExtractP7mNative, CieExtractP7mDart>(
        'cie_extract_p7m',
      );

      final inPtr = inputPath.toNativeUtf8();
      final outPtr = outputPath.toNativeUtf8();
      try {
        final rv = fn(inPtr, outPtr);
        return CieResult(returnValue: rv);
      } finally {
        calloc.free(inPtr);
        calloc.free(outPtr);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Timestamp, Encrypt, Decrypt
  // ---------------------------------------------------------------------------

  /// Apply RFC 3161 timestamp to a file using a Time Stamp Authority.
  /// No card required — uses TSA configuration.
  Future<CieResult> timestamp({
    required String inputPath,
    required String tsaUrl,
    String? tsaUsername,
    String? tsaPassword,
    required String outputPath,
    ValueChanged<CieProgress>? onProgress,
  }) async {
    return _withProgress(onProgress, (progressPort) async {
      return await Isolate.run(() {
        _activeProgressPort = progressPort;
        final lib = _openLib();
        final fn = lib.lookupFunction<CieTimestampNative, CieTimestampDart>(
          'cie_timestamp',
        );
        final inPtr = inputPath.toNativeUtf8();
        final tsaPtr = tsaUrl.toNativeUtf8();
        final userPtr = tsaUsername?.toNativeUtf8() ?? nullptr;
        final passPtr = tsaPassword?.toNativeUtf8() ?? nullptr;
        final outPtr = outputPath.toNativeUtf8();
        try {
          final rv = fn(
            inPtr,
            tsaPtr,
            userPtr.cast(),
            passPtr.cast(),
            outPtr,
            Pointer.fromFunction<ProgressCallbackNative>(_onProgress, 0),
          );
          return CieResult(returnValue: rv);
        } finally {
          calloc.free(inPtr);
          calloc.free(tsaPtr);
          if (tsaUsername != null) calloc.free(userPtr);
          if (tsaPassword != null) calloc.free(passPtr);
          calloc.free(outPtr);
          _activeProgressPort = null;
        }
      });
    });
  }

  // ---------------------------------------------------------------------------
  // Progress helper
  // ---------------------------------------------------------------------------

  /// Manages the ReceivePort lifecycle for progress callbacks.
  ///
  /// Creates a [ReceivePort] if [onProgress] is non-null, wires up the
  /// listener, passes the [SendPort] to [work], and cleans up afterward.
  Future<T> _withProgress<T>(
    ValueChanged<CieProgress>? onProgress,
    Future<T> Function(SendPort? progressPort) work,
  ) async {
    if (onProgress == null) {
      return work(null);
    }

    final receiver = ReceivePort();
    final subscription = receiver.listen((msg) {
      if (msg is List && msg.length == 2) {
        onProgress(
          CieProgress(percent: msg[0] as int, message: msg[1] as String),
        );
      }
    });

    try {
      return await work(receiver.sendPort);
    } finally {
      await subscription.cancel();
      receiver.close();
    }
  }
}

// ---------------------------------------------------------------------------
// Result types
// ---------------------------------------------------------------------------

/// Result of a CIE native operation.
class CieResult {
  const CieResult({
    required this.returnValue,
    this.remainingAttempts,
    this.statusWord,
    this.enrolledPan,
    this.enrolledName,
    this.enrolledSerial,
  });

  final int returnValue;
  final int? remainingAttempts;

  /// Raw ISO 7816 status word from the native `cie_last_error` channel,
  /// populated only when [returnValue] indicates failure. Null when the
  /// call succeeded or the loaded library predates `cie_last_error`.
  final int? statusWord;

  final String? enrolledPan;
  final String? enrolledName;
  final String? enrolledSerial;

  bool get isSuccess => returnValue == AppConstants.ckrOk;

  bool get isPinIncorrect => returnValue == AppConstants.ckrPinIncorrect;

  bool get isPinLocked => returnValue == AppConstants.ckrPinLocked;
}

/// Progress event from a long-running CIE operation.
class CieProgress {
  const CieProgress({required this.percent, required this.message});

  final int percent;
  final String message;
}
