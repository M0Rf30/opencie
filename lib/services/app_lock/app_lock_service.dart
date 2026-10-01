// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import '../secure_store.dart';
import 'passcode_hasher.dart';

/// Minimal key-value surface the app lock needs; [SecureStore] in
/// production, an in-memory map in tests.
abstract class AppLockStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureAppLockStorage implements AppLockStorage {
  const SecureAppLockStorage();
  @override
  Future<String?> read(String key) => SecureStore.read(key);
  @override
  Future<void> write(String key, String value) => SecureStore.write(key, value);
  @override
  Future<void> delete(String key) => SecureStore.delete(key);
}

/// Auto-lock delay choices (Telegram-like).
enum AutoLockTimeout {
  immediately(Duration.zero),
  oneMinute(Duration(minutes: 1)),
  fiveMinutes(Duration(minutes: 5)),
  oneHour(Duration(hours: 1)),
  fiveHours(Duration(hours: 5));

  const AutoLockTimeout(this.duration);
  final Duration duration;

  static AutoLockTimeout byNameOr(String? name, AutoLockTimeout fallback) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return fallback;
  }
}

class AppLockConfig {
  const AppLockConfig({
    this.enabled = false,
    this.timeout = AutoLockTimeout.oneMinute,
    this.biometrics = false,
  });

  final bool enabled;
  final AutoLockTimeout timeout;
  final bool biometrics;

  AppLockConfig copyWith({
    bool? enabled,
    AutoLockTimeout? timeout,
    bool? biometrics,
  }) => AppLockConfig(
    enabled: enabled ?? this.enabled,
    timeout: timeout ?? this.timeout,
    biometrics: biometrics ?? this.biometrics,
  );
}

sealed class UnlockResult {
  const UnlockResult();
}

class UnlockOk extends UnlockResult {
  const UnlockOk();
}

class UnlockWrong extends UnlockResult {
  const UnlockWrong({required this.failures, required this.lockedFor});
  final int failures;

  /// Non-zero when this failure started a lockout.
  final Duration lockedFor;
}

class UnlockThrottled extends UnlockResult {
  const UnlockThrottled(this.remaining);
  final Duration remaining;
}

/// Brute-force back-off. Failures 1-4 are free; from the 5th on the delay
/// escalates 30 s, 1 min, 5 min, 15 min, 1 h (then stays at 1 h).
Duration appLockDelayForFailures(int failures) {
  const free = 4;
  const steps = [
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 15),
    Duration(hours: 1),
  ];
  if (failures <= free) return Duration.zero;
  final i = failures - free - 1;
  return steps[i >= steps.length ? steps.length - 1 : i];
}

/// Owns the app passcode record, configuration and persisted throttle.
/// Deliberately independent from the CIE PIN and its throttle.
class AppLockService {
  AppLockService({
    AppLockStorage? storage,
    PasscodeHasher hasher = const PasscodeHasher(),
    DateTime Function()? clock,
  }) : _storage = storage ?? const SecureAppLockStorage(),
       _hasher = hasher,
       _clock = clock ?? DateTime.now;

  static const recordKey = 'opencie_app_lock_secret';
  static const configKey = 'opencie_app_lock_config';
  static const throttleKey = 'opencie_app_lock_throttle';

  /// Minimum passcode length.
  static const minLength = 4;

  /// Longest passcode the UI accepts.
  static const maxLength = 16;

  final AppLockStorage _storage;
  final PasscodeHasher _hasher;
  final DateTime Function() _clock;

  PasscodeRecord? _record;
  int _failures = 0;
  DateTime? _lockedUntil;

  static bool isValidPasscode(String s) =>
      s.length >= minLength &&
      s.length <= maxLength &&
      RegExp(r'^[0-9]+$').hasMatch(s);

  /// Loads persisted state. A storage failure with nothing read is treated
  /// as "not enabled"; the caller may surface the exception.
  Future<AppLockConfig> load() async {
    _record = PasscodeRecord.tryParse(await _storage.read(recordKey));
    var timeout = AutoLockTimeout.oneMinute;
    var bio = false;
    final rawCfg = await _storage.read(configKey);
    if (rawCfg != null) {
      try {
        final m = jsonDecode(rawCfg) as Map<String, dynamic>;
        timeout = AutoLockTimeout.byNameOr(m['timeout'] as String?, timeout);
        bio = m['biometrics'] as bool? ?? false;
      } catch (_) {}
    }
    _failures = 0;
    _lockedUntil = null;
    final rawThr = await _storage.read(throttleKey);
    if (rawThr != null) {
      try {
        final m = jsonDecode(rawThr) as Map<String, dynamic>;
        _failures = (m['failures'] as int?) ?? 0;
        final until = m['until'] as int?;
        if (until != null) {
          _lockedUntil = DateTime.fromMillisecondsSinceEpoch(until);
        }
      } catch (_) {}
    }
    return AppLockConfig(
      enabled: _record != null,
      timeout: timeout,
      biometrics: bio && _record != null,
    );
  }

  bool get hasPasscode => _record != null;
  int get failures => _failures;

  /// Remaining brute-force lockout (zero when entry is allowed).
  Duration get throttleRemaining {
    final until = _lockedUntil;
    if (until == null) return Duration.zero;
    var left = until.difference(_clock());
    // Guard against a clock moved backwards: never exceed the max step.
    const cap = Duration(hours: 1);
    if (left > cap) left = cap;
    return left.isNegative ? Duration.zero : left;
  }

  Future<void> saveConfig(AppLockConfig c) => _storage.write(
    configKey,
    jsonEncode({'timeout': c.timeout.name, 'biometrics': c.biometrics}),
  );

  /// Stores a new passcode (enabling the lock) and resets the throttle.
  Future<void> setPasscode(String passcode) async {
    if (!isValidPasscode(passcode)) {
      throw ArgumentError('Invalid passcode');
    }
    final rec = await _hasher.create(passcode);
    await _storage.write(recordKey, jsonEncode(rec.toJson()));
    _record = rec;
    await _resetThrottle();
  }

  Future<UnlockResult> verify(String passcode) async {
    final rec = _record;
    if (rec == null) return const UnlockOk();
    final remaining = throttleRemaining;
    if (remaining > Duration.zero) return UnlockThrottled(remaining);
    if (await _hasher.verify(rec, passcode)) {
      await _resetThrottle();
      return const UnlockOk();
    }
    _failures++;
    final delay = appLockDelayForFailures(_failures);
    _lockedUntil = delay > Duration.zero ? _clock().add(delay) : null;
    await _persistThrottle();
    return UnlockWrong(failures: _failures, lockedFor: delay);
  }

  /// Records a successful biometric unlock (clears the throttle).
  Future<void> noteBiometricSuccess() => _resetThrottle();

  /// Removes the passcode and configuration (lock disabled). Caller must
  /// have verified the current passcode first.
  Future<void> disable() async {
    await _storage.delete(recordKey);
    await _storage.delete(configKey);
    await _storage.delete(throttleKey);
    _record = null;
    _failures = 0;
    _lockedUntil = null;
  }

  Future<void> _resetThrottle() async {
    _failures = 0;
    _lockedUntil = null;
    await _storage.delete(throttleKey);
  }

  Future<void> _persistThrottle() => _storage.write(
    throttleKey,
    jsonEncode({
      'failures': _failures,
      'until': _lockedUntil?.millisecondsSinceEpoch,
    }),
  );
}

/// Decides when the app must lock. Pure logic with an injectable clock.
class AutoLockPolicy {
  AutoLockPolicy({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  DateTime? _leftAt;
  bool _backgrounded = false;
  DateTime _lastActivity = DateTime.fromMillisecondsSinceEpoch(0);

  /// The app lost focus / was hidden. [background] is true for a real
  /// background or minimize (hidden/paused), false for a mere blur
  /// (inactive: system dialogs, focus loss, app switcher).
  void left({required bool background}) {
    _leftAt ??= _clock();
    if (background) _backgrounded = true;
  }

  /// True when leaving in the background should lock right now (the
  /// "immediately" option), without waiting for the return.
  bool shouldLockOnLeave(AutoLockTimeout t, {required bool background}) =>
      t == AutoLockTimeout.immediately && background;

  /// The app is foreground again; returns whether it must now be locked.
  bool returned(AutoLockTimeout t) {
    final at = _leftAt;
    final bg = _backgrounded;
    _leftAt = null;
    _backgrounded = false;
    _lastActivity = _clock();
    if (at == null) return false;
    if (t == AutoLockTimeout.immediately) return bg;
    return _clock().difference(at) >= t.duration;
  }

  void activity() => _lastActivity = _clock();

  /// Desktop idle check while focused: input-free time >= timeout.
  bool idleExpired(AutoLockTimeout t) {
    if (t == AutoLockTimeout.immediately) return false;
    return _clock().difference(_lastActivity) >= t.duration;
  }
}
