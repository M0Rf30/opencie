// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/settings_provider.dart';
import '../screen_guard.dart';
import '../secure_store.dart';
import 'app_lock_service.dart';
import 'biometric_auth.dart';

final appLockServiceProvider = Provider<AppLockService>(
  (ref) => AppLockService(),
);

final biometricAuthProvider = Provider<BiometricAuth>(
  (ref) => LocalBiometricAuth(),
);

class AppLockState {
  const AppLockState({
    this.loaded = false,
    this.config = const AppLockConfig(),
    this.locked = false,
    this.biometricsAvailable = false,
  });

  final bool loaded;
  final AppLockConfig config;
  final bool locked;
  final bool biometricsAvailable;

  bool get enabled => config.enabled;

  AppLockState copyWith({
    bool? loaded,
    AppLockConfig? config,
    bool? locked,
    bool? biometricsAvailable,
  }) => AppLockState(
    loaded: loaded ?? this.loaded,
    config: config ?? this.config,
    locked: locked ?? this.locked,
    biometricsAvailable: biometricsAvailable ?? this.biometricsAvailable,
  );
}

class AppLockController extends Notifier<AppLockState> {
  bool _guarded = false;

  /// True while a biometric prompt is up: the OS reports the app as
  /// inactive/paused meanwhile, which must not count as leaving the app.
  bool biometricBusy = false;

  AppLockService get service => ref.read(appLockServiceProvider);

  @override
  AppLockState build() {
    Future.microtask(load);
    return const AppLockState();
  }

  Future<void> load() async {
    var config = const AppLockConfig();
    try {
      config = await service.load();
    } on SecureStoreException {
      ref.read(settingsProvider.notifier).flagSecureStorageUnavailable();
    }
    final bioAvail = await ref.read(biometricAuthProvider).isAvailable();
    state = AppLockState(
      loaded: true,
      config: config,
      // Cold start: locked whenever the lock is enabled.
      locked: config.enabled,
      biometricsAvailable: bioAvail,
    );
    _syncGuard();
  }

  void _syncGuard() {
    final want = state.locked;
    if (want == _guarded) return;
    _guarded = want;
    if (want) {
      ScreenGuard.protect();
    } else {
      ScreenGuard.unprotect();
    }
  }

  void lock() {
    if (!state.enabled || state.locked) return;
    state = state.copyWith(locked: true);
    _syncGuard();
  }

  void _unlock() {
    state = state.copyWith(locked: false);
    _syncGuard();
  }

  Future<UnlockResult> submitPasscode(String code) async {
    final result = await service.verify(code);
    if (result is UnlockOk) _unlock();
    return result;
  }

  /// Prompts for biometrics; unlocks on success.
  Future<bool> tryBiometric(String reason) async {
    if (!state.locked || !state.config.biometrics) return false;
    if (!state.biometricsAvailable || biometricBusy) return false;
    biometricBusy = true;
    try {
      final ok = await ref.read(biometricAuthProvider).authenticate(reason);
      if (ok && state.locked) {
        await service.noteBiometricSuccess();
        _unlock();
      }
      return ok;
    } finally {
      biometricBusy = false;
    }
  }

  /// Enables the lock with a new passcode (or changes the existing one).
  Future<void> setPasscode(String passcode) async {
    await service.setPasscode(passcode);
    final config = state.config.copyWith(enabled: true);
    await service.saveConfig(config);
    state = state.copyWith(config: config);
  }

  /// Checks a passcode without changing the lock state (settings flows).
  Future<UnlockResult> verifyCurrent(String passcode) =>
      service.verify(passcode);

  /// Turns the lock off. Callers verify the current passcode first.
  Future<void> disable() async {
    await service.disable();
    state = state.copyWith(config: const AppLockConfig(), locked: false);
    _syncGuard();
  }

  Future<void> setTimeout(AutoLockTimeout t) async {
    final config = state.config.copyWith(timeout: t);
    await service.saveConfig(config);
    state = state.copyWith(config: config);
  }

  Future<void> setBiometrics(bool on) async {
    final config = state.config.copyWith(biometrics: on);
    await service.saveConfig(config);
    state = state.copyWith(config: config);
  }

  /// "Forgot passcode": wipes the app-lock secret and the enrolled-card
  /// records. Callers must have obtained explicit confirmation.
  Future<void> resetAppData() async {
    await ref
        .read(settingsProvider.notifier)
        .update((s) => s.copyWith(enrolledCards: const []));
    await disable();
  }
}

final appLockProvider = NotifierProvider<AppLockController, AppLockState>(
  AppLockController.new,
);
